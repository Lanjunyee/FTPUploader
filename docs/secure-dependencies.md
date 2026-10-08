# SFTP 依赖、构建与更新

本阶段固定 libssh2 1.11.1（BSD 风格许可证）与 OpenSSL 3.5.9 LTS（Apache-2.0）。来源为 [libssh2 官方发布](https://github.com/libssh2/libssh2/releases/tag/libssh2-1.11.1) 与 [OpenSSL 官方发布](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9)。官方 [OpenSSL 生命周期](https://openssl-library.org/source/)列出 3.5 LTS 支持至 2030-04-08。版本及 SHA256 固定在 `script/build_secure_dependencies.sh`；OpenSSL 摘要与官方随包 SHA256 一致。许可全文位于本目录的 `licenses/`，发行包必须包含这两个许可。

开发机需 Xcode、CMake、Perl、make、curl；用户运行应用无需安装这些工具或 Homebrew。执行 `script/build_secure_dependencies.sh` 从官方源下载并验证摘要，分别用 macOS 13 部署目标编译 arm64/x86_64，合并静态 libssh2 与 libcrypto。关闭动态模块、外部 engine 和 zlib 压缩，应用静态链接两库，不加载用户安装的加密库。产物位于 `.build/secure-deps/universal/`，不将 Homebrew 单架构二进制当发布依赖。

测试 SSH 服务使用项目隔离环境：用 Python 3.12 建立 `.build/ssh-fixture-env`，安装 `paramiko==4.0.0`。这是本机测试依赖，不随应用打包。执行 `script/verify_ssh_dependencies.sh` 构建两架构最小探针，并置于具有本应用网络客户端沙盒权限的应用包中签名，验证无认证握手及取消。

2026-10-08 验证：两架构静态库构建成功；arm64 沙盒握手 0.004 秒、取消 0.202 秒；x86_64 经 Rosetta 沙盒握手 0.007 秒、取消 0.203 秒。独立命令行文件附加 App Sandbox 权限会因没有应用包而启动失败，改用正常应用包后通过。宿主为当前 macOS，未在 macOS 13 或 Intel 真机运行；面向 macOS 13 的编译和 Rosetta 不能替代这些实测。

每次发布前检查两个上游的安全公告和支持期限。升级须明确更新版本与摘要，重新构建两架构、检查静态链接路径、执行握手/取消和完整四协议矩阵，并保存证据。不得自动下载不固定版本或跳过摘要验证。最低系统或架构验收失败时停止发布，不自动退回缺失 SFTP 的系统 libcurl。
