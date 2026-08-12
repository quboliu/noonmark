# FAIL-2026-08-11-06：目录页切换与滚动搜索失配

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:54:09-04:00
- 影响版本／构建：iOS 初版开发构建；source commit `012aa8595db51d42d60f6c59515a6939acf98a32` 之后的未提交工作树
- 引入提交：待回溯；故障由当前未提交的 Simulator UI gate 暴露
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（基线提交记录）
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

飞光生命周期 gate 已成功创建和置顶内容，但第二次打开目录后点击 Sticky Note 没有稳定切换到目标页面；后续测试操作落在旧页面。失败发生在自定义 compact page-menu 的真实交互边界，App 没有退出。

## 时间线

1. focused gate 通过飞光创建和 Sticky Note 置顶操作。
2. helper 在中等高度的目录 sheet 中最多执行 5 次 `swipeUp()`；提高到 12 次后，Sticky Note 的自定义 Button action 仍在第二次 sheet presentation 中失效。
3. 运行中的 accessibility hierarchy 显示 `ios.page.stickyNotes` 可见且可点击，但页面标题和 detail identity 没有改变；该证据排除了“页面不存在”和“只差滚动次数”。
4. compact 菜单页面入口改为系统 `NavigationLink`，由 destination appearance 统一写入 `store.page`；测试按真实 `Any` descendant 查找 List 生成的 `CollectionView` detail，并保留 12 次 fail-closed 搜索。

## 复现与证据

- 固定设备：`Noonmark iPhone 17 Pro`，iOS Simulator 26.3.1，bundle `app.noonmark.ios.development`。
- focused `xcodebuild test` 首轮：飞光创建、inline 置顶通过；Sticky Note detail identity 未出现。
- runtime hierarchy：`ios.page.stickyNotes` 存在并为 hittable，但自定义 Button action 未改变 page；修复后 `testUserCanPinRestoreAndDeleteFlylightInSimulator` 在固定 iPhone Simulator 通过，0 failures，138.550 秒。

## 排除的假设

- 不是 Sticky Note 页面不存在：root page menu 明确渲染 `ios.page.stickyNotes`。
- 不是飞光 pin 事务失败：在打开目录前 pin action 已被点击。
- 不是页面切换竞态：失败时点击已完成但根 page state 没有改变；后续失败由测试查询类型与回收站显示状态两个独立问题暴露并已修正。

## 根因与破坏机制

自定义 Button 位于 compact sheet 的滚动／presentation 边界，首次展示可以派发 action，第二次展示时 accessibility hierarchy 虽报告 hittable，action 却没有可靠地传播到根导航状态；同时测试曾把 List detail 错判成 `otherElements`。固定增加 swipe 次数只能覆盖可见性，不能修复事件派发边界。

## 根因修复

页面入口改用系统 NavigationLink，使系统负责点击和 presentation 导航；destination appearance 才更新共享 page state，保持页面切换的单一状态来源。测试 helper 继续最多滚动 12 次、每次检查真实 accessibility identifier，超过上限仍 fail-closed，不使用固定 sleep、跳过或伪造页面存在。

## 验证结果

修复后的 focused symptom gate 已通过：固定 `Noonmark iPhone 17 Pro` 上 0 failures，覆盖 Sticky Note 进入、移除、飞光回收站恢复、正文替换和强制终止／重启回读。修复提交待回填；当前工作树尚未提交。

## 永久门禁

- `scripts/test-ios-target-contract`：保持所有页面 identifier 和飞光生命周期测试存在。
- `scripts/test-ios-simulator`：固定 iPhone Simulator 必须在真实目录滚动后进入 Sticky Note，完成 pin／移除和后续飞光生命周期回读。

## 发行与回滚

当前没有 iOS 发行入口。若目录增删页面，必须同步重新评估滚动上限并保持超限 fail-closed；不得删去 Sticky Note 的真实页面路径。

## 教训与永久约束

页面菜单也是长滚动 UI。测试 helper 的可见性搜索上限必须覆盖当前页面层级，并在页面结构变化时由真实 Simulator gate 重新证明。
