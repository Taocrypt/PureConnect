# 第三方声明 / Third-party notices

PureConnect 以 **GNU Affero General Public License v3.0**（`AGPL-3.0-only`）发布，完整许可文本见仓库根目录的
[`LICENSE`](LICENSE)。本文件列出 PureConnect 包含、派生或参考的第三方项目及其许可。应用内「关于 → 开源许可」
页面同时列出所有 Flutter / Dart 依赖包各自的许可文本。

PureConnect is released under the GNU AGPL-3.0 (`AGPL-3.0-only`); see [`LICENSE`](LICENSE). This file lists
the third-party projects PureConnect includes, derives from or draws on. The in-app page About → Open-source
licences shows the licence of every Flutter / Dart package as well.

## 包含的组件 / Included components

### zju-connect（内核 / core）

- 项目：<https://github.com/Mythologyli/zju-connect>
- 许可：GNU AGPL-3.0（与 PureConnect 相同，见 `LICENSE`）
- 用途：VPN 内核。构建时从上游源码编译（版本固定在 `core/build.sh` 的 `ZJU_CONNECT_REF`），`core/bridge/`
  中的桥接程序以 AGPL-3.0 随本项目发布；对上游的补丁位于 `core/patches/`。

### prism_ui（界面组件库 / design system）

- 项目：<https://github.com/chen08209/prism_ui>
- 许可：GNU GPL-3.0，原许可文件保留在 [`third_party/prism_ui/LICENSE`](third_party/prism_ui/LICENSE)
- 用途：以源码形式内置于 `third_party/prism_ui`（基于提交 `5d8ed7a`，有少量本地修改，例如横幅宽度适配文字、
  `toImageSync` 零尺寸保护）。

### tray（系统托盘插件 / tray plugin）

- 来源：FlClash（<https://github.com/chen08209/FlClash>）的 `plugins/tray`
- 许可：MIT，原许可文件保留在 [`third_party/tray/LICENSE`](third_party/tray/LICENSE)

## 派生的代码 / Derived code

### FlClash

- 项目：<https://github.com/chen08209/FlClash>
- 许可：GNU GPL-3.0（窗口插件 `plugins/window` 为 MIT）
- PureConnect 的界面风格与多处代码派生自 FlClash 并经过修改，包括：图标集（`lib/ui/kit/app_glyphs.dart`）、
  主题页（主题模式、纯黑、主题色与配色风格、底栏样式、选项卡动画、液态玻璃、侧边栏背景模糊、字体、文本缩放）、
  取色器（`lib/ui/widgets/palette.dart`）、系统字体列表（`lib/core/system_fonts.dart`）、沉浸式窗口框架
  （`lib/ui/window_frame.dart` 及 `windows/runner/window_frame.*`、`macos/Runner/MainFlutterWindow.swift`、
  `linux/runner/my_application.cc` 中移植自 FlClash 窗口插件的部分）、关于页与首次启动免责声明。
- GPL-3.0 与 AGPL-3.0 依两者第 13 条可以合并使用；合并后的作品整体以 AGPL-3.0 发布，派生自 FlClash 的部分
  仍同时受 GPL-3.0 约束。

## 参考的项目 / Projects drawn on

以下项目为部分功能提供了思路和参考：

- EZ4Connect — <https://github.com/chenx-dust/EZ4Connect> — GNU GPL-3.0
- hitsz-connect-verge — <https://github.com/kowyo/hitsz-connect-verge> — GNU GPL-3.0

## Flutter / Dart 依赖 / Flutter and Dart packages

Flutter SDK 及 `pubspec.yaml` 中的依赖包（flutter_riverpod、shared_preferences、path_provider、file_picker、
url_launcher、package_info_plus、pointycastle、crypto、ffi 等）各自以其许可发布（多为 BSD-3-Clause、MIT 或
Apache-2.0）。它们的完整许可文本由 Flutter 在构建时收集，可在应用内「关于 → 开源许可」中查看。

## 商标 / Trademarks

「EasyConnect」「aTrust」及相关名称、标识的商标权和著作权归**深信服科技股份有限公司**（Sangfor Technologies
Inc.）所有。PureConnect 是非官方的第三方客户端，与深信服及任何学校、机构均无关联，也未获得其授权或认可；
提及这些名称仅为说明所兼容的协议。

"EasyConnect", "aTrust" and related names and logos are trademarks and copyrights of Sangfor Technologies
Inc. (深信服科技股份有限公司). PureConnect is an unofficial third-party client, not affiliated with, authorized or
endorsed by Sangfor or any school or organization; the names are used only to describe compatibility.
