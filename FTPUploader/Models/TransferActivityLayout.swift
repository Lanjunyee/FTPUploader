import Foundation

/// Presentation contract, independent of the former fixed upload-bar row count.
enum TransferActivityLayout {
    enum Region: Equatable { case summary, warning }
    static func regions(for activity: TransferActivity?) -> [Region] {
        guard let activity else { return [] }
        return activity.warning == nil && !activity.targetDiffers ? [.summary] : [.summary, .warning]
    }
    static func targets(for activity: TransferActivity) -> [(title: String, text: String)] {
        var targets: [(title: String, text: String)] = []
        if let target = activity.target {
            targets.append((activity.source == .pending ? "待上传目标" : "本次传输目标", target))
        }
        if activity.targetDiffers, let prior = activity.previousTarget { targets.append(("上次上传结果目标", prior)) }
        return targets
    }
    static func details(for activity: TransferActivity, target: (title: String, text: String)) -> String {
        if target.title == "上次上传结果目标" { return target.title + "：" + target.text }
        var lines = [activity.title, "名称：" + activity.name, target.title + "：" + target.text]
        if activity.kind == .directory { lines.append("类型：文件夹；大小不适用") }
        else { lines.append("大小：" + bytes(activity.total)) }
        lines.append("已传内容：" + bytes(activity.bytes))
        if let summary = activity.summary {
            lines.append("文件 \(summary.completedFiles)/\(summary.fileCount) · 目录 \(summary.completedDirectories)/\(summary.directoryCount) 已结束")
            lines.append("成功 \(summary.succeeded) · 失败 \(summary.failed) · 取消 \(summary.cancelled) · 跳过 \(summary.skipped) · 阻塞 \(summary.blocked)")
            lines.append("成功字节：" + bytes(summary.successfulBytes))
            lines.append("本队列实际流量：" + bytes(summary.actualBytes))
            lines.append("会话实际流量（含重试）：" + bytes(activity.sessionTraffic))
        }
        if let estimate = activity.estimate {
            lines.append("速度估算：" + (estimate.speed.map { $0.formatted(.number.precision(.fractionLength(0))) + " 字节/秒" } ?? "估算中"))
            if let total = activity.total, total > 0, let remaining = estimate.remaining {
                lines.append("估算剩余：" + remaining.rounded(.up).formatted(.number.precision(.fractionLength(0))) + " 秒")
            }
        }
        if let warning = activity.warning { lines.append(warning) }
        return lines.joined(separator: "\n")
    }
    static func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
    }
}
