# 把烛龙 Engine、Session 与 Journal 恢复为一个协议

**Status**: Accepted

烛龙一次 Todo diff 或每日复盘应用会同时改变 Noonmark Engine SQLite 与加密 sidecar Session；两个存储没有共同数据库事务。晷迹采用包含 before／after Engine snapshot 与 before／after Session 的加密 pending journal，把提交建模为可前向完成、可精确识别的状态机，而不是在中断后猜测要回滚哪一边。

## Decision

- 应用前由 Engine frontier、选中 Session、Natural Day reference 和既有 pending application 共同分配 timeline。需要授权时，authorization instant 严格早于 apply instant；apply instant 同时用于 Engine、receipt／event、pending journal 与 SQLite journal。
- 正常顺序固定为：保存 pending journal → 持久化 after Engine → 在文件锁内以 before Session 为 expected token CAS 写入 after Session → 清除 journal。`ZhulongApplicationCommitOutcome` 必须区分 `beforeEngine`、`enginePersisted`、`sessionPersisted` 与 `completed`，并保留失败阶段、原错误及 journal cleanup error。
- pending journal format v3 以加密、authenticated、exact-date 的形式保存 application identity、kind、Session identity、before／after Engine、before／after Session 与 `createdAt`。加载时两个 snapshot、两个 Session 与时间关系都必须重新验证。
- pending journal prepare 不使用 Foundation `Data.write(.atomic)` 的模糊完成边界。它在同目录以 `O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC` 建立 `0600` temp，处理 partial write／`EINTR`，先同步和关闭 temp，再 exclusive rename、同步目录并最终重读。重读必须同时满足 owner-only regular file、单一 link、当前用户 owner、raw exact bytes、AEAD 与领域 restore。
- prepare 的 rename 报错后，destination absent 与 authenticated exact 都只证明当前 namespace 状态，必须再以 fresh parent-directory descriptor 同步目录并作 final observation。首次目录 open／sync 报错会重开目录并重试；只有目录同步成功，authenticated exact 才可成为 recovered committed，absent 才可成为明确 not committed。两次目录 open／sync 都失败时，即使最终观察是 authenticated exact 或 absent，也一律是 unresolved。第三内容、不可读状态及 syscall 全部成功后的 final exact mismatch 同样是 unresolved。
- clear 的 unlink 报错后，authenticated exact expected 仍存在是明确未清除；absent 只证明当前 namespace 已移除，仍须同步目录并按同一 fresh descriptor 规则重试。只有目录同步成功，或同步成功后仅 close 回报错误，final absent 才可成为 recovered committed。两次目录 open／sync 都失败时，absent 不得当作耐久证据，必须 unresolved；第三内容、不可读状态及 syscall 全部成功后的 final absent mismatch 也必须 unresolved。temp cleanup 与 descriptor cleanup 错误只保留为附属证据，不得覆盖主结果。
- regular file 优先使用 Darwin `F_FULLFSYNC`；文件系统明确不支持时才降至 `fsync` 并记录结构化 fallback。rename／unlink 后必须同步 parent directory。目录 `fsync` 已成功而 `close` 回报 `EINTR` 时，可把既有同步当作已完成；`EIO` 或未知 close error 不具此含义，必须以新 descriptor 再同步，持续失败则 unresolved。current namespace 的 exact／absent observation、process-crash recovery 与 sudden-power durability 是三个不同层级：observation 只回答当前名字可见性；成功的 file sync 加 directory sync 才支持本协议的进程中断／重启判定；突然断电仍取决于文件系统、装置与 flush 是否兑现，不作硬件持久性的额外承诺。
- 任一 prepare／clear 得到 unresolved verdict 时，journal 会由 typed verdict 驱动建立 process-local recovery fence，而不是再靠 `load() != nil` 推断。即使 clear 后当前文件已 absent，fence 仍会阻断普通 Store mutation、Session／Provider 写入与新的 application prepare。后续 `load()` 必须在 sidecar flock 内以 fresh parent-directory descriptor 同步，并 final observe authenticated exact 或 absent，才可解除 fence；exact 返回 pending application，absent 返回无 pending。进程重启后，若 journal absent 可重新评估为无 pending；若未同步的旧 journal 重现，则既有 authenticated recovery 流程接管。
- recovery fence 同时以 resolved canonical path 与可取得的 `(st_dev, st_ino)` 识别同一 sidecar root，避免 symlink alias、短暂 inode 查询失败或同路径重建绕开 gate。每个 activation／identity group 有独立 token；新 alias 只继承同 token，clear 也只清该 token，绝不按相同 ciphertext／record value 全局清除。若同次身份解析命中多个 token 或不同 record，必须 fail-closed。此 process-local 身份机制缩窄协作线程的 TOCTOU 窗口，但不宣称能防御同一 OS 用户恶意并发替换整个 data root。
- prepare 在 rename 前异常结束可能留下 `.pending-application.zhj.<canonical UUID>.tmp`。每次 locked load 只扫描 sidecar 直属目录，并只尝试清理由 `O_NOFOLLOW` 打开、regular、当前 euid owner、`nlink == 1`、mode `0600`，且 descriptor/path inode 再核对一致的准确命名候选；noncandidate、symlink、nonregular、hardlink、wrong-mode 与 wrong-owner 全部保留。成功 unlink（包括 syscall 报错后观察为 absent）须同步 parent directory并记录结构化结果；批量 sweep 若先删除一个候选、再于后续候选失败，必须先同步此前删除的目录事实才传播后续错误。两次同步失败会分别保留原始 removal、首次 durability 与 retry 错误，不能让辅助 cleanup 覆盖主失败。temp 从未成为 canonical journal，不能驱动 Engine／Session recovery，也不建立 application fence；断电后若再次出现，下次 sweep 会重试。这是 encrypted retention／resource cleanup，不是 secure erase。
- public caller 对 recovered committed 会继续完成 Engine／Session 协议，但必须把 prepare 与 clear 的 recovered evidence 传进最终 commit outcome。进度可为 `completed`，`commitCompleted` 仍为 false，UI 只显示 verified completion 并抑制普通成功提示；unresolved 一律显示 recovery pending，不能显示“未写入任何变更”。UI 取证本身若通过 locked `load()` 完成 fresh sync 并把 absent fence 解除，旧 unresolved error 不得继续制造“后续写入已阻断”的 false-pending；`sessionPersisted` 加 confirmed absent 应显示 verified completion，恢复入口确认无 pending 后也须清掉旧 pending notice。只有明确 not committed 且 journal definitely absent 才可显示普通 no-change failure。
- 恢复只接受精确三态：
  - Engine 等于 before：以原 `pending.createdAt` 持久化 after；
  - Engine 已等于 after：不重复保存 Engine；
  - 其他 Engine：报告 recovery conflict，绝不覆盖。
- Session 等于 before 时才可 CAS 为 after；已等于 after 时只继续清 journal；第三状态一律 `sessionConflict`，不得 last-write-wins。
- Engine 一旦 durable after，App 内存必须安装 after 并清除会错误重放的 undo 状态，即使 Session 或 journal 尚未完成；此时不得显示成功 toast。恢复策略是前向补齐 Session 和 journal，不把已经持久的任务事实倒回 before。
- pending journal 存在、不可验证，或 process-local recovery fence 已建立时，普通 Store mutation、natural-day rollover、同步安装、导入、直接 save 和 Session／Provider 写入全部 fail-closed。唯一例外是经 digest 验证恰好等于 pending afterSnapshot 的窄授权 Engine 写入；恢复冲突与 unresolved fence 必须给用户可见、按当前界面语言本地化的阻断状态。create／update Session 与普通／planning Provider 被 gate 阻断后不得把 recovery pending 覆盖成普通 operation failure。
- 若 Engine 首次持久化失败，可以尝试清除仍属 before 状态的 journal；清理失败必须作为独立证据保留。Engine 已持久后，不允许把删 journal 当成错误恢复手段。

## Considered Options

- 先写 Session 再写 Engine：中断后会让 sidecar 声称应用成功，但任务事实不存在。
- 失败时总是恢复 before：Engine after 可能已经被后续持久边界观察，跨存储倒写会制造新的历史不一致。
- 只比较 Session ID 或 snapshot JSON：不能区分同一 identity 的第三版本，也不能抵抗字段顺序与非 canonical 时间造成的误判。

## Consequences

- 跨存储应用不是伪装成 ACID，而是通过 durable progress、exact before／after identity 和 CAS 获得确定恢复语义。
- journal 在 Session 或 cleanup 失败时会继续阻断写入；这是保护 Engine 与 sidecar 一致性的预期行为，不得用 timeout、静默删除或自动覆盖解除。
- 这些边界把 namespace observation、process-crash recovery 与 sudden-power durability 分开记录。目录同步持续失败时，当前 exact／absent 都只属于 namespace 证据，必须 unresolved 加 process-local fence；`fsync` fallback、储存装置不兑现 flush 或突然断电时，不宣称 journal 一定已落到物理介质。
- 新增烛龙应用类型必须复用同一 coordinator、timeline、journal 与 mutation gate，不能直接写 Engine 或 Session。

## Risk And Rollout

- 风险等级：P。主要风险是 after Engine 已 durable 但 UI 误报成功、第三 Session 被覆盖、pending gate 漏掉写入口，以及 journal cleanup 失败后出现双写。
- 灰度：先覆盖 Todo diff、Daily Review、Engine-before／Engine-after、Session-before／Session-after／第三状态、engine／session／clear 三个失败阶段和真实 App 中断恢复；全部专项完成后仍须通过完整 E2E、`make check` 与最新 DMG 安装验收才可合并。
- 监控：记录不含敏感 payload 的 commit progress、failure stage、file operation、commit resolution、固定 error kind、domain-safe numeric code、sync retry／fallback、recovery action、pending gate 和 cleanup failure；不得把 error message、NSError userInfo、path、UUID、SQLite 细节、snapshot／Session 内容或 ciphertext 写入日志。E2E 对账 SQLite snapshot identity、Session receipt／event 数量、pending journal 数量、普通后续 mutation 及重启结果。
- 回滚：协议、journal format、CAS repository 与所有 gate 必须整体 revert，并按 clean cut 删除开发 SQLite／sidecar／pending journal 后重建。不得只关闭 gate、只降回旧 journal，或在未知 Engine／Session 状态下自动删除 pending 文件。
