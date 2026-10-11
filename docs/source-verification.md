# 公开源码验证

2026-10-11，在以 GitHub `main` 为基线整理的公开源码副本上重新构建和测试。仅迁入应用、测试、构建脚本与经过审查的使用文档；不上传原私有 Git 历史、本机配置、真实服务器验收资料、内部规划、原始日志或 xcresult。

## 本机结果

环境：Apple Silicon，macOS 27.0.1，SDK 27.0。

| 检查 | 结果 |
| --- | --- |
| arm64 完整 XCTest | 294 项通过，0 失败 |
| Rosetta x86_64 完整 XCTest | 294 项通过，0 失败；不是 Intel 硬件 |
| 通用 Release 构建 | 成功，包含 arm64 与 x86_64 |
| 最低系统声明 | 应用 Info.plist 与两架构 Mach-O 均为 macOS 15.0，应用／测试部署配置一致 |
| 签名与权限 | 本地 ad-hoc，严格签名验证通过；sandbox、网络客户端、用户选择文件与应用安全书签权限保留，Release 不含 get-task-allow |
| 文档 | 相对文件／锚点链接及 GitHub GFM 渲染检查；浅深色 picture 标签保留 |

本机日志与结果包未随源码上传。上表是本次公开副本的运行记录，可用下列命令复验，不代表独立第三方验证或已发布安装包能力。

## 覆盖范围

- `DirectorySortingTests`：字面匹配、Unicode 规范等价、原始身份、隐藏选择不恢复、排序、真实类型、10,000 项投影缓存及性能。
- `WorkbenchCommandTests`、`TransferActivityTests`、`TransferActivityLayoutTests`：命令路由、禁用守卫、局部输入、摘要优先级、风险可见性、目标去重及强调色对比度。
- `AppModelTests.swift` 中模型／队列／提交测试：固定身份与目标、选择器过期、覆盖默认取消行为、nonce、取消资源等待、失败／依赖阻塞、独立重试、历史隐私和完整结果。
- `WorkbenchWireAcceptanceTests`：真实 loopback FTP 单文件双向 65536 字节相等、覆盖取消不增加写入、生产 anchored 下载目标变化两次决策、暂停下筛选不修改计划、显式重试不覆盖原失败结果。
- `CollectionProtocolMatrixTests`：FTP、显式／隐式 FTPS 的 UTF-8／GB18030，以及 SFTP 密码／私钥共 8 个模式。真实混合目录、嵌套／空目录／零字节、双向合并与跳过、失败暂停、部分结果、取消和类型冲突；逐文件字节比较与请求检查。夹具请求／结果附件生成在本地 xcresult 内。
- 其余认证、站点、编码、私钥、下载落盘、权限范围及取消回归保留。测试秘密都是临时夹具数据，不需要真实账户。

README 截图是本机夹具的实际窗口，不是设计稿。示例名称特意包含长中文、空格与 `%/#`，展示截断和本地筛选。截图不证明全部测试场景或最低系统兼容性。

## 复验命令

先按 [README](../README.md#开发与验证) 准备静态依赖、TLS 测试证书及隔离 SFTP 夹具环境，然后执行：

```sh
xcodebuild -project FTPUploader.xcodeproj -scheme FTPUploader \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/verification \
  -resultBundlePath .build/arm64.xcresult test

# 需要可用的 Rosetta；不是 Intel 真机验收
xcodebuild -project FTPUploader.xcodeproj -scheme FTPUploader \
  -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath .build/verification \
  -resultBundlePath .build/rosetta.xcresult test

xcodebuild -project FTPUploader.xcodeproj -scheme FTPUploader \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/verification \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

`resultBundlePath` 每次需使用尚不存在的路径。测试应用目标不开 sandbox，以运行本机一次性服务；生产应用仍启用 sandbox。构建保留旧 `onChange` 签名的弃用警告，不声称零警告。

## 未验证／未发布

实际 macOS 15 运行、Intel 硬件、Developer ID、Hardened Runtime 发行验证、公证和隔离下载首启尚缺独立证据。本次只公开源码并创建 PR，不签发、不更新 Release、不上传新安装包。

现有 v0.2.0 安装包及其历史环境、签名和功能以对应 Release 说明为准；新版源码不再支持 macOS 13／14，编译或 Rosetta 通过不能替代最低系统／Intel 真机运行验证。
