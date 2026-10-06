# FTP 文件传输（FTPUploader）

原生 macOS FTP 客户端，支持匿名或账户登录、保存常用站点、浏览远程目录和单文件上传。

## 下载与安装

在 [Releases](https://github.com/Lanjunyee/FTPUploader/releases) 下载 `FTPUploader-0.1.0-macOS-universal.zip`，解压后将 `FTPUploader.app` 放入“应用程序”文件夹。

- 系统 API 基线为 macOS 13；当前发布构建包含 Apple Silicon（arm64）和 Intel（x86_64）。最低系统版本及 Intel 真机尚未实测。
- 此版本使用本地 ad-hoc 签名，未使用 Developer ID 签名、未经过 Apple 公证。下载后的首次启动可能被 macOS 安全机制拦截。签名完整性检查通过不代表系统信任或公证通过。
- 使用普通 FTP，网络传输不加密。钥匙串仅保护本机保存的密码。

## 使用

1. 输入 FTP 主机或地址，例如 `ftp://example.com:21/uploads`，选择匿名或账户登录，点击“连接”。
2. 双击文件夹进入，使用“上一级”或“刷新”浏览目录。
3. 点击“选择文件…”，再点击“上传到当前目录”；看到服务器最终确认后的“上传成功”才表示完成。
4. 通过站点菜单或“设置…”管理常用站点。账户密码可选择保存到系统钥匙串。

选择或保存站点不会自动连接。上传期间目标固定，不能更换服务器、身份或目录。同名文件是否可覆盖取决于服务器；失败后可能留下部分文件，应用不会自动删除、续传或重试。

支持 MLSD 和常见 Unix/DOS LIST，目录名称优先 UTF-8，无法严格解码时尝试 GB18030。非 UTF-8 服务器可从目录列表逐层进入；地址栏中的中文初始目录需要使用服务器编码对应的百分号序列。下载、文件夹及批量上传、队列、同步、续传、远程编辑和 SFTP/FTPS 尚未实现。

## 构建与运行

需要 Xcode 和 macOS SDK，无第三方包依赖，链接系统 libcurl。

```sh
./script/build_and_run.sh --verify
```

或打开 `FTPUploader.xcodeproj`，选择 FTPUploader scheme。脚本生成 `dist/FTPUploader.app`，支持 `--debug`、`--logs` 与 `--telemetry`。

构建通用 Release：

```sh
xcodebuild -project FTPUploader.xcodeproj -scheme FTPUploader \
  -configuration Release -derivedDataPath .build/release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

## 测试

```sh
xcodebuild -project FTPUploader.xcodeproj -scheme FTPUploader \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode test
```

测试环境需要 macOS 14 或更新版本。测试通过 Python 标准库启动本机 FTP 夹具，覆盖目录编码、地址校验、站点及凭据、错误脱敏、上传内容与服务器最终响应等行为。

手动启动本机夹具：

```sh
/usr/bin/python3 script/ftp_fixture.py --port 2121
```

连接 `ftp://127.0.0.1:2121`；服务仅绑定本机地址，退出后清理临时数据。

## 公开源码范围

此仓库从 2026-10-06 的本地提交 `09f73f7` 导出当前源码快照。为保护内部验收资料中的个人及网络信息，未发布原 Git 历史、内部验收文档、截图和本机协作配置。应用代码、资源、测试与构建脚本保持原样。
