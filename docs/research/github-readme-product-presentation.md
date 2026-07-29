# GitHub 产品型 README 信息架构调研

- 调研日期：2026-07-28
- 调研目标：为晷迹（Noonmark）编写兼具商业产品表达和工程可信度的高级版根目录 README
- 资料边界：只采用 GitHub 官方文档，以及项目自己维护的 README、仓库或文档
- 适用版本：晷迹 macOS `v1.0`

## 结论摘要

晷迹的根目录 README 应同时服务两类读者：

1. **产品使用者**要在首屏知道“这是什么、为什么值得用、实际长什么样、在哪里安装”；
2. **开发者和评估者**要快速找到“如何构建、架构如何分层、质量如何验证、如何报告问题、以什么许可使用”。

最合适的结构不是把所有文档搬进 README，而是以一张真实 App 主界面图建立产品印象，用按用户任务组织的实机截图说明核心能力，再用简洁章节把安装、数据边界、架构、质量、安全、贡献和许可导向可维护的专项文档。

GitHub 官方把 README 定义为仓库访问者经常最先看到的内容，典型问题包括：项目做什么、为什么有用、如何开始、到哪里求助、由谁维护；同时明确建议把长篇文档移出 README。[GitHub：About the repository README file](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

因此，“商业级”应表现为以下特征，而不是堆叠营销形容词：

- 产品定位具体，价值主张可由当前功能支持；
- 截图全部来自可重复生成、经过对账的真实 `.app`；
- 安装要求、支持范围和未支持边界明确；
- 架构、测试、安全和数据承诺都可追溯到源码、CI 或专项文档；
- 下载、反馈、漏洞报告、贡献和许可各有正确入口；
- 不用失效徽章、陈旧测试数字或未经证实的性能、隐私和可靠性声明制造“工业感”。

## 一、GitHub 官方约束

### 1. README 的职责和长度

GitHub 认为 README 通常需要回答：项目做什么、为什么有用、如何开始、到哪里获得帮助、由谁维护和贡献。README 与 `LICENSE`、`CONTRIBUTING`、`CODE_OF_CONDUCT` 等文件共同传达项目预期，而不是替代这些文件。[GitHub：About the repository README file](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

GitHub 会自动展示位于 `.github/`、仓库根目录或 `docs/` 的 README；多个 README 并存时按 `.github/`、根目录、`docs/` 的顺序选择。晷迹应使用**根目录 `README.md`**，避免被其他目录的说明文件意外抢占主入口。[GitHub：About the repository README file](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

GitHub 会截断超过 `500 KiB` 的 README，并建议 README 只保留开始使用和参与项目所必需的内容，长篇说明进入 wiki 或专项文档。[GitHub：About the repository README file](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes) 对晷迹而言，设计文档、完整 ADR、测试矩阵和功能规格应继续留在 `docs/`，README 只给摘要和稳定链接。

### 2. 标题、目录和链接

GitHub 会根据两级以上标题自动生成文档 Outline，并给标题生成可直接访问的 section link，因此不必再维护一份容易漂移的手写超长目录。[GitHub：Basic writing and formatting syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax)

仓库内部文档和图片应使用相对路径。GitHub 会根据当前分支转换相对链接，而且相对链接在仓库被 clone 后仍可工作；官方也明确建议仓库内图片使用相对路径。[GitHub：About the repository README file](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes) [GitHub：Basic writing and formatting syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax)

### 3. 截图和替代文本

GitHub Markdown 图片语法中的 `alt` 不是文件名或装饰文字，而应是“图片所承载信息的简短文字等价物”。[GitHub：Basic writing and formatting syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#images)

README 截图建议：

- 图片提交到仓库内固定目录，例如 `docs/assets/readme/`，由相对路径引用；
- 每张图都写具体 alt，例如“晷迹 Day Todo 显示按分组排列的今日任务、子任务和右侧任务详情”，不要只写“截图一”；
- 在图外保留标题或一句说明，不能让截图成为功能信息的唯一载体；
- 使用真实 `.app` 和固定演示数据，不使用 HTML 原型、设计稿或含个人数据的宿主机截图；
- 统一窗口尺寸、缩放、浅色外观、截图边界和命名，不混入红框、鼠标指针、调试窗口或不一致日期；
- 优先使用清晰静态 PNG；GitHub 支持 PNG、GIF、JPEG、SVG 和常见视频格式，但浏览器对视频编码的兼容性不同。[GitHub：Attaching files](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)

若使用 GitHub Alert，官方建议只在用户成功确实依赖该信息时使用，并把每篇内容限制在一到两个，避免连续堆放。[GitHub：Basic writing and formatting syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts) README 首屏不应堆叠“注意”“重要”“警告”卡片；安装限制或数据风险只保留最关键的一条。

### 4. 徽章和质量声明

GitHub 官方 workflow badge 只能说明对应 workflow 当前是通过还是失败，默认反映默认分支状态；它不自动证明产品功能、测试覆盖率或发行包质量。[GitHub：Adding a workflow status badge](https://docs.github.com/en/actions/how-tos/monitor-workflows/add-a-status-badge)

晷迹可在首屏保留少量可验证徽章：

- `CI / make check`：链接到真实 workflow；
- `macOS 14+`：来自 `Package.swift` 的平台下限；
- `Swift 6`：来自 Swift tools manifest；
- 许可徽章：**只有确定并落盘许可后**才能显示。

不要添加无法点击、长期无人维护或不能代表 `main` 的徽章，也不要把本地跑过一次的测试结果伪装为持续状态。固定写“1230 项测试”会随测试增减迅速漂移，宜写测试层级和门禁入口；若一定展示数量，应由 CI 自动生成并标注采样提交。

### 5. Release、tag 与安装包

GitHub 把 Release 定义为建立在 Git tag 上、可附带发行说明和二进制文件的可部署软件版本；单独的 tag 只标记历史点，不等同于已经提供安装资产的 GitHub Release。[GitHub：About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

因此 `v1.0` README 中的“下载”按钮只能指向以下真实入口之一：

- 已发布并附有经过验证 DMG 的 GitHub Release；
- 项目官方网站的稳定下载页；
- 明确写为“从源码构建”，并给出命令和环境要求。

在 Release 尚未创建或 DMG 尚未上传前，不应放一个会产生 `404` 的“下载最新版”链接。

### 6. 安全、贡献和许可

GitHub 建议使用 `SECURITY.md` 说明受支持版本和漏洞报告方式；敏感漏洞不应被引导到公开 Issue。[GitHub：Adding a security policy](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/add-security-policy)

GitHub 会在仓库总览、贡献页面、Issue 和 Pull Request 流程中主动展示 `CONTRIBUTING`；该文件适合承载 Issue／PR 要求、开发流程、行为预期和 Code of Conduct 链接，README 只需给一个入口。[GitHub：Setting guidelines for repository contributors](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors)

GitHub 的 community profile 会检查 `README`、`CODE_OF_CONDUCT`、`LICENSE`、`CONTRIBUTING` 等健康文件。[GitHub：About community profiles for public repositories](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories)

公开仓库并不会自动成为开源软件。没有许可证时，默认版权规则仍然适用；GitHub 官方鼓励把清晰、可识别的许可证文件放在仓库根目录。[GitHub：Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository) 晷迹在许可决策完成前不得显示 MIT、Apache、AGPL 等许可徽章，也不得笼统写“开源、可自由使用和修改”。

## 二、经典项目 README 的一手案例

### 案例对比

| 项目 | 首屏与定位 | 产品展示 | 工程与信任入口 | 对晷迹的启示 |
| --- | --- | --- | --- | --- |
| GitHub Desktop | 产品身份和实现技术后立即展示真实桌面 App | 一张支持亮暗主题的核心工作流图，alt 具体描述画面 | 正式／Beta／历史／社区安装渠道、支持、贡献、构建、许可 | 普通用户安装和源码构建必须分开；一张有任务的实机图胜过截图墙 |
| Visual Studio Code | 仓库名称、状态徽章，并先解释 `Code - OSS` 与正式产品的关系 | 一张“VS Code in action”真实产品图 | 下载、贡献、反馈、行为准则、许可 | 先讲清源码仓库和产品发行物的边界，再讲产品价值 |
| Ghostty | Logo、一句话定位、About／Download／Documentation／Contributing 快捷入口 | 首屏极简，没有把所有功能做成海报 | 路线状态、原生架构、crash report 隐私边界 | 简洁首屏和明确状态比大量 badge 更可信；敏感诊断数据应主动披露 |
| Zed | 一句话介绍后直接进入各平台安装 | 不在 README 重复官网式营销页面 | 分平台构建、贡献、许可、商业公司身份 | 用户安装与开发构建分开，平台状态明确 |
| AppFlowy | 产品名、定位、社区入口和多张产品图 | 展示任务、数据库、站点、AI、模板、跨设备 | 安装、技术栈、路线图、版本、贡献、使命、许可 | 图像能快速说明产品，但连续大图和过多社区徽章会稀释首屏焦点 |
| Syncthing | Logo、少量质量徽章，按优先级公开产品目标 | 以文字为主 | Getting Started、支持、安全报告、构建、签名发行、许可 | 对数据产品，安全／可靠目标和签名发行比空泛“工业级”更有说服力 |
| Bitwarden Clients | 品牌图和针对各客户端的真实 CI badge | 品牌组合图 | 构建文档、相关项目、贡献、`SECURITY.md` | 多模块仓库可分开显示门禁；安全反馈要有独立、可发现的入口 |
| OBS Studio | 一句话准确说明用途 | 不依赖长功能清单 | 文档、构建、API、Bug、贡献、Code of Conduct、静态分析 | README 可以是高质量导航页，不必复刻完整官网 |

一手来源：

- [GitHub Desktop README](https://github.com/desktop/desktop/blob/development/README.md)
- [Visual Studio Code README](https://github.com/microsoft/vscode/blob/main/README.md)
- [Ghostty README](https://github.com/ghostty-org/ghostty/blob/main/README.md)
- [Zed README](https://github.com/zed-industries/zed/blob/main/README.md)
- [AppFlowy README](https://github.com/AppFlowy-IO/AppFlowy/blob/main/README.md)
- [Syncthing README](https://github.com/syncthing/syncthing/blob/main/README.md)
- [Bitwarden Clients README](https://github.com/bitwarden/clients/blob/main/README.md)
- [OBS Studio README](https://github.com/obsproject/obs-studio/blob/master/README.rst)

### 可复用规律

这些项目没有统一模板，但反复出现六个稳定规律：

1. **一句话先说类别和差异**：Ghostty 先说自己是快速、原生、功能完整的 terminal；VS Code 先解释编辑器的核心循环；Syncthing 直接定义为持续文件同步程序。
2. **安装入口早于开发环境**：Zed、Ghostty 和 AppFlowy 都让普通用户先找到下载，源码构建另开章节或文档。
3. **产品图必须有任务**：VS Code 的单图说明产品运行状态；AppFlowy 的图片分别对应任务、数据库、站点、AI 等能力，而不是纯装饰。
4. **README 是导航，不是文档仓库**：OBS 把指南、构建和 API 分别链接到官方文档；Ghostty也把下载和文档放到稳定入口。
5. **信任来自边界透明**：VS Code 区分开源仓库与商业发行许可；Ghostty说明 crash report 的生成、发送和敏感性；Syncthing说明签名发行和私下报告漏洞。
6. **贡献和支持路径分工**：Bug、功能请求、讨论、漏洞和代码贡献不是同一个入口；VS Code、Syncthing、OBS 都明确区分。

GitHub Desktop 还提供了两个尤其适合桌面产品的细节：用 `<picture>` 为亮暗主题提供不同截图，并把截图 alt 写成具体操作场景；同时把官方稳定安装、Beta、历史版本、社区发行和源码构建拆成独立入口。[GitHub Desktop README](https://github.com/desktop/desktop/blob/development/README.md) 晷迹当前以亮色为产品基调，不必为了形式强制制作暗色截图，但应继承“单图说明真实任务”和“发行渠道不混淆”的原则。

## 三、晷迹 README 推荐结构

以下顺序既适合 GitHub 首次访问，也能覆盖产品、工程和面试介绍场景。

### 0. 首屏 Hero

建议只保留：

1. 晷迹 Logo、`晷迹 Noonmark`；
2. 一句定位：产品类别 + 用户结果 + 核心差异；
3. 2–4 个主入口：下载、产品导览、技术架构、开发；
4. 最多 3 个可验证徽章；
5. 一张来自固定交互演示基线的 Day Todo 主界面图。

定位句应避免“下一代、颠覆、极致、企业级、AI 驱动的一切”之类不可验证表达。更稳妥的句式是：

> 面向 macOS 的原生、local-first 日任务系统，把任务从记录、排期、执行延续到复盘。

这只是结构示例；正式文案必须再与当前功能、领域术语和实际 UI 对账。

### 1. Why Noonmark／产品主张

用三到四条说明产品解决的问题，不列完整功能：

- 从“记住事情”推进到“今天做什么”；
- 任务状态和历史轨迹分离，保留真实演进；
- 重复计划、未来排期与每天实例有明确边界；
- 本地数据优先，AI 和同步均为显式配置的辅助能力。

每条都必须能链接到产品规格、ADR 或真实界面，不能把愿景写成已经实现。

### 2. Product Tour／真实产品导览

按用户路径而不是源码模块组织截图：

| 顺序 | 推荐画面 | 说明重点 |
| --- | --- | --- |
| 1 | Day Todo + 任务详情 | 今天的执行入口、分组／标签、子任务和轨迹 |
| 2 | 任务池 + 快速创建 | 捕捉尚未排期的任务、快速语法和整理入口 |
| 3 | 未来计划 + 月历 | 未来排期、日历浏览和某日详情 |
| 4 | 重复计划 | 周期规则、状态区分、实例展开和结束边界 |
| 5 | 未完成／已完成 | 延续、延期、真实历史和父子任务呈现 |
| 6 | 烛龙 | 基于任务上下文的会话、建议与权限边界 |
| 7 | 全局快速输入 | 在其他 App 中快速捕捉任务及标签／分组语法 |
| 8 | 设置／同步 | AI Provider、iCloud 同步状态、失败反馈和数据导入导出 |

不建议把八张全尺寸截图连续铺开。更好的排法是：

- 首屏一张全宽 Hero；
- 后续用四组“功能标题 + 1–2 句说明 + 一张图”；
- 次要功能使用两列 `<picture>`／`<img>` 组合或折叠到 `<details>`；
- 每张截图只承担一个主要叙事，不重复展示同一页面的细微变化。

### 3. Core Capabilities／核心能力

把功能收敛成 6–8 个能力域，而不是几十项字段清单：

- 今日执行与任务池；
- 排期、延续、延期与轨迹；
- 分组、标签、置顶与子任务；
- 重复计划及周期实例；
- 未完成、已完成和日历复盘；
- 全局快速输入；
- 烛龙 AI 协作；
- local-first 数据、导入导出和 iCloud 同步。

每个能力域使用一句“用户可获得什么”加一句关键边界。不要重复截图中已经可见的全部控件。

### 4. Installation／安装

分开写：

- **普通用户安装**：支持的 macOS 版本、CPU 架构、DMG 下载、首次打开方式、升级方式；
- **从源码构建**：Xcode／Swift 工具链、clone、`make build-app` 或仓库当前正式入口；
- **发行验证**：若提供安装包，说明签名、公证和安装验证的实际状态，不要默认声称已 notarize。

如果 `v1.0` 只有 tag，没有带 DMG 的 Release，应明确“当前从源码构建”，不能让用户把源码压缩包当安装包。

### 5. Data, Privacy & AI／数据、隐私和 AI

这是晷迹建立商业可信度的关键章节，建议以“事实 + 边界”呈现：

- 默认数据存放位置和 local-first 语义；
- iCloud 同步是显式开启还是默认开启；
- 导入导出的覆盖范围和不包含内容；
- AI Provider 的配置位置、凭证保存方式、请求何时离开设备；
- 烛龙本地 sidecar、日志或 crash data 是否会自动上传；
- 当前不提供的能力，例如账号云或服务端 SLA。

任何“数据绝不丢失、绝不离开设备、端到端加密、零知识”都属于高风险承诺，只有架构、实现和运行验证共同支持时才能写。

### 6. Architecture／架构

README 只放一张小型模块图和一段文字，详细设计链接到现有文档。建议模块图覆盖：

```text
NoonmarkMacApp
    ├── MacRuntime / MacUIContract
    ├── NoonmarkCore
    ├── NoonmarkStorage / NoonmarkSync
    └── NoonmarkAI / NoonmarkZhulong
```

需要说明的不是文件列表，而是三条工程取舍：

- SwiftUI 原生 macOS App；
- domain、storage、sync、AI 和 UI contract 的边界；
- SQLite local-first、可验证同步和版本化历史的原则。

所有架构结论以 `Package.swift`、源码和 ADR 为准；不要继续传播已经过期的旧技术栈描述。

### 7. Quality／质量体系

用运行入口和覆盖层级建立可信度：

- `make check` 作为默认门禁；
- Core、AI、Storage、UI Contract、Simulation 的测试层次；
- 真实 `.app` E2E、SQLite／加密 sidecar 回读；
- 固定十天交互演示 fixture；
- DMG 挂载、安装、启动和持久化验证；
- 手动 live AI／iCloud 测试与默认 CI 的边界。

推荐展示一个链接到 `main` 的真实 CI badge，再用表格列“层级、验证对象、入口”。不要固化会漂移的测试总数，也不要把默认跳过的 live test 写成每次 CI 都会执行。

### 8. Development／开发

README 只给最短可运行路径：

```bash
git clone …
cd noonmark
make build
make test
make run-demo-app
```

同时注明 Xcode 和 macOS 前置要求，并链接：

- 工程测试与发布文档；
- 交互演示 fixture 文档；
- `CONTEXT.md` 领域语言；
- ADR 索引或架构设计文档；
- `AGENTS.md` 只作为 agent 协作规则，不替代普通贡献指南。

### 9. Support, Security & Contributing／支持、安全和贡献

四个入口必须区分：

- 普通使用问题：Discussion、帮助文档或指定支持渠道；
- 可复现 Bug：Issue 模板；
- 敏感安全问题：`SECURITY.md` 中的私密渠道；
- 代码贡献：`CONTRIBUTING.md`。

如果项目尚未准备接受外部贡献，就直接说明当前维护模式，而不是留下空泛“欢迎 PR”。`AGENTS.md` 面向自动化协作，不能直接视为外部贡献者已经看得懂的 `CONTRIBUTING.md`。

### 10. License & Release Status／许可和发行状态

README 末尾必须准确说明：

- 源码许可；
- 品牌、Logo 和截图是否采用同一许可；
- 第三方资源是否有独立许可；
- `v1.0` 是公开稳定版、内部里程碑还是技术预览；
- 正式安装包的下载和校验入口。

没有 `LICENSE` 时不要自行猜测；应先由项目所有者作许可决策。

源码许可也不必自动覆盖商标和品牌资产。GitHub Desktop 的 MIT 许可章节明确把 GitHub 商标和 Logo 排除在许可授权之外。[GitHub Desktop README：License](https://github.com/desktop/desktop/blob/development/README.md#license) 晷迹若希望公开源码但保留 Logo、名称和截图的品牌权利，应在正式许可文件或独立品牌政策中清楚表达，而不是只在 README 留一句含糊声明。

## 四、当前仓库在 README 发布前需要确认的缺口

本次只做只读检查，没有修改这些文件。当前根目录尚未发现以下 community health 文件：

- `README.md`
- `LICENSE`
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `SECURITY.md`

仓库已经存在 `.github/workflows/ci.yml`、`nightly-deterministic-sim.yml` 和 `release.yml`，因此可以优先核对 `ci.yml` 是否在 `main` 上真实运行，再决定是否展示 CI badge。

发布 `v1.0` 前至少需要明确：

1. 仓库是开源、source-available 还是保留全部权利；
2. 安装包是否会作为 GitHub Release asset 发布；
3. 安全问题的私密接收渠道；
4. 外部 Issue／PR 是否开放；
5. Logo、产品截图和演示数据是否可以随仓库公开分发。

README 可以链接这些政策，但不能代替所有者决策。

## 五、常见反模式

### 1. 用“工业级／商业级”自证质量

问题：形容词没有验证对象。  
改进：展示真实安装包、支持平台、CI 门禁、E2E、数据边界和失败反馈。

### 2. 首屏堆十几个 badge 和社区链接

问题：主要操作被状态噪音淹没，很多 badge 与用户决策无关。  
改进：只保留下载、文档、CI、平台和已确定许可。

### 3. 连续铺满所有功能截图

问题：页面加载重、视觉重复、读者不知道先看什么。  
改进：一张 Hero 建立全貌，四到八个用户任务分段叙事，次要画面折叠或进入文档。

### 4. 截图来自原型或个人真实数据

问题：无法复现、可能与产品不一致，也可能泄露隐私。  
改进：只使用 `make run-demo-app` 的固定十天演示基线，并保留可机器核对的截图来源。

### 5. 把“从源码构建”写成普通用户安装

问题：商业产品用户需要可验证二进制，不应先安装 Xcode。  
改进：用户下载和开发构建分开；若没有 Release asset，诚实标明当前交付方式。

### 6. 把 AI 写成无边界的自动智能

问题：用户无法判断 Provider、数据范围、权限和失败行为。  
改进：写清可选 Provider、配置前置条件、作用域、本地证据和需要确认的操作。

### 7. 把 local-first 等同于“永不丢数据”

问题：local-first 是数据与交互架构，不是无限可靠性承诺。  
改进：说明本地持久化、导入导出、同步策略、错误可见性和备份责任边界。

### 8. 固化易漂移数字

问题：测试数量、模块数量、截图中的日期和版本很快过期。  
改进：用测试层级和自动 badge 表达持续状态；只有自动生成或随 release 更新的数字才进入 README。

### 9. 外链托管仓库关键截图

问题：外部 CDN 路径、官网构建产物或临时 attachment 可能失效，也无法保证 clone 后可读。  
改进：把经确认的 README 截图纳入 `docs/assets/readme/`，使用相对路径。

### 10. 没有许可却写“开源”

问题：读者没有明确的使用、修改和分发权利。  
改进：先落盘许可证，再写许可说明和 badge；否则明确保留权利。

## 六、建议的最终目录

```text
README.md
docs/
  assets/
    readme/
      hero-day-todo.png
      task-pool-and-quick-entry.png
      planning-and-calendar.png
      recurring-plans.png
      task-history.png
      zhulong.png
      preferences-and-sync.png
  engineering/
  product/
  adr/
.github/
  workflows/
  ISSUE_TEMPLATE/
CONTRIBUTING.md
SECURITY.md
LICENSE
```

图片文件名应描述内容，不使用 `screenshot-1.png`。若 README 同时提供中文和英文版本，可保留根目录中文主版本，并在首屏链接 `README.en.md`；不要在同一篇内逐段双语，避免篇幅翻倍和内容漂移。

## 七、交付检查表

- [ ] 根目录 `README.md` 在 GitHub 渲染正常，标题 Outline 清晰；
- [ ] 首屏在不滚动或少量滚动内完成“定位、真实界面、下载、文档”；
- [ ] 所有产品截图来自 `make run-demo-app` 生成的真实 `.app`；
- [ ] 图片使用仓库相对路径，每张都有具体 alt 和文字说明；
- [ ] 截图不含个人信息、调试标记、红框、临时路径或 Provider 凭证；
- [ ] 下载链接真实存在，macOS 下限和安装方式与发行物一致；
- [ ] 功能描述与当前 App、`CONTEXT.md` 和产品规格逐项对账；
- [ ] 架构描述与 `Package.swift`、源码模块和 ADR 对账；
- [ ] 质量章节只引用真实门禁，不把 mock 写成 live；
- [ ] 数据、同步、AI 和隐私承诺都有实现或运行证据；
- [ ] CI badge 指向 `main` 的真实 workflow；
- [ ] 许可、贡献、安全和支持入口准确；缺失时不伪装已经具备；
- [ ] `v1.0` tag、Release、DMG 和 README 中的版本说法一致；
- [ ] 仓库内相对链接、图片路径和标题锚点经过 GitHub 渲染检查。
