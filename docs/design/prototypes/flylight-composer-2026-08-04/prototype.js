/*
 * PROTOTYPE — throwaway UI for comparing three Flylight composer structures.
 * Variants are selected with ?variant=A|B|C and share in-memory demo state only.
 */

const initialParams = new URLSearchParams(location.search);

const variants = {
  A: { name: "安静工作台", className: "variant-a" },
  B: { name: "底部捕捉坞", className: "variant-b" },
  C: { name: "聚焦编辑台", className: "variant-c" },
};

const initialMemos = [
  {
    id: 1,
    day: "2026年7月24日",
    time: "15:10",
    body: "连续用了十天，**Sticky Note** 比长清单更能压住注意力，写进复盘。",
    category: "@复盘",
    labels: ["#方法"],
    sticky: true,
    updated: "",
  },
  {
    id: 2,
    day: "2026年7月24日",
    time: "09:20",
    body: "审阅发布说明时想到：已知限制应该附上临时绕过方法，减少支持成本。",
    category: "",
    labels: ["#发布"],
    sticky: false,
    updated: "",
  },
  {
    id: 3,
    day: "2026年7月23日",
    time: "13:30",
    body: "## 可以复用的交接结构\n- 接口清单\n- 数据边界\n- 失败后的恢复入口",
    category: "@协作",
    labels: ["#交接"],
    sticky: true,
    updated: "昨天 18:42",
  },
  {
    id: 4,
    day: "2026年7月22日",
    time: "18:05",
    body: "> 数据口径注释应由周报模板统一维护。\n\n恢复这条留作用月底跟进提醒。",
    category: "@工作",
    labels: [],
    sticky: false,
    updated: "",
  },
  {
    id: 5,
    day: "2026年7月21日",
    time: "19:45",
    body: "可用性走查的意外发现：空标题占位比想象中更容易误触，值得单独跟进。",
    category: "",
    labels: ["#走查"],
    sticky: false,
    updated: "",
  },
];

const state = {
  variant: normalizedVariant(initialParams.get("variant")),
  page: "flylight",
  memos: structuredClone(initialMemos),
  selectedId: 1,
  composerText: "",
  composerStatus: "idle",
  editingId: null,
  editText: "",
  editStatus: "idle",
  openMenuId: null,
  formatMenu: null,
  searchOpen: false,
  searchText: "",
  review: false,
  railOpen: true,
  deckCollapsed: false,
  transientSavedId: null,
};

const initialDemo = initialParams.get("demo");
if (initialDemo === "valid") {
  state.composerText = "把发布与取消做成真正的产品动作，而不是两段临时文字。 #走查 @产品";
  state.composerStatus = "dirty";
} else if (initialDemo === "failed") {
  state.composerText = "即使保存失败，这份草稿也必须留在原处。";
  state.composerStatus = "failed";
} else if (initialDemo === "editing") {
  state.editingId = 1;
  state.editText = initialMemos[0].body;
  state.editStatus = "dirty";
}

let pendingSelection = null;

function normalizedVariant(value) {
  const key = String(value || "A").toUpperCase();
  return variants[key] ? key : "A";
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function inlineMarkdown(value) {
  return escapeHTML(value)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>')
    .replace(/(^|\s)(#[\p{L}\p{N}_/-]+)/gu, '$1<span class="tag">$2</span>');
}

function renderMarkdown(source) {
  const lines = String(source || "").split("\n");
  const out = [];
  let list = null;
  const closeList = () => {
    if (list) out.push(`</${list}>`);
    list = null;
  };

  for (const raw of lines) {
    if (!raw.trim()) {
      closeList();
      continue;
    }
    let match;
    if ((match = raw.match(/^(#{1,3})\s+(.+)$/))) {
      closeList();
      const level = match[1].length;
      out.push(`<h${level}>${inlineMarkdown(match[2])}</h${level}>`);
    } else if ((match = raw.match(/^>\s?(.+)$/))) {
      closeList();
      out.push(`<blockquote>${inlineMarkdown(match[1])}</blockquote>`);
    } else if ((match = raw.match(/^[-*]\s+\[([ xX])\]\s+(.+)$/))) {
      if (list !== "ul") { closeList(); list = "ul"; out.push("<ul>"); }
      const checked = match[1].toLowerCase() === "x" ? "☑" : "☐";
      out.push(`<li>${checked} ${inlineMarkdown(match[2])}</li>`);
    } else if ((match = raw.match(/^[-*]\s+(.+)$/))) {
      if (list !== "ul") { closeList(); list = "ul"; out.push("<ul>"); }
      out.push(`<li>${inlineMarkdown(match[1])}</li>`);
    } else if ((match = raw.match(/^\d+\.\s+(.+)$/))) {
      if (list !== "ol") { closeList(); list = "ol"; out.push("<ol>"); }
      out.push(`<li>${inlineMarkdown(match[1])}</li>`);
    } else {
      closeList();
      out.push(`<p>${inlineMarkdown(raw)}</p>`);
    }
  }
  closeList();
  return out.join("");
}

function sidebarMarkup() {
  const nav = (page, icon, label, count = "", accent = "") => `
    <button class="nav-item ${state.page === page ? "active" : ""}" data-page="${page}" style="--nav-accent:${accent || "var(--accent)"}">
      <span class="nav-icon">${icon}</span><span>${label}</span><span class="nav-count">${count}</span>
    </button>`;
  return `
    <aside class="sidebar">
      <div class="traffic-lights"><i></i><i></i><i></i></div>
      <section class="nav-section"><div class="nav-title">计划</div>
        ${nav("day", "◷", "Day Todo", "22", "#3976d6")}
        ${nav("pool", "▱", "任务池", "32", "#1ba99a")}
        ${nav("future", "▦", "未来计划", "23", "#7c5ce7")}
        ${nav("repeat", "↪", "重复计划", "12", "#ca791c")}
      </section>
      <section class="nav-section"><div class="nav-title">轨迹</div>
        ${nav("unfinished", "!", "未完成", "15", "#d8901a")}
        ${nav("finished", "✓", "已完成", "460", "#34a36f")}
        ${nav("calendar", "▦", "日历", "", "#d65387")}
        ${nav("zhulong", "✦", "烛龙", "", "#785bea")}
      </section>
      <section class="nav-section"><div class="nav-title">札记</div>
        ${nav("sticky", "▤", "Sticky Note", "", "#d86028")}
        ${nav("flylight", "♧", "飞光", "", "#d8a314")}
      </section>
    </aside>`;
}

function composerStatusMarkup(mode) {
  const status = mode === "edit" ? state.editStatus : state.composerStatus;
  const text = mode === "edit" ? state.editText : state.composerText;
  if (status === "saving") return '<span class="composer-status">正在写入本机…</span>';
  if (status === "failed") return '<span class="composer-status error">未保存，内容仍保留</span>';
  if (status === "saved") return '<span class="composer-status success">✓ 已保存</span>';
  if (text.trim()) return `<span class="composer-status">${text.length} 字 · ⌘↩ ${mode === "edit" ? "保存" : "发布"}</span>`;
  return '<span class="composer-status">草稿自动保留</span>';
}

function formatMenuMarkup(mode) {
  const open = state.formatMenu === mode;
  return `
    <div class="format-menu ${open ? "open" : ""}" data-format-menu="${mode}">
      <button class="menu-item" data-format="bold" data-mode="${mode}"><strong>B</strong>&nbsp;&nbsp;加粗 <kbd>⌘B</kbd></button>
      <button class="menu-item" data-format="italic" data-mode="${mode}"><em>I</em>&nbsp;&nbsp;斜体 <kbd>⌘I</kbd></button>
      <button class="menu-item" data-format="link" data-mode="${mode}">↗&nbsp;&nbsp;链接 <kbd>⌘K</kbd></button>
      <button class="menu-item" data-format="inline-code" data-mode="${mode}">&lt;/&gt;&nbsp;&nbsp;行内代码 <kbd>⌘E</kbd></button>
      <button class="menu-item" data-format="heading" data-mode="${mode}">H2&nbsp;&nbsp;二级标题</button>
      <button class="menu-item" data-format="bullet" data-mode="${mode}">≡&nbsp;&nbsp;无序列表</button>
      <button class="menu-item" data-format="ordered" data-mode="${mode}">1.&nbsp;&nbsp;有序列表</button>
      <button class="menu-item" data-format="check" data-mode="${mode}">☑&nbsp;&nbsp;任务列表</button>
      <button class="menu-item" data-format="quote" data-mode="${mode}">❞&nbsp;&nbsp;引用</button>
    </div>`;
}

function composerMarkup(mode = "new", extraClass = "") {
  const isEdit = mode === "edit";
  const value = isEdit ? state.editText : state.composerText;
  const status = isEdit ? state.editStatus : state.composerStatus;
  const secondary = isEdit ? "取消" : state.variant === "B" ? "稍后" : "收起";
  const primary = isEdit ? "保存修改" : "发布";
  const disabled = !value.trim() || status === "saving";
  const placeholder = isEdit ? "用 Markdown 修改这条飞光…" : "现在在想什么？支持 Markdown、#标签与 @分组";
  const className = isEdit ? "inline-composer" : "";
  return `
    <div class="composer-surface ${className} ${extraClass}" data-composer="${mode}">
      <textarea class="composer-textarea" data-editor="${mode}" aria-label="${isEdit ? "编辑飞光正文" : "飞光正文"}" placeholder="${placeholder}">${escapeHTML(value)}</textarea>
      <div class="composer-toolbar">
        <div class="tool-cluster">
          <button class="tool-button" data-insert="#" data-mode="${mode}" title="选择标签">#</button>
          <button class="tool-button" data-insert="@" data-mode="${mode}" title="选择分组">@</button>
          <button class="tool-button ${state.formatMenu === mode ? "open" : ""}" data-toggle-format="${mode}" title="Markdown 格式">Aa</button>
        </div>
        ${formatMenuMarkup(mode)}
        ${composerStatusMarkup(mode)}
        <div class="action-cluster">
          <button class="secondary-action" data-secondary="${mode}">${secondary}</button>
          <button class="primary-action" data-primary="${mode}" ${disabled ? "disabled" : ""}>
            ${status === "saving" ? '<span class="spinner"></span>' : `<span>${primary}</span><span class="action-arrow">↑</span>`}
          </button>
        </div>
      </div>
    </div>`;
}

function headerMarkup(title, subtitle) {
  return `
    <header class="page-header">
      <div class="page-title-group"><h1 class="page-title">${title}</h1><p class="page-subtitle">${subtitle}</p></div>
      <div class="header-actions">
        ${state.page === "flylight" ? `
          <button class="header-button ${state.searchOpen ? "active" : ""}" data-action="search">⌕ <span>搜索</span></button>
          <button class="header-button ${state.review ? "active" : ""}" data-action="review">↻ <span>回看</span></button>` : ""}
      </div>
    </header>`;
}

function currentMemos() {
  let list = state.page === "sticky" ? state.memos.filter(memo => memo.sticky) : [...state.memos];
  if (state.searchText.trim()) {
    const q = state.searchText.trim().toLowerCase();
    list = list.filter(memo => `${memo.body} ${memo.category} ${memo.labels.join(" ")}`.toLowerCase().includes(q));
  }
  if (state.review) list = list.slice(-3).reverse();
  return list;
}

function rowMenuMarkup(memo) {
  return `
    <div class="row-menu ${state.openMenuId === memo.id ? "open" : ""}" data-row-menu="${memo.id}">
      <button class="menu-item" data-row-action="edit" data-id="${memo.id}">编辑飞光</button>
      <button class="menu-item" data-row-action="sticky" data-id="${memo.id}">${memo.sticky ? "从 Sticky Note 移除" : "加入 Sticky Note"}</button>
      <button class="menu-item danger" data-row-action="delete" data-id="${memo.id}">删除飞光</button>
    </div>`;
}

function memoRowMarkup(memo) {
  if (state.editingId === memo.id) {
    return `<article class="memo-row selected editing" data-memo-id="${memo.id}">${composerMarkup("edit")}</article>`;
  }
  return `
    <article class="memo-row ${state.selectedId === memo.id ? "selected" : ""}" data-memo-id="${memo.id}">
      <div class="memo-body" data-memo-body="${memo.id}" title="双击编辑">${renderMarkdown(memo.body)}</div>
      <div class="memo-meta">
        <span>${memo.time}</span>
        ${memo.updated ? `<span>编辑于 ${memo.updated}</span>` : ""}
        ${memo.category ? `<button class="meta-link">${escapeHTML(memo.category)}</button>` : ""}
        ${memo.labels.map(label => `<button class="meta-link">${escapeHTML(label)}</button>`).join("")}
        ${memo.sticky ? '<span class="sticky-state">▤ Sticky Note</span>' : ""}
        ${state.transientSavedId === memo.id ? '<span class="saved-state">✓ 已保存</span>' : ""}
        <span class="memo-spacer"></span>
        <button class="memo-menu-trigger" data-menu-id="${memo.id}" aria-label="飞光操作">···</button>
      </div>
      ${rowMenuMarkup(memo)}
    </article>`;
}

function timelineMarkup() {
  const list = currentMemos();
  const groups = new Map();
  for (const memo of list) {
    if (!groups.has(memo.day)) groups.set(memo.day, []);
    groups.get(memo.day).push(memo);
  }
  if (!list.length) return '<div class="rail-empty" style="padding:42px 2px">没有匹配的飞光。</div>';
  return [...groups.entries()].map(([day, memos]) => `
    <section class="day-section">
      <div class="day-header"><span>${day}</span><span class="day-count">${memos.length}</span></div>
      <div class="memo-list">${memos.map(memoRowMarkup).join("")}</div>
    </section>`).join("");
}

function searchMarkup() {
  return state.searchOpen ? `
    <div class="search-row">
      <input class="search-input" data-search-input value="${escapeHTML(state.searchText)}" placeholder="搜索正文、分组或标签…" aria-label="搜索飞光">
    </div>` : "";
}

function collectionContextMarkup() {
  const count = currentMemos().length;
  const label = state.review ? "回看" : state.searchText ? `搜索「${escapeHTML(state.searchText)}」` : "最近";
  return `<div class="collection-context"><strong>${label}</strong>&nbsp;·&nbsp;${count}<span class="context-spacer"></span>${state.review || state.searchText ? '<button class="context-link" data-action="recent">返回最近</button>' : ""}</div>`;
}

function variantComposerMarkup() {
  if (state.variant === "A") {
    return `<div class="composer-wrap"><div class="classification-summary"><span>可选分类：</span><button data-insert="#" data-mode="new">#标签</button><button data-insert="@" data-mode="new">@分组</button></div>${composerMarkup("new")}</div>`;
  }
  if (state.variant === "B") {
    return `<div class="dock-shell">${composerMarkup("new")}</div>`;
  }
  return `
    <div class="focus-deck ${state.deckCollapsed ? "deck-collapsed" : ""}">
      <div class="composer-surface">
        <div class="focus-deck-head">
          <span class="focus-mode-dot"></span><span class="focus-deck-title">新建飞光</span><span class="focus-deck-hint">Markdown 编辑台</span><span class="focus-deck-spacer"></span>
          <button class="deck-collapse" data-action="deck">${state.deckCollapsed ? "展开编辑" : "收起编辑台"}</button>
        </div>
        ${composerMarkup("new", "focus-deck-composer").replace('class="composer-surface ', 'class="composer-surface-inner ')}
      </div>
    </div>`;
}

function flylightPageMarkup() {
  return `
    <main class="workspace">
      <button class="rail-expand-floating" data-action="rail">‹‹ 展开详情</button>
      <div class="workspace-scroll"><div class="workspace-inner">
        ${headerMarkup("飞光", "先记下来，再决定它要去哪里。")}
        ${state.variant !== "B" ? variantComposerMarkup() : ""}
        ${searchMarkup()}
        ${collectionContextMarkup()}
        ${timelineMarkup()}
      </div></div>
      ${state.variant === "B" ? variantComposerMarkup() : ""}
    </main>`;
}

function stickyPageMarkup() {
  const cards = state.memos.filter(memo => memo.sticky).map(memo => `
    <article class="sticky-card" data-memo-id="${memo.id}">
      <div class="memo-body" data-open-source="${memo.id}">${renderMarkdown(memo.body)}</div>
      <div class="memo-meta"><span>${memo.day.replace("2026年", "")} ${memo.time}</span><span class="memo-spacer"></span><button class="memo-menu-trigger" data-open-source="${memo.id}">在飞光中打开</button></div>
    </article>`).join("");
  return `
    <main class="workspace">
      <div class="workspace-scroll"><div class="workspace-inner">
        ${headerMarkup("Sticky Note", "把值得反复看见的飞光留在这里。")}
        <div class="collection-context"><strong>便签墙</strong>&nbsp;·&nbsp;${state.memos.filter(memo => memo.sticky).length}</div>
        <div class="sticky-grid">${cards}</div>
      </div></div>
    </main>`;
}

function detailRailMarkup() {
  const memo = state.memos.find(item => item.id === state.selectedId);
  if (state.page !== "flylight" || !memo) {
    return `<aside class="detail-rail"><button class="rail-collapse" data-action="rail">››</button><p class="rail-eyebrow">飞光详情</p><p class="rail-empty">选择一条飞光查看完整内容和操作。</p></aside>`;
  }
  return `
    <aside class="detail-rail">
      <button class="rail-collapse" data-action="rail" title="收起详情">››</button>
      <p class="rail-eyebrow">飞光详情</p>
      <div class="rail-body">${renderMarkdown(memo.body)}</div>
      <div class="rail-section"><div class="rail-label">记录时间</div><div class="rail-value">${memo.day} ${memo.time}${memo.updated ? `<br>最后编辑：${memo.updated}` : ""}</div></div>
      <div class="rail-section"><div class="rail-label">分类</div><div class="rail-value">${escapeHTML([memo.category, ...memo.labels].filter(Boolean).join("  ") || "未分类")}</div></div>
      <div class="rail-actions">
        <button class="primary-action" data-rail-action="edit" data-id="${memo.id}">编辑</button>
        <button class="secondary-action" data-rail-action="sticky" data-id="${memo.id}">${memo.sticky ? "移出 Sticky Note" : "加入 Sticky Note"}</button>
      </div>
    </aside>`;
}

function switcherMarkup() {
  const item = variants[state.variant];
  return `
    <div class="prototype-switcher" aria-label="原型方案切换">
      <button data-variant-step="-1" aria-label="上一个方案">←</button>
      <div class="variant-label">${state.variant} — ${item.name}</div>
      <button data-variant-step="1" aria-label="下一个方案">→</button>
    </div>
    <div class="prototype-state-controls">
      <span>原型状态</span>
      <button data-demo-state="empty">空白</button>
      <button data-demo-state="valid">有效</button>
      <button data-demo-state="saving">保存中</button>
      <button data-demo-state="failed">失败</button>
      <button data-demo-state="editing">编辑</button>
    </div>
    <div class="prototype-live-state">variant=${state.variant}<br>page=${state.page}<br>composer=${state.composerStatus}<br>editing=${state.editingId || "none"}</div>`;
}

function render() {
  const root = document.querySelector("#prototype-root");
  const variant = variants[state.variant];
  root.innerHTML = `
    <div class="prototype-window ${variant.className} ${state.railOpen ? "" : "rail-collapsed"}">
      ${sidebarMarkup()}
      ${state.page === "sticky" ? stickyPageMarkup() : flylightPageMarkup()}
      ${detailRailMarkup()}
      <div class="prototype-mark">PROTOTYPE · MEMORY ONLY</div>
    </div>
    ${switcherMarkup()}`;
  bindEvents();
}

function bindEvents() {
  document.querySelectorAll("[data-page]").forEach(button => button.addEventListener("click", () => {
    const page = button.dataset.page;
    if (page !== "flylight" && page !== "sticky") return;
    state.page = page;
    state.openMenuId = null;
    render();
  }));

  document.querySelectorAll("[data-editor]").forEach(editor => {
    editor.addEventListener("input", () => {
      const mode = editor.dataset.editor;
      if (mode === "edit") {
        state.editText = editor.value;
        state.editStatus = "dirty";
      } else {
        state.composerText = editor.value;
        state.composerStatus = "dirty";
      }
      syncComposer(editor.closest("[data-composer]"), mode);
      syncLiveState();
    });
    editor.addEventListener("keydown", event => {
      if (event.key === "Enter" && event.metaKey) {
        event.preventDefault();
        submitComposer(editor.dataset.editor);
      } else if (event.key === "Escape" && editor.dataset.editor === "edit") {
        event.preventDefault();
        cancelEdit();
      }
    });
  });

  document.querySelectorAll("[data-primary]").forEach(button => button.addEventListener("click", () => submitComposer(button.dataset.primary)));
  document.querySelectorAll("[data-secondary]").forEach(button => button.addEventListener("click", () => {
    if (button.dataset.secondary === "edit") cancelEdit();
    else if (state.variant === "C") { state.deckCollapsed = true; render(); }
    else document.querySelector('[data-editor="new"]')?.blur();
  }));

  document.querySelectorAll("[data-toggle-format]").forEach(button => button.addEventListener("click", event => {
    event.stopPropagation();
    state.formatMenu = state.formatMenu === button.dataset.toggleFormat ? null : button.dataset.toggleFormat;
    render();
    focusEditor(button.dataset.toggleFormat);
  }));
  document.querySelectorAll("[data-format]").forEach(button => button.addEventListener("click", () => applyFormat(button.dataset.mode, button.dataset.format)));
  document.querySelectorAll("[data-insert]").forEach(button => button.addEventListener("click", () => insertAtCursor(button.dataset.mode, `${button.dataset.insert} `)));

  document.querySelectorAll("[data-memo-id]").forEach(row => row.addEventListener("click", event => {
    if (event.target.closest("button, textarea, a")) return;
    if (event.detail > 1) return;
    clearTimeout(pendingSelection);
    const id = Number(row.dataset.memoId);
    pendingSelection = setTimeout(() => {
      if (state.selectedId === id) return;
      state.selectedId = id;
      render();
    }, 190);
  }));
  document.querySelectorAll("[data-memo-body]").forEach(body => body.addEventListener("dblclick", event => {
    event.preventDefault();
    clearTimeout(pendingSelection);
    beginEdit(Number(body.dataset.memoBody));
  }));
  document.querySelectorAll("[data-menu-id]").forEach(button => button.addEventListener("click", event => {
    event.stopPropagation();
    const id = Number(button.dataset.menuId);
    state.openMenuId = state.openMenuId === id ? null : id;
    render();
  }));
  document.querySelectorAll("[data-row-action]").forEach(button => button.addEventListener("click", () => performRowAction(button.dataset.rowAction, Number(button.dataset.id))));
  document.querySelectorAll("[data-rail-action]").forEach(button => button.addEventListener("click", () => performRowAction(button.dataset.railAction, Number(button.dataset.id))));

  document.querySelectorAll("[data-action]").forEach(button => button.addEventListener("click", () => performPageAction(button.dataset.action)));
  document.querySelector("[data-search-input]")?.addEventListener("input", event => {
    state.searchText = event.target.value;
    render();
    const search = document.querySelector("[data-search-input]");
    search?.focus();
    search?.setSelectionRange(search.value.length, search.value.length);
  });
  document.querySelectorAll("[data-open-source]").forEach(button => button.addEventListener("click", () => {
    state.page = "flylight";
    state.selectedId = Number(button.dataset.openSource);
    render();
  }));

  document.querySelectorAll("[data-variant-step]").forEach(button => button.addEventListener("click", () => stepVariant(Number(button.dataset.variantStep))));
  document.querySelectorAll("[data-demo-state]").forEach(button => button.addEventListener("click", () => demoState(button.dataset.demoState)));
}

function syncComposer(surface, mode) {
  if (!surface) return;
  const text = mode === "edit" ? state.editText : state.composerText;
  const status = mode === "edit" ? state.editStatus : state.composerStatus;
  const primary = surface.querySelector("[data-primary]");
  if (primary) primary.disabled = !text.trim() || status === "saving";
  const statusNode = surface.querySelector(".composer-status");
  if (statusNode) {
    statusNode.className = "composer-status";
    statusNode.textContent = text.trim() ? `${text.length} 字 · ⌘↩ ${mode === "edit" ? "保存" : "发布"}` : "草稿自动保留";
  }
}

function syncLiveState() {
  const node = document.querySelector(".prototype-live-state");
  if (node) node.innerHTML = `variant=${state.variant}<br>page=${state.page}<br>composer=${state.composerStatus}<br>editing=${state.editingId || "none"}`;
}

function focusEditor(mode) {
  requestAnimationFrame(() => {
    const editor = document.querySelector(`[data-editor="${mode}"]`);
    editor?.focus();
  });
}

function submitComposer(mode) {
  const isEdit = mode === "edit";
  const text = isEdit ? state.editText : state.composerText;
  if (!text.trim()) return;
  if (isEdit) state.editStatus = "saving";
  else state.composerStatus = "saving";
  render();
  setTimeout(() => {
    if (isEdit) {
      const memo = state.memos.find(item => item.id === state.editingId);
      if (memo) {
        memo.body = text.trim();
        memo.updated = "刚刚";
        state.transientSavedId = memo.id;
      }
      state.editingId = null;
      state.editText = "";
      state.editStatus = "saved";
    } else {
      const id = Math.max(...state.memos.map(memo => memo.id)) + 1;
      state.memos.unshift({ id, day: "今天", time: "现在", body: text.trim(), category: "", labels: [], sticky: false, updated: "" });
      state.selectedId = id;
      state.composerText = "";
      state.composerStatus = "saved";
    }
    render();
    setTimeout(() => {
      state.composerStatus = "idle";
      state.editStatus = "idle";
      state.transientSavedId = null;
      render();
    }, 950);
  }, 650);
}

function cancelEdit() {
  state.editingId = null;
  state.editText = "";
  state.editStatus = "idle";
  state.formatMenu = null;
  render();
}

function beginEdit(id) {
  clearTimeout(pendingSelection);
  const memo = state.memos.find(item => item.id === id);
  if (!memo) return;
  state.page = "flylight";
  state.selectedId = id;
  state.editingId = id;
  state.editText = memo.body;
  state.editStatus = "dirty";
  state.openMenuId = null;
  render();
  focusEditor("edit");
}

function performRowAction(action, id) {
  const memo = state.memos.find(item => item.id === id);
  if (!memo) return;
  if (action === "edit") return beginEdit(id);
  if (action === "sticky") memo.sticky = !memo.sticky;
  if (action === "delete") {
    state.memos = state.memos.filter(item => item.id !== id);
    if (state.selectedId === id) state.selectedId = state.memos[0]?.id || null;
  }
  state.openMenuId = null;
  render();
}

function performPageAction(action) {
  if (action === "search") state.searchOpen = !state.searchOpen;
  if (action === "review") { state.review = !state.review; state.searchOpen = false; state.searchText = ""; }
  if (action === "recent") { state.review = false; state.searchText = ""; state.searchOpen = false; }
  if (action === "rail") state.railOpen = !state.railOpen;
  if (action === "deck") state.deckCollapsed = !state.deckCollapsed;
  render();
}

function insertAtCursor(mode, token) {
  const editor = document.querySelector(`[data-editor="${mode}"]`);
  if (!editor) return;
  const start = editor.selectionStart;
  const end = editor.selectionEnd;
  const next = editor.value.slice(0, start) + token + editor.value.slice(end);
  editor.value = next;
  if (mode === "edit") { state.editText = next; state.editStatus = "dirty"; }
  else { state.composerText = next; state.composerStatus = "dirty"; }
  editor.focus();
  editor.setSelectionRange(start + token.length, start + token.length);
  syncComposer(editor.closest("[data-composer]"), mode);
}

function applyFormat(mode, format) {
  const editor = document.querySelector(`[data-editor="${mode}"]`);
  if (!editor) return;
  const start = editor.selectionStart;
  const end = editor.selectionEnd;
  const selected = editor.value.slice(start, end) || "文字";
  const transforms = {
    bold: `**${selected}**`,
    italic: `*${selected}*`,
    link: `[${selected}](https://example.com)`,
    "inline-code": `\`${selected}\``,
    heading: `## ${selected}`,
    bullet: `- ${selected}`,
    ordered: `1. ${selected}`,
    check: `- [ ] ${selected}`,
    quote: `> ${selected}`,
  };
  const replacement = transforms[format];
  const next = editor.value.slice(0, start) + replacement + editor.value.slice(end);
  if (mode === "edit") { state.editText = next; state.editStatus = "dirty"; }
  else { state.composerText = next; state.composerStatus = "dirty"; }
  state.formatMenu = null;
  render();
  requestAnimationFrame(() => {
    const nextEditor = document.querySelector(`[data-editor="${mode}"]`);
    nextEditor?.focus();
    nextEditor?.setSelectionRange(start, start + replacement.length);
  });
}

function stepVariant(step) {
  const keys = Object.keys(variants);
  const index = keys.indexOf(state.variant);
  state.variant = keys[(index + step + keys.length) % keys.length];
  const params = new URLSearchParams(location.search);
  params.set("variant", state.variant);
  history.replaceState({}, "", `${location.pathname}?${params.toString()}`);
  state.formatMenu = null;
  render();
}

function demoState(kind) {
  if (kind === "empty") {
    state.composerText = "";
    state.composerStatus = "idle";
    state.editingId = null;
  } else if (kind === "valid") {
    state.composerText = "把发布与取消做成真正的产品动作，而不是两段临时文字。 #走查 @产品";
    state.composerStatus = "dirty";
    state.editingId = null;
    state.deckCollapsed = false;
  } else if (kind === "saving") {
    state.composerText ||= "这条飞光正在保存。";
    state.composerStatus = "saving";
    state.editingId = null;
    state.deckCollapsed = false;
  } else if (kind === "failed") {
    state.composerText ||= "即使保存失败，这份草稿也必须留在原处。";
    state.composerStatus = "failed";
    state.editingId = null;
    state.deckCollapsed = false;
  } else if (kind === "editing") {
    beginEdit(state.selectedId || state.memos[0].id);
    return;
  }
  render();
  if (kind === "valid" || kind === "failed") focusEditor("new");
}

window.addEventListener("keydown", event => {
  const target = event.target;
  if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target?.isContentEditable) return;
  if (event.key === "ArrowLeft") { event.preventDefault(); stepVariant(-1); }
  if (event.key === "ArrowRight") { event.preventDefault(); stepVariant(1); }
});

document.addEventListener("click", event => {
  if (!event.target.closest("[data-toggle-format], .format-menu")) {
    state.formatMenu = null;
    document.querySelectorAll(".format-menu.open").forEach(menu => menu.classList.remove("open"));
    document.querySelectorAll("[data-toggle-format].open").forEach(button => button.classList.remove("open"));
  }
  if (!event.target.closest("[data-menu-id], .row-menu")) {
    state.openMenuId = null;
    document.querySelectorAll(".row-menu.open").forEach(menu => menu.classList.remove("open"));
  }
});

render();
