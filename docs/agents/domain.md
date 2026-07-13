# Domain docs

本文件规定 engineering skills 探索晷迹代码库时，应如何读取和使用领域文档。

## 布局

本仓库采用 **single-context** 布局：

```text
/
├── CONTEXT.md
├── docs/
│   └── adr/
├── Sources/
└── Tests/
```

根目录 `CONTEXT.md` 是晷迹的统一领域语言来源；`docs/adr/` 保存全项目架构决策。目前没有 `CONTEXT-MAP.md` 或分 context 的领域文档。

## 探索代码前

- 先读取根目录的 `CONTEXT.md`。
- 阅读 `docs/adr/` 中与当前工作范围相关的 ADR。
- 不需要无差别读取所有 ADR；应按受影响模块和设计边界选择相关文件。
- 如果其中某个文件不存在，静默继续。不得仅因文件缺失就预先建议创建；`domain-modeling`、`grill-with-docs` 或 `improve-codebase-architecture` 会在实际解决术语或决策时按需创建。

## 使用 glossary 的词汇

当输出命名领域概念，例如 issue title、重构建议、诊断假设或测试名称时，必须使用 `CONTEXT.md` 定义的词汇。

不得漂移到 glossary 明确列为 `_Avoid_` 的同义词。

如果所需概念尚未记录，应先判断：

- 是否正在引入项目并不使用的语言；若是，重新选择现有术语。
- 是否存在真实领域缺口；若是，记录并交由 `domain-modeling` 澄清。

## 标示 ADR 冲突

如果建议与现有 ADR 冲突，必须明确指出，不得静默覆盖。例如：

> _与 ADR-0007（Mac UI 原型是实现契约）冲突；但值得重新讨论，因为……_
