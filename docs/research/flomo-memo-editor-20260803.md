# flomo MEMO 输入与编辑能力核对

- 调研日期：2026-08-03
- 调研范围：flomo MEMO 的输入、编辑、格式、标签、引用、媒体与版本恢复
- 来源边界：只使用 flomo 官网与 flomo 官方帮助中心；未用第三方评测、社区文章或推测补齐空白
- 证据限制：本文核对的是调研日可访问的官方说明，不是登录真实账号后的逐平台实机测试；官方未写明的平台差异一律不作推断

## 结论摘要

flomo 官方目前**明确不支持 Markdown 语法**。它不是一个通用 Markdown 编辑器，而是一个刻意限制排版复杂度的 memo 编辑器：官方确认支持多行正文、加粗、高亮、下划线、无序列表、有序列表、正文内多级标签、MEMO 引用、图片／Live 图，以及语音转写；同时明确不做 Markdown、LaTeX、自定义标题和把图片插入正文流等能力。[flomo 快速记录](https://help.flomoapp.com/basic/quick-input.html)

因此，若晷迹要“对齐 flomo”，准确说法不是“补上完整 Markdown”，而是：

1. 先补齐 flomo 已验证有价值的低摩擦输入与小型格式集合。
2. 若晷迹仍决定支持 Markdown，应把它视为自己的产品选择，并明确支持哪一组语法及其储存、渲染和编辑语义，不能用“flomo 支持 Markdown”作依据。
3. 新建与旧 MEMO 编辑应尽量共用同一套格式、快捷键与媒体能力；flomo 官方快捷键也把双击编辑与编辑状态格式化放在同一条工作流中。[flomo 快速记录](https://help.flomoapp.com/basic/quick-input.html)

## 能力矩阵

| 能力 | 官方核对结果 | 直接证据与限制 |
| --- | --- | --- |
| Markdown | **明确不支持** | 官方把 Markdown 语法列入“不会做的记录功能”。[快速记录](https://help.flomoapp.com/basic/quick-input.html) |
| 标题／Heading | **明确不支持自定义标题** | 同一官方清单明确拒绝自定义标题；不能据此设计 `# Heading`。[快速记录](https://help.flomoapp.com/basic/quick-input.html) |
| 多行正文 | **支持** | `Enter` 换行，`⇧Enter` 或 `⌘Enter` 发布。[快捷键](https://help.flomoapp.com/basic/quick-input.html) |
| 加粗 | **支持** | Mac 为 `⌘B`；官方说明作用于编辑状态中的选中文字。[快捷键](https://help.flomoapp.com/basic/quick-input.html) |
| 高亮 | **支持固定高亮动作** | Mac 为 `⌘⇧H`。官方另行拒绝自定义字体颜色与自定义背景色，因此不能扩展解释成任意颜色系统。[快捷键](https://help.flomoapp.com/basic/quick-input.html) |
| 下划线 | **支持** | Mac 为 `⌘U`。[快捷键](https://help.flomoapp.com/basic/quick-input.html) |
| 无序列表 | **支持** | 输入 `-` 加空格触发。[快捷键](https://help.flomoapp.com/basic/quick-input.html) |
| 有序列表 | **支持** | 输入数字、句点、空格触发。[快捷键](https://help.flomoapp.com/basic/quick-input.html) |
| 斜体、删除线 | **官方未说明** | 官方编辑快捷键清单未列出；Markdown 又被明确排除。本文不把它们推定为支持。 |
| 引用块 | **官方未说明** | 官方“引用批注”指 MEMO 之间的关联，不是 Markdown `>` blockquote。[引用批注](https://help.flomoapp.com/advance/thread.html) |
| 行内代码／代码块 | **官方未说明** | 官方记录能力与快捷键清单均未列出；本文不把反引号文本推定为代码格式。 |
| 任意网址 | **确认存在链接型 MEMO，但创作细节不足** | 搜索可筛选“有链接”的 MEMO，更新日志也曾修复粘贴网址后的输入行为；官方没有说明自定义链接标题或 Markdown link 语法。[快捷搜索](https://help.flomoapp.com/advance/search.html) [版本更新](https://help.flomoapp.com/about-us/update.html) |
| `#标签` | **支持** | 标签写在正文中，可用输入框下方 `#` 按钮或直接键入；多个标签以空格分隔。[多级标签](https://help.flomoapp.com/basic/tag.html) |
| 多级标签 | **支持** | 语法为 `#标签/子标签`，可继续增加层级；标签本身仍是正文内容。[多级标签](https://help.flomoapp.com/basic/tag.html) |
| `@` MEMO 引用 | **支持** | 输入 `@` 后可从最近 MEMO 中选择或键入关键词检索，选择后插入对应 MEMO 链接。[引用批注](https://help.flomoapp.com/advance/thread.html) |
| 图片 | **支持为 MEMO 附件** | 新建记录可上传图片；官方明确不支持把图片插入正文流。[快速记录](https://help.flomoapp.com/basic/quick-input.html) |
| Live 图 | **支持，但跨平台查看有限制** | 官方说明可上传 Live 图；网页与 Android 可查看 iOS Live 图，Android 厂商格式仍在陆续支持。[快速记录](https://help.flomoapp.com/basic/quick-input.html) |
| 音频／语音 | **支持语音输入与 AI 转写** | 可从输入框进入录音，转写文字插入正文，原文默认折叠；官方页面标示 PRO 权益，同时给免费用户每周体验次数。[语音输入](https://help.flomoapp.com/ai/aivoice.html) |
| 任意文件附件 | **官方资料不足** | 储存说明使用了“附件”一词，但主要明确的是图片；微信输入还明确不支持文件。不能由此推定桌面 composer 支持任意文件类型。[存储与导出](https://help.flomoapp.com/basic/storage.html) [微信输入](https://help.flomoapp.com/basic/wechat-input.html) |
| 编辑历史 | **支持** | 自动保存编辑版本，保留最近 30 天；普通用户可查看最近 3 条，会员可查看 30 天内全部记录。[历史版本](https://help.flomoapp.com/basic/history.html) |
| 恢复旧版本 | **支持** | 从 MEMO 菜单进入历史版本，选择版本并确认恢复；历史只保存文字，不含图片和音频。[历史版本](https://help.flomoapp.com/basic/history.html) |
| 未发布草稿自动保存 | **官方未说明** | 本次查阅的官方输入、设置与更新说明没有足够证据确认跨关闭或跨重启草稿恢复，不能类比其他产品。 |

## 输入与编辑交互

### 捕获入口与焦点

flomo 把输入框描述为类似聊天窗口：不要求标题，也不要求用户先安排版式。电脑端可从菜单栏图标呼出快捷输入窗口；客户端的系统全局 `⌘N` 打开 MEMO 输入框，MEMO 列表中的 `⌘/` 聚焦输入框。[快速记录](https://help.flomoapp.com/basic/quick-input.html)

这组设计的重点是“随时进入同一个写作动作”，不是格式工具数量。官方还提供网页／电脑端禅定模式：开启后让输入框以外的内容变模糊，降低写作干扰。[禅定模式](https://help.flomoapp.com/advance/zen.html)

### 保存、换行与编辑旧内容

- `Enter` 只换行。
- `⇧Enter` 或 `⌘Enter` 发布。
- Web／客户端在 MEMO 列表中双击已有 MEMO 进入编辑；Android 官方写的是三击。
- 格式化快捷键在官方矩阵中标注为“MEMO 编辑状态”。该措辞没有进一步区分新建与旧内容，所以本文不擅自声称所有平台、两个阶段完全一致。[快速记录](https://help.flomoapp.com/basic/quick-input.html)

### 小型富文本，而非 Markdown

flomo 的实际编辑集合可以概括为“少量行内强调 + 两类列表”：

- 行内强调：加粗、高亮、下划线。
- 块结构：无序列表、有序列表。
- 组织符号：正文内 `#标签`。
- 关系符号：`@` 搜索并插入 MEMO 引用。

它没有在官方编辑说明中列出标题、斜体、删除线、引用块、行内代码、代码块或 Markdown 链接；同时又明确拒绝 Markdown。因此，“输入 `- ` 会生成列表”只代表一个快捷触发，不代表编辑器实现了 Markdown 解析器。[快速记录](https://help.flomoapp.com/basic/quick-input.html)

## 标签与 MEMO 关联

标签不是独立于正文的必填字段。用户可在正文任意位置输入 `#标签`，也可以点击输入框下的 `#` 按钮插入；`#父标签/子标签` 形成层级。官方要求多个标签之间留空格，并对特殊字符与英文空格有额外限制。[多级标签](https://help.flomoapp.com/basic/tag.html)

MEMO 关系也不是 Markdown blockquote：

1. 输入 `@` 后显示最近 MEMO，并允许按关键词检索。
2. 选择结果后，输入框插入一个可访问目标 MEMO 的链接。
3. 用户也可在既有 MEMO 菜单中选择“批注”，让新 MEMO 自动引用它；或复制 MEMO 链接后粘贴到另一条内容中。

反向链接部分属于 PRO 权益。官方只说明关联工作流，没有提供可移植的纯文本语法规范。[引用批注](https://help.flomoapp.com/advance/thread.html)

## 图片、音频与附件边界

flomo 支持在记录时上传图片和 Live 图，但图片作为 MEMO 关联媒体存在，不嵌入正文段落之间。当前官方更新日志曾记录 PRO 用户单条笔记可上传 18 张图片，也确认粘贴图片是电脑端实际输入路径；这是版本记录，不等于所有账号等级和所有平台都具有相同上限。[快速记录](https://help.flomoapp.com/basic/quick-input.html) [版本更新](https://help.flomoapp.com/about-us/update.html)

官方语音输入会录音、AI 转写，并把整理后的文字插入正文，原始转写默认折叠；免费、PRO 与 MAX 的单次时长和月度额度不同。帮助页未把这项能力明确限定或确认到 Mac composer，因此 Noonmark 不能仅凭该页面宣称 flomo Mac 端具备同样入口。[语音输入](https://help.flomoapp.com/ai/aivoice.html)

对于任意文件附件，官方储存政策虽然泛称“附件”，但没有在 MEMO 编辑帮助中列出 PDF、文档、压缩包等文件类型或桌面上传流程。微信入口还明确只支持文字和图片、不支持文件。因此本次结论只能确认图片、Live 图与音频，不能扩大为通用文件附件。[存储与导出](https://help.flomoapp.com/basic/storage.html) [微信输入](https://help.flomoapp.com/basic/wechat-input.html)

## 历史编辑与恢复

flomo 会在 MEMO 产生编辑记录时自动保存新版本，并提供 30 天内的文字版本恢复。普通用户可查看最近 3 条历史，会员可查看 30 天内全部历史。每一版包含编辑时间、文字数量与完整文字内容，但不包含图片和音频；内容从回收站删除后，相关历史也会删除。[历史版本](https://help.flomoapp.com/basic/history.html)

这说明“编辑旧内容”不只是进入编辑框，也包括可追溯与可恢复。不过，官方没有把未发布草稿恢复和已发布版本历史描述为同一机制，两者不能混为一谈。

## 对 Noonmark Idea composer 的直接启示

以下是基于上述事实的产品建议，不代表 flomo 官方原话：

1. **先纠正需求名称。** 若目标是复刻 flomo 的编辑能力，应命名为“轻量富文本与结构化输入”，而不是“完整 Markdown”。
2. **若支持 Markdown，先定义子集。** 可以考虑加粗、列表、引用、链接与代码，但必须逐项定义原始输入、即时渲染、保存格式、复制／粘贴、搜索文本和旧资料迁移；不能只给纯文本框加预览。
3. **新建与原位编辑必须能力对等。** 双击旧 memo 后，格式、标签、引用、媒体和保存键不应换一套交互。
4. **首要格式集合应可由键盘完成。** `Enter` 换行、`⌘Enter` 保存、`⌘B` 加粗、列表自动续行、`#` 标签候选与 `@` 关联候选，比常驻大工具栏更符合低摩擦捕获。
5. **附件不要伪装成正文。** 若近期只做图片，应明确为 memo 媒体区；若计划任意文件，应另立资料模型、储存限额、同步、删除与隐私需求。
6. **历史版本是独立可靠性能力。** 它不应由普通 autosave 或回收站间接冒充；是否进入当前阶段应按数据模型与同步风险单独评估。

## 一手来源索引

- [flomo：快速记录](https://help.flomoapp.com/basic/quick-input.html)
- [flomo：多级标签](https://help.flomoapp.com/basic/tag.html)
- [flomo：引用批注](https://help.flomoapp.com/advance/thread.html)
- [flomo：历史版本](https://help.flomoapp.com/basic/history.html)
- [flomo：语音输入](https://help.flomoapp.com/ai/aivoice.html)
- [flomo：快捷搜索](https://help.flomoapp.com/advance/search.html)
- [flomo：存储与导出](https://help.flomoapp.com/basic/storage.html)
- [flomo：微信输入](https://help.flomoapp.com/basic/wechat-input.html)
- [flomo：禅定模式](https://help.flomoapp.com/advance/zen.html)
- [flomo：版本更新](https://help.flomoapp.com/about-us/update.html)
