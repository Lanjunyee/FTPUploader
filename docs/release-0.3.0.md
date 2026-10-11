# v0.3.0 发行候选与剩余门槛

本页不代表已发布。新版源码已进入 GitHub main；本次只准备本地候选，旧 v0.2.0 安装包保持不变。

## 当前状态

- [x] 独立公开源码分支，未导入原私有历史、真实服务器资料或内部验收日志。
- [x] 应用 Debug／Release 版本设为 0.3.0，构建号 3。
- [x] Release 配置启用 Hardened Runtime，继续保留 sandbox 和必要的客户端网络、文件授权、安全书签权限；禁用基础调试权限注入。
- [x] 通用 Release 构建、两架构最低 macOS 15 声明和本地产物版本检查。
- [x] 包内 libssh2／OpenSSL 许可证、系统动态链接检查。
- [x] 本地 ad-hoc runtime 签名、无 get-task-allow、严格签名验证。
- [x] 通用 ZIP、SHA256 校验、解压后签名与主程序一致性检查。
- [x] 本地非隔离候选启动检查；不等同 Gatekeeper 隔离首启。
- [ ] Developer ID Application 签名及可信时间戳。
- [ ] Apple 公证 Accepted、日志检查、票据装订与验证。
- [ ] 从最终下载包进行隔离环境 Gatekeeper 与首次启动检查。
- [ ] 实际 macOS 15、Intel 硬件启动／双向传输／取消及安全确认验收。

2026-10-11 本地候选：版本 0.3.0（构建 3），ZIP 约 8 MiB；签名 flags 为 adhoc + runtime。解压后的候选实际启动并保持运行，探针仅结束其自己启动的实例，不操作原有应用或发起传输。没有删除 quarantine 或修改系统安全设置，未将此项记为 Gatekeeper 验收。

失败保留：初次审计脚本将新版 codesign 默认文本输出误作 XML plist，解析失败；构建本身成功。加入 `--xml` 后全项检查通过。失败产物目录单独保留，未覆盖日志；最终包只使用第二次成功结果。

完整公开源码先前已在 macOS 27.0.1 / Apple Silicon 上完成 arm64 和 Rosetta 各 294 项测试；本候选的版本／运行时配置变更仍需在最终签名产物上检查。本机 Hardened Runtime flag 与 ad-hoc 验证不等同正式 Developer ID 发行验证。

## 本地打包

先准备固定版本静态依赖，再运行：

```sh
bash script/prepare_release_candidate.sh
```

产物在 `dist/release-candidate/`，包含通用 ZIP、SHA256SUMS、签名／链接／构建审计日志及解压检查副本。脚本拒绝覆盖已有输出，不下载证书、不公证、不上传、不创建标签或 Release。ZIP 名称明确标为 `local-candidate`；不要将整个输出目录作为 GitHub 附件上传，原始日志可能包含本机路径。

## Developer ID Application 准备

由开发者账户持有人在 Apple 开发者账户操作，不在聊天、仓库或脚本中提供秘密：

1. 确认 Apple Developer Program 会员有效，并具有创建 Developer ID 所需的角色。Apple 官方说明要求 Account Holder；如果是团队成员，请由账户持有人处理。
2. 在这台 Mac 的“钥匙串访问 → 证书助理 → 从证书颁发机构请求证书”生成 CSR，保存到磁盘。私钥留在本机钥匙串。
3. 在 Certificates, Identifiers & Profiles 新建 **Developer ID Application**，上传 CSR，下载并安装证书。不要选 Developer ID Installer、Apple Development 或 Apple Distribution；不要撤销现有证书。
4. 确保证书在钥匙串中有对应私钥。用下面只读命令检查：

```sh
security find-identity -v -p codesigning
```

应出现有效 `Developer ID Application: ...` 身份。仅证书文件、缺少私钥不能用于签名。

官方步骤：[Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)。

## 公证凭据：由用户在本机安全保存

在 Apple Account 页面创建 App-specific password。密码不放在命令参数、不写入环境文件或聊天。以下命令让 notarytool 交互询问并存到钥匙串；账户与 TEAM_ID 使用 Developer ID 对应的有效团队：

```sh
xcrun notarytool store-credentials "FTPUploader-notary" \
  --apple-id "你的 Apple 账户" --team-id "你的 TEAM_ID"
```

输入时不会回显密码。完成后只提供钥匙串 profile 名称即可；不要发送密码或私钥。也可使用合法 App Store Connect API key，但其私钥必须本机安全保存。

官方说明：[TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)。

## 正式签名后才能继续的步骤

证书、私钥和公证 profile 就绪，并获得明确使用授权后，重新生成发行产物；保留 Hardened Runtime、使用可信时间戳和正确 entitlements，核对 TeamIdentifier、嵌套代码、资源封印及权限。提交最终签名 ZIP 至 Apple，等待 Accepted 并检查公证日志；失败时不继续。

票据装订到 app 后重新打包并重算 SHA256，对最终解压包验证签名、票据、双架构及版本。隔离下载首启须使用最终包，不能先去掉 quarantine 或改系统安全设置来冒充通过。正式发行前还需实际 macOS 15／Intel 环境证据。

## 目前的阻塞

本机只有 Apple Development／Apple Distribution 身份，没有 Developer ID Application。工具 notarytool 与 stapler 已安装，但没有取得可用公证 profile。当前没有 macOS 15／Intel 验收设备。这些门槛不能用编译、Rosetta、ad-hoc 或修改系统偏好替代；保持未完成，不公开声称“已全部补齐”。
