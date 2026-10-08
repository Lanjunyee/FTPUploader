import SwiftUI

/// The unconnected state: the whole content area is the connection form.
/// Site selection lives in the toolbar, so this form covers address, login and
/// the connect action only.
@MainActor
struct ConnectionView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var showError = false
    /// The field's own text. Binding the secure field straight to `model.password`
    /// made merely focusing an empty field write `""`, which silently meant
    /// "explicit empty password" and hid the missing-password reason.
    @State private var passwordText = ""
    @FocusState private var focus: Field?

    /// The fields this form can focus; other field issues (site editor) leave focus alone.
    private enum Field: Hashable { case address, username, password }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    form
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - Metrics.spacing24 * 2))
                .padding(Metrics.spacing24)
            }
        }
        .onChange(of: bus.request) { request in
            guard request == .showDirectoryError else { return }
            showError = true
            bus.clear(.showDirectoryError)
        }
        .onChange(of: model.fieldIssueTicket) { _ in
            // Only move focus when a new reason is raised. Clearing the reason as
            // the user types must not steal focus out of the field.
            guard let issue = model.fieldIssue else { return }
            focus = focusTarget(for: issue.field)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            Picker("传输协议与安全模式", selection: $model.transport) {
                ForEach(FileTransport.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("传输协议与安全模式")
            .disabled(!model.canEditConnection)
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("服务器地址").font(.subheadline).foregroundStyle(.secondary)
                TextField("输入服务器地址", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("服务器地址")
                    .disabled(!model.canEditConnection)
                    .focused($focus, equals: .address)
                Text("支持主机名及 ftp://、ftps://、sftp:// 地址；地址需与所选协议一致。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                fieldError(.address)
            }

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("登录方式").font(.subheadline).foregroundStyle(.secondary)
                Picker("登录方式", selection: $model.loginMode) {
                    ForEach(model.transport == .sftp ? [.account] : FTPLoginMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canEditConnection)
            }

            Picker("文件名编码", selection: $model.encodingPolicy) {
                ForEach(FTPEncodingPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("文件名编码")
            .disabled(!model.canEditConnection || model.transport == .sftp)

            if model.loginMode == .account {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    HStack(alignment: .top, spacing: Metrics.spacing12) {
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text("用户名").font(.subheadline).foregroundStyle(.secondary)
                            TextField("用户名", text: $model.username)
                                .accessibilityLabel("用户名")
                                .focused($focus, equals: .username)
                            fieldError(.username)
                        }
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text("密码").font(.subheadline).foregroundStyle(.secondary)
                            SecureField("密码", text: $passwordText)
                                .accessibilityLabel("密码")
                                .focused($focus, equals: .password)
                                .onChange(of: passwordText) { value in
                                    if value != (model.password ?? "") { model.password = value }
                                }
                                .onChange(of: model.password) { value in
                                    let text = value ?? ""
                                    if text != passwordText { passwordText = text }
                                }
                            if model.identityChangedNotice {
                                Text("连接信息已变更，请重新输入密码或明确选择使用空密码。")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            fieldError(.password)
                        }
                    }
                    HStack(spacing: Metrics.spacing8) {
                        Toggle("使用空密码", isOn: Binding(
                            get: { model.password == "" },
                            set: { on in model.password = on ? "" : nil; passwordText = "" }
                        ))
                            .toggleStyle(.checkbox)
                        if model.isPasswordLoading { ProgressView().controlSize(.small) }
                    }
                    .disabled(!model.canEditConnection)
                    Text("“使用空密码”表示显式发送空密码，而不是跳过认证。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Metrics.spacing12) {
                status
                Spacer(minLength: Metrics.spacing8)
                Button("连接") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConnect)
            }

            errors
        }
        .padding(Metrics.spacing24)
        .frame(maxWidth: Metrics.formMaxWidth)
        .onAppear { passwordText = model.password ?? "" }
        .onSubmit { model.connect() }
    }

    /// The reason for one field, placed under that field. Errors wrap instead of
    /// truncating so the whole reason stays readable in the minimum window.
    @ViewBuilder
    private func fieldError(_ field: FTPFormField) -> some View {
        if let issue = model.fieldIssue, issue.field == field {
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
        case .address: return .address
        case .username: return .username
        case .password: return .password
        default: return nil
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.isDirectoryLoading {
            HStack(spacing: Metrics.spacing8) {
                ProgressView().controlSize(.small)
                Text("正在读取目录…")
            }
            .font(.callout)
            .foregroundStyle(.primary)
        } else {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: model.directoryError == nil ? "circle" : "exclamationmark.circle.fill")
                    .foregroundStyle(model.directoryError == nil ? Color.secondary : Color.orange)
                Text(model.directoryError == nil ? "未连接" : "连接失败")
            }
            .font(.callout)
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var errors: some View {
        if let error = model.credentialError ?? model.sites.error {
            Label { Text(error).foregroundStyle(.primary).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .font(.callout)
        }
        if let error = model.directoryError {
            HStack(spacing: Metrics.spacing8) {
                Label { Text("无法读取服务器目录").foregroundStyle(.primary) } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                }
                Spacer(minLength: Metrics.spacing8)
                Button("查看详情") { showError = true }
                    .help("查看目录错误详情（⌘⇧D）")
                    .popover(isPresented: $showError, arrowEdge: .trailing) {
                        TextDetailsPopover(title: "连接与目录错误", text: error) { showError = false }
                    }
            }
            .font(.callout)
        }
    }
}
