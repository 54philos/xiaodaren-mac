<p align="center"><img src="Assets/BrandMark.png" width="112" alt="点读伙伴 Logo"></p>
<h1 align="center">点读伙伴</h1>
<p align="center">小达人点读笔的 Mac 助手 · 非官方 · MIT 开源</p>
<p align="center"><a href="https://github.com/54philos/xiaodaren-mac/releases/latest"><b>下载 Mac 应用</b></a> · <a href="docs/使用说明.md">使用说明</a> · <a href="https://github.com/54philos/xiaodaren-mac/issues">反馈问题</a></p>

在 Mac 上给小达人点读笔安装 DAB 点读包、查看书目和批量移除内容，无需为这些操作启动 Windows 虚拟机。

## 下载与适用范围

普通用户请前往 **[Releases 下载最新版](https://github.com/54philos/xiaodaren-mac/releases/latest)**，选择 `DianduPartner-0.5.1-macOS-arm64.zip`。解压后把「点读伙伴.app」拖到「应用程序」。GitHub 自动提供的 Source code 压缩包是源码，不是可直接运行的应用。

| 项目 | 当前支持情况 |
| --- | --- |
| Mac | Apple Silicon（M 系列芯片 / arm64） |
| 系统 | macOS 14 或以上 |
| 点读笔 | 小达人 908 已实机验证；其他型号尚未实机验证 |
| 点读包 | deb 智能包、标准版本 2/3 普通内容包、UNB 包 |
| 运行依赖 | 无需 Windows、PD、Python 或开发工具 |

当前为测试版。本软件与小达人官方无隶属关系；不提供点读资源下载、MP3 制包或固件升级。

## 能做什么

- 安装 DAB 点读包，按资源说明填写贴号、内容类型和必要参数。
- UNB 从原始 DAB 和当前点读笔信息独立生成设备绑定，不依赖笔内旧文件。
- 默认快速安装；需要时可在 File 菜单开启完整回读校验。
- 查看、搜索已装书目，默认按贴号排序，也可点击大小、书名和类型表头排序。
- ⌘ 多选或 ⇧ 连选，一次直接移除多个包。
- 自动识别设备和刷新书目；安装成功后自动收起参数；支持安全推出。

## 第一次使用

1. 将点读笔关机，用支持数据传输的数据线连接 Mac。
2. 打开应用，等待显示「点读笔已连接」。
3. 选择自己的 DAB，按资源提供方的说明核对贴号、类型和参数。
4. 点击「安装到点读笔」直接开始，等待显示「安装完成」。
5. 点击「安全推出」，成功后拔线，开机测试实体书点读。

更多操作见 **[使用说明](docs/使用说明.md)**。

### macOS 首次打开提示

当前应用为本地 ad-hoc 临时签名，**尚未提供 Apple Developer ID 签名与 Apple 公证**。若系统阻止打开，请先确认下载来源，再参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)处理「隐私与安全性」中的提示。本项目不要求关闭系统全局安全保护。

### 关于速度与移除

快速安装不完整回读音频数据，保留写入完成、文件大小及绑定包头检查。安装完成后应测试点读；排查问题时可开启完整校验。完整校验失败会提示重新安装，不会自动重新复制。

移除会直接删除点读笔中的所选文件，不创建备份，不能撤销。电脑上的源包不受影响。安装遇到被占用的编号时会阻止覆盖。

## 验证范围

- 72 项本地核心检查通过，包含快速及完整安装、UNB 绑定、源包保留、占用保护、损坏检测、失败清理及批量移除。
- 在一支小达人 908 上，从原始牛津树 DAB 独立安装后，用户确认实体书点读正常。
- 上述结果不代表所有型号、所有点读包都已验证。欢迎通过 Issues 补充兼容性反馈。

## 从源码构建

需要 macOS 和 Apple Command Line Tools。运行应用本身不需要开发工具。

```sh
bash build.sh
bash build.sh test
bash build.sh ui-test
```

构建结果位于 `dist/点读伙伴.app`。默认按当前 Mac 的处理器架构构建；发行包目前只提供 arm64。`PEN_BUILD_DIR` 和 `PEN_APP_DIR` 可分别指定中间文件和应用输出位置。

技术栈为 SwiftUI、AppKit、Foundation 和 CryptoKit，无第三方运行时依赖。更多算法依据、测试入口和实现范围见 [开发说明](README_DEVELOPMENT.md)。硬件写入测试需显式选择设备，不属于普通本地测试。

## 反馈问题

请在 Issues 写明应用版本、Mac 芯片、macOS 版本、点读笔型号、包格式以及错误提示。请先隐去设备标识和个人路径，不必上传完整点读资源。

## 许可与致谢

本项目采用 [MIT License](LICENSE)。common-DAB 绑定算法参考 [kings0527/talking-pen-toolkit](https://github.com/kings0527/talking-pen-toolkit)，对应许可声明保留在 [THIRD_PARTY_LICENSE.txt](THIRD_PARTY_LICENSE.txt)。

本仓库不包含点读资源、设备备份、个人设备信息或官方安装程序。
