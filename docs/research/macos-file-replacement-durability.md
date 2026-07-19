# macOS 文件替换与目录项持久化边界

最新确认日期：2026-07-17

本文回答一个窄问题：晷迹在 macOS 上以「写同目录临时文件 → 同步文件 → `rename` 安装 → 同步目录」保存 pending journal，以及以「`unlink` → 同步目录」清除 journal 时，每一步究竟能证明什么。

结论以本机 macOS 15.7.7、Darwin 24.6.0、Xcode 26.2 SDK 的 `fsync(2)`、`fcntl(2)`、`close(2)`、`rename(2)`、`unlink(2)`、SDK headers 和 Apple XNU primary source 为依据。本文刻意把当前 namespace、仅 App process 崩溃／重启，以及 OS 崩溃／突然断电分开；除非来源明确给出，否则不把「syscall 返回成功」扩大成硬件绝对保证。

## 结论

- 路径重读只证明当前运行系统的 namespace 此刻可见 `absent`、`authenticated exact` 或其他状态；重读不会刷新目录，也不证明断电后的目录项。
- 普通 `fsync` 把 host 的修改送到 drive，但 Apple 的 man page 明说 drive 仍可缓存和重排；OS 崩溃或 drive 断电后，可能只有部分或完全没有写入。
- `F_FULLFSYNC` 是这里最强的 Darwin flush 请求：先做 `fsync`，再要求 drive 清空 buffered data，并形成 barrier。它仍不是对任意外接盘、虚拟磁盘、firmware 或失效硬件的数学证明。
- `F_BARRIERFSYNC` 主要提供顺序，不提供「返回时已经持久」的结论，不能代替 `F_FULLFSYNC` 作为 durability gate。
- 临时 regular file 的同步不包含随后发生的 `rename`／`unlink` 目录项变化。namespace mutation 后必须同步相关 parent directory；晷迹的 temp 与 destination 在同一目录，因此当前只需一个 parent directory。若未来跨目录 rename，source 与 destination 两个 parent 都必须纳入协议。
- `rename`／`unlink` 或后续 directory sync 报错后，exact re-read 只可用于判断当前 namespace，不能单独升级成 `recoveredCommitted`。必须在同一 writer fence 内重新打开 parent directory，并取得一次成功的 directory `fsync`，再做最终 exact observation；做不到就保持 `unresolved`。
- `close` 返回 `EINTR` 或 `EIO` 后不得重试同一个 fd。当前 Darwin XNU 会先从 process fd table 释放 numeric fd，再把底层 close error 返回调用者；重试可能关闭已被其他线程复用的无关 fd。
- clear 已观察为 `absent`、但 directory sync 尚未成功时，文件本身已经不能承载 pending gate。进程内必须 latch 一个 process-local uncertainty fence，让所有后续 sidecar 写入继续 fail-closed。该 fence 只保护当前 process，不是跨 process restart 或 sudden power loss 的持久证据。
- 因此，任何在 `rename`／`unlink`／directory sync 报错后只凭 exact／absent 重读就返回 clean 或 recovered committed 的路径，都不满足本文的 durability contract。

## 证据范围与机器基线

本机取证结果：

| 项目 | 结果 |
| --- | --- |
| `sw_vers` | macOS 15.7.7，build 24G720 |
| `uname -a` | Darwin 24.6.0，kernel `xnu-11417.140.69.710.16~1/RELEASE_ARM64_VMAPPLE` |
| `xcodebuild -version` | Xcode 26.2，build 17C52 |
| `xcrun --sdk macosx --show-sdk-path` | Xcode 26.2 `MacOSX.sdk` |
| `xcrun --sdk macosx --show-sdk-version` | 26.2 |
| root filesystem | APFS，`diskutil` 报告 Solid State；kernel 名称含 `VMAPPLE`，不能据此断言底层 physical media 或 hypervisor 是否兑现 flush |

SDK header 把 `F_FULLFSYNC` 定义为 51，并注释为「`fsync` + ask the drive to flush to the media」；把 `F_BARRIERFSYNC` 定义为 85，并注释为「`fsync` + issue barrier to drive」。这与本机 `fcntl(2)` 的较完整说明一致。[^sdk-headers][^fcntl-man]

本机 APFS 临时目录 probe 对 regular file 和 directory 分别调用 `fsync`、`F_BARRIERFSYNC`、`F_FULLFSYNC`，六次都返回成功。这个 probe 只证明这些操作在这台机器、这个 mount 上被接受；它没有制造 process crash、OS crash 或 power loss，也没有验证设备真的把数据写到 non-volatile media。

公开 XNU tag `xnu-11417.140.69` 与本机 kernel 的 base version 对齐，但没有本机 `.710.16` vendor suffix；本文只用它核对 fd 生命周期和 VFS dispatch，不声称该公开 tag 与本机 kernel bit-for-bit 相同。[^xnu-close][^xnu-fsync][^xnu-fcntl]

## 必须分开的三层事实

| 层级 | 可接受证据 | 能证明 | 不能证明 |
| --- | --- | --- | --- |
| 当前 namespace | `rename`／`unlink` 的返回值，加上在 writer fence 内的 exact re-read | 当前 live kernel／filesystem view 中，path 是 absent、exact，还是第三状态 | 目录项已写到 non-volatile media；断电重启后仍相同 |
| App process crash／restart，OS 仍运行 | child process 在指定边界 `_exit`，由新 process 重新打开并鉴定 path | process termination 没有像数据库事务一样回滚已进入 kernel namespace 的变化；新 process 在同一 live OS 上看见什么 | OS reboot 或 sudden power loss；drive cache 是否已 flush |
| OS crash／sudden power loss | 成功的相关 file sync、directory sync，以及已声明的 device flush level | 达到对应 Darwin API contract 的最好证据 | 任意硬件、firmware、hypervisor 或损坏设备一定兑现；所有未来设备都具有同一语义 |

`close(2)` 明确说明 process exit 会释放其 file descriptors。由此可推论，App process crash／restart 与 OS crash 不是同一个故障模型：前者不会清空 kernel page cache 或重新挂载 filesystem，后者会跨越这些边界。这个推论不能拿来替代 directory sync 或 power-loss 测试。[^close-man]

同理，process-exit E2E 即使稳定得到「rename 前 absent、rename 后 authenticated exact」，也只覆盖同一 OS 的 process boundary。它不等于拔电、kernel panic 或 storage controller fault。

## `fsync`、`F_FULLFSYNC` 与 `F_BARRIERFSYNC`

### 普通 `fsync`

本机 `fsync(2)` 说，成功调用会把 fd 的 modified data 与 attributes 移到 permanent storage device，通常就是把 in-core buffers 写到 disk；同一页紧接着限定，host 虽把数据送到 drive，drive 可延迟 physical write，也可重排。drive 断电或 OS 崩溃后，App 可能发现只有部分或没有数据写入。[^fsync-man]

因此，本文把普通 `fsync` 成功记作 `fileSync` 或 `directorySync`，不记作 `powerLossProof`：

- 对 process-only crash，它提供的证据通常已足够强；其实即使仍在 kernel cache，同一 OS 的新 process 也可能读到它。
- 对 OS crash／sudden power loss，它只证明 host 已执行 `fsync` contract，不能证明 drive cache 已落到 physical media。
- `EINTR` 表示操作被 signal 中断，可以在仍拥有同一个 live fd、且没有 concurrent close 的前提下重试 sync。
- `EIO`、`EINVAL` 或其他错误不是较弱的成功。尤其 directory fd 返回 unsupported／I/O error 时，exact re-read 不能补出一个 directory durability verdict。

XNU 的 `fsync_common` 对 vnode 调用 `VNOP_FSYNC(vp, MNT_WAIT, ...)`；它没有把 regular file 写死为唯一 vnode type。实际 filesystem 仍可拒绝某类 vnode，本机 man page 也列出 `EINVAL` 作为「file type 不支持」的错误。当前 APFS probe 的 directory `fsync` 返回成功，所以晷迹可以在这个运行面使用它，但不能把这项 probe 外推成所有 filesystem 的保证。[^xnu-fsync][^fsync-man]

### `F_FULLFSYNC`

本机 `fcntl(2)` 说，`F_FULLFSYNC` 先做 `fsync`，再要求 drive flush 所有 buffered data；它会 drain 整个 device queue，并充当 barrier，所以同一 device 上此前已经 `fsync` 的 data，在调用返回时按该接口 contract 被视为 persisted。它在 APFS 上有实现，但操作可能很慢；同一 man page 也明确记录某些 FireWire drives 会忽略 flush request。[^fcntl-man]

对晷迹的含义：

- pending journal temp regular file 应优先使用 `F_FULLFSYNC`。
- 只有 filesystem 明确报告 unsupported 时，才可降到普通 `fsync`，并把 guarantee level 记录为 fallback；fallback 不能沿用 `fullSync` 文案。
- temp 上的 `F_FULLFSYNC` 发生在 `rename` 之前，因此不包含稍后才产生的 directory entry。它不能取代 parent-directory sync。
- API contract 使用「asks the drive」并记录不守约硬件；在 external storage、network filesystem、virtual disk 或 faulted device 上，不得写成绝对断电保证。

### `F_BARRIERFSYNC`

`F_BARRIERFSYNC` 先做 `fsync`，再向 drive 发 barrier。它保证 barrier 前已 `fsync` 的 I/O 不会排到 barrier 后的 I/O 之后，但 man page 明说调用返回时不能假设哪些内容已经 persisted，并直接把用途描述为「ordering is a concern but durability is not」。[^fcntl-man]

因此：

- 它适合约束 phase 1 与 phase 2 的落盘顺序。
- 它不能作为 pending journal 已 durable 的完成 gate。
- 它不能作为 `F_FULLFSYNC` 不支持时的等价 fallback。
- Apple SSD 对 barrier hardware support 的保证，不等于对所有外接盘或本机虚拟 storage path 的保证。

XNU 对 `F_BARRIERFSYNC` 不支持的 filesystem 会把它 promote 为 `F_FULLFSYNC`；这是 kernel implementation detail，更说明调用者应按实际成功的 operation／guarantee level 记录，而不是只按最初请求命名。[^xnu-fcntl]

## 为什么必须同步 parent directory

regular file fd 对应文件内容和该 vnode 的 attributes；`rename` 与 `unlink` 修改的是 parent directory 的 name-to-inode／vnode namespace。先把 temp file full-sync，再 rename，只完成了「candidate bytes」与「发布该 candidate 的目录项」两件事中的第一件。

对晷迹的同目录 replacement，最低完整顺序是：

1. 以 exclusive、no-follow、owner-only 方式建立 temp。
2. 处理 partial write 与 write `EINTR`，写完 exact bytes。
3. temp regular fd 成功 `F_FULLFSYNC`；明确 unsupported 时才记录为普通 `fsync` fallback。
4. 对 temp fd 调用 `close` 恰好一次；close error 不得重试 numeric fd，也不得继续发布 candidate。
5. 以 `renamex_np(..., RENAME_EXCL)` 安装 destination。
6. 打开 destination 的 parent directory，对 directory fd 取得一次成功 `fsync`。
7. 对 directory fd 调用 `close` 恰好一次。
8. 在 writer fence 仍持有时，最终重读并同时验证 regular file、owner、mode、link count、raw exact bytes、AEAD 和领域 restore。

第 8 步是内容与 identity 检查，不是第 6 步的替代品。反过来，directory `fsync` 也不验证 destination 是预期 ciphertext；两者都需要。

若未来 temp 与 destination 不在同一 parent，rename 会同时删除 source name 并建立 destination name，必须把两个 parent directory 都纳入同步和 final reconciliation。当前把 temp 放在 destination 同目录，既满足 same-filesystem rename，也把 namespace durability surface 收窄为一个目录。

plain directory `fsync` 仍受 `fsync(2)` 的 drive-cache caveat。若产品要声明比普通 directory sync 更强的 power-loss level，可以另外定义并验证 directory `F_FULLFSYNC` level；本机 APFS probe 虽接受该调用，本文不把一次返回 0 外推成 universal hardware guarantee。

## `rename` 与 `unlink`：atomic namespace 不等于 durable namespace

### `rename`

`rename(2)` 定义 `old` link 改名为 `new`；若 `new` 已存在，会先移除。man page 还保证 operation 中途 system crash 时始终有一个 `new` instance。这个保证保护以既有 `new` 做 atomic replacement 时不出现 name gap；它没有说明「返回后 new bytes 必定跨 sudden power loss 保存」，也不能证明从 absent 到 present 的 `RENAME_EXCL` directory entry 已 durable。`RENAME_EXCL` 另外保证 destination 已存在时返回 `EEXIST`。[^rename-man]

同一 man page 说列出的 rename failure 不影响两个 argument files；同时 `EIO` 的定义是「making or updating a directory entry 时发生 I/O error」。晷迹仍采用更保守的 application verdict：syscall／wrapper 报错、fault injection 模拟 effect-after-error，或后续 step 报错时，先把 outcome 视为 uncertain。这个策略不是声称 Darwin 总会在 rename error 后部分成功，而是拒绝把 error 后的 cache observation 误称为 directory durability。

### `unlink`

`unlink(2)` 删除 directory 中的 link 并减少 link count；若仍有 process 打开该 file，name 会消失，但 file resources 延迟到最后 reference 关闭才回收。它的 `EIO` 可发生在删除 directory entry 或回收 inode 时，因此 error 本身不能告诉调用者当前 path、inode reclamation 和 durable directory state 分别到了哪一步。[^unlink-man]

Noonmark 只应把 path absence 当成 journal namespace 已清，不应把它扩大成 ciphertext blocks 已物理擦除。`unlink` 不是 secure erase。

### error 后的统一 reconciliation

无论最初是 `rename`、`unlink`，还是 mutation 后的 directory sync 报错，使用以下规则：

1. 不释放 single-writer／sidecar transaction fence。
2. exact observe 当前 path，只把结果记为 namespace evidence。
3. 重新打开 parent directory，执行 directory `fsync`。`EINTR` 可在同一 live fd 上重试；其他错误可关闭一次后用 fresh fd 做有界重试。
4. 只有至少一次 directory `fsync` 返回成功，才做最终 exact observe。
5. final state 是 authenticated exact，才可把 prepare 归为 committed／recovered committed。
6. final state 是 absent，才可把 clear 归为 committed／recovered committed。
7. 未取得成功 directory sync、final state 变化、第三 bytes、不可读或 authentication 失败，一律 `unresolved`；不得仅凭先前 read 结果 reopen write gate。

这意味着：

| 情况 | 当前 namespace 可说什么 | Noonmark durability verdict |
| --- | --- | --- |
| rename 返回成功，directory sync 成功，final authenticated exact | 当前 target exact | `committed`，但附带实际 file／directory sync level |
| rename 报错，重读 authenticated exact，fresh directory sync 成功，final 仍 exact | effect 可在 fence 内收敛 | `recoveredCommitted(after: replacement)` |
| rename／directory sync 报错，重读 exact，但没有任何成功 directory sync | 当前 target exact | `unresolved` |
| unlink 返回成功，directory sync 成功，final absent | 当前 target absent | `committed`，不等于 secure erase |
| unlink 报错，重读 absent，fresh directory sync 成功，final 仍 absent | effect 可在 fence 内收敛 | `recoveredCommitted(after: removal)` |
| unlink／directory sync 报错，重读 absent，但没有任何成功 directory sync | 当前 target absent | `unresolved`，并 latch absent uncertainty |

如果 error 后仍看见 authenticated exact old journal，当前 namespace 只说明 clear 尚未完成；应在 fence 内重试 clear protocol。若要对外给出 durable「not cleared」结论，同样不能靠 read 本身创造新的目录同步证据。

## `close` 的 `EINTR`／`EIO` 边界

本机 `close(2)` 的主语是「delete a descriptor」。成功返回 0 只说明 close 完成；它没有同步数据或目录的承诺。错误列表中：

- `EINTR`：execution 被 signal 中断。
- `EIO`：先前尚未 committed 的 `write(2)` 遇到 I/O error。
- `EBADF`：fd 不是 valid、active descriptor。[^close-man]

Apple XNU 的当前 base-version source 给出更关键的 fd ownership 证据：`close_nocancel` 进入 `fp_close_and_unlock`；后者先 `fdrelse(p, fd)`，再调用 `fg_drop`；`fg_drop` 最后才调用底层 `fo_close` 并把其 error 返回。换句话说，能从底层 close 返回的 `EINTR`／`EIO` 到达 user space 时，numeric fd slot 已从 process table 释放。[^xnu-close]

因此，晷迹必须采用以下规则：

- 在第一次调用 `close(fd)` 前就把 fd ownership 标记为 consumed；无论返回 0 或 -1，都不再调用 `close(fd)`。
- 不把 `EINTR` 解释为「fd 肯定仍 open」。在 Darwin 当前实现上重试有关闭 reused fd 的风险。
- 不把 `EIO` 解释为「只有 close cleanup 失败」。它明确带来先前 uncommitted write 的失败证据；不能继续 rename temp，也不能把内容描述为 clean durable。
- `close == 0` 本身也不证明 durable；durability evidence 来自先前成功的 `fsync`／`F_FULLFSYNC` 和后续 directory sync。
- 先前成功的 sync 是独立 syscall evidence，`close EINTR` 不会倒写其返回值；但 higher-level protocol 可以更保守地停止发布。`close EIO` 是额外 adverse evidence，必须保留并 fail-closed。
- directory `fsync` 已返回 0 后，directory `close EINTR` 不会把那次 sync 的返回值改成失败，但 fd 已 consumed；不得用 close retry「确认」。directory `close EIO` 带来新的 I/O failure evidence，若要解除 uncertainty，应以 fresh directory fd 再取得成功 sync，而不是忽略它。
- 若需要重新建立 directory durability evidence，应打开 fresh directory fd 再 sync；不是重试旧 fd 的 close。

这里的「不得重试」专指 `close`。`write`、`fsync`、`fcntl(F_FULLFSYNC)` 在仍明确拥有 live fd 时，可以依据各自 contract 处理 `EINTR`；不能把这条规则错误套成所有 syscall 都不可重试。

## clear absent uncertainty 与 process-local fence

prepare 未确认时，destination 或 temp 通常仍能提供可观察证据；clear 不同：一旦 path 在当前 namespace 中 absent，就没有 journal file 可用来表达「unlink 看似发生，但 parent directory 尚未成功同步」。如果 gate 只靠 `fileExists`／`load == nil`，同一 process 的下一次 Session 或 Provider write 会错误地把 uncertainty 当成 clean absence。

所以 `ZhulongApplicationJournalFileCommitter`／repository 需要一个 process-local absent-uncertainty latch：

- 在持有 `ZhulongSidecarTransactionLock` 时，一旦 clear 已 absent 但 directory sync／final observation 未干净完成，就先 latch，再释放 transaction lock。
- `load`、prepare、Session CAS、Provider write、natural-day rollover、同步安装、导入和普通 Store mutation 都必须先检查 latch；命中即 fail-closed。
- 只有同一 writer fence 下 fresh parent-directory sync 成功、final state 仍 absent，并完成协议 reconciliation 后，才可清 latch。
- latch key 必须绑定 canonical data root／sidecar location，不能用容易 alias 的 raw path string。
- `NoonmarkDataRootProcessLease` 必须确保另一个 App process 不能绕过当前 process 的 latch；短期 sidecar `flock` 不能取代整个 data-root writer lease。

这个 latch 是 concurrency／state-machine fence，不是 storage barrier：

- 它不会把 directory cache flush 到 drive。
- process 一旦 crash，内存 latch 就消失。
- 它不能证明 process restart 后的 absence 是 durable clear，也不能证明 sudden power loss 后不会重新出现 old journal。
- restart recovery 仍必须以重新观察到的 authenticated exact／absent／third state，加上 Engine／Session 的 durable progress 和 single-writer protocol 决定下一步，不得把「之前内存里 latch 过」写成持久事实。

如果产品将来要求 absent uncertainty 本身跨 process crash 持久，就需要另一份 durable marker 或把 progress 放进已有 durable store；那份 marker 也必须拥有自己的 atomic write 与 directory-sync protocol，不能靠新增一个未同步 sentinel 无限递归。

## 对 Noonmark 的直接设计结论

1. `ZhulongApplicationJournalDarwinFileOperations` 的 guarantee level 必须至少区分 `fullSync`、`fileSyncFallback`、`directorySync` 和 `unresolved`；monitoring 不得把普通 `fsync` 显示为 full flush。
2. temp descriptor 与 directory descriptor 都采用 single-consumption ownership。调用 `close` 前转移／清空 ownership，error 只记录，不重试 numeric fd。
3. prepare 的 `recoveredCommitted` 必须同时要求 authenticated exact 和一次发生在 namespace mutation 之后的成功 parent-directory sync。rename error 后先 exact read、但未补成功 directory sync，不够。
4. clear 的 `recoveredCommitted` 必须同时要求 final absent 和一次发生在 unlink effect 之后的成功 parent-directory sync。unlink error 后 absent read，不够。
5. 首次 directory sync 报错时，可以 fresh fd 重试；若没有任何一次成功，状态保持 `unresolved`。unsupported directory sync 只能降低对外 guarantee，不可由 exact re-read 静默吸收。
6. 所有 final exact／absent observation 必须在 process-local transaction fence 与 data-root single-writer lease 内完成，避免 observation 后立刻被并发 writer 改写。
7. clear 的 unresolved-absent 必须 latch process-local gate。单靠 journal path presence 无法阻断后续写入。
8. process-exit 测试应明确标为 process-crash evidence；fault-injection 测试应覆盖 effect-after-error、directory sync retry、persistent sync failure、close `EINTR`／`EIO` ownership 和 absent latch。它们都不能标为 power-loss live test。
9. 若 release 文案需要「断电保护」等级，必须报告实际 mount、sync operation、fallback 与硬件范围；当前证据最多支持 Darwin API contract，不支持「任何硬件绝不丢失」。
10. ADR 或实现若允许在 directory sync unsupported／失败后仅凭 exact observation 返回 recovered committed，必须收窄为 namespace-confirmed 或改成 `unresolved`；本研究任务不修改 ADR、源码或测试。

## 取证命令

以下取证不修改仓库：版本、man page、header 与 XNU 命令都是 read-only；唯一 runtime probe 只在系统临时目录建立并自动删除 fixture，没有构建 Noonmark：

```sh
sw_vers
uname -a
xcodebuild -version
xcrun --sdk macosx --show-sdk-path
xcrun --sdk macosx --show-sdk-version
diskutil info /
```

```sh
MANPAGER=cat MANWIDTH=120 man 2 fsync | col -b
MANPAGER=cat MANWIDTH=120 man 2 fcntl | col -b
MANPAGER=cat MANWIDTH=120 man 2 close | col -b
MANPAGER=cat MANWIDTH=120 man 2 rename | col -b
MANPAGER=cat MANWIDTH=120 man 2 unlink | col -b
man -w 2 fsync
man -w 2 fcntl
man -w 2 close
man -w 2 rename
man -w 2 unlink
```

```sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rg -n -C 6 '^#define F_(FULLFSYNC|BARRIERFSYNC)' "$SDK/usr/include/sys/fcntl.h"
rg -n -C 5 '(^|[[:space:]])(close|fsync|unlink|unlinkat)\(' "$SDK/usr/include/unistd.h"
```

```sh
curl -fsSL \
  https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-11417.140.69/bsd/kern/kern_descrip.c \
  | nl -ba \
  | sed -n '243,294p;1687,1789p;3836,3869p;5352,5406p'
curl -fsSL \
  https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-11417.140.69/bsd/vfs/vfs_syscalls.c \
  | nl -ba \
  | sed -n '8570,8669p'
```

APFS acceptance probe 使用 Python standard library 的 `os.open`／`os.fsync` 与 `fcntl.fcntl(fd, 51|85)`，分别作用于 `TemporaryDirectory` 内的 regular file 与 directory。结果为：

```sh
python3 - <<'PY'
import fcntl
import os
import tempfile

def probe(label, operation):
    try:
        operation()
        print(f"{label}: ok")
    except OSError as error:
        print(f"{label}: errno={error.errno}")

with tempfile.TemporaryDirectory(prefix="noonmark-durability-probe-") as root:
    path = os.path.join(root, "probe")
    file_fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.write(file_fd, b"noonmark-durability-probe")
    probe("regular fsync", lambda: os.fsync(file_fd))
    probe("regular F_BARRIERFSYNC", lambda: fcntl.fcntl(file_fd, 85))
    probe("regular F_FULLFSYNC", lambda: fcntl.fcntl(file_fd, 51))
    os.close(file_fd)

    directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    probe("directory fsync", lambda: os.fsync(directory_fd))
    probe("directory F_BARRIERFSYNC", lambda: fcntl.fcntl(directory_fd, 85))
    probe("directory F_FULLFSYNC", lambda: fcntl.fcntl(directory_fd, 51))
    os.close(directory_fd)
PY
```

结果为：

```text
regular fsync: ok
regular F_BARRIERFSYNC: ok
regular F_FULLFSYNC: ok
directory fsync: ok
directory F_BARRIERFSYNC: ok
directory F_FULLFSYNC: ok
```

这不是 crash／power-cut harness。要验证某一具体 storage path 的突然断电行为，需要在可牺牲设备上反复切断供电并在 reboot 后检查，而且结果仍只适用于该 filesystem、device、firmware、controller 与 mount configuration。

## Primary sources

[^fsync-man]: Xcode 26.2 SDK 本机 `fsync(2)`，`$(xcrun --sdk macosx --show-sdk-path)/usr/share/man/man2/fsync.2`，SHA-256 `2399c28e11ea3a1e71b85d0002ac96b540372d405926657a101025f70ae10006`。关键范围为 source lines 48–116。

[^fcntl-man]: Xcode 26.2 SDK 本机 `fcntl(2)`，`$(xcrun --sdk macosx --show-sdk-path)/usr/share/man/man2/fcntl.2`，SHA-256 `cbb0c4e1e2778eb1c7be8ccca7bbdb7c4e5e73c41b5823118992441d540fd205`。`F_BARRIERFSYNC` 与 `F_FULLFSYNC` 的关键范围为 source lines 207–245。

[^close-man]: Xcode 26.2 SDK 本机 `close(2)`，`$(xcrun --sdk macosx --show-sdk-path)/usr/share/man/man2/close.2`，SHA-256 `90217028d7a7ff139ddb419f0a7673446c2c65273a9996e1ad4d76e896c255ac`。关键范围为 source lines 48–118。

[^rename-man]: Xcode 26.2 SDK 本机 `rename(2)`，`$(xcrun --sdk macosx --show-sdk-path)/usr/share/man/man2/rename.2`，SHA-256 `896c6a278dcfd14601147661cf2a4588d85b271ec8798bbec7913c1d17967033`。关键范围为 source lines 58–81、139–146、194–269。

[^unlink-man]: Xcode 26.2 SDK 本机 `unlink(2)`，`$(xcrun --sdk macosx --show-sdk-path)/usr/share/man/man2/unlink.2`，SHA-256 `b523d9a2223fe367d388367f8163fb906d646287ff06fdff5280180d37864e2f`。关键范围为 source lines 51–65、136–175。

[^sdk-headers]: Xcode 26.2 SDK 本机 headers：`usr/include/sys/fcntl.h` lines 259、306，SHA-256 `2072abfccdd4c5170c62b168f89659893d36e23ada3fa5502990c33bba8da613`；`usr/include/unistd.h` lines 449、506、623，SHA-256 `bc3df41b77bd9cf7c1e46bb562280d3ae11068f2e22180e1eae2125c158182ff`。

[^xnu-close]: Apple XNU `xnu-11417.140.69`：[`close_nocancel` 进入 close path](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_descrip.c#L5352-L5406)，[`fp_close_and_unlock` 先 `fdrelse` 后 `fg_drop`](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_descrip.c#L1687-L1789)，[`fg_drop` 最后调用 `fo_close` 并返回 error](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_descrip.c#L243-L294)。

[^xnu-fsync]: Apple XNU `xnu-11417.140.69`：[`fsync_common` 对 vnode dispatch `VNOP_FSYNC`](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/vfs/vfs_syscalls.c#L8570-L8669)。

[^xnu-fcntl]: Apple XNU `xnu-11417.140.69`：[`F_FULLFSYNC`／`F_BARRIERFSYNC` 的 vnode ioctl path，以及 barrier unsupported 时 promote full sync](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_descrip.c#L3836-L3869)。
