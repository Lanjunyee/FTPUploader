import XCTest

private final class MailboxTestScheduler: @unchecked Sendable {
    struct Entry { let delay: Double; let item: DispatchWorkItem }
    private let lock = NSLock()
    private var time = 0.0
    private var entries: [Entry] = []
    func clock() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func setTime(_ value: Double) { lock.lock(); time = value; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.filter { !$0.item.isCancelled }.count }
    func schedule(_ delay: Double, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        lock.lock(); entries.append(Entry(delay: delay, item: item)); lock.unlock()
        return item
    }
    func take() throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { throw FTPError.localFile("Missing scheduled delivery") }
        return entries.removeFirst()
    }
}

@MainActor
final class TransferMetricsTests: XCTestCase {
    func testConcurrentMailboxCallbacksQueueOneDeliveryAndUseMonotonicClockSlots() async throws {
        let scheduler = MailboxTestScheduler(), generation = UUID()
        var samples: [TransferProgressMailbox.Sample] = []
        let first = expectation(description: "first merged sample"), second = expectation(description: "second merged sample")
        let mailbox = TransferProgressMailbox(generation: generation, clock: scheduler.clock, schedule: scheduler.schedule) { sample in
            samples.append(sample)
            if samples.count == 1 { first.fulfill() } else { second.fulfill() }
        }
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            mailbox.submit(bytes: Int64(index), total: 20_000, generation: generation)
        }
        XCTAssertEqual(mailbox.pendingNotificationCount, 1); XCTAssertEqual(scheduler.count, 1)
        XCTAssertTrue(samples.isEmpty)
        let immediate = try scheduler.take(); XCTAssertEqual(immediate.delay, 0); immediate.item.perform()
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(samples.map(\.bytes), [9_999]); XCTAssertEqual(mailbox.pendingNotificationCount, 0)
        scheduler.setTime(0.1)
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            mailbox.submit(bytes: Int64(10_000 + index), total: -1, generation: generation)
        }
        XCTAssertEqual(scheduler.count, 1); XCTAssertEqual(mailbox.pendingNotificationCount, 1)
        let delayed = try scheduler.take(); XCTAssertEqual(delayed.delay, 0.9, accuracy: 0.000_001)
        scheduler.setTime(0.5); delayed.item.perform()
        let deadline = Date().addingTimeInterval(2)
        while scheduler.count == 0 && Date() < deadline { await Task.yield() }
        XCTAssertEqual(samples.count, 1); XCTAssertEqual(scheduler.count, 1)
        XCTAssertEqual(mailbox.pendingNotificationCount, 1)
        let remaining = try scheduler.take(); XCTAssertEqual(remaining.delay, 0.5, accuracy: 0.000_001)
        scheduler.setTime(1); remaining.item.perform()
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(samples.map(\.bytes), [9_999, 19_999]); XCTAssertEqual(samples.last?.total, -1)
        XCTAssertEqual(mailbox.pendingNotificationCount, 0); mailbox.stop()
    }
    func testMailboxGenerationStopAndSubmissionsDuringDeliveryDoNotCreateExtraNotifications() async throws {
        let scheduler = MailboxTestScheduler(), generation = UUID(), first = expectation(description: "delivery")
        var samples: [TransferProgressMailbox.Sample] = []
        var mailbox: TransferProgressMailbox!
        mailbox = TransferProgressMailbox(generation: generation, clock: scheduler.clock, schedule: scheduler.schedule) { sample in
            samples.append(sample)
            XCTAssertEqual(mailbox.pendingNotificationCount, 1)
            mailbox.submit(bytes: 200, total: 500, generation: generation)
            mailbox.submit(bytes: 150, total: 500, generation: generation)
            XCTAssertEqual(scheduler.count, 0, "No extra callback while a delivery is executing")
            first.fulfill()
        }
        mailbox.submit(bytes: 99, total: 100, generation: UUID())
        mailbox.submit(bytes: -1, total: 100, generation: generation)
        XCTAssertEqual(scheduler.count, 0)
        mailbox.submit(bytes: 100, total: 50, generation: generation)
        let item = try scheduler.take(); item.item.perform()
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(samples.first?.bytes, 100); XCTAssertEqual(samples.first?.total, 100)
        XCTAssertEqual(mailbox.pendingNotificationCount, 1); XCTAssertEqual(scheduler.count, 1)
        let delayed = try scheduler.take(); XCTAssertEqual(delayed.delay, 1)
        mailbox.stop(); XCTAssertTrue(delayed.item.isCancelled)
        mailbox.submit(bytes: 999, total: 999, generation: generation)
        scheduler.setTime(10); delayed.item.perform(); await Task.yield()
        XCTAssertEqual(samples.count, 1); XCTAssertEqual(mailbox.pendingNotificationCount, 0)
        mailbox = nil
    }

    func testContentSentControlIsImmediateOnceAndIndependentOfQueuedDisplay() async throws {
        let scheduler = MailboxTestScheduler(), control = expectation(description: "immediate phase hint")
        var controls = 0, displays = 0
        let id = UUID()
        let mailbox = TransferProgressMailbox(generation: id, clock: scheduler.clock, schedule: scheduler.schedule,
            contentSent: { controls += 1; control.fulfill() }, deliver: { _ in displays += 1 })
        mailbox.submit(bytes: 100, total: 100, generation: id)
        for _ in 0..<10_000 { mailbox.signalContentSent() }
        await fulfillment(of: [control], timeout: 2)
        XCTAssertEqual(controls, 1); XCTAssertEqual(displays, 0)
        XCTAssertEqual(mailbox.pendingNotificationCount, 1); XCTAssertEqual(scheduler.count, 1)
        mailbox.stop(); let item = try scheduler.take(); XCTAssertTrue(item.item.isCancelled)
        mailbox.signalContentSent(); await Task.yield(); XCTAssertEqual(controls, 1)
    }
    func testFrozenCounterOverflowIsUnknownInHistoryAndLateCallbacksCannotChangeIt() async throws {
        let counter = TransferByteCounter()
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in counter.receive(1) }
        XCTAssertEqual(counter.bytes, 10_000); counter.sample(20_000); XCTAssertEqual(counter.bytes, 20_000)
        counter.finish(); counter.receive(30_000); counter.sample(99_999); XCTAssertEqual(counter.bytes, 20_000)
        let request = TransferJob(direction: .download, endpoint: try FTPEndpoint(address: "example.test"), path: .root,
            encoding: .utf8, credentials: .anonymous, localURL: URL(fileURLWithPath: "/tmp/count-only"))
        request.byteCounter.receive(Int.max); request.byteCounter.receive(Int.max)
        request.byteCounter.finish(); XCTAssertTrue(request.byteCounter.hasOverflow)
        XCTAssertEqual(request.byteCounter.bytes, Int64.max)
        request.byteCounter.receive(1); request.byteCounter.sample(1); XCTAssertEqual(request.byteCounter.bytes, Int64.max)
        request.finish(.succeeded)
        let history = isolatedHistory(); history.record(request, target: "count-only", bytes: request.byteCounter.bytes)
        try await history.drain()
        XCTAssertEqual(history.records.first?.trafficOverflow, true)
        let loaded = TransferHistory(url: history.url); try await loaded.drain()
        XCTAssertEqual(loaded.records.first?.trafficOverflow, true)
        let activity = TransferActivity(source: .download, direction: .download, phase: .succeeded, name: "overflow", target: nil,
            bytes: Int64.max, trafficOverflow: true, total: Int64.max)
        XCTAssertNil(activity.contentFraction)
        XCTAssertNil(TransferSummary.sum([request.byteCounter.bytes, 1]))
        let zero = TransferByteCounter(); zero.receive(0); zero.sample(0); zero.finish(); XCTAssertEqual(zero.bytes, 0)
    }
    func testFiveSecondWindowStallUnknownZeroAndOutOfOrder() {
        var metrics = TransferMetrics()
        metrics.sample(bytes: 0, total: 1000, at: 0)
        metrics.sample(bytes: 100, total: 1000, at: 1)
        metrics.sample(bytes: 600, total: 1000, at: 6)
        XCTAssertEqual(metrics.estimate(at: 6).speed!, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.estimate(at: 6).remaining!, 4, accuracy: 0.001)
        metrics.sample(bytes: 2, total: 1000, at: 5)
        XCTAssertEqual(metrics.bytes, 600)
        XCTAssertNil(metrics.estimate(at: 11).speed)
        metrics.sample(bytes: 700, total: -1, at: 12); XCTAssertNil(metrics.estimate(at: 12).remaining)
        var empty = TransferMetrics(); empty.sample(bytes: 0, total: 0, at: 1)
        XCTAssertNil(empty.estimate(at: 1).speed); XCTAssertNil(empty.estimate(at: 1).remaining)
    }
    func testMetricPresentationAtMostOncePerSecond() {
        var now = 0.0; let monitor = TransferMetricsMonitor(clock: { now })
        monitor.reset(total: 100)
        XCTAssertTrue(monitor.update(bytes: 1, total: 100))
        now = 0.2; XCTAssertFalse(monitor.update(bytes: 2, total: 100))
        now = 0.9; XCTAssertFalse(monitor.emit())
        now = 1; XCTAssertTrue(monitor.emit()); XCTAssertEqual(monitor.estimate.bytes, 2)
        monitor.stop()
    }
}
