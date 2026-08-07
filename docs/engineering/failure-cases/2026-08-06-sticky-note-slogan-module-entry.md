# FAIL-2026-08-06-03：Sticky Note slogan 把模块名当成条目名

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-06T23:35:46-04:00
- 影响版本／构建：`73e2c597499359f05093b0beb40894a4ab4cba4f` 上尚未提交的工作树构建
- 引入提交：`20061243f96782862dcca8fc3a932e3e7f26e778` `feat(notes): build the Feiguang and Sticky Note multi-view experience`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：无法由现有 Git 证据确认
- 修复提交：待回填

## 用户症状与影响

Sticky Note 页头写着「把值得反复看见的飞光留在这里」。但「飞光」是模块入口名称，不是一条条 note；中文把模块名误作可数内容，英文复数 `Flylights` 也重复同一错误，造成产品领域语言混乱。

## 时间线

- Sticky Note 与飞光多视图首版加入页头 slogan。
- 用户在真实 App 中指出「飞光」只应表示模块入口，不能指代单条内容。
- 新真实 App 断言先要求正确 slogan 与稳定页头锚点；旧 App 因页面仍显示错误文案而在打开 Sticky Note 时判红。

## 复现与证据

- 源码本地化入口 `stickyNotesSubtitle` 的中文为「把值得反复看见的飞光留在这里。」，英文为 `Keep the Flylights worth seeing again close at hand.`。
- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e` 在加入新断言、尚未改产品文案时失败：`sidebar navigation did not open Sticky Note`；失败条件包含页面新 slogan 证据不存在。
- 复现只运行 `e2e` profile，没有读取或启动 production。

## 排除的假设

- 不是 Sticky Note 与飞光的关系模型错误：Sticky Note 仍是活动条目的精选投影，正文没有复制。
- 不是空状态同一语病：空状态写明「从飞光中挑选……条目」，其中「飞光」表示来源模块、「条目」表示内容对象，语义正确。
- 不是只有中文问题：英文把 `Flylight` 复数化，同样把模块名当成条目。

## 根因与破坏机制

页头文案没有遵守领域词汇边界，把模块入口「飞光」直接代替「内容／条目」。本地化时英文进一步复数化，导致两个语言同时暗示 Flylight 是可数实体。

## 根因修复

- 中文 slogan 改为「把值得反复看见的内容，留在手边。」。
- 英文 slogan 改为 `Keep what matters within sight.`。
- 同一共享文案文件内的空状态、过滤空状态、回看空状态和多分组校验一并改称「飞光里的记录／内容／条目」，英文使用 `Flylight entries`，彻底移除 `Flylights` 和「每条飞光」等量词化表达。
- 编辑、删除、操作菜单、校验错误、全局捕获命令和 accessibility label 等单条内容场景统一使用「记录／条目」与 `entry`；只有模块入口、来源和功能名称保留「飞光／Flylight」。
- Sticky Note 页头加入只用于 E2E 的稳定 subtitle 锚点；真实 App 与年度 Demo 均对账页面实际渲染的共享文案。

## 验证结果

- 修复前 fast gate 与真实 App symptom gate 均按预期判红。
- 修复后的定向 E2E、Demo 与完整 `make check` 待修复提交确定后回填。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，固定中英文 slogan，拒绝 `Flylights`、「每条飞光」、「编辑飞光／Edit Flylight」等量词化或单条化残留，并要求真实 App 页头证据锚点与「记录正文／Entry body」存在。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，物理打开 Sticky Note 后对账页面实际显示的新 slogan；年度 Demo 同时覆盖同一锚点。

## 发行与回滚

只改变显示文案与 E2E 锚点，不涉及 schema、同步或资料迁移。若文案导致截断或本地化回归，停止交付并修正文案；不得恢复把「飞光」当成单条内容的旧句。验证只使用 `e2e` 与 `demo` profile。

## 教训与永久约束

模块入口名与模块内实体名必须分开。界面写来源关系时可以说「从飞光中挑选条目」，但不能把「飞光」复数化或直接用作单条内容；本地化 review 必须同时检查两个语言是否保持相同领域边界。
