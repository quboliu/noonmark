# 烛龙单一纵向工作流原型

> THROWAWAY PROTOTYPE — 本轮验证“固定外框里的单一追加流”以及同一日志的三种用户可选视图。原型使用内存状态，不连接 Provider、SQLite、Keychain 或真实 Todo 写入；验证后的视图契约应重写进 SwiftUI，不能直接提升这份 HTML。

## 本轮问题

在真实 Noonmark Mac 外框内，用一条从上到下持续生长、旧记录始终保留的工作流，能否让用户自然理解任务如何形成、烛龙正在做什么、为什么停下，以及如何回到旧检查点而不篡改历史？

本轮在同一个 `stream-prototype.html` 路由上提供三个同方向、结构不同的变体，通过 `?variant=A|B|C` 切换：

- A：连续卷宗；
- B：章节手风琴；
- C：双轨编织流。

C 是默认视图，A 与 B 作为用户可切换视图继续保留。三案只改变记录的视觉组织，不改变底层会话日志、当前检查点、授权或失效结果；视图选择属于本机呈现偏好，不是领域事件。

## 需求与成功标准

- Noonmark 外框、Sidebar、会话 PageHeader 与 300px Detail Rail 始终不动；任务推进不再切换页面。
- 中央只存在一个会话流。用户回答、烛龙工作、系统授权、决策门、草稿、Todo diff 和结果回执按发生顺序追加。
- 已完成记录可以折叠正文，但记录身份、结论、来源、时间、版本与状态不能消失。
- 当前 canonical head 始终是流末端唯一 current 记录；运行期间它是最新完成的运行记录，等待用户时才是唯一展开的 current checkpoint。
- “回看上一检查点”只移动查看游标并滚动到上一个用户检查点；它不回滚 canonical head，不恢复旧授权，也不改动日志。
- 旧检查点只读。用户选择“从这里调整”后，输入区出现在流末端；提交时依次追加更正、失效说明和重新打开的检查点。
- 被更正决定派生出的未消费简报、委托、运行、草稿与 Todo diff 仍可审计，但必须失效并且不能通过 URL、浏览器 Back 或旧节点恢复执行能力。已经成功应用的 Todo、写入授权消费与 receipt 是已发生事实，不得追溯失效；后续只能基于新 Base revision、diff hash 与幂等键形成补偿性变更。
- 用户离开流末端查看旧记录时，新追加内容不得强制抢走滚动位置；只显示轻量“回到当前”入口。
- 回看上一检查点、回到当前、确认进入下一检查点与从旧决定开始更正，都必须在同一个中央滚动容器中连续滑动；中间记录要真实经过视野，禁止瞬移后用高亮冒充滚动轨迹。
- 1320×820 为主尺寸，1180×760 为最小压测；中央与右栏独立滚动，不能横向溢出。PageHeader 必须直接提供当前视图入口，不能依赖开发者浮条。

## 当前原型差距

R3 的 `surface / flow / step / panel` 共同存在 URL model，`step` 同时承担业务游标与页面游标。`sessionScreen()` 每次只渲染当前步骤，因此旧步骤不在 DOM；进入设置会丢失会话来源；浏览器历史也会重新解释业务 `step`。现有 `planInvalidated` 等布尔值能 fail-closed，但不能从一份不可变记录解释当前有效对象。

本轮不在 R3 状态条上继续加导航，而是把会话改成 append-only 日志，并分离：

```text
canonical head：从日志投影出的唯一当前检查点与有效授权
view cursor：当前查看的旧记录、右栏 panel 与是否跟随流末端
```

URL 只保存 `variant`、确定性 `scenario` 和辅助 `panel`；正常业务推进不再写入 URL `step`。

## 会话记录模型

每条记录具有稳定、全局唯一的 `entryId`：

```text
entryId / sequence / actor / kind / createdAt
dependsOn[] / payload / branch
```

原型使用七类记录：

1. `message`：用户描述、烛龙追问与解释；
2. `artifact`：范围回执、活简报、规划草稿、Todo diff 与结果回执；
3. `checkpoint`：等待用户回答、审查、决策或授权；
4. `resolution`：用户回答，或精确绑定对象的规划／写入授权；
5. `activity`：本地检查、Provider 调用与规划运行步骤；
6. `correction`：指向旧决定的追加式更正；
7. `invalidation`：列出因此失效的后继对象与授权。

所有领域动作只追加记录。`projectSession(entries)` 从完整日志推导 active checkpoint、有效简报、有效规划委托、有效草稿、有效 Todo diff、失效关系与 `canRun / canApply`。原型不得用浏览器位置恢复这些能力。

## 逐条运行模型

- 交互式规划不能把整批预定结果一次性写入。用户点击运行后先追加一条 `authorized` resolution；后续 `started → running → finishing → completed` 每次只在对应工作真实结束后追加一条 durable record。
- 同一运行的每条记录都固定携带 `runId / ordinal / authorityId / contractId / branch`，并以 `dependsOn` 指向上一条运行记录。ordinal 必须连续，任意时刻只允许一个 producer。
- `canonical head` 由日志投影：运行中指向最新 durable run record，完成后指向最终 checkpoint。DOM timer 只负责唤醒下一次原型事件，回调执行前必须重新核对 run identity、epoch、授权、契约、branch、ordinal 与最新日志记录；timer 本身不是运行事实。
- 暂停会清除待执行回调并追加 durable `paused` 回执；暂停窗口不得形成任何排队步骤。继续会追加 `resumed` resolution，并从下一条尚未执行的记录继续，不新建授权或运行身份。
- 暂停后必须允许“终止本次运行”。终止依次形成用户 cancel request、系统 cancelled receipt 与新的 recovery checkpoint；尚未执行步骤直接丢弃，重新开始必须建立新 run identity。
- 流末端只允许一个不进入历史的 working placeholder。它只显示当前可证明的 `running / finishing / paused` 状态，不展示百分比、ETA、逐字 token、轮换“思考中”文案，也不提前挂载未来结果。
- HTML 没有真实 Provider 或 planner；当前 520ms 事件源只是验证 painted append、暂停与滚动所有权的确定性脚本，不是“真实工作耗时”，严禁迁入 App。正式 producer 必须持久化 run command、correlation 与 step cursor，只在真实工作完成事件后幂等推进；同步 `scenario` fixture 只能构造截图历史。

## 共同像素级 prompt

- 完全复用真实 Noonmark 亮色外框：240px Sidebar、82px PageHeader、300px Detail Rail；只有中央内容滚动。
- 窗口背景 `#FDFDFC`，Sidebar `#FAFAF9`，主 panel `#FFFFFF`，次 panel `#FBFBFC`；分隔线 `#E6E6E9`。
- 正文 `#1C1C1F`，次文 `#6B6B75`，弱文 `#A1A1AB`；主动作 `#2961C7`／`#EDF4FF`；`#7C5CFF` 只作为烛龙身份点缀。
- 系统字体只用 `-apple-system`、`SF Pro Text` 与 `PingFang SC`；基准 13px。Page title 21px，记录标题 12–13px，辅助标签 10–11px。
- 1320×820 时中央可用宽约 780px，左右 padding 24px；1180×760 时约 640px，左右 padding 20px。
- 禁止聊天气泡、暗色主页、渐变 Hero、玻璃态、Dashboard 卡片阵列、固定底部 composer 与大面积紫色按钮。
- 当前动作使用 accent-soft 背景与 3px 蓝色定位线；失效后继保留正文，以 45% 弱化和琥珀色状态标记表达，不能删除或用删除线覆盖事实。
- Detail Rail 检视当前或所选记录的依据、范围、版本与授权；事件历史是跨功能行为摘要，不复制完整会话正文。
- PageHeader 使用现有 `HeaderButton` 风格显示“视图 · 双轨／卷宗／章节”；点击出现 264px 白色原生菜单，逐项展示 A／B／C、名称、用途和当前勾选。菜单开关只重绘 Header，不得取消正在发生的滚动轨迹，也不得遮挡当前动作；选择后保持同一可见记录、日志 head 与未提交输入。

## Variant A — 连续卷宗

- 中央是一张连续白色卷宗，外框 1px `#E6E6E9`、8px 圆角，不拆成浮动卡片。
- 每条记录使用 `30px 来源脊柱 + minmax(0,1fr) 正文 + 54px 时间／状态` 三列。
- 脊柱线 1px，来源节点 18px；显示“你／烛／系”或等价短标识。
- 早期完成记录压成 44px 摘要行；用户决定、范围授权、规划委托和 Todo 写入授权永不合并。
- 当前记录完全展开，直接相关的上一条说明保留展开；AI 连续运行可收拢为“运行记录 · N 步”。
- 点击“回看上一检查点”滚动到前一个用户检查点，短暂使用淡蓝定位背景；旧记录提供“从这里调整”。

## Variant B — 章节手风琴

- 中央不画时间脊柱，以连续章节组织：意图与范围、活简报、规划委托、决策门与计划、Todo 应用。
- 章节标题高 50px，左侧两位编号，中间为章节名与一句结果，右侧为状态和展开按钮；章节之间只用 1px 横线。
- 当前章节展开并使用 4px accent 左线；前一章节保留 72px 结果摘要，其余默认压成 50px，但可同时手动展开。
- 章节内部仍保留逐条 append-only 记录；更正在流末端形成 `04A` 类新章节，不能插回或覆盖旧章节。
- 本案用于验证超长任务的可管理性；主要风险是重新产生 wizard 感。

## Variant C — 双轨编织流

- C 是默认视图。中央固定为 `60% 烛龙工作 / 28px 因果脊柱 / 40% 用户决定`；1180px 最小窗口使用 `58% / 24px / 42%`，不反转左右关系。
- 左轨承载烛龙追问、比较材料、分析、可选方案、规划产物和普通运行记录；右轨承载用户原话、取舍、授权、暂停／继续／终止等明确决定。两侧正文都保持左对齐。
- 轨道标题在 `.stream-scroll` 顶部吸附：左为“烛龙 · 分析、选项与执行”，右为“你 · 决定与授权”。标题下方用 1px 线和中央脊柱保持共同时间轴，不建立两个独立滚动区。
- 普通记录仍按 sequence 一条占一行；左右错位只改变横向归属，不配对、不补齐另一侧，也不改变相对于 A 的记录顺序。
- `checkpoint`、系统契约与授权边界、correction、invalidation、原子写入 receipt 横跨全宽。这不是布局例外，而是语义标点：全宽卡顶部必须显示“共同决策点／系统边界／历史边界／结果回执”。
- 左轨使用极淡紫灰 `#FBFAFF` 与烛龙色身份点；右轨使用冷蓝灰 `#F7F9FC` 与 accent 身份点；均沿用 1px `#E6E6E9` 分隔，不使用大圆角气泡、尾巴或头像墙。
- 普通轨道记录 padding `10px 11px`，标题 `12.5px`，正文 `11.6px/1.52`；全宽重大节点使用 8px 圆角、accent-soft current 状态与 3px 左定位线，可以容纳完整 composer。
- 用户切换到 A／B 后，C 的左右归属不写入日志；再次回到 C 必须恢复相同 head、查看游标、展开状态、未提交输入和滚动锚点。

## 交互与滚动规则

- `.stream-scroll` 只在初次挂载时建立，后续 render 只更新 Header、日志与 Detail Rail 的内容，不能替换滚动容器。
- 导航前先记录起点 entryId、scrollTop、当前 sticky inset 与它相对“可见内容顶部”的 Y；内容更新后按目标视图的 sticky inset 做 scroll compensation，再由统一控制器逐帧改变同一 scroller 的 scrollTop。这保证 A／B 进入 C 时记录不会躲到吸附标题后，也保证视觉上像鼠标滚轮／触控板移动，而不是从新容器顶部重新开始。
- 回看旧检查点时，目标落在中央视口约 30% 高度；回到当前或推进下一步时，沿用各变体的 current context 落点，并保证当前 CTA 完整可见。
- 轨迹使用先加速、再减速的 smootherstep：短距离 240–440ms，超过 2.5 个视口时按距离使用 620–760ms。前 100ms 位移不超过 0.45 个视口，任一控制器帧不超过 0.18 个视口，避免长流一点击就猛甩一屏。
- 运动中 Sidebar、PageHeader 与 Detail Rail 不移动；到达后才播放一次定位光。`is-located` 只表示 view cursor，不能承担“已经移动”的假动画。
- wheel、touch、滚动条 pointer 操作及导航键会立即取消程序滚动，停在用户接管的位置且不得回弹。新的定位动作取消旧轨迹并从当前 scrollTop 重新计算。
- `prefers-reduced-motion: reduce` 下允许立即抵达，但仍保留静态落点提示与语义播报。
- 正常进入会话时自动跟随流末端。只有 `view.followTail = true` 且用户没有接管滚动时，新记录才沿同一 scroller 柔和跟随。
- wheel、touch、pointer 或导航键会立即把滚动所有权交给用户；距底部超过 56px 后不再自动跟随。此后每条新 durable record 只增加“`N 条新运行记录 ↓`”，不移动 viewport；用户明确返回尾端后才清零并恢复跟随。
- “回看上一检查点”查找前一个 `checkpoint`，只更新 `view.cursorEntryId` 并滚动定位，`entries` 与 canonical head 必须逐字不变。
- “从这里调整”记录目标引用后回到流末端打开更正 composer。空更正 fail-closed。
- 提交更正追加 `correction → invalidation → reopened checkpoint`；原节点 payload 不变，受影响的未消费后继带同一个 `invalidatedBy`。若旧分支已产生 receipt，失效回执必须明确保留已发生批次，并要求新分支形成补偿性 diff。
- 浏览器 Back／Forward 只改变 variant、panel 或 entry 锚点；不得改变 canonical head 或恢复 Todo 写入。
- 三案切换必须保留完整 entries、active checkpoint、未提交输入、滚动语义和授权投影。C 为首次默认值；显式 URL `variant` 优先，用户选择同时更新 URL 与本机视图偏好。不得用全局左右方向键意外切换布局；菜单本身必须具有键盘焦点和 `aria-pressed`。

## 验证矩阵

- 空回答不追加；每次有效动作后，旧 entry ID 是新列表的严格前缀，旧 payload 完全一致，DOM id 全局唯一。
- 交互式运行从授权到 checkpoint 必须产生至少 5 次独立 painted DOM commit；每次只增长一条，旧记录的 ID、payload、依赖与运行身份逐字不变。
- 真实物理双击只能建立一个 run producer；暂停至少跨越两个原型事件间隔仍然零追加，继续后的 ordinal 与 `dependsOn` 必须连续。
- 真实 wheel 上滑后，后续运行记录不得改变可见 anchor 的 Y；未读数必须严格等于上滑后新增的 durable record 数，明确返回当前后才归零。
- 完整主路径能在同一 DOM 中留下范围、用户取舍、完成标准、简报、委托、运行、决策门、修订、草稿、Todo diff 与 receipt。
- 任意时刻恰好一个 current checkpoint，且它位于流末端。
- 决策门没有回答不能继续；证据不足时不得出现具体日期、点数或正式概率。
- 规划委托与 Todo 写入授权分开；receipt 后没有可用写入能力。
- “回看上一检查点”不改变 entries、active checkpoint 或授权；“回到当前”恢复跟随。
- 更正后旧草稿与未消费 diff 仍可见但失效；事件历史出现引用，浏览器 Back／Forward 不能复活旧能力。receipt 后更正不得重开旧 apply，新的应用必须使用新 diff hash、Base revision 与幂等键。
- A／B／C 切换不改变节点、payload、active checkpoint 或未提交输入；键盘行为符合输入焦点规则。
- 1320×820 与 1180×760 无横向溢出；长流顶部、底部、当前动作和 Detail Rail 底部都可达；PageHeader 视图菜单不改变壳层几何，也不遮挡正文命中区域；“回到当前”与当前 composer 主动作必须保持安全间距。
- A／B／C 的回看与返回当前都要逐帧出现至少 4 个严格位于起终点之间的 scrollTop，方向单调、中央 scroller 实例不变、外框位移不超过 1px；确认进入下一检查点也必须满足同一轨迹条件。
- `scenario=long&demo=motion` 的“回看检查点”实际起终点距离必须至少达到 3 个 viewport，专门用于人工判断滚轮式轨迹；正式 `scenario=long` 继续聚合连续 machine activity。
- wheel 中断后 scrollTop 停在接管点，不再继续逼近旧目标；canonical head、授权与 append-only payload 在纯查看轨迹前后保持不变。

## 当前视图决策

用户明确否决“由产品替用户选定唯一布局”。A、B、C 应成为同一 append-only 日志的三种可选视图，C 为默认；原因是左烛龙／右用户的错位能够直接呈现“系统提供了什么、用户决定了什么”，全宽节点则承担重大决策提醒。后续评审重点从“淘汰哪案”转为“视图切换是否零语义损失，以及 C 在长流和最小窗口下是否仍清晰”。
