# Issue tracker：GitHub

本仓库的 Issues 和 PRD 存放在 `quboliu/noonmark` 的 GitHub Issues。所有操作使用 `gh` CLI。

## 前置条件

运行会访问 issue tracker 的 skill 前，必须安装 `gh`，并完成对 `quboliu/noonmark` 的认证。

命令必须显式指定 `--repo quboliu/noonmark`，不得依赖 `gh` 自动推断仓库。

## 操作约定

- **创建 issue**：`gh issue create --repo quboliu/noonmark --title "..." --body "..."`。多行正文使用 heredoc。
- **读取 issue**：`gh issue view <number> --repo quboliu/noonmark --comments`，并按需读取 labels、以 `jq` 筛选 comments。
- **列出 issues**：`gh issue list --repo quboliu/noonmark --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，并按任务加入适当的 `--label` 和 `--state` filters。
- **评论 issue**：`gh issue comment <number> --repo quboliu/noonmark --body "..."`
- **加入或移除 label**：`gh issue edit <number> --repo quboliu/noonmark --add-label "..."` / `--remove-label "..."`
- **关闭 issue**：`gh issue close <number> --repo quboliu/noonmark --comment "..."`

## Pull requests 作为 triage 入口

**PRs as a request surface: no.**

外部 PR 不进入与 Issues 相同的 triage queue。协作者进行中的 PR 也不受 issue triage 状态机管理。

如果日后把此值改为 `yes`，外部 PR 才使用对应的 `gh pr` 操作：

- **读取 PR**：`gh pr view <number> --repo quboliu/noonmark --comments`，并使用 `gh pr diff <number> --repo quboliu/noonmark` 读取 diff。
- **列出等待 triage 的外部 PR**：`gh pr list --repo quboliu/noonmark --state open --json number,title,body,labels,author,authorAssociation,comments`，只保留 `authorAssociation` 为 `CONTRIBUTOR`、`FIRST_TIME_CONTRIBUTOR` 或 `NONE` 的 PR；排除 `OWNER`、`MEMBER` 和 `COLLABORATOR`。
- **评论、label 或关闭**：使用 `gh pr comment`、`gh pr edit --add-label` / `--remove-label` 和 `gh pr close`，并显式指定仓库。

GitHub 的 Issues 和 PRs 共用编号空间。遇到无法确认类型的 `#42` 时，先运行 `gh pr view 42 --repo quboliu/noonmark`，失败后再运行 `gh issue view 42 --repo quboliu/noonmark`。

## Skill 要求“发布到 issue tracker”时

创建一个 GitHub issue。

## Skill 要求“读取相关 ticket”时

运行：

```sh
gh issue view <number> --repo quboliu/noonmark --comments
```

## Wayfinding 操作

供 `/wayfinder` 使用。一个 **map** 对应一个主 issue，**child tickets** 对应子 issues。

- **Map**：使用单一 issue 保存 Notes、Decisions-so-far 和 Fog，并加入 `wayfinder:map` label。创建命令为 `gh issue create --repo quboliu/noonmark --label wayfinder:map`。
- **Child ticket**：优先通过 GitHub sub-issues API 连接到 map。若 sub-issues 不可用，在 map 正文加入 task list，并在 child 正文顶部写入 `Part of #<map>`。使用 `wayfinder:<type>` labels，其中 type 为 `research`、`prototype`、`grilling` 或 `task`。Ticket 被认领后，assign 给负责推进的 developer。
- **Blocking**：优先使用 GitHub 原生 issue dependencies。加入依赖边：`gh api --method POST repos/quboliu/noonmark/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`。`<blocker-db-id>` 必须是 blocker 的 numeric database ID，可通过 `gh api repos/quboliu/noonmark/issues/<n> --jq .id` 取得，不能使用 issue number 或 `node_id`。若原生 dependencies 不可用，在 child 正文顶部写入 `Blocked by: #<n>, #<n>`。
- **Frontier query**：列出 map 的开放 child issues，排除仍有开放 blocker 或已有 assignee 的 tickets；按 map 中的顺序选择第一项。
- **Claim**：`gh issue edit <n> --repo quboliu/noonmark --add-assignee @me`。这是 session 的第一次写操作。
- **Resolve**：先评论答案，再关闭 issue，最后在 map 的 Decisions-so-far 中加入 context pointer 和链接。
