import AppKit
import SwiftUI

@MainActor
struct SiteManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sites: SiteManager
    @State private var selection: UUID?
    @State private var draft: SiteDraft?
    @State private var editorIssue: FieldIssue?
    @State private var editorIssueTicket = 0
    @State private var pendingDelete: FTPSite?

    init(model: AppModel) { self.model = model; self.sites = model.sites }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if sites.isSaving || sites.isRecovering { ProgressView().controlSize(.small) }
            }
            if draft != nil {
                ScrollView {
                    SiteEditor(draft: Binding(get: { draft ?? SiteDraft() }, set: { draft = $0 }), issue: editorIssue, issueTicket: editorIssueTicket)
                        .disabled(!model.canEditConnection)
                }.frame(minHeight: 240, maxHeight: 360)
            } else {
                List(selection: $selection) {
                    ForEach(sites.sites) { site in
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text(site.name)
                            Text("\(site.transport.title) · \(site.address) · \(site.authenticationMethod == .privateKey ? site.authenticationMethod.title : site.loginMode.title)").font(.caption).foregroundStyle(.secondary)
                        }.tag(site.id)
                    }
                }.frame(minHeight: 180, maxHeight: 280)
                if sites.sites.isEmpty { Text("尚未保存站点，可新增或保存当前连接配置。").foregroundStyle(.secondary) }
                HStack {
                    Button("新增") { beginEditing(SiteDraft()) }.disabled(!sites.canSave || !model.canEditConnection)
                    Button("保存当前配置…") { beginEditing(model.siteDraft()) }.disabled(!sites.canSave || !model.canEditConnection)
                    Button("编辑") {
                        if let site = selected { beginEditing(SiteDraft(site: site)) }
                    }.disabled(selected == nil || !sites.canSave || !model.canEditConnection)
                    Button("删除…", role: .destructive) { pendingDelete = selected }
                        .disabled(selected == nil || !sites.canSave || !model.canEditConnection)
                }
            }
            if let error = sites.error {
                Label { Text(error).foregroundStyle(.primary).textSelection(.enabled) } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .font(.callout)
            }
            if sites.isRecovering {
                Text("正在恢复本机站点事务，不会连接服务器…").font(.callout).foregroundStyle(.secondary)
            } else if sites.canRetryRecovery {
                Button("重试站点恢复／清理") { Task { await sites.retryRecovery() } }
                    .disabled(!model.canEditConnection)
            }
            Divider()
            HStack {
                if draft != nil {
                    Button("取消编辑") { endEditing() }.disabled(sites.isSaving).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存") { save() }.disabled(!model.canEditConnection || !sites.canSave).keyboardShortcut(.defaultAction)
                } else {
                    Text("选择或保存站点不会自动连接。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(Metrics.spacing24)
        .frame(minWidth: 560, minHeight: 420)
        .alert("删除本机站点？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let site = pendingDelete else { return }
                Task { if await model.deleteSite(site) { selection = nil }; pendingDelete = nil }
            }
        } message: { Text("将删除该站点的本机配置、私钥关联和保存密码，不删除源私钥或修改服务器文件。") }
    }

    /// A draft whose UUID belongs to an already saved site is an edit; anything
    /// else (new draft, or "save current configuration") is a new site.
    private var editingSavedSite: Bool {
        guard let draft else { return false }
        return sites.sites.contains { $0.id == draft.id }
    }

    private var title: String {
        guard draft != nil else { return "站点管理" }
        return editingSavedSite ? "编辑站点" : "新增站点"
    }

    private func beginEditing(_ value: SiteDraft) {
        sites.clearEditingError()
        editorIssue = nil
        draft = value
    }

    private func endEditing() {
        sites.clearEditingError()
        editorIssue = nil
        draft = nil
    }

    private func save() {
        guard let value = draft else { return }
        // Validate with the same model the save path uses, so the reason lands on
        // the owning field without a storage round trip.
        do { _ = try value.configuration() }
        catch let issue as FieldIssue { raise(issue); return }
        catch { /* storage or keychain failures surface from SiteManager below */ }
        editorIssue = nil
        Task {
            if await model.saveSite(value) {
                selection = value.id
                draft = nil
            } else if let issue = model.sites.fieldIssue {
                raise(issue)
            }
        }
    }

    private func raise(_ issue: FieldIssue) {
        editorIssue = issue
        editorIssueTicket += 1
    }

    private var selected: FTPSite? { sites.sites.first { $0.id == selection } }
}

private struct SiteEditor: View {
    @Binding var draft: SiteDraft
    let issue: FieldIssue?
    let issueTicket: Int
    @FocusState private var focus: Field?
    @State private var identityChanged = false
    @State private var originalTransport = FileTransport.ftp
    /// See ConnectionView: a direct nil/"" binding marks "explicit empty password"
    /// as soon as an untouched field is focused.
    @State private var passwordText = ""
    @State private var localKeyIssue: FieldIssue?

    private enum Field: Hashable { case server, port, initialDirectory, username, password, privateKey, passphrase }

    var body: some View {
        Form {
            TextField("名称", text: $draft.name)
            Picker("传输协议与安全模式", selection: $draft.transport) {
                ForEach(FileTransport.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("站点传输协议与安全模式")
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                TextField("服务器", text: $draft.host)
                    .focused($focus, equals: .server)
                Text("主机名或 IP，例如 example.com 或 127.0.0.1；端口和目录使用下方独立字段。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                fieldError(.server)
            }
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                TextField("端口", text: $draft.port)
                    .focused($focus, equals: .port)
                fieldError(.port)
            }
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                TextField("初始目录", text: $draft.initialDirectory)
                    .focused($focus, equals: .initialDirectory)
                fieldError(.initialDirectory)
            }
            Picker("文件名编码", selection: $draft.encodingPolicy) {
                ForEach(FTPEncodingPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("站点文件名编码")
            .disabled(draft.transport == .sftp)
            if draft.transport == .sftp {
                Picker("认证方式", selection: $draft.authenticationMethod) {
                    ForEach(AuthenticationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            } else {
                Picker("登录方式", selection: $draft.loginMode) {
                    ForEach(FTPLoginMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if draft.loginMode == .account {
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    TextField("用户名", text: $draft.username)
                        .focused($focus, equals: .username)
                    fieldError(.username)
                }
                if draft.authenticationMethod == .privateKey {
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        Text("私钥文件").font(.callout)
                        HStack {
                            Text(draft.privateKeySelection?.name ?? draft.privateKeyReference?.name ?? "尚未选择私钥").lineLimit(1)
                            Spacer()
                            Button("选择私钥…") { chooseKey() }.focusable().focused($focus, equals: .privateKey)
                        }
                        if let path = draft.privateKeySelection?.url.path ?? draft.privateKeyReference.flatMap({ try? PrivateKeyAccess().resolve($0.bookmark).path }) {
                            Text(path).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        fieldError(.privateKey)
                        Text("私钥口令").font(.callout)
                        SecureField("私钥口令", text: Binding(get: { draft.passphrase ?? "" }, set: { draft.passphrase = $0 }))
                            .accessibilityLabel("站点私钥口令").focused($focus, equals: .passphrase)
                        fieldError(.passphrase)
                        Text(identityChanged ? "连接信息或私钥已变更，请重新输入私钥口令。" : "口令用于解锁私钥，仅保留在当前连接会话；保存站点不保存口令。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    SecureField("密码", text: $passwordText)
                        .accessibilityLabel("站点密码")
                        .focused($focus, equals: .password)
                        .onChange(of: passwordText) { value in
                            if value != (draft.password ?? "") { draft.password = value }
                        }
                        .onChange(of: draft.password) { value in
                            let text = value ?? ""
                            if text != passwordText { passwordText = text }
                        }
                    if identityChanged && draft.password == nil {
                        Text("连接信息已变更，请重新输入密码或明确选择使用空密码。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    fieldError(.password)
                }
                Toggle("使用空密码", isOn: Binding(
                    get: { draft.password == "" },
                    set: { on in draft.password = on ? "" : nil; passwordText = "" }
                ))
                Text("“使用空密码”表示显式发送空密码，而不是跳过认证。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("记住密码", isOn: $draft.rememberPassword)
                Text(draft.rememberPassword ? "保存后使用系统钥匙串。身份不变且不填写新密码时，保留原保存密码。" : "密码仅用于当前运行，重新打开时需输入。")
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: issueTicket) { _ in
            guard let issue else { return }
            focus = focusTarget(for: issue.field)
        }
        .onAppear { passwordText = draft.password ?? ""; originalTransport = draft.transport }
        .onChange(of: draft.password) { value in
            if value != nil { identityChanged = false }
        }
        .onChange(of: draft.transport) { value in
            invalidateIdentity()
            // Preserve custom ports; replace only the previous protocol default.
            let oldDefault = originalTransport.defaultPort
            if draft.port == String(oldDefault) { draft.port = String(value.defaultPort) }
            originalTransport = value
            if value == .sftp { draft.loginMode = .account; draft.encodingPolicy = .utf8 }
            else { draft.authenticationMethod = .password; draft.privateKeyReference = nil; draft.privateKeySelection = nil }
        }
        .onChange(of: draft.authenticationMethod) { _ in
            invalidateIdentity(); localKeyIssue = nil
            if draft.authenticationMethod == .privateKey { draft.rememberPassword = false }
        }
        .onChange(of: draft.passphrase) { value in if value != nil { identityChanged = false } }
        .onChange(of: draft.host) { _ in invalidateIdentity() }
        .onChange(of: draft.port) { _ in invalidateIdentity() }
        .onChange(of: draft.username) { _ in invalidateIdentity() }
        .onChange(of: draft.loginMode) { mode in
            invalidateIdentity()
            if mode == .anonymous { draft.rememberPassword = false }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择私钥文件"; panel.prompt = "选择私钥"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let selected = try PrivateKeySelection.select(url)
            invalidateIdentity(); draft.privateKeySelection = selected; draft.privateKeyReference = nil
            localKeyIssue = nil
        } catch let error as FieldIssue { localKeyIssue = error; focus = .privateKey }
        catch { localKeyIssue = FieldIssue(field: .privateKey, message: "无法读取私钥，请重新选择。"); focus = .privateKey }
    }

    /// A changed identity cannot reuse an existing password. Only report it when a
    /// password was actually present, so a first empty form is not mislabelled.
    private func invalidateIdentity() {
        if draft.password != nil || draft.passphrase != nil { identityChanged = true }
        draft.password = nil; draft.passphrase = nil
    }

    @ViewBuilder
    private func fieldError(_ field: FTPFormField) -> some View {
        if let issue = localKeyIssue ?? issue, issue.field == field {
            Label { Text(issue.message).foregroundStyle(.primary) } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func focusTarget(for field: FTPFormField) -> Field? {
        switch field {
        case .server: return .server
        case .port: return .port
        case .initialDirectory: return .initialDirectory
        case .username: return .username
        case .password: return .password
        case .privateKey: return .privateKey
        case .passphrase: return .passphrase
        default: return nil
        }
    }
}
