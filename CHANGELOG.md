# 更新日志

本文件记录 PureConnect 各版本的变化。发布时 CI 会把对应版本的小节作为 GitHub Release 说明。
格式：每个版本一个 `## [x.y.z] - YYYY-MM-DD` 小节。

## [1.0.0] - 2026-11-09

首个正式版本。PureConnect 是基于 [zju-connect](https://github.com/Mythologyli/zju-connect) 内核的跨平台
EasyConnect / aTrust 客户端，支持 Android、Windows、macOS、Linux。

### 连接与认证
- 支持 EasyConnect 与 aTrust 两种协议，多配置管理、拖拽排序、分享与导入配置
- 用户名密码、TOTP、客户端证书（.p12）、TWFID 登录
- aTrust：密码 / 短信 / CAS / OAuth2 认证，登录域选择，查询认证方式，记住并信任设备，MAC 上报
- 交互式二次认证：短信 / TOTP / Radius 验证码、图形验证码、点选验证码、CAS/OAuth2 浏览器回调
- 内核错误自动归类并给出中文提示

### 接管方式
- 系统代理（Windows / macOS / GNOME / KDE），断开或退出时恢复原设置，异常退出后下次启动自动恢复
- TUN：Android 使用 VpnService（可设置不走 VPN 的应用）；桌面使用内核 TUN（Windows UAC、macOS 管理员授权、Linux pkexec）
- 仅代理模式：SOCKS5（可认证）/ HTTP 代理、允许局域网连接、Shadowsocks 服务端

### 网络与路由
- 远程 / 备用 / 本地 DNS、本地 DNS 服务、DNS 劫持、Fake IP、自定义 DNS 记录
- 端口转发（TCP/UDP）、强制代理域名、全部流量走 VPN、直连上游代理、TCP 隧道模式
- 按服务端资源添加路由、保活 URL、绑定网卡（可自动检测）、aTrust 刷新间隔
- 前置代理（如 Clash 本地端口），导出 Clash 规则便于配合使用

### 界面
- Material 3 设计，仪表盘卡片：连接状态、流量统计、虚拟 IP、连接拓扑
- 资源页：浏览 IP / 域名 / Web 资源，探测可达性并一键打开
- 实时日志：过滤、搜索、复制
- 主题：浅色 / 深色 / 跟随系统、主题色、动态取色，多款应用图标可选
- 备份与恢复：本地加密备份、WebDAV 同步
- 应用内检查更新：从 GitHub Release 获取新版本，Android 直接下载安装对应架构的 APK

### 桌面
- 托盘 / 菜单栏：状态、连接 / 断开、切换接管方式和配置、退出
- 关闭到托盘、开机自启、静默启动、隐藏 Dock 图标（macOS）、单实例运行

### 发布
- Android：arm64-v8a / armeabi-v7a / x86_64 及通用 APK
- Windows：便携版 zip 与安装程序
- macOS：通用（Apple Silicon + Intel）dmg
- Linux：tar.gz 与 deb
