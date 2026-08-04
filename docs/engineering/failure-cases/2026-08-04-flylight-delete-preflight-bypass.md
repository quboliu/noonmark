# FAIL-2026-08-04-07：飞光删除绕过行内编辑前置保存

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:00 -04:00
- 影响版本／构建：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` 至 `0d62105`，以及修复前工作树
- 引入提交：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` `feat(ideas): 原生想法记录与置顶、回收站、标签过滤`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

用户正在行内编辑飞光时，详情栏删除动作可直接写入 tombstone，随后才取消 editor。若草稿无效或尚未保存，条目会先消失，草稿也一并丢失；删除因此绕过了搜索、导航与切换条目已经使用的统一 preflight。

## 时间线

- K3 最终 review 静态指出删除顺序与其余上下文切换不一致。
- 真实 App E2E 输入无效草稿后从右侧详情栏物理打开菜单并选择删除，原实现返回 `deleting from the inspector discarded an invalid inline draft`。
- 删除入口移到 `prepareForIdeaContextChange` 之后；无效草稿会阻止删除并恢复焦点，合法草稿先保存再允许删除。

## 复现与证据

运行 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`。修复前，详情栏菜单完成 tracking 后目标飞光已成为 tombstone、editor 结束。修复后，同一路径证明飞光仍为 active、草稿仍在、first responder 仍是原生 editor，SQLite 不出现删除写入。

## 排除的假设

- 不是菜单选错项目：tracking、按键顺序及目标 ID 均由真实视图锚点确认。
- 不是 blur 自动保存可以兜底：草稿本身无效，保存必须 fail-closed。
- 不是只需删除后恢复：tombstone 已经持久化后再恢复会制造额外历史并违反资料事务边界。

## 根因与破坏机制

`deleteIdea` 先调用 `commitEngineMutation`，成功后才在目标恰为 active editor 时取消编辑。它把删除与 editor 结束视为两个独立动作，没有复用“任何会隐藏当前卡片的 mutation 必须先结束 editor”的 Store 边界。

## 根因修复

删除在任何持久化前先调用 `prepareForIdeaContextChange()`；失败立即返回，不写 Engine、不改变选择、不关闭 editor。成功 preflight 后才提交 tombstone。

## 验证结果

- 原始真实 App 症状已由红转绿。
- 飞光专项 E2E、重启及 SQLite 对账通过。
- 完整 `make check` 尚待本轮最终执行。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求删除保留共享 preflight 与真实详情栏失败断言。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，以无效草稿从真实详情栏物理删除；任何 tombstone、草稿或焦点漂移即判红。

## 发行与回滚

只使用固定 `e2e` profile，没有启动或读取 production。若门禁回归，停止交付并回退本轮删除 cutover，不得以删除后恢复或隐藏菜单绕过。

## 教训与永久约束

删除也是上下文切换。凡是会隐藏 active editor 的 intent，都必须经过同一个保存／取消事务边界，不能因动作不可逆而例外。
