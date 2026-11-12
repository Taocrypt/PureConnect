<div align="center">

<img src="docs/assets/mark.svg" alt="PureConnect" width="96">

# PureConnect

**基于 zju-connect 内核的跨平台 EasyConnect / aTrust 客户端：一个应用，覆盖 Android、Windows、macOS 与 Linux。**

[![Release](https://img.shields.io/github/v/release/Taocrypt/PureConnect?style=flat-square&label=Release)](https://github.com/Taocrypt/PureConnect/releases/latest)
[![Platforms](https://img.shields.io/badge/Platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux-3451b2?style=flat-square)](#系统要求)
[![Core: zju-connect](https://img.shields.io/badge/Core-zju--connect-5865F2?style=flat-square)](https://github.com/Mythologyli/zju-connect)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-64748B?style=flat-square)](LICENSE)

**简体中文** · [English](#english)

[下载](https://github.com/Taocrypt/PureConnect/releases/latest) · [功能](#功能) · [工作原理](#工作原理) · [从源码构建](#从源码构建) · [常见问题](#常见问题)

</div>

> [!NOTE]
> 这是一个**社区项目**，与 [zju-connect](https://github.com/Mythologyli/zju-connect) 的作者、深信服科技股份有限公司（Sangfor）以及任何学校或机构**均无从属或合作关系**，也未获得其授权或认可。使用中遇到的问题请在本仓库反馈，不要打扰上游作者。

## 这是什么

**PureConnect**（包名 `com.taocrypt.pureconnect`）是一个用 Flutter 编写的图形客户端：

- 以独立进程运行 **[zju-connect](https://github.com/Mythologyli/zju-connect)** 内核，通过 EasyConnect 或 aTrust 协议接入你已获授权访问的内网；
- 提供统一的 Material 3 界面（风格参考 [FlClash](https://github.com/chen08209/FlClash)）：仪表盘、配置、资源、日志与工具页；
- 在各平台补上原生能力：Android 的 VpnService 前台服务，桌面的系统代理、TUN 提权、托盘 / 菜单栏与沉浸式窗口。

所有账号、密码与流量只在本机处理，应用不收集、不上传任何数据（你自行配置的 WebDAV 备份除外）。

## 功能

| | |
| --- | --- |
| **双协议** | 支持 EasyConnect 与 aTrust；多配置管理、拖拽排序。aTrust 支持密码 / 短信 / CAS / OAuth2 认证、登录域、查询认证方式、记住并信任设备、MAC 上报。 |
| **多种登录方式** | 用户名密码、TOTP、客户端证书（`.p12`）、TWFID；连接时可临时输入未保存的账号密码或手机号，并可选择保存。 |
| **交互式二次认证** | 短信 / TOTP / Radius 验证码、图形验证码、点选验证码，以及 CAS / OAuth2 浏览器回调，均以弹窗完成。 |
| **代理服务** | SOCKS5（可设认证）/ HTTP 代理，可允许局域网连接；可选 Shadowsocks 服务端。 |
| **系统代理** | Windows / macOS / GNOME / KDE；支持排除列表与覆盖提醒，断开或退出时恢复原设置，异常退出后下次启动自动恢复。 |
| **TUN / VPN** | Android 使用 VpnService（可设置不走 VPN 的应用）；桌面使用内核 TUN，Windows 经 UAC、macOS 经管理员授权框、Linux 经 `pkexec` 提权。 |
| **外部代理** | 可设置前置代理（如 Clash 本地端口），并导出 Clash 规则配合使用；TUN 模式下非校园流量同样经外部代理转发。 |
| **DNS 与路由** | 远程 / 备用 / 本地 DNS、本地 DNS 服务、TTL、DNS 劫持、Fake IP、自定义记录；强制代理域名、全部走 VPN、TCP 隧道模式、按服务端资源加路由、保活 URL、绑定网卡。 |
| **端口转发** | TCP / UDP 端口转发规则。 |
| **仪表盘与拓扑** | 连接状态、流量统计、虚拟 IP、连接拓扑；桌面宽屏显示应用与内核内存占用。 |
| **资源浏览** | 浏览服务端下发的 IP / 域名 / Web 资源，探测可达性并一键打开。 |
| **日志与诊断** | 实时日志（过滤、搜索、复制、导出）；额外内核参数，PCAP 抓包与 TLS 密钥日志等调试文件。 |
| **自动重连与掉线处理** | 网络中断自动重连（可设延迟，密码错误不重试）；账号在其他设备登录导致本机被挤下线时干净断开并提示原因，不再自动重连。 |
| **轻量模式** | 默认关闭。已连接且窗口隐藏到托盘（Android：应用在后台）达到设定时间后，界面进程退出，仅内核维持连接；再次打开应用时自动接回状态、日志、流量与拓扑。 |
| **托盘 / 菜单栏** | 显示状态，连接 / 断开，切换接管方式与配置；关闭或最小化到托盘、开机自启、静默启动、单实例、隐藏 Dock 图标（macOS）、`--connect` 启动参数。 |
| **配置分享与导入** | 分享单个配置，或从分享内容导入。 |
| **备份与恢复** | 本地备份与 WebDAV 同步；设置备份密码后以 AES-256-GCM 加密（密钥由 PBKDF2-HMAC-SHA256 派生）。 |
| **应用内更新** | 从 GitHub Releases 检查更新，Android 按架构下载并安装 APK、桌面下载安装包；直连不通时自动测速选择镜像，可自定义镜像或始终直连；支持发布方声明最低支持版本以强制更新。 |
| **主题与外观** | 主题模式、纯黑模式、主题色（跟随系统 / 预设 / 自定义）与配色风格、底栏样式、液态玻璃、字体与文本缩放；侧边栏背景模糊（Windows 云母 / 模糊、macOS 毛玻璃）；沉浸式自绘标题栏。 |
| **应用图标** | 四款图标可选；Windows 将四款图标内嵌到 `pureconnect.exe`，并同步更新开始菜单、桌面与任务栏快捷方式。 |
| **配置引导** | 首次启动按协议、服务器、认证方式、账号分步引导，并以界面上的放大镜动画指引。 |

## 工作原理

```
┌──────────────────────────── 本机 ─────────────────────────────┐
│  PureConnect 界面（Flutter）                                    │
│     │  JSON lines：stdin/stdout，或 127.0.0.1 + token          │
│     ▼                                                          │
│  zjuconnect-core（Go 桥接 + 上游 zju-connect 包）              │
│     ├─ SOCKS5 / HTTP / Shadowsocks / 端口转发 / DNS            │
│     └─ TUN ── Android: VpnService 传入 fd                      │
│              桌面: 内核自建 TUN（以管理员身份启动）            │
└─────────────────────────────┬──────────────────────────────────┘
                              ▼
              EasyConnect / aTrust 服务端（例如 vpn.example.edu.cn）
```

- **桥接协议**：`core/bridge/` 中的 Go 程序按上游流程启动会话，并把错误、日志、会话信息与二次认证转换为 JSON 事件（Go 侧 `core/bridge/protocol.go`，Dart 侧 `lib/core/protocol.dart`）。构建时它被复制进上游源码树，无需 fork 上游。
- **独立进程**：上游的代理监听器无法在进程内停止，因此内核始终以独立进程运行，每次断开都能干净释放资源。
- **Android**：Kotlin 前台服务 `CoreService`（VpnService）执行随 APK 分发的内核；收到内核的 TUN 请求后建立 VPN，并通过 Unix socket 把文件描述符交给内核。本应用自身被排除在 VPN 之外，避免回环。
- **桌面**：界面直接以子进程启动内核。TUN 模式需要管理员权限：Windows 通过 UAC、macOS 通过系统授权框启动内核，内核再经 `127.0.0.1` 加一次性 token 连回界面；Linux 使用 `pkexec`（无 pkexec 时退回 `sudo -S`）。
- **轻量模式**：界面向内核发送 `detach`（附随机 token 与系统代理恢复计划）后退出；内核改为在 `127.0.0.1` 随机端口等待接回。下次启动时界面以 token 握手接回，内核回放状态、日志、拓扑与流量。内核结束时会先还原系统代理。

## 系统要求

| 平台 | 要求 |
| --- | --- |
| Android | Android 7.0（API 24）或更高；提供 arm64-v8a、armeabi-v7a、x86_64 与通用 APK。 |
| Windows | Windows 10 / 11，x64。TUN 模式需管理员权限（UAC）。 |
| macOS | macOS 12 或更高，Apple Silicon 与 Intel（通用二进制）。 |
| Linux | x64；需要 GTK 3 与 `libayatana-appindicator3`（托盘）。TUN 模式需要 `pkexec` 或 `sudo`。 |

## 安装

从 [Releases](https://github.com/Taocrypt/PureConnect/releases/latest) 下载对应平台的文件（`<版本>` 为版本号，例如 `1.0.4`）。之后的版本可在应用内「工具 → 关于 → 检查更新」直接升级。

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android | `PureConnect-<版本>-android-arm64-v8a.apk` | 绝大多数手机选这个；另有 `armeabi-v7a`、`x86_64` 与 `universal`。需允许「安装未知来源应用」。 |
| Windows | `PureConnect-<版本>-windows-x64-setup.exe` | 安装程序；便携版为 `PureConnect-<版本>-windows-x64.zip`。 |
| macOS | `PureConnect-<版本>-macos-universal.dmg` | 打开后将应用拖入「应用程序」。 |
| Linux | `PureConnect-<版本>-linux-amd64.deb` | Debian / Ubuntu 用 `sudo apt install ./PureConnect-*.deb`；其他发行版使用 `PureConnect-<版本>-linux-x64.tar.gz`。 |

首次启动需阅读并同意免责声明，之后按引导填写服务器地址（例如 `vpn.example.edu.cn`）、协议与账号即可连接。

## 权限说明

| 权限 | 用途 |
| --- | --- |
| 网络、网络状态（`INTERNET`、`ACCESS_NETWORK_STATE`） | 连接 VPN 服务端、提供本地代理、检查更新 |
| VPN 服务（`BIND_VPN_SERVICE`） | TUN 模式下建立系统 VPN（由系统弹窗授权） |
| 前台服务、通知（`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_SPECIAL_USE`、`POST_NOTIFICATIONS`） | 让内核在后台常驻，显示连接状态、掉线 / 重连与下载进度 |
| 读取应用列表（`QUERY_ALL_PACKAGES`、`GET_INSTALLED_APPS`） | 选择不走 VPN 的应用 |
| 安装未知应用（`REQUEST_INSTALL_PACKAGES`） | 应用内更新时调起系统安装器 |
| 桌面管理员权限（Windows UAC / macOS 授权框 / Linux `pkexec`） | 仅在桌面 TUN 模式下以管理员身份启动内核；系统代理与代理模式无需提权 |

应用不包含任何统计或追踪 SDK。

## 从源码构建

需要：

- Flutter **3.47**（CI 使用 `3.47.x`）
- Go **1.25**（CI 使用 `1.25.x`，最低 1.25.6）
- Android：Android SDK 与 JDK；构建 armeabi-v7a / x86_64 内核需要 NDK
- Linux：`libgtk-3-dev libx11-dev libayatana-appindicator3-dev`

```sh
# 1. 编译内核（拉取固定版本的上游 zju-connect）
core/build.sh android                      # arm64；设置 ANDROID_NDK_HOME 可额外构建 armeabi-v7a / x86_64
core/build.sh linux-amd64 linux-arm64
core/build.sh windows-amd64 windows-arm64  # 同时下载并校验 wintun.dll
core/build.sh darwin-arm64 darwin-amd64    # 在 macOS 上自动合成 universal 二进制

# 2. 构建应用
flutter pub get
flutter build apk --release --split-per-abi   # Android
flutter build windows --release               # Windows
flutter build macos --release                 # macOS
flutter build linux --release                 # Linux
```

**签名密钥不包含在仓库中。** Android 发布构建请使用你自己的 keystore，并在 `android/key.properties`（已被 `.gitignore` 忽略，切勿提交）中填写：

```properties
# 生成密钥（只需一次）：
#   keytool -genkeypair -keystore android/app/release.p12 -storetype PKCS12 \
#     -alias pureconnect -keyalg RSA -keysize 4096 -validity 10000
storeFile=release.p12
storeType=PKCS12
storePassword=<你的密码>
keyAlias=pureconnect
keyPassword=<你的密码>
```

未提供 `key.properties` 时，构建会退回开发用签名密钥，仅适合本地调试。

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `ZJU_CONNECT_REF` | 上游 zju-connect 的提交或标签 | `core/build.sh` 中固定的提交 |
| `ZJU_CONNECT_DIR` | 上游源码检出目录 | 见 `core/build.sh` |
| `ANDROID_NDK_HOME` | Android NDK 目录，用于额外 ABI | 未设置时只构建 arm64 |
| `REQUIRE_NDK` | 设为 `1` 时缺少 NDK 直接报错 | 未设置 |
| `ZJU_CONNECT_CORE` | 开发时指定内核可执行文件路径 | 使用随应用分发的内核 |

> 发布时以 tag 为版本（`v1.2.3` → `1.2.3`）。更新内容写在 [`CHANGELOG.md`](CHANGELOG.md) 对应的 `## [x.y.z] - 日期` 小节；在小节中单独写一行 `最低支持版本: x.y.z` 即可声明强制更新。CI（`.github/workflows/build.yml`）会构建全部平台并附带供应用检查更新的 `update.json`。

> 用自己的密钥签名的 APK 与 Releases 中的官方包签名不同，不能覆盖安装，需要先卸载（会清除应用数据）。

## 常见问题

**连接时提示需要二次认证？**
按弹窗输入短信 / TOTP / Radius 验证码，或完成图形 / 点选验证码；CAS / OAuth2 认证会打开浏览器，完成后自动回到应用。

**应该选系统代理、TUN 还是仅代理？**
系统代理无需提权，适合浏览器等遵循系统代理的应用；TUN 接管所有流量，桌面端需要管理员权限；仅代理模式只开放 SOCKS5 / HTTP 端口，适合配合 Clash 等工具使用。

**提示“账号已在其他设备登录”？**
同一账号在其他设备登录后，服务端会把本机挤下线。应用会干净断开并提示，不会自动重连，以免两端互相顶替。

**直连 GitHub 无法检查更新？**
应用会自动测速选择镜像；也可在「工具 → 关于 → 下载镜像」中添加自定义镜像或改为始终直连。

**Android 后台被系统杀掉？**
请允许通知权限，并在系统设置中为 PureConnect 关闭电池优化、允许后台运行。

**这是官方客户端吗？**
不是。本项目是社区作品，与 zju-connect 的作者、深信服及任何学校均无关。上游内核本身的问题请到其仓库反馈。

## 反馈

- 问题与建议：[Issues](https://github.com/Taocrypt/PureConnect/issues)
- QQ 群「PureConnect用户交流群」：<https://qm.qq.com/q/tLAgIcTjFY>（应用内：工具 → 关于 → 反馈渠道）

## 许可证与致谢

本项目以 [GNU Affero General Public License v3.0](LICENSE)（SPDX：`AGPL-3.0-only`）发布。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；Flutter / Dart 依赖的许可可在应用内「关于 → 开源许可」查看。

- [zju-connect](https://github.com/Mythologyli/zju-connect) — AGPL-3.0（连接内核）
- [FlClash](https://github.com/chen08209/FlClash) — GPL-3.0（界面设计参考，托盘组件与 prism_ui 取自其生态）
- [EZ4Connect](https://github.com/chenx-dust/EZ4Connect) — GPL-3.0（部分功能参考）

「EasyConnect」「aTrust」及相关商标归深信服科技股份有限公司所有。本软件仅供学习研究与个人使用，请仅连接你已获授权访问的网络，并遵守所在单位的网络使用规定及适用法律法规。本软件按“现状”提供，不附带任何担保。

---

## English

**PureConnect** (`com.taocrypt.pureconnect`) is a cross-platform EasyConnect / aTrust client for **Android, Windows, macOS and Linux**, built with Flutter on top of the [zju-connect](https://github.com/Mythologyli/zju-connect) core.

- **Connect**: EasyConnect and aTrust (password, SMS, CAS, OAuth2, TOTP, client certificate, TWFID), with interactive second-factor and captcha prompts.
- **Route traffic**: SOCKS5 / HTTP / Shadowsocks proxies, port forwarding, DNS options, system proxy, TUN (Android VpnService; elevated core on desktop via UAC / macOS authorization / `pkexec`), and an external upstream proxy.
- **Live view**: dashboard with traffic and connection topology, resource browser, real-time logs, auto-reconnect and clean handling of being kicked offline.
- **Stay light**: optional lightweight mode lets the UI exit while the core keeps the connection, then reattaches over a token-authenticated loopback channel; tray / menu-bar controls on desktop.
- **Maintain**: profile sharing and import, local and WebDAV backups encrypted with AES-256-GCM, in-app updates with mirror fallback and forced updates, theming, a setup guide and selectable app icons.

The UI talks to the Go core over a JSON-lines bridge; the core always runs as a separate process. Build with Flutter 3.47 and Go 1.25 (`core/build.sh`, then `flutter build`); sign Android releases with your own keystore via `android/key.properties`.

This is a **community project, not affiliated with** the zju-connect authors, Sangfor, or any school. Please report issues here or in the QQ group linked above. Licensed under AGPL-3.0-only; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
