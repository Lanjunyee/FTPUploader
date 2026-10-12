import SwiftUI

/// The actual preview presentation is shared with integration tests, without
/// credentials or AppModel. All controls stay in one SwiftUI focus/environment tree.
@MainActor
struct TransferPlanPreviewContent: View {
    let plan: TransferPlan
    let canRemoveRoots: Bool
    let location: (TransferPlan.Location) -> String
    let issueTitle: (TransferPlan.Issue.Reason) -> String
    let onRemove: (UUID) -> Void
    let onConfirm: (TransferConflictPolicy) -> Void
    let onCancel: () -> Void
    @State private var policy = TransferConflictPolicy.ask
    @FocusState private var focus: Control?

    enum Control: Hashable { case policy, list, root(UUID), start, cancel }
    var removableRoots: [UUID] { canRemoveRoots ? plan.roots.map(\.id) : [] }
    static func traversal(from current: Control?, forward: Bool, roots: [UUID], canStart: Bool) -> Control {
        if case .root(let id) = current, let index = roots.firstIndex(of: id) {
            if forward { return index + 1 < roots.count ? .root(roots[index + 1]) : (canStart ? .start : .cancel) }
            return index > 0 ? .root(roots[index - 1]) : .list
        }
        return forward ? (roots.first.map { .root($0) } ?? (canStart ? .start : .cancel)) : .policy
    }
    private var listControlsFocused: Bool {
        if focus == .list { return true }
        if case .root = focus { return true }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核对传输计划").font(.title2)
            Text(plan.direction == .upload ? "上传 · 确认前不发送文件或创建目录" : "下载 · 确认前只读列表，不接收内容或创建目录")
                .fixedSize(horizontal: false, vertical: true)
            Text("文件 \(plan.nodes.filter { $0.kind == .regularFile }.count) · 目录 \(plan.nodes.filter { $0.kind == .directory }.count) · " +
                 (plan.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "总大小未知"))
            Picker("本计划同名普通文件", selection: $policy) {
                Text("逐项询问（默认）").tag(TransferConflictPolicy.ask)
                Text("本批跳过同名文件").tag(TransferConflictPolicy.skipExistingFiles)
                Text("本批覆盖同名文件").tag(TransferConflictPolicy.overwriteExistingFiles)
            }.focused($focus, equals: .policy)
            Text("目录仅合并，类型冲突禁止覆盖；检测到下载目标变化仍须独立确认。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            KeyboardPlanScrollView(active: listControlsFocused, canScroll: focus == .list, onCancel: onCancel,
                                   onTraverse: { forward in
                focus = Self.traversal(from: focus, forward: forward, roots: removableRoots, canStart: plan.canStart)
            }) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.roots) { root in
                        // Vertical layout reserves the button's width instead of
                        // letting a long root path push it outside a narrow viewport.
                        VStack(alignment: .leading, spacing: 4) {
                            PlanPathText(text: "所选根：" + location(root.source))
                            if canRemoveRoots {
                                Button("移除此根并重扫") { onRemove(root.id) }
                                    .fixedSize()
                                    .accessibilityLabel("移除 " + location(root.source) + " 并重新扫描")
                                    .focused($focus, equals: .root(root.id))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                        PlanPathText(text: "阻断：" + issueTitle(issue.reason) + "\n" + issue.path).foregroundStyle(.red)
                    }
                    ForEach(plan.nodes) { node in
                        VStack(alignment: .leading, spacing: 4) {
                            PlanPathText(text: title(node)).font(.headline)
                            PlanPathText(text: "来源：" + location(node.source))
                            PlanPathText(text: "目标：" + location(node.target))
                            if node.kind == .regularFile {
                                Text(node.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")
                            }
                            if plan.existingTargetIDs.contains(node.id) { Text("目标已存在，将按本计划策略重新核对").font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(title(node) + "\n" + details(node))
                            .id(node.id)
                        Divider()
                    }
                }.padding(8)
            }
            .focused($focus, equals: .list)
            .frame(minHeight: 100, maxHeight: .infinity)
            Button("确认开始本计划") { onConfirm(policy) }
                .disabled(!plan.canStart).focused($focus, equals: .start)
            HStack {
                Text("逐文件执行，失败/取消不回滚已成功内容。")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("取消计划", action: onCancel)
                    .keyboardShortcut(.cancelAction).focused($focus, equals: .cancel)
            }
        }
        .onAppear { focus = .policy }
        .onChange(of: plan.id) { _ in policy = .ask; focus = .policy }
    }
    private func title(_ node: TransferPlan.Node) -> String {
        (node.kind == .directory ? "目录 · " : "文件 · ") + node.relativePath.map(\.name).joined(separator: "/")
    }
    private func details(_ node: TransferPlan.Node) -> String {
        var fields = ["来源：" + location(node.source), "目标：" + location(node.target)]
        if node.kind == .regularFile {
            fields.append(node.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")
        }
        if plan.existingTargetIDs.contains(node.id) { fields.append("目标已存在，将按本计划策略重新核对") }
        return fields.joined(separator: "\n")
    }
}
