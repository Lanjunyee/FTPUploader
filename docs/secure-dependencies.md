# SFTP 依赖、构建与更新

本阶段固定 libssh2 1.11.1（BSD 风格许可证）与 OpenSSL 3.5.9 LTS（Apache-2.0）。来源为 [libssh2 官方发布](https://github.com/libssh2/libssh2/releases/tag/libssh2-1.11.1) 与 [OpenSSL 官方发布](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9)。官方 [OpenSSL 生命周期](https://openssl-library.org/source/)列出 3.5 LTS 支持至 2030-04-08。版本及 SHA256 固定在 `script/build_secure_dependencies.sh`；OpenSSL 摘要与官方随包 SHA256 一致。许可全文位于本目录的 `licenses/`，发行包必须包含这两个许可。

开发机需 Xcode、Python 3（Xcode 提供的 Python 3.9 可用）、CMake、Perl、make、curl；用户运行应用无需安装这些工具或 Homebrew。执行 `script/build_secure_dependencies.sh` 从固定官方源取得并验证摘要，分别用 macOS 13 **依赖**部署目标编译 arm64/x86_64，合并静态 libssh2 与 libcrypto；不改变应用的 macOS 15 基线。关闭动态模块、外部 engine 和 zlib 压缩，应用静态链接两库，不加载用户安装的加密库。稳定产物入口为 `.build/secure-deps/universal/`，不将 Homebrew 单架构二进制当发布依赖。

## 缓存与完成证明

版本及 SHA256 的唯一声明仍在 `script/build_secure_dependencies.sh`，实现边界为 `script/secure_dependency_cache.py`；不会自动改写 pin。fingerprint 包含源码版本/摘要、架构、部署目标、SDK 路径/版本/设置摘要、编译器、Xcode、链接器/归档器、CMake/Perl/make 身份、配置参数、构建 recipe 与根位置。libssh2 key 包含该架构的 OpenSSL key，OpenSSL 变化会连带使 SSH 和 universal 缓存失效。会影响编译的未声明环境覆盖（CFLAGS、LDFLAGS、SDKROOT、CC 等）不被继承。

分架构产物放在 `cache/<依赖>/<架构>/<fingerprint>/`。源码摘要验证通过后在独立临时目录构建，核对库架构并保留对应源码许可；只有成功完成才原子发布包含输入和**所有产物文件 SHA256** 的 `manifest.json`。缺失/损坏 manifest、输入失配、缺失/新增/损坏文件或产物内符号链接不能复用。旧无 manifest 目录首次重建；旧 universal 目录保留为 `legacy-universal-*`，不把存在旧库当匹配证据。

合并前核对两个输入库的单架构、版本标记、头文件清单及许可一致性。非生成头差异阻断；仅已知 OpenSSL 生成配置头（configuration.h、opensslconf.h）允许按架构分派，不盲目采用 arm64 头。本次两架构头完全一致；分派分支另有临时夹具测试。合并库通过两架构编译/静态链接探针以及本机架构运行时版本核对后才发布完成 manifest。`universal` 原子切换到已完成不可变 generation；`licenses` 指向它的许可目录。这里是进程中断/产物完整性保护，不宣称断电级持久原子性或防御能同时修改产物和 manifest 的恶意本机进程。

```sh
# 只读匹配检查：不建目录、不下载、不编译。失配返回非零。
script/build_secure_dependencies.sh --check
# 失配才构建固定版本；匹配时不重复下载/编译。
script/build_secure_dependencies.sh
# 两架构版本、头/库一致性与静态链接探针；x86_64 运行需 Rosetta 或 Intel。
script/build_secure_dependencies.sh --verify
# 仅临时假产物/工具测试，不下载、不编译、不启动应用。
python3 script/test_secure_dependency_cache.py
```

`script/build_and_run.sh` 先执行上述无下载检查，只有失配才进入固定版本构建，不再只检查 libssh2.a 存在。用于隔离检查/构建时可设置 `FTP_SECURE_DEP_ROOT`；根位置属于 fingerprint，不能把另一位置产物误当当前缓存。该覆盖仅用于依赖脚本，不改变 Xcode 项目固定的默认链接位置。

测试 SSH 服务使用项目隔离环境：用 Python 3.12 建立 `.build/ssh-fixture-env`，安装 `paramiko==4.0.0`。这是本机测试依赖，不随应用打包。执行 `script/verify_ssh_dependencies.sh` 构建两架构最小探针，并置于具有本应用网络客户端沙盒权限的应用包中签名，验证无认证握手及取消。

2026-10-08 验证：两架构静态库构建成功；arm64 沙盒握手 0.004 秒、取消 0.202 秒；x86_64 经 Rosetta 沙盒握手 0.007 秒、取消 0.203 秒。独立命令行文件附加 App Sandbox 权限会因没有应用包而启动失败，改用正常应用包后通过。宿主为当前 macOS，未在 macOS 13 或 Intel 真机运行；面向 macOS 13 的编译和 Rosetta 不能替代这些实测。

## 本次验证 — 2026-10-12

macOS 27.0.1 arm64 / Xcode macOS SDK 27.0 / Apple clang 21.0.0 上，从原 pin 重新构建两架构；SHA256 不变。15 项缓存/失败夹具通过；只读检查匹配、再次构建没有下载或编译。arm64 原生与 x86_64 **Rosetta** 探针均报告 libssh2 1.11.1、OpenSSL 3.5.9，运行时/头版本一致；两库均含 arm64+x86_64，探针不动态链接外部 libssh2/libcrypto/libssl。两架构许可一致，且与应用打包的 `docs/licenses/` 内容逐字节一致。新依赖上的应用 Release 全量测试 **414 项通过，0 失败**。以上为开发工作区的本机验证记录，原始日志和本机缓存资料不随公开源码上传；公开副本的复验状态见 [源码验证记录](source-verification.md)。这些结果不能替代 Intel 真机或 macOS 15 真机验证，也不是发布、公证或三次性能验收。

每次发布前检查两个上游的安全公告和支持期限。升级须明确更新版本与摘要，重新构建两架构、检查静态链接路径、执行握手/取消和完整四协议矩阵，并保存证据。不得自动下载不固定版本或跳过摘要验证。最低系统或架构验收失败时停止发布，不自动退回缺失 SFTP 的系统 libcurl。
