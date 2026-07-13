(() => {
  "use strict";

  const app = document.querySelector("#app");
  const routeKeys = ["surface", "flow", "step", "panel", "provider", "condition", "settings", "scroll", "variant"];
  const valid = {
    surface: ["zhulong", "day", "settings"],
    flow: ["shape", "close"],
    provider: ["online", "local", "failed"],
    condition: ["normal", "scope-expanded", "stale", "long"],
    settings: ["permissions", "memory", "provider", "transparency"],
    variant: ["A", "B", "C"],
  };

  const ui = {
    excludedScope: new Set(),
    focusChoice: "",
    closeReason: "",
    rationaleOpen: false,
    correctionOpen: false,
    correctionText: "",
    lastCorrection: "",
    splitBatch: false,
    planVersion: 1,
    reviewSaved: false,
    yoloEnabled: false,
    hiddenMemories: new Set(),
    clearConfirm: "",
    eventsCleared: false,
    toast: "",
    toastTimer: null,
    homeIntent: "",
    permissions: {
      tasks: "ask",
      memory: "ask",
      remote: "ask",
      todo: "ask",
    },
    shaping: {
      pathChoice: "",
      pathText: "",
      comparisonReady: false,
      criteriaChoice: "",
      criteriaText: "",
      gateChoice: "",
      gateText: "",
      planInvalidated: false,
      replacementRunAuthorized: false,
      correctionRevision: false,
    },
  };

  function readModel() {
    const query = new URLSearchParams(window.location.search);
    const surface = valid.surface.includes(query.get("surface")) ? query.get("surface") : "zhulong";
    const flow = valid.flow.includes(query.get("flow")) ? query.get("flow") : "shape";
    const fallbackStep = surface === "zhulong" ? "home" : "home";
    return {
      surface,
      flow,
      step: query.get("step") || fallbackStep,
      panel: query.get("panel") || "",
      provider: valid.provider.includes(query.get("provider")) ? query.get("provider") : "online",
      condition: valid.condition.includes(query.get("condition")) ? query.get("condition") : "normal",
      settings: valid.settings.includes(query.get("settings")) ? query.get("settings") : "permissions",
      scroll: query.get("scroll") === "bottom" ? "bottom" : "top",
      variant: valid.variant.includes(query.get("variant")) ? query.get("variant") : "A",
    };
  }

  function updateRoute(patch, options = {}) {
    const query = new URLSearchParams(window.location.search);
    for (const key of routeKeys) {
      if (!(key in patch)) continue;
      const value = patch[key];
      if (value === "" || value === null || value === undefined) query.delete(key);
      else query.set(key, String(value));
    }
    if (options.resetPanel !== false && !("panel" in patch)) query.delete("panel");
    const url = `${window.location.pathname}?${query.toString()}`;
    if (options.replace) window.history.replaceState({}, "", url);
    else window.history.pushState({}, "", url);
    render();
  }

  function routeAttributes(patch) {
    return Object.entries(patch)
      .map(([key, value]) => `data-${key}="${value}"`)
      .join(" ");
  }

  function escapeHTML(value) {
    return String(value || "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function navIcon(name) {
    const common = `viewBox="0 0 24 24" aria-hidden="true"`;
    const icons = {
      day: `<svg ${common}><circle cx="12" cy="12" r="8.5"></circle><path d="M12 7v5H8.5"></path></svg>`,
      pool: `<svg ${common}><path d="M4 9.5h16v8.2a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z"></path><path d="M4 9.5 7 5h10l3 4.5"></path><path d="M4 13h4l1.5 2h5L16 13h4"></path></svg>`,
      future: `<svg ${common}><rect x="4" y="5" width="14" height="14" rx="2"></rect><path d="M7.5 3.5v3M14.5 3.5v3M4 9h14M7 12h2M11 12h2M7 15h2"></path><circle cx="18" cy="17" r="3.3"></circle><path d="M18 15.2V17l1.2.8"></path></svg>`,
      unfinished: `<svg ${common}><circle cx="12" cy="12" r="8.7"></circle><path d="M12 7.2v6.2"></path><circle cx="12" cy="16.8" r=".7" class="fill"></circle></svg>`,
      completed: `<svg ${common}><path d="m12 3 2 2.1 2.9-.1.1 2.9L19 10l-1.9 2.1-.1 2.9-2.9-.1L12 17l-2.1-2.1-2.9.1-.1-2.9L5 10l1.9-2.1L7 5l2.9.1z"></path><path d="m8.8 10.2 2 2 4.3-4.4"></path></svg>`,
      calendar: `<svg ${common}><rect x="4" y="5" width="16" height="15" rx="2"></rect><path d="M8 3.5v3M16 3.5v3M4 9h16M8 12h.01M12 12h.01M16 12h.01M8 16h.01M12 16h.01M16 16h.01"></path></svg>`,
      zhulong: `<svg ${common}><path d="m12 3 .7 3.3L16 7l-3.3.7L12 11l-.7-3.3L8 7l3.3-.7z"></path><path d="m17.5 11 .5 2.4 2.5.6-2.5.5-.5 2.5-.5-2.5-2.5-.5 2.5-.6zM7 13l.7 3.1 3.1.7-3.1.7L7 20.6l-.7-3.1-3.1-.7 3.1-.7z"></path></svg>`,
      settings: `<svg ${common}><circle cx="12" cy="12" r="3"></circle><path d="M19.2 13.3v-2.6l-2-.6a6.8 6.8 0 0 0-.6-1.4l1-1.8L15.8 5l-1.8 1a6.8 6.8 0 0 0-1.4-.6l-.6-2h-2.6l-.6 2a6.8 6.8 0 0 0-1.4.6L5.6 5 3.8 6.9l1 1.8a6.8 6.8 0 0 0-.6 1.4l-2 .6v2.6l2 .6a6.8 6.8 0 0 0 .6 1.4l-1 1.8L5.6 19l1.8-1a6.8 6.8 0 0 0 1.4.6l.6 2H12l.6-2a6.8 6.8 0 0 0 1.4-.6l1.8 1 1.8-1.9-1-1.8a6.8 6.8 0 0 0 .6-1.4z"></path></svg>`,
    };
    return icons[name] || icons.day;
  }

  function navItem({ key, label, count = "", active = false, attrs = "", color = "#2961c7" }) {
    return `<button class="nav-item${active ? " active" : ""}" style="--nav-color:${color}" type="button" ${attrs}>
      <span class="nav-icon">${navIcon(key)}</span><span>${label}</span>${count ? `<span class="nav-count">${count}</span>` : ""}
    </button>`;
  }

  function sidebar(model) {
    const dayActive = model.surface === "day";
    const zhulongActive = model.surface === "zhulong";
    const settingsActive = model.surface === "settings";
    return `<aside class="sidebar">
      <div class="sidebar-top"><div class="traffic-lights"><span class="traffic-light red"></span><span class="traffic-light amber"></span><span class="traffic-light green"></span></div></div>
      <div class="brand"><span class="clock-logo"><i></i><b></b></span><strong>晷迹</strong></div>
      <div class="nav-group-label">计划</div>
      <nav class="nav-list" aria-label="主导航">
        ${navItem({ key: "day", label: "Day Todo", count: "5", active: dayActive, color: "#2a6fdb", attrs: routeAttributes({ surface: "day", step: "home" }) })}
        ${navItem({ key: "pool", label: "任务池", count: "3", color: "#0e9488", attrs: `data-notice="本原型只实现烛龙相关路径；任务池保持现有产品边界。"` })}
        ${navItem({ key: "future", label: "未来计划", count: "3", color: "#7c5cff", attrs: `data-notice="本原型不改动未来计划。"` })}
        <div class="nav-group-label trace-label">轨迹</div>
        ${navItem({ key: "unfinished", label: "未完成", count: "5", color: "#e0851b", attrs: `data-notice="本原型不改动未完成池。"` })}
        ${navItem({ key: "completed", label: "已完成", count: "8", color: "#1f8a5b", attrs: `data-notice="本原型不改动已完成池。"` })}
        ${navItem({ key: "calendar", label: "日历", color: "#d1477a", attrs: `data-notice="本原型不改动日历。"` })}
        ${navItem({ key: "zhulong", label: "烛龙", color: "#7c5cff", active: zhulongActive, attrs: routeAttributes({ surface: "zhulong", flow: "shape", step: "home" }) })}
      </nav>
      <div class="sidebar-bottom">
        ${navItem({ key: "settings", label: "设置", color: "#64748b", active: settingsActive, attrs: routeAttributes({ surface: "settings", settings: "permissions", step: "home" }) })}
      </div>
    </aside>`;
  }

  function providerBanner(model) {
    if (model.provider === "online") return "";
    if (model.provider === "local") {
      return `<div class="notice-banner">
        <div class="notice-copy"><strong>当前为烛龙本地模式。</strong> 会话、既有草稿、本地证据和事件历史仍可使用；新的追问与规划生成等待 Provider。</div>
        <div class="button-row"><button class="ghost-button" type="button" data-notice="保留当前输入，继续整理本地事实与范围。">继续本地准备</button><button class="primary-button" type="button" ${routeAttributes({ surface: "settings", settings: "provider", step: "home" })}>配置 Provider</button></div>
      </div>`;
    }
    return `<div class="notice-banner failed">
      <div class="notice-copy"><strong>Provider 无响应，输入与草稿已保存在本机。</strong> 系统没有静默切换 Provider，也没有重复发送。</div>
      <div class="button-row"><button class="ghost-button" type="button" data-provider="online" data-notice="Prototype：模拟重试成功。">重试</button><button class="ghost-button" type="button" ${routeAttributes({ surface: "settings", settings: "provider", step: "home" })}>选择其他 Provider</button><button class="primary-button" type="button" data-provider="local">继续本地工作</button></div>
    </div>`;
  }

  function headerButton(title, attrs = "") {
    return `<button class="header-button" type="button" ${attrs}>${title}</button>`;
  }

  function pageHeader(title, subtitle, trailing = "") {
    return `<header class="page-header"><div class="page-header-copy"><h1>${title}</h1>${subtitle ? `<p>${subtitle}</p>` : ""}</div><div class="page-header-actions">${trailing}</div></header>`;
  }

  function railHeader(title, subtitle, closable = false) {
    return `<div class="rail-header"><div><h2>${title}</h2>${subtitle ? `<p>${subtitle}</p>` : ""}</div>${closable ? `<button class="rail-close" type="button" data-close-panel="true" aria-label="关闭">×</button>` : ""}</div>`;
  }

  function railSection(title, content) {
    return `<section class="rail-section"><h3>${title}</h3>${content}</section>`;
  }

  function railList(rows) {
    return `<div class="rail-list">${rows.map((row) => `<div class="rail-list-row">${row}</div>`).join("")}</div>`;
  }

  function eventRail(model) {
    const events = [
      ["21:18", "使用会话授权调用 Provider", "配置身份 #P-04 · 会话摘要 v4、5 项任务、3 条记忆"],
      ["21:17", "本地承诺风险：证据不足", "没有一致工作量单位和足够可比历史"],
      ["21:16", "用户确认原因假设", "进入复盘草稿，不自动进入长期记忆"],
      ["09:10", "生成承诺快照 v1", "用户手动确认 5 项今日计划"],
      ["昨天", "用户清理最近 1 小时事件", "已清理 12 条内容，保留无正文范围标记"],
    ];
    if (ui.lastCorrection) events.unshift(["刚刚", "用户追加会话更正", escapeHTML(ui.lastCorrection)]);
    if (model.condition === "long") {
      for (let index = 1; index <= 14; index += 1) events.push([`7月${9 - Math.floor(index / 5)}日`, `历史验证事件 ${index}`, "确认长历史滚动与操作区可达"]);
    }
    return `${railHeader("烛龙事件历史", "系统与用户都不能逐条改写", true)}<div class="detail-rail-scroll"><div class="rail-notice">事件只保存用户可读摘要与关联入口，不复制敏感正文。</div><div class="native-events">${ui.eventsCleared ? `<div class="native-event"><time>现在</time><div><strong>用户清理最近 ${ui.clearConfirm}</strong><p>内容已清理；仅保留范围、数量和操作时间。</p></div></div>` : ""}${events.map(([time, title, copy]) => `<div class="native-event"><time>${time}</time><div><strong>${title}</strong><p>${copy}</p><button class="rail-link" type="button" data-notice="Prototype：打开对应的脱敏记录或会话位置。">查看关联 →</button></div></div>`).join("")}</div><div class="rail-clear"><strong>按连续时间范围清理</strong><p>不能逐条删除，也不会撤销 Todo 历史事实。</p><div class="rail-actions">${["1 小时", "1 天", "7 天"].map((range) => `<button class="small-action" type="button" data-action="prepare-clear-events" data-value="${range}">最近 ${range}</button>`).join("")}</div>${ui.clearConfirm ? `<div class="native-notice warn"><span>确认清理最近 ${ui.clearConfirm}？清理后追加无正文标记。</span><button class="small-action warn" type="button" data-action="confirm-clear-events">确认清理</button></div>` : ""}</div></div>`;
  }

  function contextRail(model) {
    if (model.provider !== "online") {
      const title = model.provider === "failed" ? "Provider 失败" : "烛龙本地模式";
      const sections = `${railSection("仍可使用", railList(["会话与既有草稿", "本地承诺事实与风险证据", "记忆管理与事件历史"]))}${railSection("等待 Provider", railList(["新的 LLM 追问", "规划与复盘草稿生成", "记忆候选生成"]))}<div class="rail-actions"><button class="small-action" type="button" data-provider="online">重试</button><button class="small-action accent" type="button" ${routeAttributes({ surface: "settings", settings: "provider", step: "home" })}>配置 Provider</button></div>`;
      return `${railHeader(title, "不会静默切换 Provider", true)}<div class="detail-rail-scroll">${sections}</div>`;
    }
    if (model.flow === "shape") return shapingContextRail(model);
    if (model.step === "tomorrow") {
      return `${railHeader("AI 决策说明", "理由摘要，不暴露原始 chain-of-thought", true)}<div class="detail-rail-scroll">${railSection("主要证据", railList(["承诺快照与今日轨迹", "用户确认的未完成原因", "明日尚未形成新承诺"]))}${railSection("不确定性", `<div class="rail-card"><p>明日任务只形成待确认计划，不自动生成承诺快照。</p></div>`)}</div>`;
    }
    return `${railHeader("依据与范围", "当前动作实际使用的内容", true)}<div class="detail-rail-scroll">${railSection("当前会话", railList(["主要意图：每日收尾", "Provider：配置身份 #P-04", "Todo 写入仍需具体确认"]))}</div>`;
  }

  function sessionControlRail() {
    return `${railHeader("会话控制", "一个主要意图 · 本机保存", true)}<div class="detail-rail-scroll">${railSection("重做烛龙 Agent", `<div class="rail-card"><p>会话 #ZL-204 · 摘要 v4 · 最近保存：刚刚</p></div>`)}${railSection("内容语义", `<div class="rail-card"><p>既有回答不能逐条改写。需要修正时追加会话更正，摘要采用最新内容。</p></div>`)}<div class="rail-stack"><button class="small-action" type="button" data-action="pause-session">暂停并返回</button><button class="small-action" type="button" data-action="toggle-correction">追加会话更正</button><button class="small-action" type="button" data-notice="Prototype：会话已归档。">归档会话</button><button class="small-action warn" type="button" data-notice="Prototype：整体删除会话，不影响已应用 Todo。">整体删除会话</button></div></div>`;
  }

  function memoryRail() {
    return `${railHeader("会话记忆范围", "只使用已确认记忆", true)}<div class="detail-rail-scroll"><div class="rail-notice">排除只影响当前会话，不会删除设置中的记忆。</div>${railSection("正在使用 · 3 条", railList(["偏好滚动式规划", "拒绝隐藏自动化", "Todo 写入接受整组一次确认"]))}<button class="small-action accent" type="button" ${routeAttributes({ surface: "settings", settings: "memory", step: "home" })}>管理全部记忆</button></div>`;
  }

  function pathChoiceText() {
    if (ui.shaping.pathText) return escapeHTML(ui.shaping.pathText);
    const values = {
      daily: "先完整交付每日收尾",
      shape: "先完整交付任务成形",
    };
    return values[ui.shaping.pathChoice] || "先完整交付任务成形";
  }

  function selectedPath() {
    if (ui.shaping.pathText) return "custom";
    return ui.shaping.pathChoice === "daily" ? "daily" : "shape";
  }

  function firstSliceTitle() {
    if (selectedPath() === "daily") return "每日收尾 vertical slice";
    if (selectedPath() === "custom") return pathChoiceText();
    return "任务成形 vertical slice";
  }

  function deferredSliceTitle() {
    return selectedPath() === "daily" ? "任务成形闭环" : "每日收尾闭环";
  }

  function firstSliceCopy() {
    if (selectedPath() === "daily") return "事实 → 原因 → 复盘 → 明日计划 → 结果回执。";
    if (selectedPath() === "custom") return "按用户确认的第一条路径细化；完成标准与事件来源保持可追溯。";
    return "活简报 → 内联 grill → 委托运行 → 草稿 → 原子应用。";
  }

  function criteriaChoiceText() {
    if (ui.shaping.criteriaText) return escapeHTML(ui.shaping.criteriaText);
    const values = {
      usable: "第一条路径可以在真实 App 中端到端每天使用",
      traceable: "所有关键决定、授权和 Todo 变化都可以追溯",
      both: "端到端可用，并且所有关键决定与写入都可追溯",
    };
    return values[ui.shaping.criteriaChoice] || values.both;
  }

  function gateChoiceText() {
    if (ui.shaping.gateText) return escapeHTML(ui.shaping.gateText);
    const values = {
      investigate: "先形成调查任务，取得真实测量后再排日期",
      range: "只记录用户确认的工作量区间，不生成精确日期",
      unresolved: "保留为未决，停止生成近期 Todo 草稿",
    };
    return values[ui.shaping.gateChoice] || values.investigate;
  }

  function gateAutonomyText() {
    if (ui.shaping.gateChoice === "range") return "只使用用户确认的工作量区间；不生成精确日期";
    if (ui.shaping.gateChoice === "unresolved") return "保持暂停，直到用户补充的证据条件成立";
    if (ui.shaping.gateText && !ui.shaping.gateChoice) return "只按用户补充的处置边界继续；超出即停下";
    return "允许形成调查任务；取得真实测量前不做具体排期";
  }

  function shapingVersion(stage) {
    const normal = { focus: "v0.4", criteria: "v0.5", brief: "v0.6", amended: "v0.7" };
    const corrected = { focus: "v0.8", criteria: "v0.9", brief: "v0.10", amended: "v0.11" };
    return (ui.shaping.correctionRevision ? corrected : normal)[stage];
  }

  function shapingStatusBar(model) {
    const statusByStep = {
      scope: ["等待范围确认", "会话摘要 v0.1"],
      focus: ["等你回答", `简报 ${shapingVersion("focus")} · 2 个缺口`],
      criteria: ["等你回答", `简报 ${shapingVersion("criteria")} · 1 个缺口`],
      brief: ["简报待审", `简报 ${shapingVersion("brief")} · 可委托`],
      run: ["规划运行已准备", `绑定简报 ${shapingVersion("brief")}`],
      gate: ["停在决策门", "证据不足"],
      amendment: ["简报修订待审", `${shapingVersion("brief")} → ${shapingVersion("amended")}`],
      "run-resumed": ["规划运行完成", `绑定简报 ${shapingVersion("amended")} · 草稿 v1 已生成`],
      draft: ["规划草稿待审", "草稿 v1 · 写入未授权"],
      apply: ["等待应用确认", "当前批次 · 3 项"],
      receipt: ["本次规划已结束", "批次 #A-301"],
    };
    let [status, version] = statusByStep[model.step] || ["共同定义中", "简报 v0.4"];
    if (ui.shaping.planInvalidated) {
      if (["focus", "criteria", "brief"].includes(model.step)) {
        status = "会话更正待重新确认";
        version = `简报 ${model.step === "focus" ? shapingVersion("focus") : model.step === "criteria" ? shapingVersion("criteria") : shapingVersion("brief")} 修订中 · 旧草稿已停用`;
      } else if (["run", "gate", "amendment", "run-resumed"].includes(model.step) && !ui.shaping.replacementRunAuthorized) {
        status = "旧委托已失效";
        version = "必须从活简报重新委托";
      } else if (["draft", "apply", "receipt"].includes(model.step)) {
        status = "旧草稿已停用";
        version = "会话更正尚未归并";
      }
    }
    const writeStatus = ui.shaping.planInvalidated && ["draft", "apply", "receipt"].includes(model.step) ? "无可用写入授权" : model.step === "apply" ? "当前批次待授权" : model.step === "receipt" ? "一次性写入授权已结束" : "Todo 写入未授权";
    return `<div class="interaction-statusbar"><span class="run-status"><i></i>${status}</span><span>${version}</span><span>单一意图</span><span>${writeStatus}</span><button class="statusbar-link" type="button" data-panel="context">当前对象检视</button></div>`;
  }

  function shapingRail(model) {
    if (ui.shaping.planInvalidated && ["run", "gate", "amendment", "run-resumed"].includes(model.step) && !ui.shaping.replacementRunAuthorized) return `${railHeader("旧规划委托已失效", "会话更正尚未归并")}<div class="detail-rail-scroll">${railSection("更正来源", `<div class="rail-card warn"><p>${escapeHTML(ui.lastCorrection)}</p></div>`)}${railSection("恢复路径", railList(["返回活简报", "重新确认受影响字段", "建立新的单次规划委托"]))}</div>`;
    if (ui.shaping.planInvalidated && ["draft", "apply", "receipt"].includes(model.step)) return `${railHeader("旧规划产物已停用", "会话更正尚未归并")}<div class="detail-rail-scroll"><div class="rail-notice">旧草稿、Todo diff 与任何待建写入授权只能审计，不能继续执行。</div>${railSection("失效来源", `<div class="rail-card warn"><p>${escapeHTML(ui.lastCorrection)}</p></div>`)}${railSection("恢复路径", railList(["返回活简报", "重新确认受影响字段", "再次委托规划", "生成新的 Todo diff"]))}</div>`;
    if (model.step === "scope") return `${railHeader("会话数据授权", "规划与 Todo 写入均未授权")}<div class="detail-rail-scroll">${railSection("当前范围", railList(["6 项相关任务的本地摘要", "2 条相关任务链", "3 条已确认记忆", "Provider 配置身份 #P-04"]))}${railSection("触发重授权", railList(["范围扩大", "Provider 身份变化", "授权过期或上限收紧"]))}</div>`;
    if (model.step === "focus") return `${railHeader("当前字段检视", "用户取舍 · 阻塞委托")}<div class="detail-rail-scroll"><div class="rail-notice">这里只解释当前字段；规划自治与 Todo 写入都尚未授权。</div>${railSection("用户原话", `<div class="rail-card"><p>“两个闭环都要，但不知道先从哪里开始。”</p></div>`)}${railSection("已确认事实", railList(["两个闭环都尚未通过真实 App 端到端验证", "两条路径可以复用会话、事件和 diff 基础"]))}${railSection("烛龙提议 · 非事实", `<div class="rail-card accent"><p>先交付每日收尾可能更早得到每天可用的闭环；需要用户决定。</p></div>`)}${railSection("回答会改变", railList(["第一条近期路径", "验证顺序", "下一条完成标准问题"]))}</div>`;
    if (model.step === "criteria") return `${railHeader("当前字段检视", "完成标准 · 阻塞委托")}<div class="detail-rail-scroll"><div class="rail-notice">第一条路径已经确认；现在只定义怎样才算真正可用。</div>${railSection("已确认取舍", `<div class="rail-card accent"><p>${pathChoiceText()}</p></div>`)}${railSection("为什么现在问", railList(["没有完成标准就无法验收计划", "不能由烛龙自行降低标准", "完成标准会约束后续阶段地图和 E2E"]))}${railSection("尚未授权", railList(["规划自治", "Todo 写入", "长期托管", "记忆确认"]))}</div>`;
    if (model.step === "brief") return `${railHeader("规划委托预检", `绑定简报 ${shapingVersion("brief")}`)}<div class="detail-rail-scroll">${railSection("本版变化", railList([`用户取舍：${pathChoiceText()}`, `完成标准：${criteriaChoiceText()}`, "阻塞缺口：0"]))}${railSection("允许烛龙自主", railList(["拆解与排序", "依赖和风险检查", "初步排期建议", "形成 AI 规划草稿"]))}${railSection("必须停下", railList(["改变目标或完成标准", "扩大数据范围或切换 Provider", "证据不足却需要强结论", "形成 Todo 写入"]))}${railSection("不包含", railList(["Todo 写入", "长期托管", "承诺快照", "自动确认记忆"]))}</div>`;
    if (["run", "gate", "amendment", "run-resumed"].includes(model.step)) return shapingRunRail(model);
    if (model.step === "draft") return shapingDraftRail(false);
    if (model.step === "apply") return shapingApplyRail();
    if (model.step === "receipt") return `${railHeader("应用凭证", "AI 应用批次 #A-301")}<div class="detail-rail-scroll">${railSection("事务结果", railList(["3 项创建全部成功", "最终 diff v1", "事件 #E-930", "结果实体 readback 一致"]))}${railSection("没有发生", railList(["没有生成承诺快照", "没有确认长期记忆", "没有保留未来写入授权"]))}${railSection("有限撤销", `<div class="rail-card ok"><p>目前可用；一旦产生后续依赖或历史事实即失效。</p></div>`)}</div>`;
    return `${railHeader("当前对象检视", "一个主要意图")}<div class="detail-rail-scroll"></div>`;
  }

  function shapingRunRail(model) {
    const current = model.step === "run" ? "建立依赖地图" : model.step === "gate" ? "可行性审查" : model.step === "amendment" ? `简报修订 ${shapingVersion("amended")}` : "编译规划草稿";
    return `${railHeader("本轮运行检视", `当前：${current}`)}<div class="detail-rail-scroll"><div class="rail-notice">运行契约绑定简报与范围版本；命中停机条件会立即等待用户。</div>${railSection("实际输入", railList([`规划简报 ${model.step === "amendment" || model.step === "run-resumed" ? shapingVersion("amended") : shapingVersion("brief")}`, "会话范围授权 #SG-12", "本地证据报告 #ER-08", "Provider 配置身份 #P-04"]))}${railSection("本步证据", railList(model.step === "gate" || model.step === "amendment" ? ["未取得真实工程工作量测量", "没有同度量的可比实现历史", "无资格生成日期、点数或概率"] : ["已有领域模块和真实 App 入口", "共享会话、事件、权限与 diff 边界", "远期范围仍缺工程测量"]))}${railSection("可行性结论", `<div class="rail-card ${model.step === "gate" || model.step === "amendment" ? "warn" : ""}"><p>${model.step === "gate" || model.step === "amendment" ? "证据不足。只能形成调查任务或保留未决。" : "当前没有硬约束不可行结论；仍不得解释为已经可承诺。"}</p></div>`)}${railSection("下一停机条件", `<div class="rail-card"><p>${model.step === "run" ? "遇到证据不足或需要改变简报。" : model.step === "gate" ? "等待用户决定证据不足的处置方式。" : model.step === "amendment" ? "等待重新确认简报修订与规划委托。" : "草稿生成后等待用户审查，不自动写入 Todo。"}</p></div>`)}</div>`;
  }

  function shapingDraftRail(closable = true) {
    return `${railHeader("AI 决策说明", "草稿 v1 · 用户可审查", closable)}<div class="detail-rail-scroll">${railSection("数据范围", railList([`规划简报 ${shapingVersion("amended")}`, "运行记录 #RUN-31", "本地证据报告 #ER-08", "Provider 配置身份 #P-04"]))}${railSection("主要证据", railList(["任务成形与每日收尾共享会话和审计基础", "第一条路径与完成标准由用户确认", "真实工程工作量仍未测量"]))}${railSection("适用约束", railList(["闭域规划", "滚动式规划", "没有具体 diff 不写入", "证据不足不做伪精确排期"]))}${railSection("主要备选", railList(["同时完整推进两个闭环——近期不可验收", "直接安排日期——缺少测量依据", "先做调查与垂直 slice——当前采用"]))}${railSection("不确定性", `<div class="rail-card warn"><p>工程切入点、实际工作量和依赖修改范围尚需调查；因此没有日期、点数或正式兑现概率。</p></div>`)}${railSection("预期影响", railList(["形成完整阶段地图", "派生 3 项近期 Todo 建议", "不改变目标、记忆或承诺快照"]))}</div>`;
  }

  function shapingApplyRail() {
    return `${railHeader("本次应用授权", "只对当前批次与本次点击有效")}<div class="detail-rail-scroll">${railSection("准确批次", railList([`草稿 ${ui.splitBatch ? "v1-U1" : "v1"}`, `${ui.splitBatch ? "2" : "3"} 项创建`, "目标：任务池", "Base Todo revision #T-221"]))}${railSection("预检", railList(["草稿状态：有效", "selection hash：一致", "领域操作：合法", "写入接口：普通 SuntraceCore"]))}${railSection("原子语义", `<div class="rail-card ok"><p>全部成功，或 0 项写入并完整回滚。</p></div>`)}${railSection("不包含", railList(["未来草稿与跨会话写入", "目标、记忆或 Provider 变更", "长期托管", "承诺快照"]))}</div>`;
  }

  function shapingContextRail(model) {
    if (ui.shaping.planInvalidated && ["run", "gate", "amendment", "run-resumed"].includes(model.step) && !ui.shaping.replacementRunAuthorized) return `${railHeader("为什么运行不能继续", "绑定旧简报的委托已经失效", true)}<div class="detail-rail-scroll">${railSection("用户更正", `<div class="rail-card accent"><p>${escapeHTML(ui.lastCorrection)}</p></div>`)}${railSection("安全边界", `<div class="rail-card"><p>更正后的目标和标准尚未重新确认，旧运行不能通过浏览历史恢复。</p></div>`)}</div>`;
    if (ui.shaping.planInvalidated && ["draft", "apply", "receipt"].includes(model.step)) return `${railHeader("为什么不能继续", "会话更正已使旧产物失效", true)}<div class="detail-rail-scroll">${railSection("用户更正", `<div class="rail-card accent"><p>${escapeHTML(ui.lastCorrection)}</p></div>`)}${railSection("被停用的对象", railList(["旧规划草稿", "由旧草稿派生的 Todo diff", "尚未建立的一次性写入授权"]))}${railSection("下一步", `<div class="rail-card"><p>回到活简报重新确认，再建立新的单次规划委托。</p></div>`)}</div>`;
    if (model.step === "draft") return shapingDraftRail(true);
    if (model.step === "apply") return `${railHeader("写入授权为何独立", "规划委托不等于 Todo 写入", true)}<div class="detail-rail-scroll">${railSection("规划委托", `<div class="rail-card"><p>只授权拆解、排序、风险检查和生成草稿。</p></div>`)}${railSection("当前动作", `<div class="rail-card accent"><p>将对最终 diff v1 的当前具体批次建立一次性写入授权。</p></div>`)}${railSection("安全边界", railList(["点击时重新校验版本", "只走普通领域接口", "全部成功或全部回滚", "不会形成承诺快照"]))}<button class="small-action full" type="button" data-close-panel="true">返回确认</button></div>`;
    if (["run", "gate", "amendment", "run-resumed"].includes(model.step)) return `${railHeader("运行决策说明", "不是原始 chain-of-thought", true)}<div class="detail-rail-scroll">${railSection("为什么停下", `<div class="rail-card accent"><p>工程工作量与可比实现历史缺失，无法科学地产生日期、点数或概率。</p></div>`)}${railSection("考虑过的动作", railList(["编造粗略日期——拒绝", "默认任务很小——拒绝", "形成调查任务——可选", "保留未决并停止——可选"]))}${railSection("回答会改变", railList(["简报中的证据不足处置", "近期 Todo 派生规则", "原规划委托将失效并重新确认"]))}<button class="small-action full" type="button" data-close-panel="true">返回运行</button></div>`;
    return `${railHeader("为什么现在问", "当前字段的 AI 决策说明", true)}<div class="detail-rail-scroll">${railSection("用户原话", `<div class="rail-card"><p>“两个闭环都要，但不知道先从哪里开始。”</p></div>`)}${railSection("已确认事实", railList(["两个闭环都尚未端到端验证", "当前没有可行性证明链", "范围与 Provider 身份已确认"]))}${railSection("烛龙提议 · 非事实", `<div class="rail-card accent"><p>先交付每日收尾可能更早形成每天可用的闭环。</p></div>`)}${railSection("主要备选", railList(["先交付任务成形", "先补齐比较后再决定", "同时推进——无法形成单一近期验收路径"]))}${railSection("回答影响", railList(["简报字段与版本", "下一关键缺口", "不会启动规划或 Todo 写入"]))}<button class="small-action full" type="button" data-close-panel="true">返回字段</button></div>`;
  }

  function r3DefaultSessionRail(model) {
    if (model.flow === "shape") return shapingRail(model);
    if (model.step === "facts") return `${railHeader("事实来源", "Provider 没有参与统计")}<div class="detail-rail-scroll">${railSection("本地证据", railList(["承诺快照 v1 · 09:10", "Day Todo 日轨迹", "子任务状态", "2 项日内新增记录"]))}${railSection("尚未形成", `<div class="rail-card"><p>这一阶段不解释原因、不生成记忆，也不改变明日 Todo。</p></div>`)}</div>`;
    if (model.step === "cause") return `${railHeader("可见事实", "最终归因权属于用户")}<div class="detail-rail-scroll">${railSection("任务进展", railList(["权限分组与读取范围已完成", "写入边界尚未开始", "日内新增两项排查并完成"]))}${railSection("当前归因", `<div class="rail-card accent"><p>${closeReasonText()}</p></div>`)}</div>`;
    if (model.step === "review") return `${railHeader("复盘来源", "复盘与 Todo 分开保存")}<div class="detail-rail-scroll">${railSection("事实", railList(["承诺快照 v1", "今日任务轨迹", "2 项日内新增完成"]))}${railSection("原因", `<div class="rail-card"><p>${closeReasonText()}</p></div>`)}</div>`;
    if (model.step === "receipt") return `${railHeader("收尾结果", "下一次承诺尚未形成")}<div class="detail-rail-scroll">${railSection("已完成", railList(["每日复盘已保存", "明日 Todo 批次已应用", "事件 #E-901"]))}${railSection("等待用户", `<div class="rail-card warn"><p>执行“确认今日计划”后才生成新快照。</p></div>`)}</div>`;
    return `${railHeader("当前对象检视", "每日收尾")}<div class="detail-rail-scroll"></div>`;
  }

  function r3NativeDetailRail(model, location = "session") {
    let content = "";
    if (model.panel === "events") content = eventRail(model);
    else if (model.panel === "context") content = contextRail(model);
    else if (model.panel === "session") content = sessionControlRail();
    else if (model.panel === "memory") content = memoryRail();
    else if (location === "home") content = `${railHeader("烛龙边界", "可选 sidecar，不影响普通清单")}<div class="detail-rail-scroll">${railSection("一次一个主要意图", `<div class="rail-card"><p>会话可以暂停与恢复；新目标建立新会话。</p></div>`)}${railSection("快速捕获不受影响", `<div class="rail-card"><p>普通 Todo 始终可以不经过烛龙直接创建。</p></div>`)}${railSection("写入护栏", railList(["没有具体 diff 不写入", "不自动改写历史日", "Provider 失败不影响清单"]))}</div>`;
    else content = r3DefaultSessionRail(model);
    return `<aside class="detail-rail">${content}</aside>`;
  }

  function homeHeader() {
    return pageHeader(
      "烛龙",
      "把模糊的事想清楚，把已经开始的事继续推进。",
      headerButton("事件历史 · 4", `data-panel="events"`),
    );
  }

  function homeIntentComposer({ compact = false, heading = true } = {}) {
    const examples = [
      "规划一个还很模糊的大任务",
      "结束今天并安排明天",
      "梳理一条卡住的 Todo",
    ];
    return `<section class="home-intent${compact ? " compact" : ""}">
      ${heading ? `<div class="home-intent-heading"><h2>你现在想推进什么？</h2><p>先说结果，烛龙会在需要时再询问范围与授权。</p></div>` : ""}
      <div class="home-intent-field">
        <span class="home-intent-plus" aria-hidden="true">＋</span>
        <textarea rows="1" data-home-intent aria-label="告诉烛龙想推进什么" placeholder="说说你现在想推进什么……">${escapeHTML(ui.homeIntent)}</textarea>
        <button class="home-intent-submit" type="button" aria-label="开始梳理" ${routeAttributes({ surface: "zhulong", flow: "shape", step: "scope" })}>→</button>
      </div>
      <div class="home-examples" aria-label="可以直接这样说">
        ${examples.map((example) => `<button type="button" data-action="set-home-intent" data-value="${example}">${example}</button>`).join("")}
      </div>
    </section>`;
  }

  function homeDecisionRow({ tone, marker, title, state, next, action, route }) {
    return `<article class="home-decision-row">
      <span class="home-decision-marker ${tone}">${marker}</span>
      <span class="home-decision-copy"><strong>${title}</strong><span>${state}</span><small>下一步：${next}</small></span>
      <button class="small-action${tone === "accent" ? " accent" : ""}" type="button" ${routeAttributes(route)}>${action}</button>
    </article>`;
  }

  function homeDecisionList() {
    return `<div class="home-decision-list">
      ${homeDecisionRow({ tone: "accent", marker: "形", title: "重做烛龙 Agent", state: "规划简报 v0.6 已形成，规划尚未开始", next: "审查简报，再决定是否委托", action: "审查简报", route: { surface: "zhulong", flow: "shape", step: "brief" } })}
      ${homeDecisionRow({ tone: "amber", marker: "收", title: "7 月 9 日收尾", state: "复盘草稿已经完成，没有写入明日 Todo", next: "确认内容，或回到会话修改", action: "审查复盘", route: { surface: "zhulong", flow: "close", step: "review" } })}
    </div>`;
  }

  function homeRecentRow({ title, state, route }) {
    return `<button class="home-recent-row" type="button" ${routeAttributes(route)}>
      <span><strong>${title}</strong><small>${state}</small></span><b>继续会话 →</b>
    </button>`;
  }

  function homeVariantA(model) {
    return `<div class="native-page" data-home-variant="A">
      ${homeHeader()}
      <div class="native-columns"><div class="page-scroll"><div class="home-prototype home-a">
        ${homeIntentComposer()}
        <section class="home-section"><div class="home-section-heading"><h2>待你决定</h2><span>2 项</span></div>${homeDecisionList()}</section>
      </div></div>${model.panel ? r3NativeDetailRail(model, "home") : ""}</div>
    </div>`;
  }

  function homeVariantB(model) {
    return `<div class="native-page" data-home-variant="B">
      ${homeHeader()}
      <div class="native-columns"><div class="page-scroll"><div class="home-prototype home-b">
        <section class="home-focus-card">
          <div class="home-focus-kicker"><span>现在需要你</span><span class="status-pill amber">运行已暂停</span></div>
          <h2>决定是否把“重做烛龙 Agent”交给烛龙规划</h2>
          <p>目标、完成标准和硬约束已经确认。烛龙尚未运行，也没有创建 Todo。</p>
          <div class="home-focus-next"><span><b>你要做的下一步</b><small>审查规划简报 v0.6，然后确认委托或返回修改。</small></span><button class="small-action accent" type="button" ${routeAttributes({ surface: "zhulong", flow: "shape", step: "brief" })}>审查并决定</button></div>
        </section>
        ${homeIntentComposer({ compact: true, heading: false })}
        <section class="home-section subdued"><div class="home-section-heading"><h2>稍后处理</h2><span>1 项</span></div>
          ${homeRecentRow({ title: "7 月 9 日收尾", state: "复盘草稿等待你确认", route: { surface: "zhulong", flow: "close", step: "review" } })}
        </section>
      </div></div>${model.panel ? r3NativeDetailRail(model, "home") : ""}</div>
    </div>`;
  }

  function homeDecisionRail() {
    return `<aside class="home-decision-rail">
      <header><div><h2>待你决定</h2><p>只收纳会改变后续行动的决定</p></div><span>2</span></header>
      <div class="home-decision-rail-body">${homeDecisionList()}</div>
    </aside>`;
  }

  function homeVariantC(model) {
    return `<div class="native-page" data-home-variant="C">
      ${homeHeader()}
      <div class="home-split">
        <div class="page-scroll"><div class="home-prototype home-c">
          ${homeIntentComposer()}
          <section class="home-section"><div class="home-section-heading"><h2>最近会话</h2><span>不含待决定事项</span></div>
            ${homeRecentRow({ title: "整理同步模块的验证证据", state: "已暂停 · 可以从上次位置继续", route: { surface: "zhulong", flow: "shape", step: "focus" } })}
          </section>
        </div></div>
        ${model.panel ? "" : homeDecisionRail()}
      </div>
      ${model.panel ? r3NativeDetailRail(model, "home") : ""}
    </div>`;
  }

  function zhulongHome(model) {
    if (model.variant === "B") return homeVariantB(model);
    if (model.variant === "C") return homeVariantC(model);
    return homeVariantA(model);
  }

  function sessionPhases(model) {
    const phases = model.flow === "close" ? ["事实", "原因", "复盘", "明日计划", "完成"] : ["范围", "澄清", "简报", "草稿", "应用"];
    const indexMap = model.flow === "close"
      ? { facts: 0, cause: 1, review: 2, tomorrow: 3, receipt: 4 }
      : { scope: 0, focus: 1, brief: 2, draft: 3, apply: 4, receipt: 5 };
    const current = indexMap[model.step] ?? 0;
    return phases.map((phase, index) => `<span class="phase-step${index < current || current >= 5 ? " done" : index === current ? " active" : ""}">${phase}</span>`).join("");
  }

  function sessionHeader(model) {
    const title = model.flow === "close" ? "7 月 10 日收尾" : "重做烛龙 Agent";
    const subtitle = model.flow === "close" ? "承诺与现实分别核对" : "单一意图 · clean-sheet 重做";
    const trailing = `${headerButton("返回", `${routeAttributes({ surface: "zhulong", flow: "shape", step: "home" })} aria-label="返回烛龙首页"`)}${headerButton("暂停", `data-action="pause-session"`)}${headerButton("事件历史 · 4", `data-panel="events"`)}<button class="header-button icon-only" type="button" data-panel="session" aria-label="会话菜单">•••</button>`;
    if (model.flow === "shape") return `${pageHeader(title, subtitle, trailing)}${shapingStatusBar(model)}`;
    return `${pageHeader(title, subtitle, trailing)}<div class="phase-toolbar" aria-label="会话阶段">${sessionPhases(model)}</div>`;
  }

  function scopeRow({ key, icon, title, detail, reason, source }) {
    const excluded = ui.excludedScope.has(key);
    return `<div class="scope-row${excluded ? " excluded" : ""}">
      <span class="scope-icon">${icon}</span>
      <span class="scope-main"><strong>${title}</strong><span>${detail}</span></span>
      <span class="scope-reason"><strong>${reason}</strong><span>${source}</span></span>
      <button class="text-button" type="button" data-action="toggle-scope" data-value="${key}">${excluded ? "恢复" : "排除"}</button>
    </div>`;
  }

  function scopeScreen(model) {
    const memoryCount = ui.excludedScope.has("memory") ? 0 : 3;
    const taskCount = ui.excludedScope.has("tasks") ? 0 : 6;
    return `<div class="workspace">
      <div class="workspace-title"><span class="eyebrow">会话范围回执 · 首次远程调用前</span><h1>先确认烛龙这次可以看到什么。</h1><p>下面只列出当前意图必需的范围。你可以排除任何一项；烛龙会根据剩余资料追问或明确保留不确定性。</p></div>
      ${model.condition === "scope-expanded" ? `<div class="scope-delta"><span class="status-pill amber">新增范围</span><span>规划草稿需要核对“未来计划”中的 2 项依赖。原授权不包含它们；确认前不会读取或发送。</span></div>` : ""}
      <div class="scope-receipt"><div class="receipt-head"><strong>本次会话数据</strong><span>${taskCount} 项任务 · 2 条相关链 · ${memoryCount} 条记忆</span></div>
        ${scopeRow({ key: "tasks", icon: "任", title: "当前项目相关的 6 项任务", detail: "Day Todo 5 项，任务池 1 项", reason: "确认现状与重复项", source: "本机 Todo" })}
        ${scopeRow({ key: "chains", icon: "链", title: "2 条相关任务链摘要", detail: "只含状态、日期与延续次数", reason: "识别真实依赖", source: "本地广算" })}
        ${scopeRow({ key: "memory", icon: "记", title: "3 条已确认记忆", detail: "滚动规划、拒绝隐藏自动化、批量确认", reason: "避免重复询问偏好", source: "可逐项查看" })}
        ${scopeRow({ key: "summary", icon: "会", title: "当前会话摘要 v1", detail: "目标、你的原文与尚未确认的意图", reason: "生成第一条追问", source: "本机会话" })}
        ${scopeRow({ key: "provider", icon: "模", title: "OpenAI Compatible · planning-model", detail: "provider.example/v1 · 远程", reason: "生成情境追问", source: "配置身份 #P-04" })}
      </div>
      <div class="receipt-footer"><p>选择“记住此范围”只会让当前会话在范围不变时继续使用；扩大范围、切换 Provider 或授权过期仍会再次询问。</p><div class="button-row"><button class="ghost-button" type="button" ${routeAttributes({ step: "focus" })}>仅本次使用</button><button class="primary-button" type="button" ${routeAttributes({ step: "focus" })}>继续并记住此范围</button></div></div>
    </div>`;
  }

  function rationaleBlock(kind) {
    if (!ui.rationaleOpen) return "";
    if (kind === "cause") {
      return `<div class="rationale"><div class="rationale-row"><strong>本地事实</strong><span>任务的权限分组子项完成，写入边界子项未开始；临时新增工作共 2 项。</span></div><div class="rationale-row"><strong>烛龙假设</strong><span>边界不清可能阻塞继续推进，但临时工作挤占也是合理备选。</span></div><div class="rationale-row"><strong>回答影响</strong><span>只影响复盘草稿中的原因描述，不改写任务事实，也不会自动成为长期记忆。</span></div></div>`;
    }
    return `<div class="rationale"><div class="rationale-row"><strong>本地事实</strong><span>两个顶层闭环尚未在真实 App 中验证；每日收尾复用 Day Todo 与复盘领域入口。</span></div><div class="rationale-row"><strong>烛龙假设</strong><span>先做每日收尾可能更快建立承诺校准闭环，但这不是用户价值排序的事实。</span></div><div class="rationale-row"><strong>回答影响</strong><span>决定第一条 vertical slice 和验证顺序；不会替你决定长期产品优先级。</span></div></div>`;
  }

  function choiceButton(value, key, title, copy, selected, action = "choose-focus") {
    return `<button class="choice-button${selected ? " selected" : ""}" type="button" data-action="${action}" data-value="${value}"><span class="choice-key">${key}</span><span class="choice-copy"><strong>${title}</strong><span>${copy}</span></span><span class="choice-arrow">›</span></button>`;
  }

  function draftRows(model, tomorrow = false) {
    const base = tomorrow
      ? [
          ["创建", "完成 Provider 权限写入边界", "7 月 11 日 · 优先级 1", "延续未完成且边界已明确"],
          ["创建", "验证 Todo diff 原子应用", "7 月 11 日 · 优先级 2", "拆分为可独立验收的任务"],
          ["回池", "综合概率资格门槛研究", "任务池", "证据不足，不进入明日承诺"],
        ]
      : [
          ["创建", "定义统一烛龙会话状态机", "任务池 · 3 点", "支撑两条顶层闭环"],
          ["创建", "制作收敛后的交互原型", "7 月 12 日 · 4 点", "先验证真实窗口与关键状态"],
          ["添加子任务", "验证事件历史长滚动", "交互原型 · 2 点", "固定 UI 必须不遮挡内容"],
        ];
    if (model.condition === "long") {
      for (let index = 1; index <= 9; index += 1) {
        base.push(["创建", `长内容验收任务 ${index}`, index % 2 ? "任务池" : `7 月 ${12 + index} 日`, "用于验证滚动、日期与理由列在窄窗口中的可读性"]);
      }
    }
    const rows = ui.splitBatch && !tomorrow ? base.slice(0, 2) : base;
    return rows.map(([op, title, target, reason]) => `<div class="diff-row"><span class="diff-operation">${op}</span><span class="diff-main"><strong>${title}</strong><span>烛龙建议 · 等待用户确认</span></span><span class="diff-target">${target}</span><span class="diff-reason">${reason}</span></div>`).join("");
  }

  function diffTable(model, tomorrow = false) {
    return `<div class="diff-table"><div class="diff-head"><span>操作</span><span>任务／子任务</span><span>目标位置</span><span>来源理由</span></div>${draftRows(model, tomorrow)}</div>`;
  }

  function decisionChoice(kind, value, title, copy, selected) {
    return `<button class="decision-choice${selected ? " selected" : ""}" type="button" data-action="choose-r3" data-kind="${kind}" data-value="${value}"><span class="decision-radio"><i></i></span><span><strong>${title}</strong><small>${copy}</small></span></button>`;
  }

  function r3BriefField(label, status, title, copy, className = "") {
    return `<section class="living-field ${className}"><div class="field-label"><span>${label}</span><small>${status}</small></div><div class="field-body"><strong>${title}</strong>${copy ? `<p>${copy}</p>` : ""}</div></section>`;
  }

  function r3BriefHeading(version, gaps, subtitle) {
    return `<div class="brief-document-head"><div><span class="eyebrow">活简报 · 共同工作对象</span><h2>规划简报 <span>${version}</span></h2><p>${subtitle}</p></div><div class="brief-version-actions"><span class="status-pill ${gaps ? "amber" : "green"}">${gaps ? `${gaps} 个阻塞缺口` : "可委托"}</span><button class="small-action" type="button" data-notice="Prototype：打开字段级版本差异。">版本历史</button></div></div>`;
  }

  function r3FocusScreen(model) {
    const choice = ui.shaping.pathChoice;
    const comparison = ui.shaping.comparisonReady
      ? `<div class="r3-comparison"><div><span class="status-pill accent">烛龙比较 · 非用户决定</span><strong>每日收尾</strong><p>复用 Day Todo 与复盘入口；更早验证承诺、事实、原因和明日计划。</p></div><div><span class="status-pill accent">烛龙比较 · 非用户决定</span><strong>任务成形</strong><p>更早验证 grill、规划简报、委托运行和结构化计划。</p></div><p>当前没有完整工程测量，比较只说明产品验证面，不构成可行性结论。</p></div>`
      : "";
    const primary = model.provider === "online"
      ? `<button class="small-action accent" type="button" data-action="confirm-r3-field" data-kind="path">确认并更新简报</button>`
      : `<button class="small-action" type="button" data-notice="回答已保存在本机；等待 Provider 后才能生成下一条追问。">保存回答，等待 Provider</button>`;
    const active = `<section class="living-field active-field r3-active-field"><div class="field-label"><span>用户取舍</span><small>缺口 1 / 2</small></div><div class="field-body"><div class="field-head"><span class="status-pill accent">内联 grill</span><span>会改变：近期路径、验证顺序、下一问题</span></div><strong>如果只能先完整交付一条每天可用的路径，哪一条更重要？</strong><p>烛龙可以比较两条路径的产品验证面，但不能替你作价值取舍。当前没有足够工程测量，不能声称任何一条已经可行或更快。</p>${comparison}<div class="decision-choice-list compact">${decisionChoice("path", "daily", "每日收尾先完整落地", "先验证承诺、事实、原因、复盘和明日计划", choice === "daily")}${decisionChoice("path", "shape", "任务成形先完整落地", "先验证模糊任务、grill、委托运行和计划结构", choice === "shape")}${decisionChoice("path", "compare", "先补齐比较", "只让烛龙补充依赖比较，不把建议当成用户决定", choice === "compare")}</div><textarea id="r3-path-response" data-r3-input="path" aria-label="改写第一条可用路径" placeholder="也可以用自己的话定义第一条路径……">${escapeHTML(ui.shaping.pathText)}</textarea><div class="field-actions"><div><button class="text-button" type="button" data-panel="context">为什么现在问</button><button class="text-button" type="button" data-notice="不知道会保留这个缺口；没有用户决定就不能委托规划。">不知道</button><button class="text-button" type="button" data-action="toggle-correction">追加会话更正</button></div>${primary}</div></div></section>`;
    const version = ui.shaping.planInvalidated ? `${shapingVersion("focus")} 修订` : shapingVersion("focus");
    const subtitle = ui.shaping.planInvalidated ? "会话更正已追加；旧版本和旧草稿均保留审计，但不能继续应用。" : "每次回答都形成新版本；当前只展开最影响委托的一个字段。";
    return `<div class="shaping-workspace living-brief-view r3-brief">${r3BriefHeading(version, 2, subtitle)}<div class="living-brief-document">${r3BriefField("目标", "用户原话", "完整重做烛龙 Agent", "形成一套每天可用、所有重要判断都能审查的工作空间。", "confirmed-field")}${active}${r3BriefField("完成标准", "缺失", "尚未定义最低可接受完成标准", "用户取舍确认后，烛龙只澄清这一项。", "missing-field")}${r3BriefField("硬约束", "3 项已确认", "clean-sheet · 全面白盒 · 无无人写入", "所有范围、假设、授权和写入都必须可审查。", "confirmed-field")}${r3BriefField("可自主事项", "尚未授权", "规划委托尚未发生", "当前只允许共同定义简报。")}${r3BriefField("数据范围", "已披露", "6 项任务 · 2 条任务链 · 3 条已确认记忆", "Provider 配置身份 #P-04；Todo 写入未授权。")}</div></div>`;
  }

  function r3CriteriaScreen(model) {
    const choice = ui.shaping.criteriaChoice;
    const primary = model.provider === "online"
      ? `<button class="small-action accent" type="button" data-action="confirm-r3-field" data-kind="criteria">确认完成标准</button>`
      : `<button class="small-action" type="button" data-notice="回答已保存在本机；等待 Provider 后继续。">保存回答，等待 Provider</button>`;
    const active = `<section class="living-field active-field r3-active-field"><div class="field-label"><span>完成标准</span><small>缺口 1 / 1</small></div><div class="field-body"><div class="field-head"><span class="status-pill accent">内联 grill</span><span>会约束：阶段地图、E2E、规划结束条件</span></div><strong>第一条路径怎样才算真正可用？</strong><p>完成标准必须能被真实 App 路径验收；烛龙不能替你降低标准，也不能把“代码能跑”当成完成。</p><div class="decision-choice-list compact">${decisionChoice("criteria", "usable", "端到端每天可使用", "从入口到结果回执可以在真实 App 中完整走通", choice === "usable")}${decisionChoice("criteria", "traceable", "所有关键决定可追溯", "范围、假设、委托、运行和写入都能回到来源", choice === "traceable")}${decisionChoice("criteria", "both", "两者同时满足", "端到端可用，并且所有关键决定与写入都可追溯", choice === "both")}</div><textarea id="r3-criteria-response" data-r3-input="criteria" aria-label="改写最低完成标准" placeholder="改写或补充最低完成标准……">${escapeHTML(ui.shaping.criteriaText)}</textarea><div class="field-actions"><div><button class="text-button" type="button" data-panel="context">为什么现在问</button><button class="text-button" type="button" data-notice="不知道会继续阻塞规划委托；烛龙不会替你猜一个标准。">不知道</button><button class="text-button" type="button" ${routeAttributes({ step: "focus" })}>返回上一字段</button></div>${primary}</div></div></section>`;
    const version = ui.shaping.planInvalidated ? `${shapingVersion("criteria")} 修订` : shapingVersion("criteria");
    const pathStatus = ui.shaping.planInvalidated ? "用户重新确认" : `用户确认 · ${shapingVersion("criteria")}`;
    return `<div class="shaping-workspace living-brief-view r3-brief">${r3BriefHeading(version, 1, "用户取舍已经进入简报；当前只剩最低完成标准。")}<div class="living-brief-document">${r3BriefField("目标", "用户原话", "完整重做烛龙 Agent", "形成一套每天可用、所有重要判断都能审查的工作空间。", "confirmed-field")}${r3BriefField("用户取舍", pathStatus, pathChoiceText(), "原烛龙提议继续保留在版本历史，不再作为用户决定。", "changed-field")}${active}${r3BriefField("硬约束", "3 项已确认", "clean-sheet · 全面白盒 · 无无人写入", "范围扩大、Provider 变化和 Todo 写入仍需分别确认。", "confirmed-field")}${r3BriefField("可自主事项", "尚未授权", "规划委托尚未发生", "当前只允许共同定义简报。")}${r3BriefField("数据范围", "已披露", "6 项任务 · 2 条任务链 · 3 条已确认记忆", "Provider 配置身份 #P-04；Todo 写入未授权。")}</div></div>`;
  }

  function r3BriefScreen(model) {
    const canDelegate = model.provider === "online";
    const revision = ui.shaping.planInvalidated;
    const version = revision ? `${shapingVersion("brief")} 修订候选` : shapingVersion("brief");
    const pathStatus = revision ? "用户重新确认" : `用户确认 · ${shapingVersion("criteria")}`;
    const criteriaStatus = revision ? "用户重新确认" : `用户确认 · ${shapingVersion("brief")}`;
    const delegationTitle = revision ? `确认修订后的简报 ${shapingVersion("brief")}，并重新进行一次规划委托。` : `确认简报 ${shapingVersion("brief")}，并进行一次规划委托。`;
    const delegationAction = revision ? "确认修订简报并重新委托规划" : `确认简报 ${shapingVersion("brief")} 并委托规划`;
    return `<div class="shaping-workspace living-brief-view r3-brief">${r3BriefHeading(version, 0, "阻塞缺口已经清零；现在审查整份委托合同。")}<div class="living-brief-document">${r3BriefField("目标", "用户原话", "完整重做烛龙 Agent", "形成一套每天可用、所有重要判断都能审查的工作空间。", "confirmed-field")}${r3BriefField("用户取舍", pathStatus, pathChoiceText(), "来源：本轮用户决定；原 AI 提议保留在版本历史。", "changed-field")}${r3BriefField("完成标准", criteriaStatus, criteriaChoiceText(), "必须由真实 App E2E、事件与结果回执共同验证。", "changed-field")}${r3BriefField("硬约束", "3 项已确认", "clean-sheet · 全面白盒 · 无无人写入", "未知外部事实只能成为追问、显式假设或调查任务。", "confirmed-field")}${r3BriefField("可自主事项", "本次委托上限", "拆解、排序、依赖与风险检查、初步排期建议", "遇到目标、标准、硬约束、范围扩大或证据不足必须停下。")}${r3BriefField("显式假设", "1 项待运行验证", "共享会话、事件、权限和 diff 基础可以支撑两条闭环", "运行中发现反例必须停下并生成简报修订。", "assumption-field")}${r3BriefField("数据范围", "会话授权 #SG-12", "6 项任务 · 2 条任务链 · 3 条已确认记忆", "Provider 配置身份 #P-04；本地广算、远程少发。")}</div><div class="delegation-bar r3-delegation"><div><strong>${delegationTitle}</strong><p>允许生成 AI 规划草稿；不包含 Todo 写入、长期托管、承诺快照或记忆确认。</p></div><div class="button-row"><button class="ghost-button" type="button" ${routeAttributes({ step: "criteria" })}>返回修改</button><button class="primary-button" type="button" data-action="restart-r3-planning" ${canDelegate ? routeAttributes({ step: "run" }) : "disabled"}>${delegationAction}</button></div></div></div>`;
  }

  function r3RunRow(status, title, copy, meta, extra = "", className = "") {
    const glyph = status === "done" ? "✓" : status === "active" ? "●" : status === "blocked" ? "!" : "○";
    return `<section class="run-row ${status} ${className}"><span class="run-glyph">${glyph}</span><div class="run-copy"><strong>${title}</strong><p>${copy}</p>${extra}</div><span class="run-meta">${meta}</span></section>`;
  }

  function r3RunContract(version = shapingVersion("brief")) {
    return `<div class="run-contract r3-run-contract"><div><span class="eyebrow">有界规划运行 · #RUN-31</span><h2>重做烛龙 Agent</h2><p>绑定规划简报 ${version}；每一步可见、可暂停、可介入。</p></div><dl><div><dt>本轮可自主</dt><dd>拆解、排序、依赖和风险检查</dd></div><div><dt>必须停下</dt><dd>目标、标准、硬约束、范围或证据不足</dd></div><div><dt>Todo 写入</dt><dd>未授权</dd></div></dl></div>`;
  }

  function r3RunScreen(model) {
    const action = model.provider === "online"
      ? `<button class="small-action accent" type="button" ${routeAttributes({ step: "gate" })}>运行到下一决策门</button>`
      : `<button class="small-action" type="button" disabled>等待 Provider</button>`;
    return `<div class="shaping-workspace delegated-run-view r3-run">${r3RunContract()}<div class="run-timeline">${r3RunRow("done", "锁定运行输入", `规划简报 ${shapingVersion("brief")}、会话范围授权 #SG-12 与 Base Todo revision #T-221 已冻结。`, "完成")}${r3RunRow("done", "核对本地事实", "形成本地证据报告 #ER-08；任务事实与用户决定已经分型。", "完成")}${r3RunRow("active", "建立依赖地图", "正在比较共享基础与两条产品闭环；不会在没有测量时安排日期。", "当前", `<div class="run-artifact"><strong>可见产物</strong><span>会话／权限／事件／diff 是共享基础；两条闭环分别保持独立验收。</span></div><div class="run-actions"><button class="text-button" type="button" data-panel="context">查看本步依据</button>${action}</div>`)}${r3RunRow("pending", "可行性审查", "检查工作量测量、可比历史和可验证世界约束。", "等待")}${r3RunRow("pending", "形成阶段地图", "完整展示长期路径，只细化近期信息充分部分。", "等待")}${r3RunRow("pending", "编译规划草稿", "结构化计划成立后才派生 Todo diff。", "等待")}</div></div>`;
  }

  function r3GateScreen() {
    const choice = ui.shaping.gateChoice;
    return `<div class="shaping-workspace delegated-run-view r3-run">${r3RunContract()}<div class="run-timeline">${r3RunRow("done", "锁定运行输入", `规划简报 ${shapingVersion("brief")} 与会话范围授权已经冻结。`, "完成")}${r3RunRow("done", "建立依赖地图", "共享基础和两条独立验收路径已经形成。", "完成")}${r3RunRow("blocked", "可行性审查", "没有真实工程工作量测量，也没有同度量的可比实现历史。", "已暂停", `<div class="decision-gate r3-gate"><div class="gate-head"><span class="status-pill amber">证据不足</span><span>不能生成具体日期、点数或正式概率</span></div><h3>是否允许先形成调查任务，并把具体排期保留到取得测量之后？</h3><p>这个选择会实质改变简报中的自主边界和近期 Todo 派生规则，因此需要生成简报修订并重新确认委托。</p><div class="decision-choice-list compact">${decisionChoice("gate", "investigate", "先调查，再排日期", "形成工程切入点与工作量测量任务；近期计划不写具体日期", choice === "investigate")}${decisionChoice("gate", "range", "只使用我确认的工作量区间", "不生成精确日期；需要用户先给出区间和可投入时间", choice === "range")}${decisionChoice("gate", "unresolved", "保留未决并停止", "不生成近期 Todo 草稿，等待用户补充证据", choice === "unresolved")}</div><textarea id="r3-gate-response" data-r3-input="gate" aria-label="补充证据不足处置" placeholder="补充限制或用自己的话定义处置方式……">${escapeHTML(ui.shaping.gateText)}</textarea><div class="gate-actions"><button class="text-button" type="button" data-panel="context">为什么必须停下</button><button class="small-action accent" type="button" data-action="confirm-r3-gate">形成简报修订</button></div></div>`)}${r3RunRow("pending", "形成阶段地图", "等待决策门解除。", "阻塞")}${r3RunRow("pending", "编译规划草稿", "结构化计划成立后才派生 Todo diff。", "等待")}</div></div>`;
  }

  function r3AmendmentScreen() {
    const briefVersion = shapingVersion("brief");
    const amendedVersion = shapingVersion("amended");
    return `<div class="shaping-workspace living-brief-view r3-brief">${r3BriefHeading(`${amendedVersion} 修订`, 0, "运行中的新证据实质改变了自主边界；旧委托已经失效。")}<div class="r3-amendment-notice"><span class="status-pill warn">旧委托失效</span><div><strong>为什么必须重新确认</strong><p>“证据不足时如何继续”会改变近期任务派生规则，不能在绑定 ${briefVersion} 的旧委托下继续。</p></div></div><div class="living-brief-document">${r3BriefField("用户取舍", `用户确认 · ${shapingVersion("criteria")}`, pathChoiceText(), "第一条完整路径不变。", "confirmed-field")}${r3BriefField("完成标准", `用户确认 · ${briefVersion}`, criteriaChoiceText(), "最低完成标准不变。", "confirmed-field")}${r3BriefField("证据不足处置", `待确认修订 · ${amendedVersion}`, gateChoiceText(), "来源：运行 #RUN-31 决策门；没有工程测量时不得生成日期、点数或概率。", "changed-field")}${r3BriefField("规划自治", "修订后上限", gateAutonomyText(), "仍不能改变目标、扩大数据范围或写入 Todo。", "changed-field")}</div><div class="delegation-bar r3-delegation"><div><strong>确认简报修订 ${amendedVersion}，并继续此次规划。</strong><p>这会建立绑定新版本的单次委托；Todo 写入仍未授权。</p></div><div class="button-row"><button class="ghost-button" type="button" ${routeAttributes({ step: "gate" })}>返回决策门</button><button class="primary-button" type="button" ${routeAttributes({ step: "run-resumed" })}>确认修订并继续规划</button></div></div></div>`;
  }

  function r3RunResumedScreen() {
    return `<div class="shaping-workspace delegated-run-view r3-run">${r3RunContract(shapingVersion("amended"))}<div class="run-timeline">${r3RunRow("done", "锁定修订后的输入", `新委托绑定规划简报 ${shapingVersion("amended")} 与原会话范围授权。`, "完成", "", "changed-run")}${r3RunRow("done", "完成可行性审查", "结论：证据不足；生成调查任务，不生成具体日期、点数或概率。", "完成")}${r3RunRow("done", "形成阶段地图", "完整路径、依赖与滚动触发条件已经形成。", "完成")}${r3RunRow("done", "派生近期 Todo 建议", "只从信息充分的近期 slice 派生 3 项创建建议。", "完成")}${r3RunRow("active", "编译规划草稿 v1", "阶段地图、AI 决策说明和 Todo 变更 diff 已完成一致性检查。", "可审查", `<div class="run-artifact ok"><strong>运行产物</strong><span>AI 规划草稿 v1 · Base Todo revision #T-221 · 当前有效</span></div><div class="run-actions"><button class="text-button" type="button" data-panel="context">查看运行依据</button><button class="small-action accent" type="button" data-action="accept-r3-draft" ${routeAttributes({ step: "draft" })}>审查规划草稿</button></div>`)}</div></div>`;
  }

  function r3DiffRows(model) {
    const sliceTitle = firstSliceTitle();
    const implementationTitle = selectedPath() === "daily" ? "实现每日收尾 vertical slice" : selectedPath() === "custom" ? `实现：${pathChoiceText()}` : "实现活简报任务成形 vertical slice";
    const validationTitle = selectedPath() === "daily" ? "用真实 App E2E 验证每日收尾闭环" : selectedPath() === "custom" ? `用真实 App E2E 验证：${pathChoiceText()}` : "用真实 App E2E 验证任务成形闭环";
    const rows = [
      ["创建", "调查 R3 的真实工程切入点", "任务池", "阶段 0 · 取得模块边界与工作量测量"],
      ["创建", implementationTitle, "任务池", `阶段 1 · ${sliceTitle} · ${criteriaChoiceText()}`],
      ["创建", validationTitle, "任务池", "阶段 1 · 验证完成标准与白盒事件"],
    ];
    if (model.condition === "long") {
      for (let index = 1; index <= 9; index += 1) rows.push(["调查", `远期阶段触发条件 ${index}`, "会话未决", "只保留触发条件，不形成 Todo 写入"]);
    }
    const visible = ui.splitBatch ? rows.slice(0, 2) : rows;
    return visible.map(([op, title, target, source]) => `<div class="diff-row r3-diff-row"><span class="diff-operation">${op}</span><span class="diff-main"><strong>${title}</strong><span>${source}</span></span><span class="diff-target">${target}</span><span class="diff-reason">没有具体日期 · 等待当前批次确认</span></div>`).join("");
  }

  function r3DiffTable(model) {
    return `<div class="diff-table r3-diff-table">${r3DiffRows(model)}</div>`;
  }

  function r3DraftScreen(model) {
    const invalidated = ui.shaping.planInvalidated;
    const stale = model.condition === "stale" || invalidated;
    const staleBanner = invalidated ? `<div class="stale-banner"><div><strong>会话更正已使这份草稿和它的写入批次失效。</strong><p>旧草稿只供审计；必须回到活简报重新确认并完成一次新的规划委托。</p></div><button class="primary-button" type="button" ${routeAttributes({ step: "focus" })}>返回活简报处理更正</button></div>` : model.condition === "stale" ? `<div class="stale-banner"><div><strong>依赖的 Base Todo revision 已变化，这份草稿不能应用。</strong><p>旧版继续保留供审计；必须按当前状态生成新版本，不能静默 rebase。</p></div><button class="primary-button" type="button" data-action="refresh-draft">生成新版本</button></div>` : "";
    return `<div class="workspace wide r3-draft"><div class="document-head"><div><span class="eyebrow">AI 规划草稿 v1 · Brief ${shapingVersion("amended")} · Run #RUN-31</span><h1>完整路径，近期细化；先取得测量，再讨论日期。</h1><p>计划先描述阶段、依赖和滚动触发条件，Todo diff 只是从成熟近期 slice 派生的独立写入建议。</p></div><div class="button-row"><button class="ghost-button" type="button" data-panel="context">查看 AI 决策说明</button><span class="status-pill ${stale ? "amber" : "green"}">${stale ? "已失效" : "当前有效"}</span></div></div>${staleBanner}<div class="r3-stage-map"><section class="r3-stage done"><span>阶段 0 · 先调查</span><strong>工程切入点与测量</strong><p>确认模块边界、真实修改面和统一工作量制度。</p><small>完成后触发阶段 1 细化</small></section><section class="r3-stage active"><span>阶段 1 · 近期细化</span><strong>${firstSliceTitle()}</strong><p>${firstSliceCopy()}</p><small>以真实 App E2E 验收</small></section><section class="r3-stage"><span>阶段 2 · 后续复用</span><strong>${deferredSliceTitle()}</strong><p>复用会话、事件、权限和 diff 基础，保持独立验收。</p><small>阶段 1 稳定后重新委托</small></section><section class="r3-stage"><span>远期保留</span><strong>校准与世界约束</strong><p>需要真实后验、版本化测量和单独产品审查。</p><small>不生成伪精确 Todo</small></section></div><div class="r3-plan-grid"><section class="native-card"><div class="native-card-heading"><div><h2>依赖与滚动触发</h2><p>远期只保留何时重新细化，不预写假设性任务。</p></div></div><div class="rail-list"><div class="rail-list-row">共享基础：会话、范围授权、事件、版本和 Todo diff</div><div class="rail-list-row">阶段 0 产出工程测量后，刷新阶段 1 草稿</div><div class="rail-list-row">阶段 1 真实 E2E 通过后，再委托 ${deferredSliceTitle()}</div></div></section><section class="native-card"><div class="native-card-heading"><div><h2>可行性审查</h2><p>当前结果不会冒充承诺结论。</p></div><span class="status-pill amber">证据不足</span></div><div class="rail-list"><div class="rail-list-row">缺少真实工程工作量测量</div><div class="rail-list-row">缺少同度量的可比实现历史</div><div class="rail-list-row">因此没有日期、点数或正式兑现概率</div></div></section></div><section class="review-section"><div class="review-title"><h3>从近期 slice 派生的 Todo 变更 diff</h3><span class="rule"></span><span class="status-pill accent">${ui.splitBatch ? "2 项 · 用户修订批次" : model.condition === "long" ? "12 项 · 长内容" : "3 项 · 写入未授权"}</span></div>${r3DiffTable(model)}</section><div class="draft-actions"><p>${invalidated ? "这份 Todo diff 已随旧草稿停用；不能建立写入授权。" : "规划委托已经结束。进入下一步只会审查当前具体 Todo 批次，不会自动写入、形成承诺或确认记忆。"}</p><div class="button-row"><button class="ghost-button" type="button" data-action="split-batch" ${invalidated ? "disabled" : ""}>${ui.splitBatch ? "恢复完整批次" : "拆分批次"}</button><button class="primary-button" type="button" ${stale ? "disabled" : routeAttributes({ step: "apply" })}>审查 Todo 写入</button></div></div></div>`;
  }

  function r3ApplyScreen(model) {
    if (ui.shaping.planInvalidated) return r3InvalidatedWriteScreen("Todo 写入确认");
    return `<div class="workspace wide r3-apply"><div class="workspace-title"><span class="eyebrow">最终写入确认 · AI 规划草稿 ${ui.splitBatch ? "v1-U1" : "v1"}</span><h1>确认当前批次将创建的全部普通 Todo。</h1><p>下面的 diff 是唯一执行依据。这个动作与规划委托分离，也不会生成承诺快照。</p></div><div class="apply-summary"><div class="summary-cell"><span>具体操作</span><strong>${ui.splitBatch ? "2 项创建" : "3 项创建"}</strong></div><div class="summary-cell"><span>目标范围</span><strong>任务池 · 无具体日期</strong></div><div class="summary-cell"><span>授权有效期</span><strong>仅本次点击</strong></div></div><section class="review-section"><div class="review-title"><h3>最终 Todo 变更 diff</h3><span class="rule"></span><button class="text-button" type="button" data-panel="context">为什么需要独立确认</button></div>${r3DiffTable(model)}</section><div class="atomic-box"><span class="atomic-icon">原</span><div class="atomic-copy"><strong>全部成功，或 0 项写入。</strong><p>点击时重新校验草稿 hash、选择批次与 Base Todo revision；任何失败都会完整回滚并追加事件。</p></div><button class="primary-button" type="button" ${routeAttributes({ step: "receipt" })}>确认并原子应用 ${ui.splitBatch ? "2" : "3"} 项</button></div><div class="draft-actions"><p>不包含未来草稿、跨会话写入、目标、记忆、Provider、长期托管或承诺快照。</p><button class="ghost-button" type="button" ${routeAttributes({ step: "draft" })}>返回修改批次</button></div></div>`;
  }

  function r3InvalidatedWriteScreen(objectName) {
    return `<div class="workspace wide r3-invalidated-write"><div class="stale-banner"><div><strong>${objectName}已随旧规划草稿停用。</strong><p>用户追加了会话更正，旧 diff 不能再建立或恢复写入授权；没有 Todo 被应用。</p></div><button class="primary-button" type="button" ${routeAttributes({ step: "focus" })}>返回活简报处理更正</button></div><div class="r3-correction-receipt"><span class="status-pill accent">更正来源</span><div><strong>${escapeHTML(ui.lastCorrection)}</strong><p>旧事件与旧草稿继续保留审计，但不会产生执行入口。</p></div><button class="text-button" type="button" data-panel="events">查看事件</button></div></div>`;
  }

  function r3InvalidatedRunScreen() {
    return `<div class="workspace wide r3-invalidated-run"><div class="stale-banner"><div><strong>绑定旧简报的规划委托已经失效。</strong><p>浏览器历史不能恢复旧运行。用户更正必须先进入活简报并重新确认。</p></div><button class="primary-button" type="button" ${routeAttributes({ step: "focus" })}>返回活简报处理更正</button></div><div class="r3-correction-receipt"><span class="status-pill accent">更正来源</span><div><strong>${escapeHTML(ui.lastCorrection)}</strong><p>旧运行记录继续可审计，但没有继续按钮或草稿生成权限。</p></div><button class="text-button" type="button" data-panel="events">查看事件</button></div></div>`;
  }

  function r3ReceiptScreen() {
    if (ui.shaping.planInvalidated) return r3InvalidatedWriteScreen("应用回执");
    const count = ui.splitBatch ? 2 : 3;
    const implementationTitle = selectedPath() === "daily" ? "实现每日收尾 vertical slice" : selectedPath() === "custom" ? `实现：${pathChoiceText()}` : "实现活简报任务成形 vertical slice";
    const validationTitle = selectedPath() === "daily" ? "用真实 App E2E 验证每日收尾闭环" : selectedPath() === "custom" ? `用真实 App E2E 验证：${pathChoiceText()}` : "用真实 App E2E 验证任务成形闭环";
    return `<div class="workspace r3-receipt"><div class="receipt-success">✓</div><div class="workspace-title" style="margin-top:15px"><span class="eyebrow">AI 应用批次 #A-301 · readback 已核对</span><h1>${count} 项创建已经原子应用。</h1><p>这些结果已经成为普通 Noonmark Todo；本次规划委托与一次性写入授权均已结束。</p></div><div class="result-list"><div class="result-row"><span class="result-check">✓</span><span class="result-copy"><strong>调查 R3 的真实工程切入点</strong><span>已创建到任务池 · 来源：阶段 0 · 结果 #T-310</span></span><button class="text-button" type="button" data-notice="Prototype：打开结果 Todo。">查看任务</button></div><div class="result-row"><span class="result-check">✓</span><span class="result-copy"><strong>${implementationTitle}</strong><span>已创建到任务池 · 无具体日期 · 结果 #T-311</span></span><button class="text-button" type="button" data-notice="Prototype：打开结果 Todo。">查看任务</button></div>${ui.splitBatch ? "" : `<div class="result-row"><span class="result-check">✓</span><span class="result-copy"><strong>${validationTitle}</strong><span>已创建到任务池 · 无具体日期 · 结果 #T-312</span></span><button class="text-button" type="button" data-notice="Prototype：打开结果 Todo。">查看任务</button></div>`}</div><div class="r3-no-side-effects"><span class="status-pill green">Todo 事务成功</span><span>没有生成承诺快照</span><span>没有确认长期记忆</span><span>没有保留未来写入授权</span></div><div class="receipt-meta"><span class="status-pill green">有限撤销目前可用</span><span class="status-pill">最终 diff v1</span><span class="status-pill">事件 #E-930</span></div><div class="draft-actions"><p>后续若取得工程测量或阶段结果，需要更新活简报并再次进行单次规划委托。</p><div class="button-row"><button class="ghost-button" type="button" data-panel="events">查看事件历史</button><button class="primary-button" type="button" ${routeAttributes({ surface: "zhulong", flow: "shape", step: "home" })}>返回烛龙</button></div></div></div>`;
  }

  function closeFactsScreen() {
    return `<div class="workspace wide">
      <div class="workspace-title"><span class="eyebrow">每日收尾 · 先看事实</span><h1>原计划没有完整兑现，但实际产出没有停下。</h1><p>承诺兑现与实际产出分别呈现，不互相抵销；这一页只展示本地确定性事实，不做原因归纳。</p></div>
      <div class="facts-grid"><section class="fact-panel"><div class="fact-panel-head"><strong>承诺兑现</strong><span>承诺快照 v1 · 09:10 手动确认 · 5 项</span></div><div class="fact-line"><span>完整兑现</span><strong class="good">3 项</strong></div><div class="fact-line"><span>部分推进</span><strong>1 项</strong></div><div class="fact-line"><span>未完成</span><strong class="warn">1 项</strong></div><div class="fact-line"><span>承诺调整</span><strong>0 项</strong></div></section><section class="fact-panel"><div class="fact-panel-head"><strong>实际产出</strong><span>今天真实完成或推进的全部工作</span></div><div class="fact-line"><span>承诺内完成</span><strong class="good">3 项</strong></div><div class="fact-line"><span>日内新增完成</span><strong class="good">2 项</strong></div><div class="fact-line"><span>新增但未完成</span><strong>0 项</strong></div><div class="fact-line"><span>仍在推进</span><strong>1 项</strong></div></section></div>
      <p class="fact-note">本地事实来源：承诺快照、Day Todo 日轨迹、子任务状态与日内新增记录。Provider 没有参与统计。</p>
      <section class="review-section"><div class="review-title"><h3>需要用户解释的 1 项</h3><span class="rule"></span><span class="status-pill amber">未形成原因</span></div><div class="result-list"><div class="result-row"><span class="scope-icon">权</span><span class="result-copy"><strong>整理 Provider 权限</strong><span>2/3 子任务完成；“确定 YOLO 写入边界”未开始</span></span><span class="status-pill">部分推进</span></div></div></section>
      <div class="draft-actions"><p>烛龙下一步只提出原因假设。你可以选择“不知道”，未经确认的内容不会进入复盘或记忆。</p><button class="primary-button" type="button" ${routeAttributes({ step: "cause" })}>确认事实，审查原因</button></div>
    </div>`;
  }

  function closeCauseScreen() {
    return `<div class="workspace wide"><div class="focus-layout">
      <section class="question-card"><span class="question-number">未完成原因 1 / 1 · 等待用户确认</span><h1>“整理 Provider 权限”停在部分推进，主要原因是什么？</h1><p>烛龙依据可见轨迹提出三个可能解释。它们都不是事实，最终归因权属于你。</p><div class="choice-list">
        ${choiceButton("boundary", "A", "任务边界仍不清楚", "权限分组完成，但 YOLO 与 Todo 写入边界尚未确定", ui.closeReason === "boundary", "choose-cause")}
        ${choiceButton("interrupt", "B", "临时工作挤占了时间", "今天额外完成了两项未在承诺中的排查工作", ui.closeReason === "interrupt", "choose-cause")}
        ${choiceButton("unknown", "C", "我现在还不知道", "保留为不确定，不把猜测写入复盘或记忆", ui.closeReason === "unknown", "choose-cause")}
      </div><div class="question-tools"><button class="text-button" type="button" data-action="toggle-rationale">${ui.rationaleOpen ? "收起判断依据" : "为什么提出这些可能"}</button><button class="text-button" type="button" data-action="choose-cause" data-value="unknown">保留不确定</button><button class="text-button" type="button" data-action="toggle-correction">更正事实</button></div>${rationaleBlock("cause")}</section>
      <aside class="mini-brief"><h3>可见事实</h3><div class="brief-item"><label>任务进展</label><p>权限分组与读取范围已完成；写入边界未开始。</p></div><div class="brief-item"><label>日内变化</label><p>新增两项 Provider 排查并完成。</p></div><div class="brief-item changed"><label>当前归因</label><p>${closeReasonText()}</p></div><div class="brief-item"><label>记忆</label><p>本次原因不会自动成为长期记忆。</p></div></aside>
    </div></div>`;
  }

  function closeReasonText() {
    const values = { boundary: "用户确认：任务边界仍不清楚。", interrupt: "用户确认：临时工作挤占时间。", unknown: "用户明确保留为不确定。" };
    return values[ui.closeReason] || "等待用户确认；当前只是烛龙假设。";
  }

  function closeReviewScreen() {
    return `<div class="workspace wide">
      <div class="document-head"><div><span class="eyebrow">AI 复盘草稿 · 与 Todo 分开保存</span><h1>先审查今天的文字记录。</h1><p>草稿只引用本地事实和你确认的原因；编辑后将标记为“烛龙起草后用户修改”。</p></div><span class="status-pill ${ui.reviewSaved ? "green" : "amber"}">${ui.reviewSaved ? "已保存" : "未保存"}</span></div>
      <div class="review-editor"><div class="editor-card"><textarea aria-label="复盘草稿">今天原计划 5 项，完整完成 3 项，另有 1 项部分推进、1 项未完成。日内新增并完成了两项 Provider 排查工作，这些产出不抵销原承诺结果。

“整理 Provider 权限”未完整完成，${ui.closeReason === "unknown" ? "目前原因仍不确定" : ui.closeReason === "interrupt" ? "主要因为临时排查工作挤占了原计划时间" : "主要因为 YOLO 与 Todo 写入边界仍不明确"}。明天先收敛写入边界，再验证具体 Todo diff。</textarea><div class="draft-actions"><p>保存复盘不会创建、延续或排期任何任务。</p><button class="primary-button" type="button" data-action="save-review">${ui.reviewSaved ? "已保存复盘" : "保存复盘"}</button></div></div><aside class="editor-meta"><div class="meta-card"><strong>事实来源</strong><p>承诺快照 v1、今日任务轨迹、2 项日内新增完成记录。</p></div><div class="meta-card"><strong>原因来源</strong><p>${closeReasonText()}</p></div><div class="meta-card"><strong>复盘来源标记</strong><p>烛龙起草；保存时按文本是否修改记录来源。</p></div></aside></div>
      <div class="draft-actions"><p>下一步将单独审查明日 Todo diff。即使 Todo 应用失败，已经保存的复盘也不会被回滚。</p><button class="primary-button" type="button" ${routeAttributes({ step: "tomorrow" })}>审查明日计划</button></div>
    </div>`;
  }

  function closeTomorrowScreen(model) {
    return `<div class="workspace wide">
      <div class="document-head"><div><span class="eyebrow">明日 Todo 建议 · 独立批次</span><h1>处理未决后续，不自动制造新承诺。</h1><p>应用后只会形成 7 月 11 日的计划草稿与任务池项目；用户仍需在 Day Todo 中执行“确认今日计划”。</p></div><button class="ghost-button" type="button" data-panel="context">为什么这样安排</button></div>
      <div class="stage-map"><div class="stage-lane active"><span>明日优先</span><strong>收敛写入边界</strong><p>解除当前任务的明确阻塞。</p></div><div class="stage-lane"><span>随后验证</span><strong>Todo diff 原子应用</strong><p>在边界明确后完成真实路径验证。</p></div><div class="stage-lane"><span>暂不承诺</span><strong>综合概率研究</strong><p>证据不足，回到任务池等待。</p></div></div>
      <section class="review-section"><div class="review-title"><h3>明日 Todo diff</h3><span class="rule"></span><span class="status-pill accent">3 项</span></div>${diffTable(model, true)}</section>
      <div class="atomic-box"><span class="atomic-icon">原</span><div class="atomic-copy"><strong>复盘与 Todo 分别处理。</strong><p>这次只原子应用上面的 3 项 Todo 变化；不会生成承诺快照，也不会修改已保存复盘。</p></div><button class="primary-button" type="button" ${routeAttributes({ step: "receipt" })}>原子应用明日计划</button></div>
    </div>`;
  }

  function closeReceiptScreen() {
    return `<div class="workspace">
      <div class="receipt-success">✓</div><div class="workspace-title" style="margin-top:15px"><span class="eyebrow">7 月 10 日收尾 · 已完成</span><h1>事实、复盘与明日计划已经分别落定。</h1><p>烛龙没有替你解释未知原因，也没有把明日计划追认为新的承诺。</p></div>
      <div class="result-list"><div class="result-row"><span class="result-check">✓</span><span class="result-copy"><strong>每日复盘已保存</strong><span>来源：烛龙起草后用户确认 · 不含未确认归因</span></span><button class="text-button" type="button" data-notice="Prototype：打开 7 月 10 日每日复盘。">查看复盘</button></div><div class="result-row"><span class="result-check">✓</span><span class="result-copy"><strong>明日计划草稿已应用</strong><span>7 月 11 日 2 项；任务池 1 项 · AI 应用批次 #A-205</span></span><button class="text-button" type="button" data-notice="Prototype：打开 7 月 11 日 Day Todo。">查看计划</button></div><div class="result-row"><span class="scope-icon">承</span><span class="result-copy"><strong>尚未形成下一次承诺</strong><span>到 7 月 11 日 Day Todo 执行“确认今日计划”后才生成快照</span></span><span class="status-pill amber">等待确认</span></div></div>
      <div class="receipt-meta"><span class="status-pill green">复盘已保存</span><span class="status-pill green">Todo 批次成功</span><span class="status-pill">事件 #E-901</span></div>
      <div class="draft-actions"><p>本次会话可以归档；记忆刷新只会产生候选，不会让新的画像结论自动生效。</p><div class="button-row"><button class="ghost-button" type="button" data-panel="events">查看事件历史</button><button class="primary-button" type="button" ${routeAttributes({ surface: "day", step: "home" })}>返回 Day Todo</button></div></div>
    </div>`;
  }

  function sessionCorrectionPanel(model) {
    if (ui.correctionOpen) {
      return `<section class="native-card r3-correction-panel"><div><span class="eyebrow">追加式更正 · 不覆盖旧历史</span><strong>说明要更正的原决定，以及新的准确表达。</strong><p>提交后会新增一条会话事件。若规划已经委托，当前运行或草稿会停用并回到活简报重新确认。</p></div><textarea data-correction-input="true" aria-label="追加会话更正" placeholder="例如：我更正第一条路径；先完整验证任务成形，而不是每日收尾。">${escapeHTML(ui.correctionText)}</textarea><div class="button-row"><button class="ghost-button" type="button" data-action="toggle-correction">取消</button><button class="primary-button" type="button" data-action="confirm-correction">追加更正</button></div></section>`;
    }
    if (!ui.lastCorrection) return "";
    return `<div class="r3-correction-receipt"><span class="status-pill accent">更正已追加</span><div><strong>${escapeHTML(ui.lastCorrection)}</strong><p>旧事件仍保留；需要重新规划的内容必须从活简报再次确认。</p></div><button class="text-button" type="button" data-panel="events">查看事件</button></div>`;
  }

  function sessionDock(model) {
    if (model.flow === "close" && model.step === "cause") {
      return `<div class="session-dock"><div class="dock-field"><span class="dock-mark">因</span><input class="dock-input" placeholder="补充实际原因，或保留为不确定……" /></div><button class="ghost-button" type="button" data-action="choose-cause" data-value="unknown">保留不确定</button><button class="primary-button" type="button" ${routeAttributes({ step: "review" })}>确认并生成复盘草稿</button></div>`;
    }
    return "";
  }

  function sessionScreen(model) {
    let body = "";
    if (model.flow === "shape") {
      const blockedOldRun = ui.shaping.planInvalidated && ["run", "gate", "amendment", "run-resumed"].includes(model.step) && !ui.shaping.replacementRunAuthorized;
      if (blockedOldRun) body = r3InvalidatedRunScreen();
      else if (model.step === "scope") body = scopeScreen(model);
      else if (model.step === "focus") body = r3FocusScreen(model);
      else if (model.step === "criteria") body = r3CriteriaScreen(model);
      else if (model.step === "brief") body = r3BriefScreen(model);
      else if (model.step === "run") body = r3RunScreen(model);
      else if (model.step === "gate") body = r3GateScreen(model);
      else if (model.step === "amendment") body = r3AmendmentScreen(model);
      else if (model.step === "run-resumed") body = r3RunResumedScreen(model);
      else if (model.step === "draft") body = r3DraftScreen(model);
      else if (model.step === "apply") body = r3ApplyScreen(model);
      else if (model.step === "receipt") body = r3ReceiptScreen(model);
      else return zhulongHome(model);
    } else {
      if (model.step === "facts") body = closeFactsScreen(model);
      else if (model.step === "cause") body = closeCauseScreen(model);
      else if (model.step === "review") body = closeReviewScreen(model);
      else if (model.step === "tomorrow") body = closeTomorrowScreen(model);
      else if (model.step === "receipt") body = closeReceiptScreen(model);
      else body = closeFactsScreen(model);
    }
    return `<div class="native-page session-shell">${sessionHeader(model)}${providerBanner(model)}<div class="native-columns"><div class="session-scroll"><div class="zhulong-content">${sessionCorrectionPanel(model)}${body}${sessionDock(model)}</div></div>${r3NativeDetailRail(model)}</div></div>`;
  }

  function dayReviewRail(model) {
    if (model.panel === "events") return `<aside class="detail-rail">${eventRail(model)}</aside>`;
    if (model.panel === "context") {
      return `<aside class="detail-rail">${railHeader("每日收尾将使用什么", "先核对事实，再请你确认原因", true)}<div class="detail-rail-scroll">${railSection("本地事实", railList(["今日承诺快照 v1", "Day Todo 任务与子任务状态", "日内新增、延续和回池轨迹"]))}${railSection("Provider 参与", `<div class="rail-card"><p>只在原因追问与复盘草稿阶段使用已披露摘要；本地统计不依赖 Provider。</p></div>`)}${railSection("不会发生", railList(["不会自动生成长期记忆", "不会自动写入明日 Todo", "不会覆盖承诺快照"]))}</div></aside>`;
    }
    return `<aside class="detail-rail day-review-rail">${railHeader("每日复盘", "7 月 10 日 · 周五")}<div class="detail-rail-scroll"><button class="rail-primary-entry" type="button" ${routeAttributes({ surface: "zhulong", flow: "close", step: "facts" })}><span>✦</span><strong>让烛龙分析今日</strong><b>→</b></button><div class="day-stat-card"><div class="stat-head"><span>总任务</span><strong>6</strong></div><div class="stat-bar"><i></i><b></b></div><div class="stat-grid"><span><i class="blue-dot"></i>待完成 <b>3</b></span><span><i class="green-dot"></i>已完成 <b>3</b></span><span>部分推进 <b>1</b></span><span>日内新增 <b>2</b></span></div></div>${railSection("今日总结", `<textarea class="review-textarea" placeholder="今天整体推进如何？"></textarea>`)}${railSection("未完成原因", `<textarea class="review-textarea" placeholder="哪些没完成，真实原因是什么？"></textarea>`)}${railSection("明日注意事项", `<textarea class="review-textarea" placeholder="明天开始前想提醒自己什么？"></textarea>`)}<div class="rail-stack"><button class="small-action accent full" type="button" ${routeAttributes({ surface: "zhulong", flow: "close", step: "facts" })}>开始收尾</button><button class="small-action full" type="button" data-notice="Prototype：普通复盘入口保持可用。">直接写复盘</button></div></div></aside>`;
  }

  function dayScreen(model) {
    const confirmed = ui.planVersion > 0;
    const headerActions = `${headerButton("‹", `data-notice="Prototype：查看前一天。"`)}${headerButton("今天", `data-notice="已是今天。"`)}${headerButton("›", `data-notice="Prototype：查看后一天。"`)}${headerButton("选日期", `data-notice="Prototype：打开日期选择器。"`)}`;
    return `<div class="native-page day-page">
      ${pageHeader("2026年7月10日", "周五 · 今天", headerActions)}
      <div class="native-columns"><div class="page-scroll day-main"><div class="date-strip">${[["一","6"],["二","7"],["三","8"],["四","9"],["五","10"],["六","11"],["日","12"],["一","13"],["二","14"],["三","15"],["四","16"],["五","17"],["六","18"],["日","19"]].map(([week, date]) => `<button class="date-chip${date === "10" ? " active" : ""}" type="button"><span>${week}</span><strong>${date}</strong><i></i></button>`).join("")}</div>
        <div class="quick-add"><input placeholder="添加今日任务，回车确认" aria-label="添加今日任务" /><button class="small-action" type="button" data-notice="Prototype：打开任务池排期选择。">从任务池排期…</button></div>
        <div class="commitment-strip${confirmed ? " confirmed" : ""}"><div><strong>${confirmed ? `今日承诺快照 v${ui.planVersion}` : "确认你今天真正准备完成的任务"}</strong><span>${confirmed ? "09:10 手动确认 5 项；日内新增不会覆盖原快照。" : "本地核心能力，不调用 Provider。"}</span></div><button class="small-action${confirmed ? "" : " accent"}" type="button" data-action="confirm-plan">${confirmed ? "重新确认" : "确认今日计划"}</button></div>
        <div class="task-list">
          ${taskRow("", "整理 Q3 OKR 草案", "#复盘 · 第 2 次延续 · 持续 5 天", false, false, "30%")}
          ${taskRow("", "修复图标导出脚本", "#工程 · 第 1 次延续 · 持续 2 天", false, false, "45%")}
          ${taskRow("", "整理 Provider 权限", "#工程 · 2/3 子任务 · 部分推进", false, true, "67%")}
          ${taskRow("", "审阅 onboarding 三屏文案", "#复盘 · 第 2 次延续 · 持续 3 天", false, true, "33%")}
          ${taskRow("✓", "晨跑 5 公里", "#生活 · 承诺内", true)}
          ${taskRow("", "清理下载文件夹", "#生活 · 日内新增", false)}
        </div>
      </div>${dayReviewRail(model)}</div>
    </div>`;
  }

  function taskRow(check, title, meta, done, zhulong = false, progress = "") {
    return `<div class="task-row${done ? " done" : ""}"><button class="task-check${done ? " done" : ""}" type="button">${check}</button><span class="task-copy"><strong>${title}</strong><span>${meta}</span>${progress ? `<span class="task-progress"><i style="width:${progress}"></i><b>${progress}</b></span>` : ""}</span><span class="task-actions">${zhulong ? `<button class="small-action" type="button" ${routeAttributes({ surface: "zhulong", flow: "shape", step: "scope" })}>交给烛龙梳理</button>` : ""}<span class="status-pill ${done ? "green" : "accent"}">${done ? "已完成" : "待完成"}</span><button class="icon-button" type="button" data-notice="任务菜单会包含普通领域操作。">⌄</button></span></div>`;
  }

  function settingsScreen(model) {
    const rail = model.panel === "events" ? `<aside class="detail-rail">${eventRail(model)}</aside>` : "";
    return `<div class="native-page settings-page">${pageHeader("设置", "偏好、数据、同步和烛龙配置的统一入口。", "")}<div class="settings-toolbar">
      ${settingsTab("permissions", "权限上限", model.settings)}${settingsTab("memory", "记忆与画像", model.settings)}${settingsTab("provider", "Provider", model.settings)}${settingsTab("transparency", "透明度与事件", model.settings)}
    </div><div class="native-columns settings-columns"><div class="page-scroll"><div class="settings-content"><div class="settings-card">${settingsContent(model)}</div></div></div>${rail}</div></div>`;
  }

  function settingsTab(key, label, current) {
    return `<button class="settings-tab${key === current ? " active" : ""}" type="button" ${routeAttributes({ surface: "settings", settings: key, step: "home" })}>${label}</button>`;
  }

  function settingsContent(model) {
    if (model.settings === "memory") return memorySettings();
    if (model.settings === "provider") return providerSettings();
    if (model.settings === "transparency") return transparencySettings();
    return permissionSettings();
  }

  function permissionSettings() {
    return `<span class="eyebrow">烛龙 · 权限上限</span><h1>每类能力都有自己的边界。</h1><p>会话授权不能超过这里的上限。Todo 写入在第一阶段始终需要具体 diff 确认。</p><section class="settings-section"><h3>权限列表</h3><p>禁止、每次询问或允许。任何实际使用仍会进入事件历史。</p><div class="permission-list">
      ${permissionRow("tasks", "读取任务轨迹", "用于本地证据、相关任务链与规划上下文")}
      ${permissionRow("memory", "使用已确认记忆", "候选与冲突记忆不会自动参与规划")}
      ${permissionRow("remote", "向当前 Provider 发送", "只发送会话必需摘要与已披露范围")}
      ${permissionRow("todo", "应用 Todo 建议", "第一阶段即使设为允许，也必须确认具体 diff")}
    </div></section><div class="yolo-card"><div><strong>YOLO 便利权限 ${ui.yoloEnabled ? "已启用" : "未启用"}</strong><p>一次放开读取、记忆与远程发送，并让新会话在 Provider 配置身份不变时继承。它不包含无人确认的 Todo 写入，也不会隐藏披露。</p></div><button class="${ui.yoloEnabled ? "ghost-button" : "primary-button"}" type="button" data-action="toggle-yolo">${ui.yoloEnabled ? "关闭 YOLO" : "启用 YOLO"}</button></div>
      <section class="settings-section"><h3>会话仍会显示什么</h3><p>实际任务范围、使用的记忆、Provider 配置身份、范围扩大、每次写入 diff 与所有失败。</p></section>`;
  }

  function permissionRow(key, title, copy) {
    const value = ui.permissions[key];
    return `<div class="permission-row"><span class="permission-copy"><strong>${title}</strong><span>${copy}</span></span><span class="segmented">${["deny", "ask", "allow"].map((item) => `<button class="segmented-button${value === item ? " active" : ""}" type="button" data-action="set-permission" data-key="${key}" data-value="${item}">${item === "deny" ? "禁止" : item === "ask" ? "询问" : "允许"}</button>`).join("")}</span></div>`;
  }

  function memorySettings() {
    const memoryRows = [
      ["m1", "stated", "用户陈述", "偏好滚动式规划，只细化近期可承诺范围。", "用户在 2 场会话中明确确认 · 最近使用：今天"],
      ["m2", "stated", "用户陈述", "拒绝隐藏自动化；所有 AI 假设、权限和写入必须可审查。", "用户明确要求记住 · 最近使用：今天"],
      ["m3", "inferred", "烛龙推断 · 已确认", "偏好先看结构，再看解释。", "证据窗口 4 场会话 · 置信度中 · 1 个反例"],
      ["m4", "inferred", "记忆候选", "大型任务开始前可能更希望先做一轮强追问。", "证据窗口 3 场会话 · 置信度低 · 尚未参与规划"],
    ];
    return `<span class="eyebrow">本机 sidecar · 已开启</span><h1>记忆是可管理的原子事实，不是黑盒画像。</h1><p>已确认记忆可修改、停用或删除；候选必须先审查，冲突默认不参与规划。</p><section class="settings-section"><h3>记忆项</h3><p>精粹画像只从当前有效记忆重新生成，每条结论都能回到来源。</p><div class="memory-list">${memoryRows.filter(([id]) => !ui.hiddenMemories.has(id)).map(memoryRow).join("") || `<div class="empty-note">没有可用记忆。</div>`}</div></section><section class="settings-section"><h3>刷新策略</h3><p>每日收尾、任务成形结束、重要更正或主动请求时批量产生候选；单次任务操作与 YOLO 都不会自动确认推断。</p></section>`;
  }

  function memoryRow([id, origin, label, text, meta]) {
    const candidate = label === "记忆候选";
    return `<div class="memory-row"><span class="memory-origin${origin === "inferred" ? " inferred" : ""}"></span><div class="memory-copy"><strong>${label} · ${text}</strong><p>${meta}</p><div class="memory-meta"><span class="status-pill">${origin === "stated" ? "用户陈述" : "烛龙推断"}</span>${candidate ? `<span class="status-pill amber">未生效</span>` : `<span class="status-pill green">当前有效</span>`}</div></div><div class="memory-actions">${candidate ? `<button class="ghost-button" type="button" data-notice="Prototype：候选会在修改后形成待确认新版本。">修改</button><button class="primary-button" type="button" data-notice="Prototype：候选已确认，后续会话可以使用。">确认</button><button class="ghost-button" type="button" data-action="delete-memory" data-value="${id}">拒绝</button>` : `<button class="ghost-button" type="button" data-notice="Prototype：修改会生成带生效时间的新版本，旧内容不被覆盖。">修改</button><button class="ghost-button" type="button" data-notice="Prototype：停用后不参与规划，历史引用仍可审计。">停用</button><button class="danger-button" type="button" data-action="delete-memory" data-value="${id}">删除</button>`}</div></div>`;
  }

  function providerSettings() {
    return `<span class="eyebrow">Provider 配置身份 #P-04</span><h1>信任绑定到具体配置，不绑定品牌名称。</h1><p>Base URL、模型、本地／远程性质或发送能力实质变化时，会形成新的身份并暂停继承授权。</p><section class="settings-section"><div class="permission-list"><div class="permission-row"><span class="permission-copy"><strong>类型</strong><span>OpenAI Compatible</span></span><span class="status-pill green">已连接</span></div><div class="permission-row"><span class="permission-copy"><strong>Endpoint</strong><span>provider.example/v1 · 远程</span></span><button class="ghost-button" type="button" data-notice="Prototype：编辑后会形成新的 Provider 配置身份。">编辑</button></div><div class="permission-row"><span class="permission-copy"><strong>模型</strong><span>planning-model</span></span><span class="status-pill">身份组成部分</span></div><div class="permission-row"><span class="permission-copy"><strong>概率校准资格</strong><span>当前没有足够后验样本</span></span><span class="status-pill amber">证据不足</span></div></div></section><div class="yolo-card"><div><strong>连接与授权是两件事</strong><p>测试连接只验证 Provider 可用性，不会读取任务、使用记忆或发送会话数据。</p></div><button class="primary-button" type="button" data-provider="online" data-notice="Prototype：连接测试成功，没有发送任务数据。">测试连接</button></div>`;
  }

  function transparencySettings() {
    return `<span class="eyebrow">白盒原则 · 分层披露</span><h1>主界面克制，历史仍然完整可追溯。</h1><p>情境提示回答“现在发生什么”，事件历史回答“刚才发生什么”，Provider 发送记录回答“实际发送了什么”。</p><section class="settings-section"><h3>事件历史</h3><div class="permission-list"><div class="permission-row"><span class="permission-copy"><strong>保留策略</strong><span>本机 append-only 语义；用户不能修改、重排或逐条删除</span></span><span class="status-pill green">开启</span></div><div class="permission-row"><span class="permission-copy"><strong>清理方式</strong><span>只能清理最近连续时间范围，并留下无正文范围标记</span></span><button class="ghost-button" type="button" data-panel="events">打开事件历史</button></div><div class="permission-row"><span class="permission-copy"><strong>Provider 发送记录</strong><span>凭证脱敏的请求与响应正文保存在对应会话</span></span><span class="status-pill">按会话查看</span></div></div></section>`;
  }

  function prototypeSwitcher(model) {
    const variants = {
      A: "单列指令台",
      B: "下一件事",
      C: "决定分栏",
    };
    const keys = Object.keys(variants);
    const index = keys.indexOf(model.variant);
    const previous = keys[(index - 1 + keys.length) % keys.length];
    const next = keys[(index + 1) % keys.length];
    return `<div class="prototype-switcher" role="group" aria-label="首页原型方案切换">
      <button type="button" data-variant="${previous}" aria-label="上一个方案">←</button>
      <span><b>${model.variant}</b><small>${variants[model.variant]}</small></span>
      <button type="button" data-variant="${next}" aria-label="下一个方案">→</button>
    </div>`;
  }

  function render() {
    const model = readModel();
    let content = "";
    if (model.surface === "day") content = dayScreen(model);
    else if (model.surface === "settings") content = settingsScreen(model);
    else content = model.step === "home" ? zhulongHome(model) : sessionScreen(model);
    const switcher = model.surface === "zhulong" && model.step === "home" ? prototypeSwitcher(model) : "";
    app.innerHTML = `<div class="mac-window">${sidebar(model)}<main class="app-main">${content}</main>${switcher}${ui.toast ? `<div class="toast">${ui.toast}</div>` : ""}</div>`;
    if (model.scroll === "bottom") {
      window.requestAnimationFrame(() => {
        const target = model.panel ? document.querySelector(".detail-rail-scroll") : document.querySelector(".session-scroll") || document.querySelector(".page-scroll");
        if (target) target.scrollTop = target.scrollHeight;
      });
    }
  }

  function showToast(message) {
    ui.toast = message;
    if (ui.toastTimer) window.clearTimeout(ui.toastTimer);
    render();
    ui.toastTimer = window.setTimeout(() => {
      ui.toast = "";
      render();
    }, 2600);
  }

  function handleAction(element, action) {
    const value = element.dataset.value;
    if (action === "toggle-scope") ui.excludedScope.has(value) ? ui.excludedScope.delete(value) : ui.excludedScope.add(value);
    else if (action === "set-home-intent") {
      ui.homeIntent = value;
      render();
      window.requestAnimationFrame(() => document.querySelector("[data-home-intent]")?.focus());
      return;
    }
    else if (action === "choose-focus") ui.focusChoice = value;
    else if (action === "choose-r3") {
      const key = `${element.dataset.kind}Choice`;
      if (key in ui.shaping) ui.shaping[key] = value;
    } else if (action === "confirm-r3-field") {
      const kind = element.dataset.kind;
      const input = document.querySelector(`[data-r3-input="${kind}"]`);
      const textValue = input ? input.value.trim() : "";
      const choiceKey = `${kind}Choice`;
      const textKey = `${kind}Text`;
      if (textKey in ui.shaping) ui.shaping[textKey] = textValue;
      const choice = ui.shaping[choiceKey];
      if (!choice && !textValue) {
        showToast("先选择一项或写下你的判断；烛龙不会用空回答继续。");
        return;
      }
      if (kind === "path" && choice === "compare" && !textValue) {
        ui.shaping.comparisonReady = true;
        showToast("已补齐两条路径的产品验证面；用户取舍仍是阻塞缺口。");
        return;
      }
      if (kind === "path") {
        updateRoute({ step: "criteria" });
        showToast(`已生成规划简报 ${shapingVersion("criteria")}；用户取舍及来源已经记录。`);
      } else {
        updateRoute({ step: "brief" });
        showToast(`已生成规划简报 ${shapingVersion("brief")}；阻塞缺口已经清零，仍需审查后才能委托。`);
      }
      return;
    } else if (action === "confirm-r3-gate") {
      const input = document.querySelector('[data-r3-input="gate"]');
      ui.shaping.gateText = input ? input.value.trim() : "";
      if (!ui.shaping.gateChoice && !ui.shaping.gateText) {
        showToast("先选择处置方式或写下限制；证据不足时烛龙不会自行继续。");
        return;
      }
      if (ui.shaping.gateChoice === "range" && !ui.shaping.gateText) {
        showToast("请先写明你确认的工作量区间与可投入时间；烛龙不会补造这个依据。");
        return;
      }
      if (ui.shaping.gateChoice === "unresolved" && !ui.shaping.gateText) {
        showToast("已保留为未决；规划运行继续暂停，也不会生成近期 Todo 草稿。");
        return;
      }
      updateRoute({ step: "amendment" });
      showToast(`已形成简报修订 ${shapingVersion("amended")}；原规划委托失效，等待你重新确认。`);
      return;
    }
    else if (action === "choose-cause") ui.closeReason = value;
    else if (action === "toggle-rationale") ui.rationaleOpen = !ui.rationaleOpen;
    else if (action === "toggle-correction") ui.correctionOpen = !ui.correctionOpen;
    else if (action === "confirm-correction") {
      const input = document.querySelector("[data-correction-input]");
      const correction = input ? input.value.trim() : "";
      if (!correction) {
        showToast("先写明要更正的内容；空更正不会进入历史。");
        return;
      }
      const model = readModel();
      ui.lastCorrection = correction;
      ui.correctionText = "";
      ui.correctionOpen = false;
      const invalidatesPlan = model.flow === "shape" && ["brief", "run", "gate", "amendment", "run-resumed", "draft", "apply"].includes(model.step);
      if (invalidatesPlan) {
        ui.shaping.planInvalidated = true;
        ui.shaping.replacementRunAuthorized = false;
        ui.shaping.correctionRevision = true;
        updateRoute({ step: "focus" });
        showToast("更正已追加；当前委托或草稿已停用，返回活简报重新确认。");
      } else {
        showToast("更正已追加为新事件；旧内容没有被覆盖。");
      }
      return;
    }
    else if (action === "split-batch") ui.splitBatch = !ui.splitBatch;
    else if (action === "restart-r3-planning") ui.shaping.replacementRunAuthorized = true;
    else if (action === "accept-r3-draft") {
      ui.shaping.planInvalidated = false;
      ui.shaping.replacementRunAuthorized = false;
    }
    else if (action === "refresh-draft") {
      ui.shaping.planInvalidated = false;
      ui.shaping.replacementRunAuthorized = false;
      updateRoute({ condition: "normal" });
      showToast("已按当前 Todo 版本生成规划草稿 v5；旧版继续保留供审计。");
      return;
    } else if (action === "confirm-plan") {
      ui.planVersion += 1;
      showToast(`已追加承诺快照 v${ui.planVersion}；旧版本没有被覆盖。`);
      return;
    } else if (action === "save-review") {
      ui.reviewSaved = true;
      showToast("每日复盘已独立保存；没有创建或调整 Todo。");
      return;
    } else if (action === "set-permission") {
      ui.permissions[element.dataset.key] = value;
    } else if (action === "toggle-yolo") {
      ui.yoloEnabled = !ui.yoloEnabled;
      showToast(ui.yoloEnabled ? "YOLO 已启用：读取、记忆与远程发送可以继承；Todo 写入仍需具体 diff。" : "YOLO 已关闭；既有事件历史不受影响。");
      return;
    } else if (action === "delete-memory") {
      ui.hiddenMemories.add(value);
      showToast("记忆已从当前有效集合移除；已应用 Todo 历史不会被改写。");
      return;
    } else if (action === "prepare-clear-events") ui.clearConfirm = value;
    else if (action === "confirm-clear-events") {
      ui.eventsCleared = true;
      ui.clearConfirm = ui.clearConfirm || "1 小时";
    } else if (action === "pause-session") {
      updateRoute({ surface: "zhulong", flow: "shape", step: "home" });
      showToast("会话已暂停并保存在本机；下次从“继续会话”恢复。");
      return;
    }
    render();
  }

  document.addEventListener("click", (event) => {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const backdrop = target.closest("[data-backdrop]");
    if (backdrop && event.target === backdrop) {
      updateRoute({ panel: "" }, { resetPanel: false });
      return;
    }
    const close = target.closest("[data-close-panel]");
    if (close) {
      updateRoute({ panel: "" }, { resetPanel: false });
      return;
    }
    const element = target.closest("button, [data-action], [data-panel]");
    if (!element || element.disabled) return;

    const action = element.dataset.action;
    if (action) handleAction(element, action);

    if (element.dataset.notice) showToast(element.dataset.notice);

    const patch = {};
    for (const key of routeKeys) {
      if (key in element.dataset) patch[key] = element.dataset[key];
    }
    if (Object.keys(patch).length) updateRoute(patch, { resetPanel: !("panel" in patch) });
  });

  document.addEventListener("input", (event) => {
    const target = event.target;
    if (!(target instanceof Element)) return;
    const homeIntent = target.closest("[data-home-intent]");
    if (homeIntent) {
      ui.homeIntent = homeIntent.value;
      return;
    }
    const correction = target.closest("[data-correction-input]");
    if (correction) {
      ui.correctionText = correction.value;
      return;
    }
    const input = target.closest("[data-r3-input]");
    if (!input) return;
    const key = `${input.dataset.r3Input}Text`;
    if (key in ui.shaping) ui.shaping[key] = input.value;
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    const target = event.target;
    if (!(target instanceof Element)) return;
    if (target.closest("input, textarea, [contenteditable='true']")) return;
    const model = readModel();
    if (model.surface !== "zhulong" || model.step !== "home") return;
    const keys = ["A", "B", "C"];
    const offset = event.key === "ArrowLeft" ? -1 : 1;
    const index = (keys.indexOf(model.variant) + offset + keys.length) % keys.length;
    event.preventDefault();
    updateRoute({ variant: keys[index] }, { resetPanel: false, replace: true });
  });

  window.addEventListener("popstate", render);
  render();
})();
