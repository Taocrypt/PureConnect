# ZJU Connect (Flutter)

跨平台的 ZJU Connect 客户端（Android / Windows / macOS / Linux），内核为
[Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect)，界面风格参考
[FlClash](https://github.com/chen08209/FlClash)（Material 3、仪表盘卡片、侧栏/底栏导航、右下角启动按钮）。

## 功能

| 内核功能 | 界面位置 |
|---|---|
| EasyConnect / aTrust 协议，多配置切换、拖拽排序 | 配置 |
| 用户名密码、TOTP、客户端证书 (.p12)、TWFID | 配置 → 编辑 |
| aTrust 认证方式：密码 / 短信 / CAS / OAuth2，登录域，client data 记住设备，MAC 上报 | 配置 → 编辑 |
| aTrust 查询认证方式（`-auth-info`）、信任/取消信任设备 | 配置 → 编辑 |
| 交互式二次认证：短信/TOTP/Radius 验证码、图形验证码、点选验证码、CAS/OAuth2 浏览器回调 | 弹窗 |
| SOCKS5（含认证）/ HTTP 代理、允许局域网、Shadowsocks 服务端 | 工具 → 连接 → 代理 |
| 系统代理（Windows/macOS/GNOME/KDE），断开或退出时恢复原有设置，崩溃后下次启动自动恢复 | 仪表盘 → 接管方式 |
| TUN：Android VpnService；桌面使用内核 TUN（Windows 弹 UAC、macOS 系统管理员授权框、Linux pkexec） | 仪表盘 → 接管方式 |
| 桌面托盘/菜单栏：状态、连接/断开、切换接管方式和配置、退出；关闭到托盘、开机自启、静默启动、隐藏 Dock 图标（macOS）、单实例 | 托盘 / 工具 → 桌面 |
| 端口转发 TCP/UDP | 工具 → 规则与转发 |
| 远程/备用/本地 DNS、本地 DNS 服务、TTL、DNS 劫持、Fake IP、自定义 DNS | 工具 → 连接 → DNS / 规则与转发 |
| 强制代理域名、全部走 VPN、直连上游代理、TCP 隧道模式 | 工具 → 连接 / 规则与转发 |
| 按服务端资源加路由、保活 URL、绑定网卡/自动检测、调试日志、aTrust 刷新间隔 | 工具 → 连接 → 高级 |
| 虚拟 IP、路由、IP/域名资源浏览 | 仪表盘 / 资源 |
| 实时日志（过滤、搜索、复制） | 日志 |
| 主题模式、主题色、动态取色、应用图标 | 工具 → 应用 → 主题 |
| 自动重连（可设间隔）、掉线 / 重连系统通知 | 工具 → 连接 / 应用 |
| 连接时询问未保存的账号密码或手机号；首次启动配置引导 | 弹窗 / 配置 → 添加 |
| 额外内核参数（zju-connect 命令行格式）、PCAP / TLS 密钥导出与调试文件 | 工具 → 连接 → 高级 |
| 最小化到托盘、系统代理排除、覆盖提示、清除系统代理、`--connect` 启动参数 | 工具 → 桌面 |
| 日志导出、aTrust 清除登录缓存、恢复默认设置 | 日志 / 配置 → 编辑 / 备份与恢复 |
| 检查更新（GitHub Release；Android 按架构下载 APK 并安装，桌面下载安装包），启动时每天最多自动检查一次 | 工具 → 关于 |

## 架构

```
Flutter UI ──JSON lines(stdin/stdout)──▶ zjuconnect-core (Go)
                                         └─ 上游 zju-connect 包（client / stack / service …）
```

* `core/bridge/`：Go 桥接程序，按上游 `main.go` 的流程启动会话，但把错误、日志、会话信息、
  二次认证全部变成 JSON 事件（协议见 `core/bridge/protocol.go`，Dart 侧 `lib/core/protocol.dart`）。
  构建时被复制进上游源码树 `cmd/zjuconnect-core`，以便复用 `internal/` 包，无需 fork 上游。
* 内核以**独立进程**运行：上游的代理监听器无法在进程内停止，独立进程保证每次断开都能干净释放。
* 桌面：Dart 直接拉起 `zjuconnect-core`。TUN 模式需要管理员权限：Windows 用 UAC（`Start-Process -Verb RunAs`）、
  macOS 用系统授权框（`osascript … with administrator privileges`）以管理员身份启动内核，内核带
  `--dial 127.0.0.1:<port> --token <t>` 通过本机 TCP 连回界面（协议与 stdin/stdout 相同，连接断开内核即退出）；
  应用本身已是管理员时直接用管道。Linux 用 `pkexec`（保留管道），没有 pkexec 时退回 `sudo -S`（应用内输入密码）。
  Windows TUN 需要 `wintun.dll`，`core/build.sh windows-*` 会下载并校验（wintun 0.14.1），安装规则把它放在内核旁。
* 窗口/托盘：原生 `pureconnect/window` 通道（`windows/runner/flutter_window.cpp`、`macos/Runner/MainFlutterWindow.swift`、
  `linux/runner/my_application.cc`）负责显示/隐藏、拦截关闭、退出、Windows 系统代理（注册表 + InternetSetOption，
  注销/关机时由原生代码恢复）；托盘用 `third_party/tray`（取自 FlClash，MIT，Linux 需 libayatana-appindicator3）。
* Android：Kotlin 前台服务 `CoreService`（VpnService）从 `nativeLibraryDir` 执行
  `libzjuconnect_core.so`，收到内核 `tun_request` 后建立 TUN，并通过抽象 Unix socket（SCM_RIGHTS）把 fd 传给内核；
  本应用 UID 被排除在 VPN 之外，避免内核到服务器的连接回环。

## 构建

```bash
# 1. 内核（Go ≥ 1.25.6）
core/build.sh android                         # arm64；设置 ANDROID_NDK_HOME 可额外构建 armeabi-v7a / x86_64（REQUIRE_NDK=1 时缺 NDK 直接报错）
core/build.sh linux-amd64 linux-arm64
core/build.sh windows-amd64 windows-arm64
core/build.sh darwin-arm64 darwin-amd64       # macOS 构建时自动合成 universal 二进制

# 2. 应用（Flutter ≥ 3.47）
flutter pub get
flutter build apk --release      # Android
flutter build linux --release    # Linux（内核自动安装到 bundle/lib/）
flutter build windows --release  # Windows（内核和 wintun.dll 放在 exe 旁）
flutter build macos --release    # macOS（内核放在 .app/Contents/Resources/）
```

内核版本固定在 `core/build.sh` 的 `ZJU_CONNECT_REF`（当前 `8576e7a`，即上游 `nightly`，最新正式版为 `v1.3.1`）。
开发时也可用环境变量 `ZJU_CONNECT_CORE=/path/to/zjuconnect-core` 指定内核。

## 版本与发布

* 版本号以 `pubspec.yaml` 的 `version` 为准；发布时以 tag 为准（`v1.2.3` → `1.2.3`），
  CI 用 `--build-name` 写入应用，构建号由版本推出（`1.2.3` → `10203`），保证 Android 每次升级 versionCode 递增。
* 更新内容写在 `CHANGELOG.md` 的 `## [x.y.z] - 日期` 小节。
* CI（`.github/workflows/build.yml`）：推送到 `main` 时构建全部平台并上传 artifacts；推送 `v*` tag 时额外创建
  GitHub Release（说明取自 CHANGELOG 对应小节，没有则用上一个 tag 以来的提交），附带：
  Android arm64-v8a / armeabi-v7a / x86_64 / universal APK、Windows zip + 安装程序、macOS universal dmg、
  Linux tar.gz + deb。各平台内核均由 CI 现场编译（Android 的 armeabi-v7a / x86_64 使用 NDK）。
* Android 签名使用仓库 secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。
* Linux 本地构建需要 `libgtk-3-dev libx11-dev libayatana-appindicator3-dev`。

## 许可

内核 zju-connect 为 AGPL-3.0；本项目的界面参考 FlClash（GPL-3.0）的设计但为独立实现。
