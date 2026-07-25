# 知名 Windows 桌面软件技术栈调研

- 调研日期：2026-07-25
- 调研目标：为晷迹 Windows 版选择技术栈
- 产品原则：Windows 平台原生；不追求跨平台；接受按平台重写
- 资料边界：只采用产品官方源码仓库、官方工程博客与官方文档

## 结论

晷迹 Windows 版应以 **C# + WinUI 3 + Windows App SDK + .NET 10 LTS** 为首选，不共享 Swift 源码，只共享领域语义、数据交换协议、测试 fixture 与契约测试。

本次案例没有显示“知名软件都在转向某一个栈”。相反，技术栈与产品的首要约束高度一致：

- VS Code、Signal、GitHub Desktop 与 1Password 采用 Electron 或 Web UI，核心收益是跨平台 UI／代码复用；新 Teams 采用 WebView2，也保留了大规模 Web UI 与 React 资产。这些收益与晷迹“不追求跨平台、接受重写”的原则不一致。
- Telegram Desktop、OBS 与 VLC 使用 C／C++、Qt 或自有渲染层，原因与跨平台、媒体管线、插件、既有 native core 或极高性能要求密切相关。晷迹目前没有足以抵销 C++ 复杂度的同类约束。
- Windows Terminal 继续大量使用 C++，是为了复用既有 Console 组件、DirectWrite renderer、VT parser 与 text buffer；这不是一般信息管理应用选择 C++ 的证据。
- PowerToys 是由三十多个系统工具构成的混合技术仓库，其 C#／C++ 混用反映不同工具的系统集成需求，不宜复制到一个 Todo 应用。
- **Files 是最接近晷迹的参考案例**：现代、数据密集、Windows-only 风格的桌面应用，使用 C#、WinUI 3、Windows App SDK、MVVM toolkit、SQLite 与必要的 Win32／WinRT interop。

微软当前也把 WinUI 3 定位为新建原生 Windows 桌面应用的推荐 UI framework，并同时支持 C# 与 C++。[Windows app development](https://learn.microsoft.com/en-us/windows/apps/) [.NET 10 当前为 LTS，支持至 2028-11-14](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)。

WPF 是可信的后备方案，但不应因为“成熟”而成为新项目默认值。建议先用 WinUI 3 完成一个真实纵向切片；只有在可复现的产品级阻碍出现，并确认 WPF 能解决时，才切换到 WPF。

## 研究方法与限制

本报告把“官方明确披露”与“从源码直接可见”视为可确认事实；没有一手证据的实现语言或模块关系写为“未知”，不根据界面外观、安装包体积或第三方检测结果猜测。

需要注意两项样本限制：

1. 官方源码可核验的知名应用天然偏向开源软件。Microsoft Office、Microsoft To Do、Todoist、TickTick、Adobe Creative Cloud 等闭源产品即使很知名，也没有足够的一手资料支持逐项列出当前桌面栈，因此不猜测或纳入。
2. 软件会迁移技术栈。本报告尽量注明分支或产品代际；例如 Windows Terminal 当前源码仍引用 WinUI 2，不能把它误写成 WinUI 3；VLC 稳定 3.x 与下一代 master UI 也必须分开。

## 案例总览

| 类别 | 软件 | UI | 主要语言／runtime | 最值得注意的架构点 |
|---|---|---|---|---|
| Windows 原生 | Windows Terminal | C++/WinRT、WinUI 2 XAML、native renderer | C++ | 复用 Console core，并把 Terminal core 做成可复用 control |
| Windows 原生 | Windows Calculator | UWP XAML | C++、C# | 原生 UI 与计算 engine 分离；属于既有 UWP 产品 |
| Windows 原生 | Microsoft PowerToys | Settings 使用 C# + WinUI 3；各 utility 不同 | C#、C++、.NET、Win32 | 多工具、多进程、native interop 的混合仓库 |
| Windows 原生 | Files | C# + WinUI 3／Windows App SDK | C#、.NET | MVVM、SQLite、Win32／WinRT interop、MSIX |
| Web／混合 | Visual Studio Code | Electron + DOM／Web UI + Monaco | TypeScript、Electron、Node.js | 分层 core、独立 extension host、多进程 sandbox |
| Web／混合 | Microsoft Teams（new Teams） | native host + Edge WebView2；React + Fluent UI | TypeScript、React、WebView2；host 语言未知 | client data layer worker、GraphQL、IPC |
| Web／混合 | 1Password 8 Desktop | Electron web UI | Rust core；前端具体语言未被所引官方资料确认 | 除 UI 外尽量下沉到共享 Rust Core |
| Web／混合 | Signal Desktop | Electron + React | TypeScript、Electron／Node、Rust native modules | main／renderer／preload；libsignal、RingRTC、SQLCipher |
| Web／混合 | GitHub Desktop | Electron + React | TypeScript、Electron／Node | 为统一 macOS／Windows 而重写成共享 UI |
| C++／Qt | Telegram Desktop | Qt | C++、Qt | MTProto client；集成 WebRTC、FFmpeg 等 native libraries |
| C++／Qt | OBS Studio | Qt 6 Widgets | C++ frontend、C／C++ core | Qt shell + libobs + plugin modules |
| C++／Qt | VLC | 稳定 3.x：Qt Widgets；master：Qt 6／Qt Quick／QML | C／C++、Qt | UI 是 libVLC media engine 上的 interface module |

## 一、Windows 原生案例

### 1. Windows Terminal

**UI**

当前源码使用 C++/WinRT 与 XAML。`App.xaml` 使用 `Microsoft.UI.Xaml` controls，而仓库的 NuGet manifest 明确引用 `Microsoft.UI.Xaml 2.8.4`，因此应写作 **WinUI 2**，不是 WinUI 3。[App.xaml](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalApp/App.xaml) [packages.config](https://github.com/microsoft/terminal/blob/main/dep/nuget/packages.config)

**主要语言／runtime**

应用与 terminal components 主要是 C++。`TerminalAppLib.vcxproj` 直接编译大量 `.cpp` 与 XAML page；官方仓库也明确说明团队为了复用已现代化的 Console components，继续投资 C++ codebase。[TerminalAppLib.vcxproj](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalApp/TerminalAppLib.vcxproj) [官方仓库说明](https://github.com/microsoft/terminal)

**关键架构**

Windows Console 与 Windows Terminal 共享 DirectWrite text layout／rendering engine、支持 UTF-16／UTF-8 的 text buffer、VT parser／emitter 等组件。Terminal core 本身被设计为可复用 UI control；Windows Terminal 通过 ConPTY 与 command-line applications 通信。[官方仓库说明](https://github.com/microsoft/terminal)

**对晷迹的启示**

Terminal 选择 C++ 的决定建立在“已有可复用 C++ console engine + terminal renderer 性能与兼容性”上。晷迹没有类似资产，不应只因为 Terminal 是微软知名应用就选择 C++。另外，这个案例也说明不能把所有现代微软 XAML 应用统称为 WinUI 3。

### 补充案例：Windows Calculator

**UI 与主要语言**

Windows Calculator 官方仓库明确说明该应用使用 C++ 与 C#，并以 UWP／XAML 构建；当前源码仍要求 Universal Windows Platform workload 与 C++ UWP tools。[Windows Calculator repository](https://github.com/microsoft/calculator)

**关键架构**

公开架构文档把 Calculator 拆为 XAML view、view model、calculation manager 与独立 calculation engine；graphing implementation 也位于共同 interface 后面。[Application Architecture](https://github.com/microsoft/calculator/blob/main/docs/ApplicationArchitecture.md)

**对晷迹的启示**

Calculator 证明 Windows 原生应用可以让 UI 与业务 engine 分离，并由 C#／C++ 混合实现。但微软已经把 UWP 列为 maintenance mode，新建原生 Windows desktop app 推荐 Windows App SDK／WinUI 3，因此不能把 Calculator 的历史技术选择直接复制到晷迹。[Windows app development](https://learn.microsoft.com/en-us/windows/apps/)

### 2. Microsoft PowerToys

**UI**

PowerToys 不是单一 UI 应用。当前主 Settings project 是 C#／.NET，project file 设置 `UseWinUI=true`、引用 `Microsoft.WindowsAppSDK`，并把输出归入 `WinUI3Apps`；部分 utility 的 UI 与实现栈不同。[PowerToys.Settings.csproj](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/PowerToys.Settings.csproj)

**主要语言／runtime**

仓库同时包含大量 C# projects 与 C++ `.vcxproj`。Settings project 自己也直接引用 native `GPOWrapper.vcxproj`、`PowerToys.Interop.vcxproj` 与 `ZoomItSettingsInterop.vcxproj`，说明 managed UI 与 native integration 并存。[PowerToys.Settings.csproj](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/PowerToys.Settings.csproj) [PowerToys repository](https://github.com/microsoft/PowerToys)

**关键架构**

PowerToys 是三十多个 Windows utilities 的集合，不是一个内聚的单窗口产品。各 utility 面向窗口管理、keyboard hooks、Explorer extensions、OCR、launcher 等不同 OS surfaces，因此允许按模块选择 C# 或 C++。近期 Keyboard Manager editor 也由团队明确重建为 WinUI 3 UI。[PowerToys release notes](https://github.com/microsoft/PowerToys/releases)

**对晷迹的启示**

PowerToys 证明 C# WinUI 3 可以与必要的 native components 共存，但不证明晷迹应该从第一天建立混合语言架构。更合适的做法是默认全 C#，只有当某项 Windows integration 无法通过 CsWin32／WinRT projection 安全完成时，才把极窄的边界下沉到 C++。

### 3. Files

**UI**

Files 主应用是 .NET SDK project，启用 `UseWinUI`，通过 `Microsoft.UI.Xaml` XAML pages 建立 UI。依赖表明确包含 `Microsoft.WindowsAppSDK`、CommunityToolkit WinUI controls 与 `CommunityToolkit.Mvvm`。[Files.App.csproj](https://github.com/files-community/Files/blob/main/src/Files.App/Files.App.csproj) [MainPage.xaml](https://github.com/files-community/Files/blob/main/src/Files.App/Views/MainPage.xaml) [Directory.Packages.props](https://github.com/files-community/Files/blob/main/Directory.Packages.props)

**主要语言／runtime**

主要语言是 C#，当前 repository baseline 指向 .NET 10 与 Windows App SDK；应用目标包括 x86、x64 与 ARM64。依赖中还有 `Microsoft.Windows.CsWin32`、C#/WinRT、Win2D、SQLite 与 Windows Shell wrappers。[Directory.Build.props](https://github.com/files-community/Files/blob/main/Directory.Build.props) [Directory.Packages.props](https://github.com/files-community/Files/blob/main/Directory.Packages.props) [Files.App.csproj](https://github.com/files-community/Files/blob/main/src/Files.App/Files.App.csproj)

**关键架构**

从 project manifest 可确认它把现代 WinUI controls／MVVM、SQLite 数据层，以及必要的 Shell／Win32／WinRT interop 组合在同一个原生 Windows 产品中；MSIX tooling 也在 app project 内启用。更细的高层模块边界没有在所引一手资料中形成稳定架构声明，因此不继续推断。

**对晷迹的启示**

这是本次样本中最接近晷迹的技术参照：界面与数据交互密集、需要 Windows Shell integration，但不需要自研 media／terminal engine。它表明 C# + WinUI 3 并不妨碍 SQLite、复杂导航、文件系统操作或必要的 Win32 interop。

## 二、Electron／WebView 混合案例

### 4. Visual Studio Code

**UI**

VS Code desktop 使用 Electron，Workbench 承载 Monaco Editor Core，并通过 DOM／browser APIs 构建 UI。[Source Code Organization](https://github.com/microsoft/vscode/wiki/source-code-organization)

**主要语言／runtime**

VS Code core 完全以 TypeScript 实现。desktop runtime 包括 Electron 的 main、renderer、utility processes，以及 Node.js 能力；官方源码组织明确区分 `common`、`browser`、`node`、`electron-browser`、`electron-utility` 与 `electron-main` target environments。[Source Code Organization](https://github.com/microsoft/vscode/wiki/source-code-organization)

**关键架构**

Core 分为 `base`、`platform`、`editor`、`workbench`、`code` 与 `server` layers，使用 service／dependency injection。Extensions 在独立 extension host process 内运行；Electron renderers 开启 sandbox，shared process 与各窗口通过 IPC 协作。[Source Code Organization](https://github.com/microsoft/vscode/wiki/source-code-organization) [Migrating VS Code to Process Sandboxing](https://code.visualstudio.com/blogs/2022/11/28/vscode-sandbox)

**对晷迹的启示**

VS Code 的选择让 desktop 与 Web 共享大量代码，并承载庞大 extension ecosystem。这两点都不是晷迹 Windows 首版的约束。可以借鉴的是“领域／平台服务分层、扩展工作隔离、renderer 不直接取得高权限”，不是 Electron 本身。

### 5. Microsoft Teams（new Teams）

**UI**

new Teams 的 Windows native host 使用 Edge WebView2，用户体验层标准化在 ReactJS、TypeScript 与 Fluent UI。微软明确把它描述为从 classic Teams 的 Electron architecture 迁移到 WebView2 host。[Microsoft Teams: Advantages of the new architecture](https://techcommunity.microsoft.com/blog/microsoftteamsblog/microsoft-teams-advantages-of-the-new-architecture/3775704) [New Teams security architecture](https://techcommunity.microsoft.com/blog/microsoftteamsblog/what%E2%80%99s-new-for-security-in-the-new-microsoft-teams/3804261)

**主要语言／runtime**

已确认的是 TypeScript／React 与 Evergreen Edge WebView2 runtime。所引官方资料没有披露 Windows native host 的实现语言，故记为 **未知**。

**关键架构**

Client data layer 从 UI main thread 移到 worker；GraphQL 抽象 client data layer；IPC 连接 native host 与其他 parts。Teams platform apps 在 out-of-process iframe／Edge Renderer Process 中运行。Evergreen WebView2 runtime 可随 Edge 独立更新，并被多个 embedding apps 共享。[Microsoft Teams: Advantages of the new architecture](https://techcommunity.microsoft.com/blog/microsoftteamsblog/microsoft-teams-advantages-of-the-new-architecture/3775704) [Teams WebView2 runtime](https://learn.microsoft.com/en-us/microsoftteams/platform/resources/teams-updates)

**对晷迹的启示**

Teams 选择 WebView2 的背景是已有庞大的 React／Web product surface 与多平台协同，并希望共享 Edge runtime。晷迹若没有既有 Web client，直接采用 WebView2 会先引入 host／web bridge、runtime process failure、user-data folder 与 security boundary，却没有获得相应复用收益。

### 6. 1Password 8 Desktop

**UI**

1Password 官方工程回顾明确说明 Windows 选择 web UI approach；Linux proof of concept 以 Electron 打包，随后 Electron 覆盖 desktop platforms。官方资料没有足够信息确认当前 Windows UI 的具体前端语言，因此不把 React 或 TypeScript写成已确认事实。[1Password 8: The Story So Far](https://1password.com/blog/1password-8-the-story-so-far)

**主要语言／runtime**

共享 backend／underlying logic 使用 Rust。官方还公开了用于 1Password desktop secure frontend foundation 的 Electron secure defaults，但这只能确认 Electron security foundation，不能单独证明整个产品 UI 的语言。[1Password 8: The Story So Far](https://1password.com/blog/1password-8-the-story-so-far) [electron-secure-defaults](https://github.com/1Password/electron-secure-defaults)

**关键架构**

团队把 server communication、database、permissions enforcement、cryptography 与 search 等尽可能集中到共享 Rust Core，只把 UI 留在 platform frontend。Electron frontend 使用 sandbox、context isolation、restricted bridge 与 strict Content Security Policy 等硬化措施。[1Password 8: The Story So Far](https://1password.com/blog/1password-8-the-story-so-far) [electron-secure-defaults](https://github.com/1Password/electron-secure-defaults)

**对晷迹的启示**

1Password 是“共享跨平台 core + 多端一致业务行为”的强案例，但晷迹已经明确接受 Windows 重写。应借鉴的是把 permissions、storage、sync 与 domain invariants 放到深模块，并用契约测试保证 Swift／C# 行为一致；不需要为了共享源码引入 Rust Core 或 Electron。

### 7. Signal Desktop

**UI**

官方 repository manifest 直接列出 Electron、React／ReactDOM、TypeScript／TSX、Sass 与 Tailwind，desktop entry point 是 `bundles/main.js`。[Signal Desktop repository](https://github.com/signalapp/Signal-Desktop) [package.json](https://github.com/signalapp/Signal-Desktop/blob/main/package.json)

**主要语言／runtime**

UI 与 desktop orchestration 主要运行在 TypeScript + Electron／Node.js；native modules 包括 `@signalapp/libsignal-client`、RingRTC 与 SQLCipher。libsignal repository 说明其底层实现主要是 Rust，并向 TypeScript 等 clients 提供 APIs。[Signal Desktop package.json](https://github.com/signalapp/Signal-Desktop/blob/main/package.json) [libsignal](https://github.com/signalapp/libsignal)

**关键架构**

源码可直接看到 Electron main／renderer／preload boundary；Windows packaging 使用 electron-builder 与 NSIS。Cryptographic protocol、calling／media 与 encrypted storage 下沉到独立 native modules，而 UI 仍以 Web stack 交付。

**对晷迹的启示**

Signal 的分层适合“跨平台 UI + 高安全 native crypto／media modules”。晷迹没有必须由 Rust native module 承担的密码学协议，也不需要以一套 UI 支持三个 desktop OS，因此不应照搬其部署与 IPC 复杂度。

### 8. GitHub Desktop

**UI**

官方 repository 直接声明 GitHub Desktop 是 Electron app，使用 TypeScript 与 React。[GitHub Desktop repository](https://github.com/desktop/desktop)

**主要语言／runtime**

TypeScript、React、Electron／Node.js；Git operations 还依赖独立的 native／bundled Git components，但本报告不进一步推断未在 README 中定义的当前进程边界。

**关键架构**

GitHub 官方工程文章说明，这次 Electron rewrite 的核心动机是把原来独立的 macOS 与 Windows products 合并为共享逻辑与 UI，避免功能做两次，并为潜在 Linux support 留路。[How Four Native Developers Wrote An Electron App](https://github.blog/engineering/architecture-optimization/how-four-native-developers-wrote-an-electron-app/)

**对晷迹的启示**

这个案例几乎是晷迹原则的反例对照：GitHub Desktop 为了消除双平台重写而选择 Electron；晷迹则主动接受双实现，以换取平台原生体验。两者目标不同，不能只比较开发速度。

## 三、C++／Qt／自绘案例

### 9. Telegram Desktop

**UI**

官方 repository 明确列出经过轻微 patch 的 Qt 6 与 Qt 5.15，应用并非 Electron／WebView UI。[Telegram Desktop repository](https://github.com/telegramdesktop/tdesktop)

**主要语言／runtime**

主要实现为 C++／CMake；官方 repository 同时列出 OpenSSL、WebRTC、OpenAL、Opus 与 FFmpeg 等 native dependencies。[Telegram Desktop repository](https://github.com/telegramdesktop/tdesktop) [CMake build entry](https://github.com/telegramdesktop/tdesktop/blob/dev/CMakeLists.txt)

**关键架构**

可确认它是基于 Telegram API 与 MTProto 的 desktop client，并以多项 native libraries 承担 networking、media 与 calling。所引官方资料没有稳定的高层 module diagram，因此不猜测内部 UI pattern 或进程模型。

**对晷迹的启示**

Telegram 的 Qt／C++ 选择同时服务于跨平台与重 native dependency graph。晷迹不需要共享 Windows／macOS UI，也没有 WebRTC／codec pipeline；采用 Qt 会牺牲 Windows-specific design system，却得不到它最主要的回报。

### 10. OBS Studio

**UI**

OBS frontend 明确查找并链接 Qt 6 Widgets、Network、Svg 与 Xml；Qt `.ui`／`.qrc` 由 AUTOUIC／AUTORCC 处理，因此是 Qt Widgets native desktop UI，不是 WebView。[ui-qt.cmake](https://github.com/obsproject/obs-studio/blob/master/frontend/cmake/ui-qt.cmake)

**主要语言／runtime**

Frontend 主要是 C++；`libobs` 对 applications 与 modules 暴露 C API，repository 主体为 C 与 C++。[OBS Studio repository](https://github.com/obsproject/obs-studio) [libobs API](https://github.com/obsproject/obs-studio/blob/master/libobs/obs.h)

**关键架构**

`obs-studio` frontend executable 链接 `OBS::libobs` 与 `OBS::frontend-api`。Media core 把 source、filter、transition、output、encoder 与 service 建模为 modules；Windows graphics backend 可使用 D3D11。[frontend/CMakeLists.txt](https://github.com/obsproject/obs-studio/blob/master/frontend/CMakeLists.txt) [libobs API](https://github.com/obsproject/obs-studio/blob/master/libobs/obs.h)

**对晷迹的启示**

OBS 是“复杂实时 media engine + plugin ecosystem + 薄 UI shell”的典型。它证明 Qt 能包住高性能 C／C++ core，但不能证明普通 productivity app 值得承担同等语言、ABI、deployment 与 UI customization 成本。

### 11. VLC

**UI**

必须按代际区分：

- 官方当前 Windows 下载版本为 3.0.23；其 3.x source line 的 desktop UI 是 Qt Widgets／C++，build manifest 包含大量 `.cpp`、`.hpp` 与 `.ui`。[VLC for Windows](https://www.videolan.org/vlc/download-windows.html) [VLC 3.x Qt UI](https://github.com/videolan/vlc/tree/3.0.x/modules/gui/qt) [3.x Makefile.am](https://github.com/videolan/vlc/blob/3.0.x/modules/gui/qt/Makefile.am)
- Master／下一代 UI 使用 Qt 6、Qt Quick／QML，并仍包含 Widgets 与 C++ compositor／controller／model。[master qt6.pro](https://github.com/videolan/vlc/blob/master/modules/gui/qt/qt6.pro) [master Qt interface](https://github.com/videolan/vlc/tree/master/modules/gui/qt)

**主要语言／runtime**

Media core 与 libVLC 主要是 C／C++；Qt interface 是 core 上的一个 UI module。VLC 官方把 libVLC 描述为可嵌入其他 applications 的 multimedia framework。[libVLC](https://www.videolan.org/vlc/libvlc.html)

**关键架构**

核心 media engine、codec／output plugins 与 UI interface 分离；Qt UI 可从 Widgets 演进到 QML，而不重写整个 libVLC engine。

**对晷迹的启示**

值得借鉴的是“domain／engine 不依赖 UI framework”的边界，而不是 Qt 本身。晷迹的 C# Domain project 同样应避免引用 WinUI，让 UI 可以重构而不破坏任务、日轨迹、同步与烛龙规则。

## 五条候选路线比较

### 比较表

| 路线 | UI 与 Windows 一致性 | 开发与维护 | Windows API／interop | Runtime／部署特点 | 与晷迹原则的匹配 |
|---|---|---|---|---|---|
| C# + WinUI 3 | 最直接采用当前 Fluent controls、Windows App SDK 与 app lifecycle | C#／XAML 生产力高；框架较新，需真实验证边角能力 | C#/WinRT；Win32 可用 CsWin32／P/Invoke | 可 framework-dependent 或 self-contained；可 MSIX 或 unpackaged | **最佳** |
| WPF + C# | Windows-only 且成熟，但默认控件与现代 Windows 11 视觉有代差 | 工具、控件、资料与稳定性成熟 | 可直接 .NET interop，也可接 Windows App SDK | .NET desktop deployment 成熟 | **后备** |
| C++ + WinUI 3 | 与 C# 使用相同 WinUI 3／XAML | 手动内存／ABI／template／build complexity 更高 | C++/WinRT、COM、Win32 最直接 | Native binary；仍需处理 Windows App SDK deployment | 只适合已有 C++ core 或被证实的性能／ABI需求 |
| Electron／WebView2 | UI 由 Web technology 塑造；要额外实现 Windows 行为与细节 | Web 团队和跨平台共享时高效；多进程、IPC、安全与更新面更大 | 通过 Electron native modules 或 WebView host bridge | Electron 自带 Chromium／Node；WebView2 通常共享 Evergreen runtime | 与“不追求跨平台”冲突，不宜作主 UI |
| C++ + Qt | 成熟 desktop toolkit，但设计语言以跨平台 abstraction 为主 | C++ 与 Qt tooling 成熟；Qt／plugin／license 成本需长期承担 | 可调用 Win32，但不是 Windows App SDK 的首选 projection | 需部署 Qt DLL、platform plugin、QML modules 等 | 与“不追求跨平台”冲突，不宜选择 |

### 1. C# + WinUI 3

微软把 WinUI 3 定义为当前推荐的 native Windows desktop UI framework；它属于 Windows App SDK，可用 C# 或 C++ 与 XAML，并面向 Windows 10 1809+ 与 Windows 11。[WinUI 3](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/) [Windows App SDK platform overview](https://learn.microsoft.com/en-us/windows/apps/develop/platform/)

对晷迹，C# 比 C++ 更合适：

- Todo、日轨迹、搜索、SQLite、sync、AI orchestration 都不是需要 C++ 才能成立的 hot path。
- C# 可以直接使用 C#/WinRT；调用 Win32 时，微软推荐使用 CsWin32 source generator。[C# WinUI and Win32 interop](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/desktop-winui3-app-with-basic-interop)
- Files 与 PowerToys Settings 已证明 WinUI 3 C# 可以服务真实、复杂的 Windows desktop products。
- .NET 10 是当前 LTS，可把新项目生命周期放在受支持 baseline 上。[.NET support policy](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)

主要风险不是语言性能，而是 WinUI 3 较新的窗口管理、控件细节、UI automation、输入与 deployment edge cases。应通过纵向切片取得运行证据，不应在设计阶段凭印象放弃。

Windows App SDK 可 framework-dependent 或 self-contained；前者部署较小且 serviceability 较好，后者把 SDK dependencies 随应用携带。MSIX、unpackaged 与 self-contained 是不同维度，应在 release spike 中实测选择。[Windows App SDK deployment overview](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/deploy-overview)

### 2. WPF

WPF 是 Windows-only 的 .NET UI framework，使用 XAML、data binding、styles／templates 与 vector-based rendering engine；它仍被官方支持。[WPF overview](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)

其优势是成熟、可预测、第三方控件与调试资料丰富。代价是默认视觉模型不等于当前 WinUI／Fluent，若大量重做 control templates，应用虽然 Windows-only，却不一定更“平台原生”。Windows App SDK 可以被现有 WPF app 增量使用，但这不把 WPF controls 自动变成 WinUI controls。[Windows App SDK](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/)

因此 WPF 应是实证后备，而不是心理保险：

- 若 WinUI 3 在晷迹必须的 keyboard navigation、drag-and-drop、multi-window、accessibility automation、rich text 或 testing path 上出现可复现 blocker；
- 且 WPF prototype 能证明这些路径通过；
- 才整体切换，不做长期 WinUI／WPF 双 UI。

### 3. C++ + WinUI 3

C++/WinRT 与 C#/WinRT 都是 WinUI 3 官方支持 projection；两者使用同一套 WinUI 3 XAML。[Windows App SDK platform overview](https://learn.microsoft.com/en-us/windows/apps/develop/platform/)

C++ 的合理触发条件应很窄：

- 已有必须复用的 C++ engine；
- 对 COM／ABI 暴露有明确要求；
- profiler 证明某一计算或 I/O component 需要 native optimization；
- 某个 Windows SDK 没有可靠的 managed projection。

即使触发，也优先把 C++ 限制在独立 component，并从 C# UI 通过清楚的 contract 调用。微软有正式路径把 C++/WinRT component 投影给 .NET app。[C++/WinRT component to C# projection](https://learn.microsoft.com/en-us/windows/apps/develop/platform/csharp-winrt/net-projection-from-cppwinrt-component)

晷迹不应为了“更原生”把整个应用写成 C++：WinUI 3 的 controls 与 rendering path 不会因为 code-behind 从 C# 改成 C++ 就变得更 Windows。

### 4. Electron／WebView2

Electron 把 Chromium 与 Node.js 打包进应用，以一个 JavaScript codebase 支持 Windows、macOS 与 Linux；其标准架构包含 main、renderer、preload 与 utility processes。[Electron introduction](https://www.electronjs.org/docs/latest/) [Electron process model](https://www.electronjs.org/docs/latest/tutorial/process-model)

WebView2 不等同于 Electron。它是 native host 内嵌 Edge rendering runtime；Evergreen runtime 自动更新并可被多个 apps 共享，但 host 必须管理 user-data folder、process failures 与 web／native security boundary。[WebView2 development best practices](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/developer-guide)

它们适合：

- 已有大型 Web UI 需要复用；
- desktop 与 browser 必须高比例共享；
- UI extension ecosystem 本来就是 HTML／CSS／JavaScript；
- 产品明确接受 Web rendering 与 native bridge 的工程成本。

晷迹目前没有这些条件。若以后某个独立 surface 确实需要 Web content，例如受限的富文档 renderer，也可以把 WebView2 当局部 component；这不构成用 WebView2 建整个应用 shell 的理由。

### 5. C++ + Qt

Qt 能以 Widgets 或 Qt Quick／QML 构建成熟 desktop UI，也有完整 Windows deployment tooling。但 Windows package 必须带上所需 Qt libraries、QML modules、runtime dependencies 与 `qwindows.dll` platform plugin。[Qt for Windows deployment](https://doc.qt.io/qt-6/windows-deployment.html)

Qt 的核心价值是跨平台 abstraction 与 C++ ecosystem。晷迹主动不追求跨平台，因此这项价值被移除；与此同时，还要承担 Windows design language 适配、Qt deployment 与 license compliance。Qt 同时提供 commercial 与 open-source licenses，LGPL／GPL obligations 必须纳入产品决策，不能只看技术能力。[Qt licensing](https://www.qt.io/development/open-source-lgpl-obligations)

除非未来策略重新改为共享 Windows／Linux UI，或出现必须基于 Qt 的既有 C++ engine，否则不选 Qt。

## 对晷迹的建议架构

```text
Windows/
├── Noonmark.Windows.App              # WinUI 3：窗口、页面、命令、通知、托盘
├── Noonmark.Application              # use cases、事务边界、DTO
├── Noonmark.Domain                   # 任务、日轨迹、任务链、子任务领域规则
├── Noonmark.Infrastructure.Sqlite
├── Noonmark.Infrastructure.Sync
├── Noonmark.Infrastructure.AI
├── Noonmark.Windows.Interop          # 仅放必要的 Win32／WinRT adapter
└── Noonmark.Tests

SharedContracts/
├── domain-scenarios/                 # 平台中立命令／结果 fixture
├── sync-protocol/                    # 版本化 wire contract
└── export-format/                    # 版本化数据交换格式
```

边界原则：

1. `Noonmark.Domain` 不引用 WinUI、SQLite 或 WebView2。
2. 不逐行翻译 Swift；依据 `CONTEXT.md`、行为规格与 fixtures 重新实现 C# domain model。
3. Mac 与 Windows 不共享 SQLite file，也不假设数据库 schema 必须相同。
4. 两端共享的是可版本化的 sync／export contract，以及同一组 domain scenario tests。
5. Win32／COM 只通过 `Noonmark.Windows.Interop` 暴露小接口；不让 platform handles 渗入 domain。
6. 先保持全 C#；只有运行数据证明必要时才增加 C++ component。
7. UI 完全遵循 Windows interaction conventions，不机械复刻 SwiftUI view tree。

## 建议的决策验证

在全面移植前，用 C#／WinUI 3 完成一个可安装纵向切片：

1. 原生窗口、navigation、light theme、keyboard／screen-reader path。
2. 创建 Todo、编辑、完成、撤销。
3. SQLite 落库，退出后重启回读。
4. 一段 AI SSE response 的流式显示与取消。
5. Tray、notification、global shortcut 中实际需要的最小集合。
6. x64 MSIX 安装、升级、卸载与 clean user machine 启动。
7. UI automation 跑通同一真实用户路径。

切片应记录：

- cold／warm startup；
- idle 与典型页面 memory；
- 100、1,000、10,000 items 的 list scroll 与 search latency；
- keyboard focus order 与 Narrator output；
- packaged／unpackaged、framework-dependent／self-contained 的安装行为；
- crash／log／data recovery path。

只有出现具体 blocker 才启动同范围 WPF spike，并用同一组用户路径与指标对照。不要同时维持两套 UI，也不要因为某个孤立 control 不理想就提前转向 Electron 或 Qt。

## 最终选择

**主选**

- UI：WinUI 3／Windows App SDK
- 语言：C#
- Runtime：.NET 10 LTS
- 架构：UI、application、domain、infrastructure、Windows interop 分层
- 持久化：SQLite，通过 repository boundary 隔离
- 发布：优先验证 signed MSIX；同时实测 framework-dependent 与 self-contained

**后备**

- WPF + C#，仅在 WinUI 3 纵向切片出现产品级 blocker 且 WPF 对照通过时采用。

**不作为主选**

- C++／WinUI：没有既有 C++ core 或已证实 hot path。
- Electron／WebView2：没有 Web codebase 或跨平台 UI 复用目标。
- Qt：不需要跨平台 abstraction，也不值得引入额外 runtime／license／Windows visual adaptation 成本。

最重要的决策不是“哪个知名软件用了什么”，而是它为何这样选。按晷迹自己的约束，C# + WinUI 3 保留了最高的平台一致性，同时没有引入 terminal／media 产品才需要的 C++ 复杂度，也没有引入跨平台产品才愿意承担的 Web／Qt abstraction。
