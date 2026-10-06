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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            form
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.spacing24)
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
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("服务器地址").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Metrics.spacing8) {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    TextField("输入 FTP 服务器地址", text: $model.address)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("FTP 服务器地址")
                        .disabled(!model.canEditConnection)
                        .focused($focus, equals: .address)
                        .onSubmit { model.connect() }
                }
                Text("支持 ftp:// 地址或主机名，例如 ftp://example.com:21/uploads")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                fieldError(.address)
            }

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("登录方式").font(.caption).foregroundStyle(.secondary)
                Picker("登录方式", selection: $model.loginMode) {
                    ForEach(FTPLoginMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canEditConnection)
            }

            if model.loginMode == .account {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    HStack(alignment: .top, spacing: Metrics.spacing12) {
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text("用户名").font(.caption).foregroundStyle(.secondary)
                            TextField("用户名", text: $model.username)
                                .accessibilityLabel("用户名")
                                .focused($focus, equals: .username)
                            fieldError(.username)
                        }
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text("密码").font(.caption).foregroundStyle(.secondary)
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
                                    .font(.caption).foregroundStyle(.orange)
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
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Metrics.spacing12) {
                status
                Spacer(minLength: Metrics.spacing8)
                Button("连接") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConnect)
            }

            errors
        }
        .padding(Metrics.spacing24)
        .frame(maxWidth: Metrics.formMaxWidth)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).strokeBorder(.quaternary, lineWidth: 1))
        .onAppear { passwordText = model.password ?? "" }
    }

    /// The reason for one field, placed under that field. Errors wrap instead of
    /// truncating so the whole reason stays readable in the minimum window.
    @ViewBuilder
    private func fieldError(_ field: FTPFormField) -> some View {
        if let issue = model.fieldIssue, issue.field == field {
            Text(issue.message)
                .font(.caption).foregroundStyle(.red)
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
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: model.directoryError == nil ? "circle" : "exclamationmark.circle.fill")
                Text(model.directoryError == nil ? "未连接" : "连接失败")
            }
            .font(.caption)
            .foregroundStyle(model.directoryError == nil ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private var errors: some View {
        if let error = model.credentialError ?? model.sites.error {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        if let error = model.directoryError {
            HStack(spacing: Metrics.spacing8) {
                Label("连接失败", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Spacer(minLength: Metrics.spacing8)
                Button("查看详情") { showError = true }
                    .help("查看目录错误详情（⌘⇧D）")
                    .popover(isPresented: $showError, arrowEdge: .trailing) {
                        TextDetailsPopover(title: "连接与目录错误", text: error) { showError = false }
                    }
            }
            .font(.caption)
        }
    }
}
