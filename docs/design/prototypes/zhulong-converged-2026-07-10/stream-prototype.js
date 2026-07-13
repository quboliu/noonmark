(() => {
  "use strict";

  // THROWAWAY PROTOTYPE: three visual organisations of one append-only session stream.
  const app = document.querySelector("#app");
  const variants = {
    A: "连续卷宗",
    B: "章节手风琴",
    C: "左右对照流",
  };
  const variantPresentation = {
    A: { short: "卷宗", description: "连续时间脊线" },
    B: { short: "章节", description: "按阶段折叠浏览" },
    C: { short: "双轨", description: "左烛龙 · 右用户", default: true },
  };
  const variantPreferenceKey = "noonmark.zhulong.stream-layout";
  const allowedScenarios = ["focus", "run", "gate", "draft", "receipt", "corrected", "long"];
  const queryAtLaunch = new URLSearchParams(window.location.search);
  const launchScenario = allowedScenarios.includes(queryAtLaunch.get("scenario")) ? queryAtLaunch.get("scenario") : "focus";

  const stageMeta = {
    scope: { label: "范围", phase: "define", phaseLabel: "定义意图与范围" },
    focus: { label: "用户取舍", phase: "define", phaseLabel: "定义意图与范围" },
    criteria: { label: "完成标准", phase: "define", phaseLabel: "定义意图与范围" },
    brief: { label: "活简报", phase: "brief", phaseLabel: "形成规划简报" },
    run: { label: "规划运行", phase: "run", phaseLabel: "单次规划委托" },
    gate: { label: "决策门", phase: "run", phaseLabel: "决策门与规划" },
    amendment: { label: "重新委托", phase: "run", phaseLabel: "决策门与规划" },
    draft: { label: "计划审查", phase: "review", phaseLabel: "审查规划草稿" },
    apply: { label: "Todo 应用", phase: "apply", phaseLabel: "Todo 写入与结果" },
    receipt: { label: "结果回执", phase: "apply", phaseLabel: "Todo 写入与结果" },
    correction: { label: "追加更正", phase: "correction", phaseLabel: "更正与重新确认" },
  };

  const state = {
    sessionId: "ZL-204",
    entries: [],
    nextSequence: 0,
    branch: 1,
    longFixture: launchScenario === "long",
    motionDemo: launchScenario === "long" && queryAtLaunch.get("demo") === "motion",
    nextRunNumber: 0,
  };

  const runRuntime = {
    epoch: 0,
    timer: 0,
    runId: "",
    status: "idle",
    queue: [],
    nextOrdinal: 0,
    lastEntryId: "",
    authorityId: "",
    contractId: "",
    mode: "",
    branch: 0,
    interval: 520,
  };

  const view = {
    panel: queryAtLaunch.get("panel") || "",
    followTail: queryAtLaunch.get("scroll") !== "top",
    userOwnsScroll: queryAtLaunch.get("scroll") === "top",
    cursorEntryId: null,
    locatedEntryId: null,
    correctionTargetId: null,
    correctionText: "",
    expandedEntries: new Set(),
    expandedSegments: new Set(),
    selected: { focus: "", criteria: "", gate: "" },
    responseText: { focus: "", criteria: "", gate: "" },
    inputSelections: {},
    unseenLiveEntries: 0,
    returningToTail: false,
    layoutMenuOpen: queryAtLaunch.get("fixture") === "layout-menu",
    passiveContextEntryId: "",
    passiveRailFrame: null,
    pendingFocusSelector: "",
    pendingLayoutAnchor: null,
    restoringViewport: false,
    renderedVariant: "",
    shellMounted: false,
    pendingScrollMotion: null,
    renderGeneration: 0,
    toast: "",
    toastTimer: null,
  };

  function escapeHTML(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function currentQuery() {
    const query = new URLSearchParams(window.location.search);
    let rememberedVariant = "";
    try {
      rememberedVariant = window.localStorage.getItem(variantPreferenceKey) || "";
    } catch (_error) {
      rememberedVariant = "";
    }
    const preferredVariant = Object.hasOwn(variants, rememberedVariant) ? rememberedVariant : "C";
    const variant = Object.hasOwn(variants, query.get("variant")) ? query.get("variant") : preferredVariant;
    return {
      variant,
      panel: query.get("panel") ?? "",
      entry: query.get("entry") || "",
      scenario: allowedScenarios.includes(query.get("scenario")) ? query.get("scenario") : launchScenario,
      scroll: query.get("scroll") || "",
    };
  }

  function replaceQuery(patch) {
    const query = new URLSearchParams(window.location.search);
    Object.entries(patch).forEach(([key, value]) => {
      if (value === "" || value === null || value === undefined) query.delete(key);
      else query.set(key, String(value));
    });
    window.history.replaceState({}, "", `${window.location.pathname}?${query.toString()}`);
  }

  function deterministicTime(sequence) {
    const minute = 2 + sequence;
    return `21:${String(minute).padStart(2, "0")}`;
  }

  function deepFreeze(value) {
    if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
    Object.values(value).forEach(deepFreeze);
    return Object.freeze(value);
  }

  function immutableDetails(details) {
    const copy = Object.fromEntries(
      Object.entries(details).map(([key, value]) => [key, Array.isArray(value) ? [...value] : value]),
    );
    return deepFreeze(copy);
  }

  function appendEntry({ actor, kind, stage, title, summary, points = [], dependsOn = [], details = {} }) {
    state.nextSequence += 1;
    const entry = Object.freeze({
      id: `entry-${String(state.nextSequence).padStart(3, "0")}`,
      sequence: state.nextSequence,
      createdAt: deterministicTime(state.nextSequence),
      actor,
      kind,
      stage,
      title,
      summary,
      points: Object.freeze([...points]),
      dependsOn: Object.freeze([...dependsOn]),
      details: immutableDetails(details),
      branch: state.branch,
    });
    state.entries.push(entry);
    return entry;
  }

  function projectRunGroups(entries, allEntries) {
    const groups = new Map();
    entries.forEach((entry) => {
      const group = groups.get(entry.details.runId) || [];
      group.push(entry);
      groups.set(entry.details.runId, group);
    });
    const allowedTransitions = {
      authorized: new Set(["started", "paused", "cancelling", "failed"]),
      started: new Set(["running", "finishing", "paused", "cancelling", "failed"]),
      running: new Set(["running", "finishing", "paused", "cancelling", "failed"]),
      finishing: new Set(["finishing", "completed", "paused", "cancelling", "cancelled", "failed"]),
      paused: new Set(["resumed", "cancelling", "failed"]),
      resumed: new Set(["started", "running", "finishing", "completed", "paused", "cancelling", "failed"]),
      cancelling: new Set(["cancelling", "cancelled", "failed"]),
    };
    const terminalStatuses = new Set(["completed", "cancelled", "failed"]);
    return [...groups.entries()].map(([runId, unordered]) => {
      const runEntries = unordered.slice().sort((left, right) => left.sequence - right.sequence);
      const first = runEntries[0];
      const contract = allEntries.find((entry) => entry.id === first.details.contractId);
      const authority = allEntries.find((entry) => entry.sequence <= first.sequence
        && entry.branch === first.branch
        && entry.details.authorityId === first.details.authorityId
        && entry.details.resolutionType === "planning-authorization");
      const validAuthorization = first.kind === "resolution"
        && first.details.ordinal === 0
        && first.details.runStatus === "authorized"
        && Boolean(first.details.runMode)
        && Boolean(authority)
        && contract?.branch === first.branch
        && contract?.sequence < first.sequence
        && contract?.details.activityType === "run-contract"
        && first.dependsOn.length === 1
        && first.details.resolves === first.dependsOn[0];
      let valid = validAuthorization;
      let reason = valid ? "" : "run authorization, authority or contract binding is invalid";
      runEntries.forEach((entry, index) => {
        if (!valid) return;
        const previous = runEntries[index - 1];
        const sameIdentity = entry.branch === first.branch
          && entry.details.authorityId === first.details.authorityId
          && entry.details.contractId === first.details.contractId
          && entry.details.runMode === first.details.runMode;
        const ordinalValid = entry.details.ordinal === index;
        const predecessorValid = index === 0 || (entry.dependsOn.length === 1 && entry.dependsOn[0] === previous.id);
        const transitionValid = index === 0 || Boolean(allowedTransitions[previous.details.runStatus]?.has(entry.details.runStatus));
        const terminalPlacementValid = index === runEntries.length - 1 || !terminalStatuses.has(entry.details.runStatus);
        if (!sameIdentity || !ordinalValid || !predecessorValid || !transitionValid || !terminalPlacementValid) {
          valid = false;
          reason = `invalid run chain at ordinal ${entry.details.ordinal}`;
        }
      });
      return { runId, entries: runEntries, lastEntry: runEntries.at(-1), valid, reason };
    });
  }

  function projectSession() {
    const resolved = new Set();
    const invalidatedBy = new Map();
    const correctedBy = new Map();

    state.entries.forEach((entry) => {
      if (entry.kind === "resolution" && entry.details.resolves) resolved.add(entry.details.resolves);
      if (entry.kind === "correction" && entry.details.corrects) correctedBy.set(entry.details.corrects, entry.id);
      if (entry.kind === "invalidation") {
        (entry.details.invalidates || []).forEach((entryId) => invalidatedBy.set(entryId, entry.id));
      }
    });
    const closedRunIds = new Set(
      state.entries
        .filter((entry) => entry.branch === state.branch && entry.details.closesRunId)
        .map((entry) => entry.details.closesRunId),
    );

    const consumedAncestorIds = new Set();
    const ancestorStack = state.entries
      .filter((entry) => entry.details.artifactType === "receipt")
      .flatMap((entry) => entry.dependsOn);
    while (ancestorStack.length) {
      const entryId = ancestorStack.pop();
      if (consumedAncestorIds.has(entryId)) continue;
      consumedAncestorIds.add(entryId);
      const entry = state.entries.find((candidate) => candidate.id === entryId);
      if (entry) ancestorStack.push(...entry.dependsOn);
    }

    const activeCheckpoint = [...state.entries]
      .reverse()
      .find((entry) => entry.branch === state.branch && entry.kind === "checkpoint" && !resolved.has(entry.id) && !invalidatedBy.has(entry.id));
    const runEntries = state.entries.filter((entry) => entry.branch === state.branch && entry.details.runId && !invalidatedBy.has(entry.id));
    const runGroups = projectRunGroups(runEntries, state.entries);
    const latestRunGroup = runGroups.slice().sort((left, right) => left.lastEntry.sequence - right.lastEntry.sequence).at(-1) || null;
    const latestRunEntry = latestRunGroup?.valid ? latestRunGroup.lastEntry : null;
    const latestIntegrityIncident = [...state.entries]
      .reverse()
      .find((entry) => entry.branch === state.branch && entry.details.integrityReason);
    const incidentIsCurrent = latestIntegrityIncident
      && latestIntegrityIncident.sequence > (latestRunGroup?.lastEntry.sequence || 0);
    const runIntegrityError = latestRunGroup && !latestRunGroup.valid
      ? latestRunGroup.reason
      : incidentIsCurrent ? latestIntegrityIncident.details.integrityReason : "";
    const activeRunStatuses = new Set(["authorized", "started", "running", "finishing", "paused", "resumed", "cancelling"]);
    const activeRun = latestRunEntry
      && !closedRunIds.has(latestRunEntry.details.runId)
      && activeRunStatuses.has(latestRunEntry.details.runStatus)
      ? {
        runId: latestRunEntry.details.runId,
        status: latestRunEntry.details.runStatus,
        lastEntry: latestRunEntry,
        ordinal: latestRunEntry.details.ordinal,
        authorityId: latestRunEntry.details.authorityId,
        contractId: latestRunEntry.details.contractId,
      }
      : null;
    const canonicalHead = [activeCheckpoint, latestRunEntry]
      .filter(Boolean)
      .sort((left, right) => left.sequence - right.sequence)
      .at(-1) || null;
    const validPlan = [...state.entries]
      .reverse()
      .find((entry) => entry.details.artifactType === "plan" && !invalidatedBy.has(entry.id) && !consumedAncestorIds.has(entry.id));
    const hasInvalidatedPlan = state.entries.some((entry) => entry.details.artifactType === "plan" && invalidatedBy.has(entry.id));
    const hasConsumedPlan = state.entries.some((entry) => entry.details.artifactType === "plan" && consumedAncestorIds.has(entry.id));
    const consumedDiffHashes = new Set(
      state.entries
        .filter((entry) => entry.details.artifactType === "receipt" && entry.details.diffHash)
        .map((entry) => entry.details.diffHash),
    );
    const activeDiff = activeCheckpoint?.stage === "apply"
      ? activeCheckpoint.dependsOn
        .map((entryId) => state.entries.find((entry) => entry.id === entryId))
        .find((entry) => entry?.details.artifactType === "todo-diff" && !invalidatedBy.has(entry.id))
      : null;

    return {
      resolved,
      invalidatedBy,
      correctedBy,
      activeCheckpoint,
      activeRun,
      latestRunEntry,
      runGroups,
      runIntegrityError,
      canonicalHead,
      validPlan,
      activeDiff,
      consumedDiffHashes,
      planState: validPlan ? "valid" : hasInvalidatedPlan ? "invalidated" : hasConsumedPlan ? "consumed" : "none",
      canApply: activeCheckpoint?.stage === "apply"
        && Boolean(validPlan)
        && Boolean(activeDiff?.details.hash)
        && !consumedDiffHashes.has(activeDiff.details.hash),
    };
  }

  function entryState(entry, projection) {
    if (projection.invalidatedBy.has(entry.id)) return "invalidated";
    if (projection.canonicalHead?.id === entry.id) return "current";
    return "complete";
  }

  function activeCheckpoint(expectedStage) {
    const active = projectSession().activeCheckpoint;
    if (!active || (expectedStage && active.stage !== expectedStage)) return null;
    return active;
  }

  function findAncestorEntry(startEntry, predicate) {
    const pending = [...(startEntry?.dependsOn || [])];
    const visited = new Set();
    while (pending.length) {
      const entryId = pending.pop();
      if (visited.has(entryId)) continue;
      visited.add(entryId);
      const entry = state.entries.find((candidate) => candidate.id === entryId);
      if (!entry) continue;
      if (predicate(entry)) return entry;
      pending.push(...entry.dependsOn);
    }
    return null;
  }

  function choiceLabel(kind, value, text = "") {
    if (text) return text;
    const labels = {
      focus: {
        daily: "先完整交付每日收尾",
        shape: "先完整交付任务成形",
        compare: "先补齐两条路径的比较，再决定",
      },
      criteria: {
        usable: "真实 App 端到端每天可用",
        traceable: "所有关键决定都能追溯",
        both: "端到端可用，并且全部可追溯",
      },
      gate: {
        investigate: "先形成调查任务，取得真实测量后再排日期",
        range: "只使用用户明确给出的工作量区间",
        unresolved: "保留未决，停止生成近期 Todo 草稿",
      },
    };
    return labels[kind]?.[value] || "用户补充了自然语言决定";
  }

  function currentBaseTodoRevision() {
    return [...state.entries]
      .reverse()
      .find((entry) => entry.details.artifactType === "receipt" && entry.details.resultBaseRevision)
      ?.details.resultBaseRevision || "T-221";
  }

  function seedBaseSession() {
    const opened = appendEntry({
      actor: "system",
      kind: "activity",
      stage: "scope",
      title: "有界会话已经建立",
      summary: "会话 #ZL-204 · 一个主要意图 · 本机保存",
      points: ["规划自治尚未授权", "Todo 写入尚未授权"],
    });
    const intent = appendEntry({
      actor: "user",
      kind: "message",
      stage: "scope",
      title: "完整重做烛龙 Agent",
      summary: state.longFixture
        ? "我希望它能够接住一个完全模糊、跨度很大的任务：先通过持续追问帮助我澄清真正想解决的问题，再公开说明使用了哪些事实、假设和世界知识，给出多个可比较方案，并在得到明确授权后继续规划；任何自主决定、范围变化、长期记忆、Todo 写入和承诺判断都必须让我知情，证据不足时必须停下，而不是为了显得聪明就补造日期、工作量或成功概率。"
        : "希望它能处理模糊的大任务，又必须白盒、有界，并且最终服务于 Todo。",
      dependsOn: [opened.id],
    });
    const scope = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "scope",
      title: "会话范围回执 #SG-12",
      summary: "6 项相关任务、2 条任务链、3 条已确认记忆、Provider 配置身份 #P-04。",
      points: ["只读取当前意图所需摘要", "范围扩大必须重新确认", "没有 Todo 写入能力"],
      dependsOn: [intent.id],
      details: { artifactType: "scope" },
    });
    appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "scope",
      title: "确认仅在本次会话使用",
      summary: "范围已确认；不会成为跨会话的默认授权。",
      dependsOn: [scope.id],
      details: { resolutionType: "scope" },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "focus",
      title: "第一条完整路径先做哪一条？",
      summary: "两个闭环都重要，但近期必须先形成一条能真实验收的路径。",
      points: ["烛龙建议不是事实", "用户拥有最终取舍权", "没有回答就不会继续"],
      dependsOn: [scope.id],
      details: { checkpointType: "decision" },
    });
  }

  function resolveFocus(value, text = "") {
    const checkpoint = activeCheckpoint("focus");
    if (!checkpoint) return false;
    const decision = choiceLabel("focus", value, text);
    const resolution = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "focus",
      title: decision,
      summary: "这项决定只改变第一条近期验证路径，不授权规划或写入。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "decision", value },
    });
    const version = state.branch === 1 ? "v0.5" : `v0.${7 + state.branch}`;
    const brief = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "brief",
      title: `活简报 ${version} 已更新`,
      summary: `“用户取舍”已经写入：${decision}。原提议继续保留在记录中。`,
      points: ["目标没有改变", "范围没有扩大", "仍缺最低完成标准"],
      dependsOn: [resolution.id],
      details: { artifactType: "brief", version },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "criteria",
      title: "第一条路径怎样才算真正可用？",
      summary: "完成标准必须能由真实 App 路径验收，不能以“代码能跑”代替。",
      points: ["回答会约束阶段地图", "回答会约束 E2E", "烛龙不能自行降低标准"],
      dependsOn: [brief.id],
      details: { checkpointType: "decision" },
    });
    return true;
  }

  function resolveCriteria(value, text = "") {
    const checkpoint = activeCheckpoint("criteria");
    if (!checkpoint) return false;
    const decision = choiceLabel("criteria", value, text);
    const resolution = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "criteria",
      title: decision,
      summary: "最低完成标准由用户确认；烛龙不能在规划中静默降低。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "decision", value },
    });
    const version = state.branch === 1 ? "v0.6" : `v0.${8 + state.branch}`;
    const brief = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "brief",
      title: `规划简报 ${version} 已经成立`,
      summary: "目标、用户取舍、完成标准、硬约束、自治上限和数据范围已可共同审查。",
      points: ["允许：拆解、排序、依赖与风险检查", "停机：目标变化、范围扩大或证据不足", "不包含：Todo 写入、承诺快照、长期记忆"],
      dependsOn: [resolution.id],
      details: { artifactType: "brief", version },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "brief",
      title: "是否按这份简报建立一次性规划委托？",
      summary: "这次授权只允许形成可审查的 AI 规划草稿。",
      points: ["绑定当前简报版本", "绑定范围 #SG-12", "不包含 Todo 写入"],
      dependsOn: [brief.id],
      details: { checkpointType: "authorization" },
    });
    return true;
  }

  function delegatePlanning() {
    const checkpoint = activeCheckpoint("brief");
    if (!checkpoint) return false;
    const authorization = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "brief",
      title: "确认简报并委托一次规划",
      summary: "允许拆解、排序、依赖与风险检查；不允许改变目标或写入 Todo。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "planning-authorization", authorityId: `PA-${state.branch}` },
    });
    const contract = appendEntry({
      actor: "system",
      kind: "activity",
      stage: "run",
      title: "运行契约已经锁定",
      summary: "简报版本、范围授权和 Provider 配置身份已经冻结到本轮运行。",
      points: ["遇到证据不足立即停下", "范围变化立即重授权", "产物只能是草稿"],
      dependsOn: [authorization.id],
      details: { activityType: "run-contract" },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "run",
      title: "运行到下一个必须由你决定的位置",
      summary: "烛龙将只推进已授权的自主步骤，并把真实产物追加在这里。",
      points: ["不会静默跨过决策门", "不会生成 Todo", "不会伪造精度"],
      dependsOn: [contract.id],
      details: { checkpointType: "run" },
    });
    return true;
  }

  function runToGate() {
    const checkpoint = activeCheckpoint("run");
    if (!checkpoint) return false;
    const start = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "run",
      title: "运行到下一决策门",
      summary: "没有新增权限；只消费本次规划委托。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "run" },
    });
    const dependency = appendEntry({
      actor: "zhulong",
      kind: "activity",
      stage: "run",
      title: "依赖地图已经形成",
      summary: "会话、事件、权限和 Todo diff 是两个闭环的共享基础。",
      points: ["阶段 0：工程切入点与测量", "阶段 1：任务成形 vertical slice", "阶段 2：每日收尾复用"],
      dependsOn: [start.id],
      details: { activityType: "planning-step" },
    });
    const feasibility = appendEntry({
      actor: "zhulong",
      kind: "activity",
      stage: "gate",
      title: "可行性审查命中停机条件",
      summary: "没有真实工程工作量测量，也没有同度量的可比实现历史。",
      points: ["不能生成具体日期", "不能生成点数", "不能生成正式兑现概率"],
      dependsOn: [dependency.id],
      details: { activityType: "stop-condition" },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "gate",
      title: "证据不足时，这次规划应该怎样继续？",
      summary: "运行已经暂停。烛龙不会替你决定是否先形成调查任务。",
      points: ["规划委托仍不包含这项取舍", "你的回答会形成简报修订", "旧委托随后失效"],
      dependsOn: [feasibility.id],
      details: { checkpointType: "decision" },
    });
    return true;
  }

  // PROTOTYPE EVENT SOURCE ONLY: these scripted descriptors test painted append rhythm and controls.
  // A real producer must persist its command/cursor and emit each descriptor from completed work, never a fixed timer.
  function liveRunQueue(mode) {
    if (mode === "gate") {
      return [
        {
          actor: "system",
          kind: "activity",
          stage: "run",
          title: "规划运行已经开始",
          summary: "运行身份、授权与契约引用已经核对；本轮不会取得新的能力。",
          points: ["只消费当前规划委托", "用户仍可暂停", "滚动查看不会影响运行"],
          details: { activityType: "run-started", runStatus: "started" },
        },
        {
          actor: "zhulong",
          kind: "activity",
          stage: "run",
          title: "依赖地图已经形成",
          summary: "会话、事件、权限和 Todo diff 是两个闭环的共享基础。",
          points: ["阶段 0：工程切入点与测量", "阶段 1：任务成形 vertical slice", "阶段 2：每日收尾复用"],
          details: { activityType: "planning-step", runStatus: "running" },
        },
        {
          actor: "zhulong",
          kind: "activity",
          stage: "gate",
          title: "可行性审查命中停机条件",
          summary: "没有真实工程工作量测量，也没有同度量的可比实现历史。",
          points: ["不能生成具体日期", "不能生成点数", "不能生成正式兑现概率"],
          details: { activityType: "stop-condition", runStatus: "finishing" },
        },
        {
          actor: "zhulong",
          kind: "checkpoint",
          stage: "gate",
          title: "证据不足时，这次规划应该怎样继续？",
          summary: "运行已经在停机条件安全结束。烛龙不会替你决定是否先形成调查任务。",
          points: ["规划委托仍不包含这项取舍", "你的回答会形成简报修订", "旧委托随后失效"],
          details: { checkpointType: "decision", runStatus: "completed" },
        },
      ];
    }

    return [
      {
        actor: "system",
        kind: "activity",
        stage: "run",
        title: "修订后的运行契约已经锁定",
        summary: "新授权只绑定修订后的活简报；旧委托继续保留供审计。",
        points: ["旧授权不可复用", "产物仍然只是草稿", "Todo 写入未授权"],
        details: { activityType: "run-started", runStatus: "started" },
      },
      {
        actor: "zhulong",
        kind: "activity",
        stage: "run",
        title: "阶段地图与滚动触发条件已经形成",
        summary: "远期不确定内容保留为触发条件；近期只留下可以验证的 vertical slice。",
        points: ["先取得真实工程测量", "再交付任务成形", "最后复用基础完成每日收尾"],
        details: { activityType: "planning-step", runStatus: "running" },
      },
      {
        actor: "zhulong",
        kind: "activity",
        stage: "run",
        title: "剩余规划步骤已经完成",
        summary: "阶段地图、依赖、滚动触发条件与近期 slice 已经编译成草稿。",
        points: ["远期范围不排具体日期", "近期只派生可验证任务", "没有写入 Todo"],
        details: { activityType: "planning-complete", runStatus: "finishing" },
      },
      {
        actor: "zhulong",
        kind: "artifact",
        stage: "draft",
        title: `AI 规划草稿 v${state.branch}`,
        summary: "先取得真实工程测量，再交付任务成形 vertical slice，最后复用基础完成每日收尾。",
        points: ["阶段 0：调查工程切入点与测量", "阶段 1：任务成形 vertical slice", "阶段 2：每日收尾复用", "不生成日期、点数或正式概率"],
        details: { artifactType: "plan", version: `v${state.branch}`, runStatus: "finishing" },
      },
      {
        actor: "zhulong",
        kind: "checkpoint",
        stage: "draft",
        title: "先审查完整计划，再决定是否查看 Todo diff",
        summary: "计划与执行分离；当前没有 Todo 写入授权。",
        points: ["可回到任一旧检查点", "可追加更正", "只有成熟近期 slice 可以派生 Todo"],
        details: { checkpointType: "review", runStatus: "completed" },
      },
    ];
  }

  function clearLiveRunTimer(invalidateCallback = false) {
    if (runRuntime.timer) window.clearTimeout(runRuntime.timer);
    runRuntime.timer = 0;
    if (invalidateCallback) runRuntime.epoch += 1;
  }

  function liveRunRuntimeIsCurrent(epoch) {
    if (epoch !== runRuntime.epoch || !runRuntime.runId || runRuntime.branch !== state.branch) return false;
    const latest = projectSession().latestRunEntry;
    return Boolean(latest
      && latest.id === runRuntime.lastEntryId
      && latest.details.runId === runRuntime.runId
      && latest.details.authorityId === runRuntime.authorityId
      && latest.details.contractId === runRuntime.contractId
      && latest.details.ordinal === runRuntime.nextOrdinal - 1);
  }

  function renderLiveRunCommit(origin, wasFollowing) {
    if (wasFollowing) {
      view.unseenLiveEntries = 0;
      queueScrollMotion({
        kind: "follow-live-run",
        targetRole: "tail",
        sourceId: origin.entryId,
        direction: "forward",
      }, origin);
    } else if (view.returningToTail) {
      view.unseenLiveEntries += 1;
      queueScrollMotion({
        kind: "retarget-live-return",
        targetRole: "tail",
        sourceId: origin.entryId,
        direction: "forward",
      }, origin);
    } else {
      view.unseenLiveEntries += 1;
      const interruptedNavigation = streamMotion.active?.motion || streamMotion.preparingMotion;
      if (interruptedNavigation?.targetRole === "entry" && interruptedNavigation.targetId === view.cursorEntryId) {
        queueScrollMotion({
          kind: interruptedNavigation.kind,
          targetRole: "entry",
          targetId: interruptedNavigation.targetId,
          sourceId: origin.entryId,
          direction: interruptedNavigation.direction,
        }, origin);
      }
    }
    render();
  }

  function appendNextLiveRunEntry(descriptor) {
    const ordinal = runRuntime.nextOrdinal;
    const entry = appendEntry({
      ...descriptor,
      dependsOn: [runRuntime.lastEntryId],
      details: {
        ...descriptor.details,
        runId: runRuntime.runId,
        ordinal,
        authorityId: runRuntime.authorityId,
        contractId: runRuntime.contractId,
        runMode: runRuntime.mode,
      },
    });
    runRuntime.nextOrdinal += 1;
    runRuntime.lastEntryId = entry.id;
    runRuntime.status = descriptor.details.runStatus;
    return entry;
  }

  function failClosedLiveRun(reason) {
    if (!runRuntime.runId || ["completed", "cancelled", "failed"].includes(runRuntime.status)) return;
    const origin = captureViewportAnchor();
    const wasFollowing = view.followTail && !view.userOwnsScroll && !view.cursorEntryId;
    clearLiveRunTimer(true);
    let recoveryDependencyId = runRuntime.lastEntryId;
    const projectedRunHead = projectSession().latestRunEntry;
    const canCloseProjectedRun = projectedRunHead
      && projectedRunHead.details.runId === runRuntime.runId
      && projectedRunHead.details.authorityId === runRuntime.authorityId
      && projectedRunHead.details.contractId === runRuntime.contractId
      && !["completed", "cancelled", "failed"].includes(projectedRunHead.details.runStatus);
    if (canCloseProjectedRun) {
      runRuntime.lastEntryId = projectedRunHead.id;
      runRuntime.nextOrdinal = projectedRunHead.details.ordinal + 1;
      runRuntime.status = projectedRunHead.details.runStatus;
      const failure = appendNextLiveRunEntry({
        actor: "system",
        kind: "activity",
        stage: "run",
        title: "运行完整性检查失败",
        summary: reason,
        points: ["后续步骤已经停止", "失败事实已经进入运行链", "恢复前不会猜测继续"],
        details: { activityType: "run-failed", runStatus: "failed" },
      });
      recoveryDependencyId = failure.id;
    }
    const recoveryStage = runRuntime.mode === "gate" ? "run" : "amendment";
    appendEntry({
      actor: "system",
      kind: "checkpoint",
      stage: recoveryStage,
      title: "规划运行已中断，需要重新确认",
      summary: reason,
      points: ["没有继续执行排队步骤", "旧运行身份已经关闭", "重新开始会建立新的明确授权"],
      dependsOn: recoveryDependencyId ? [recoveryDependencyId] : [],
      details: {
        checkpointType: "recovery",
        failedRunId: runRuntime.runId,
        closesRunId: runRuntime.runId,
        integrityReason: reason,
      },
    });
    runRuntime.status = "failed";
    runRuntime.queue = [];
    renderLiveRunCommit(origin, wasFollowing);
  }

  function commitNextLiveRunStep(epoch) {
    runRuntime.timer = 0;
    if (epoch !== runRuntime.epoch) return;
    if (runRuntime.status === "paused") return;
    if (!liveRunRuntimeIsCurrent(epoch)) {
      failClosedLiveRun("运行日志未通过身份、授权、契约或顺序校验；烛龙已停止而不是猜测继续。");
      return;
    }
    const descriptor = runRuntime.queue.shift();
    if (!descriptor) {
      failClosedLiveRun("运行没有可验证的下一步骤；烛龙已停止而不是生成缺失结果。");
      return;
    }
    const origin = captureViewportAnchor();
    const wasFollowing = view.followTail && !view.userOwnsScroll && !view.cursorEntryId;
    try {
      appendNextLiveRunEntry(descriptor);
    } catch (error) {
      failClosedLiveRun(`追加运行记录失败：${error instanceof Error ? error.message : "未知错误"}`);
      return;
    }
    if (["completed", "cancelled", "failed"].includes(runRuntime.status)) {
      clearLiveRunTimer();
    } else scheduleNextLiveRunStep();
    renderLiveRunCommit(origin, wasFollowing);
  }

  function scheduleNextLiveRunStep(delay = runRuntime.interval) {
    clearLiveRunTimer();
    const epoch = runRuntime.epoch;
    runRuntime.timer = window.setTimeout(() => commitNextLiveRunStep(epoch), delay);
  }

  function beginLiveRun(mode) {
    const expectedStage = mode === "gate" ? "run" : "amendment";
    const checkpoint = activeCheckpoint(expectedStage);
    const activeStatuses = new Set(["authorized", "started", "running", "finishing", "paused", "resumed", "cancelling"]);
    const projection = projectSession();
    if (!checkpoint || activeStatuses.has(runRuntime.status) || projection.activeRun) return false;

    const isValidAncestor = (entry) => entry.branch === state.branch && !projection.invalidatedBy.has(entry.id);
    const priorAuthority = findAncestorEntry(checkpoint, (entry) => isValidAncestor(entry)
      && entry.details.resolutionType === "planning-authorization"
      && Boolean(entry.details.authorityId));
    const priorContract = findAncestorEntry(checkpoint, (entry) => isValidAncestor(entry)
      && entry.details.activityType === "run-contract");
    if (!priorContract || (mode === "gate" && !priorAuthority)) return false;

    clearLiveRunTimer(true);
    state.nextRunNumber += 1;
    const runId = `RUN-${state.branch}-${String(state.nextRunNumber).padStart(2, "0")}`;
    const authorityId = mode === "gate" ? priorAuthority.details.authorityId : `PA-${state.branch + 1}-${state.nextRunNumber}`;
    const contractId = priorContract.id;
    const authorization = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: expectedStage,
      title: mode === "gate" ? "运行到下一决策门" : "确认修订并重新委托剩余规划",
      summary: mode === "gate"
        ? "没有新增权限；只消费本次规划委托。"
        : "新委托只绑定修订后的活简报；旧委托继续保留供审计。",
      dependsOn: [checkpoint.id],
      details: {
        resolves: checkpoint.id,
        resolutionType: mode === "gate" ? "run" : "planning-authorization",
        runId,
        runStatus: "authorized",
        ordinal: 0,
        authorityId,
        contractId,
        runMode: mode,
      },
    });

    runRuntime.runId = runId;
    runRuntime.status = "authorized";
    runRuntime.mode = mode;
    runRuntime.queue = liveRunQueue(mode);
    runRuntime.nextOrdinal = 1;
    runRuntime.lastEntryId = authorization.id;
    runRuntime.authorityId = authorityId;
    runRuntime.contractId = contractId;
    runRuntime.branch = state.branch;
    scheduleNextLiveRunStep();
    return true;
  }

  function pauseLiveRun() {
    const projection = projectSession();
    if (!projection.activeRun || projection.activeRun.status === "paused") return false;
    if (!liveRunRuntimeIsCurrent(runRuntime.epoch)) return false;
    const origin = captureViewportAnchor();
    const wasFollowing = view.followTail && !view.userOwnsScroll && !view.cursorEntryId;
    clearLiveRunTimer(true);
    const paused = appendNextLiveRunEntry({
      actor: "user",
      kind: "resolution",
      stage: "run",
      title: "暂停当前规划运行",
      summary: "已经形成的记录保持不变；继续运行前不会追加新的规划步骤。",
      points: ["授权边界没有扩大", "排队步骤尚未执行", "查看历史不会恢复运行"],
      details: { resolutionType: "run-pause", runStatus: "paused" },
    });
    runRuntime.lastEntryId = paused.id;
    renderLiveRunCommit(origin, wasFollowing);
    return true;
  }

  function resumeLiveRun() {
    const projection = projectSession();
    if (projection.activeRun?.status !== "paused") return false;
    if (!liveRunRuntimeIsCurrent(runRuntime.epoch)) return false;
    const origin = captureViewportAnchor();
    const wasFollowing = view.followTail && !view.userOwnsScroll && !view.cursorEntryId;
    clearLiveRunTimer(true);
    const resumed = appendNextLiveRunEntry({
      actor: "user",
      kind: "resolution",
      stage: "run",
      title: "继续当前规划运行",
      summary: "继续同一运行身份和剩余队列；没有重新授权，也没有扩大范围。",
      points: ["沿用原授权与契约", "从下一未执行步骤继续", "仍会在决策门停下"],
      details: { resolutionType: "run-resume", runStatus: "resumed" },
    });
    runRuntime.lastEntryId = resumed.id;
    renderLiveRunCommit(origin, wasFollowing);
    scheduleNextLiveRunStep();
    return true;
  }

  function cancelLiveRun() {
    const projection = projectSession();
    if (!projection.activeRun || projection.activeRun.status === "cancelling") return false;
    if (!liveRunRuntimeIsCurrent(runRuntime.epoch)) return false;
    const origin = captureViewportAnchor();
    const wasFollowing = view.followTail && !view.userOwnsScroll && !view.cursorEntryId;
    clearLiveRunTimer(true);
    const cancellation = appendNextLiveRunEntry({
      actor: "user",
      kind: "resolution",
      stage: "run",
      title: "终止本次规划运行",
      summary: "终止只影响尚未执行的步骤；已经形成的记录继续保留并可审计。",
      points: ["不回滚已形成记录", "不执行剩余队列", "不保留隐含继续能力"],
      details: { resolutionType: "run-cancel", runStatus: "cancelling" },
    });
    const recoveryStage = runRuntime.mode === "gate" ? "run" : "amendment";
    runRuntime.lastEntryId = cancellation.id;
    runRuntime.queue = [
      {
        actor: "system",
        kind: "activity",
        stage: "run",
        title: "本轮运行已经安全终止",
        summary: "待执行步骤已丢弃；授权、契约和已形成产物都没有被静默改写。",
        points: ["运行身份已经关闭", "未执行步骤没有进入历史", "如需继续必须重新确认"],
        details: { activityType: "run-cancelled", runStatus: "cancelling" },
      },
      {
        actor: "zhulong",
        kind: "checkpoint",
        stage: recoveryStage,
        title: runRuntime.mode === "gate" ? "是否重新运行到下一决策门？" : "是否按当前修订重新委托剩余规划？",
        summary: "上一运行已经终止；重新开始会建立新的 run identity，并再次记录明确授权。",
        points: ["不会恢复旧 timer", "不会复用已关闭运行", "Todo 写入仍未授权"],
        details: { checkpointType: runRuntime.mode === "gate" ? "run" : "authorization", runStatus: "cancelled" },
      },
    ];
    renderLiveRunCommit(origin, wasFollowing);
    scheduleNextLiveRunStep(180);
    return true;
  }

  function resolveGate(value, text = "") {
    const checkpoint = activeCheckpoint("gate");
    if (!checkpoint) return false;
    const decision = choiceLabel("gate", value, text);
    const resolution = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "gate",
      title: decision,
      summary: "这项决定只处置证据不足，不构成 Todo 写入授权。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "decision", value },
    });
    const amendment = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "amendment",
      title: `简报修订 v0.${6 + state.branch} 已形成`,
      summary: `新增“证据不足处置”：${decision}。绑定旧简报的规划委托已经失效。`,
      points: ["目标与完成标准不变", "近期任务派生规则改变", "需要重新委托"],
      dependsOn: [resolution.id],
      details: { artifactType: "brief-amendment", version: `v0.${6 + state.branch}` },
    });
    const contract = appendEntry({
      actor: "system",
      kind: "activity",
      stage: "amendment",
      title: "修订后的运行契约等待授权",
      summary: "契约只绑定当前简报修订、剩余规划步骤与草稿产物；旧委托不会复用。",
      points: ["范围仍为 #SG-12", "Todo 写入未授权", "命中新的决策门仍会停下"],
      dependsOn: [amendment.id],
      details: { activityType: "run-contract", contractState: "pending-authorization" },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "amendment",
      title: "确认这项修订，并重新委托剩余规划？",
      summary: "旧委托不能沿用；Todo 写入仍然没有授权。",
      points: ["只继续剩余规划步骤", "绑定修订后的简报", "草稿生成后再次等待审查"],
      dependsOn: [contract.id],
      details: { checkpointType: "authorization" },
    });
    return true;
  }

  function resumePlanning() {
    const checkpoint = activeCheckpoint("amendment");
    if (!checkpoint) return false;
    const authorization = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "amendment",
      title: "确认修订并重新委托剩余规划",
      summary: "新委托只绑定修订后的活简报；旧委托继续保留供审计。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "planning-authorization", authorityId: `PA-${state.branch + 1}` },
    });

    if (state.longFixture) {
      const fixtureLength = state.motionDemo ? 36 : 16;
      for (let index = 1; index <= fixtureLength; index += 1) {
        appendEntry({
          actor: index % 4 === 0 ? "system" : "zhulong",
          kind: "activity",
          stage: "run",
          title: `规划证据记录 ${String(index).padStart(2, "0")}`,
          summary: index % 3 === 0 ? "核对依赖、反例与滚动触发条件；没有新增授权。" : "把远期不确定内容保留为触发条件，不伪装成近期承诺。",
          dependsOn: [authorization.id],
          details: { activityType: "long-fixture" },
        });
      }
    }

    const completed = appendEntry({
      actor: "zhulong",
      kind: "activity",
      stage: "run",
      title: "剩余规划步骤已经完成",
      summary: "阶段地图、依赖、滚动触发条件与近期 slice 已经编译成草稿。",
      points: ["远期范围不排具体日期", "近期只派生可验证任务", "没有写入 Todo"],
      dependsOn: [authorization.id],
      details: { activityType: "planning-complete" },
    });
    const plan = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "draft",
      title: `AI 规划草稿 v${state.branch}`,
      summary: "先取得真实工程测量，再交付任务成形 vertical slice，最后复用基础完成每日收尾。",
      points: ["阶段 0：调查工程切入点与测量", "阶段 1：任务成形 vertical slice", "阶段 2：每日收尾复用", "不生成日期、点数或正式概率"],
      dependsOn: [completed.id],
      details: { artifactType: "plan", version: `v${state.branch}` },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "draft",
      title: "先审查完整计划，再决定是否查看 Todo diff",
      summary: "计划与执行分离；当前没有 Todo 写入授权。",
      points: ["可回到任一旧检查点", "可追加更正", "只有成熟近期 slice 可以派生 Todo"],
      dependsOn: [plan.id],
      details: { checkpointType: "review" },
    });
    return true;
  }

  function openTodoDiff() {
    const checkpoint = activeCheckpoint("draft");
    if (!checkpoint) return false;
    const review = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "draft",
      title: "计划结构已审查，查看近期 Todo diff",
      summary: "这不代表接受写入，也不会形成承诺快照。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "review" },
    });
    const diffVersion = `v${state.branch}`;
    const diffHash = `D-${300 + state.branch}`;
    const baseRevision = currentBaseTodoRevision();
    const diff = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "apply",
      title: `Todo 变更 diff ${diffVersion} · 3 项${state.branch === 1 ? "创建" : "补偿／调整"}`,
      summary: state.branch === 1
        ? "调查工程切入点、实现任务成形 vertical slice、用真实 App E2E 验收闭环。"
        : "基于已发生 Todo 与新修订形成补偿性调整；不会重复创建已经存在的结果。",
      points: ["目标：任务池", "无具体日期", "全部成功或 0 项写入", `Base Todo revision #${baseRevision}`, `selection hash ${diffHash}`],
      dependsOn: [review.id],
      details: { artifactType: "todo-diff", version: diffVersion, hash: diffHash, baseRevision },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "apply",
      title: "是否原子应用当前 3 项 Todo 变更？",
      summary: `授权只对 diff ${diffVersion}、hash ${diffHash} 与本次点击有效。`,
      points: ["不包含未来草稿", "不包含记忆或 Provider 变更", "不形成承诺快照"],
      dependsOn: [diff.id],
      details: { checkpointType: "authorization", capability: "todo-write" },
    });
    return true;
  }

  function applyTodoDiff() {
    const projection = projectSession();
    const checkpoint = projection.activeCheckpoint;
    if (!checkpoint || checkpoint.stage !== "apply" || !projection.canApply) return false;
    const diff = projection.activeDiff;
    const batchId = `A-${300 + state.branch}`;
    const authorityId = `WA-${300 + state.branch}`;
    const resultBase = 310 + ((state.branch - 1) * 10);
    const baseRevisionNumber = Number.parseInt(diff.details.baseRevision.replace(/^T-/, ""), 10);
    const resultBaseRevision = `T-${baseRevisionNumber + 1}`;
    const authorization = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "apply",
      title: "确认并原子应用当前 3 项",
      summary: `一次性写入授权绑定 diff ${diff.details.version}、hash ${diff.details.hash} 与 Base revision #${diff.details.baseRevision}。`,
      dependsOn: [checkpoint.id],
      details: {
        resolves: checkpoint.id,
        resolutionType: "todo-write-authorization",
        authorityId,
        diffHash: diff.details.hash,
        baseRevision: diff.details.baseRevision,
        idempotencyKey: batchId,
      },
    });
    const receipt = appendEntry({
      actor: "system",
      kind: "artifact",
      stage: "receipt",
      title: "3 项 Todo 已经原子应用",
      summary: "事务 readback 一致；一次性写入授权已经消费并结束。",
      points: [`结果 #T-${resultBase}、#T-${resultBase + 1}、#T-${resultBase + 2}`, `Base Todo revision readback #${resultBaseRevision}`, "没有生成承诺快照", "没有确认长期记忆", "没有保留未来写入授权"],
      dependsOn: [authorization.id],
      details: {
        artifactType: "receipt",
        batchId,
        diffHash: diff.details.hash,
        baseRevision: diff.details.baseRevision,
        resultBaseRevision,
        idempotencyKey: batchId,
      },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "receipt",
      title: "本次任务成形已经完成",
      summary: "完整记录仍然留在这条流里；后续取得新证据时建立新修订。",
      points: ["可查看事件历史", "可整体归档会话", "普通 Todo 已脱离本次 AI 授权"],
      dependsOn: [receipt.id],
      details: { checkpointType: "completion" },
    });
    return true;
  }

  function appendCorrection(targetId, text) {
    const target = state.entries.find((entry) => entry.id === targetId && entry.kind === "checkpoint");
    const correctableStages = new Set(["focus", "criteria", "gate"]);
    if (!target || !correctableStages.has(target.stage) || !text.trim()) return false;
    const latestAppliedReceipt = [...state.entries]
      .reverse()
      .find((entry) => entry.sequence > target.sequence && entry.details.artifactType === "receipt");
    const invalidationCutoff = latestAppliedReceipt?.sequence || target.sequence;
    const affected = state.entries
      .filter((entry) => entry.sequence > invalidationCutoff)
      .filter((entry) => !["correction", "invalidation"].includes(entry.kind))
      .filter((entry) => entry.stage !== "receipt")
      .filter((entry) => entry.details.resolutionType !== "todo-write-authorization")
      .map((entry) => entry.id);
    state.branch += 1;
    const correction = appendEntry({
      actor: "user",
      kind: "correction",
      stage: "correction",
      title: `追加更正：${text.trim()}`,
      summary: `引用 ${target.id}「${target.title}」；旧表达不会被覆盖。`,
      dependsOn: [target.id],
      details: { corrects: target.id, correctionText: text.trim() },
    });
    const invalidation = appendEntry({
      actor: "system",
      kind: "invalidation",
      stage: "correction",
      title: latestAppliedReceipt
        ? affected.length
          ? `${affected.length} 条 receipt 后的未消费记录已停止生效`
          : "已发生的 Todo 应用事实不会被回滚"
        : `${affected.length} 条后续记录已停止生效`,
      summary: latestAppliedReceipt
        ? "旧批次、写入授权消费与 receipt 继续作为已发生事实；receipt 之后尚未消费的计划、diff 与检查点已经停用。新修订只能形成新的补偿性 Todo diff。"
        : "旧简报、委托、运行、草稿与未消费写入能力仍可审计，但不能继续执行。",
      points: latestAppliedReceipt
        ? ["原 receipt 与结果实体保持有效", "相同 diff hash 已消费，不能再次应用", "后续修改必须基于新的 Base revision 与幂等键"]
        : ["原记录与原 payload 保持不变", "浏览器历史不能恢复旧授权", "需要从更正后的检查点重新形成有效分支"],
      dependsOn: [correction.id],
      details: { invalidates: affected, invalidationReason: correction.id },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: target.stage,
      title: `重新确认：${target.title}`,
      summary: "请按更正后的真实意图重新回答；旧分支继续保留在上方。",
      points: ["这是新的检查点", "不复用旧规划委托", "所有后续能力必须重新建立"],
      dependsOn: [correction.id, invalidation.id],
      details: { checkpointType: target.details.checkpointType, reopens: target.id },
    });
    view.selected[target.stage] = "";
    view.responseText[target.stage] = "";
    view.correctionTargetId = null;
    view.correctionText = "";
    return true;
  }

  function seedScenario(name) {
    seedBaseSession();
    if (["run", "gate", "draft", "receipt", "corrected", "long"].includes(name)) {
      resolveFocus("shape");
      resolveCriteria("both");
      delegatePlanning();
    }
    if (["gate", "draft", "receipt", "corrected", "long"].includes(name)) {
      runToGate();
    }
    if (["draft", "receipt", "corrected", "long"].includes(name)) {
      resolveGate("investigate");
      resumePlanning();
    }
    if (name === "receipt") {
      openTodoDiff();
      applyTodoDiff();
    }
    if (name === "corrected") {
      const focus = state.entries.find((entry) => entry.kind === "checkpoint" && entry.stage === "focus");
      appendCorrection(focus.id, "先完整验证任务成形，不再把每日收尾作为第一条路径。");
    }
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

  function navItem({ key, label, count = "", active = false, color = "#2961c7", action = "" }) {
    return `<button class="nav-item${active ? " active" : ""}" style="--nav-color:${color}" type="button" ${action ? `data-notice="${action}"` : ""}>
      <span class="nav-icon">${navIcon(key)}</span><span>${label}</span>${count ? `<span class="nav-count">${count}</span>` : ""}
    </button>`;
  }

  function sidebar() {
    return `<aside class="sidebar">
      <div class="sidebar-top"><div class="traffic-lights"><span class="traffic-light red"></span><span class="traffic-light amber"></span><span class="traffic-light green"></span></div></div>
      <div class="brand"><span class="clock-logo"><i></i><b></b></span><strong>晷迹</strong></div>
      <div class="nav-group-label">计划</div>
      <nav class="nav-list" aria-label="主导航">
        ${navItem({ key: "day", label: "Day Todo", count: "5", color: "#2a6fdb", action: "Prototype：固定会话外框不切换页面。" })}
        ${navItem({ key: "pool", label: "任务池", count: "3", color: "#0e9488", action: "Prototype：任务池保持现有产品边界。" })}
        ${navItem({ key: "future", label: "未来计划", count: "3", color: "#7c5cff", action: "Prototype：未来计划保持现有产品边界。" })}
        <div class="nav-group-label trace-label">轨迹</div>
        ${navItem({ key: "unfinished", label: "未完成", count: "5", color: "#e0851b", action: "Prototype：未完成池保持现有产品边界。" })}
        ${navItem({ key: "completed", label: "已完成", count: "8", color: "#1f8a5b", action: "Prototype：已完成池保持现有产品边界。" })}
        ${navItem({ key: "calendar", label: "日历", color: "#d1477a", action: "Prototype：日历保持现有产品边界。" })}
        ${navItem({ key: "zhulong", label: "烛龙", active: true, color: "#7c5cff" })}
      </nav>
      <div class="sidebar-bottom">${navItem({ key: "settings", label: "设置", color: "#64748b", action: "Prototype：设置是辅助路径，不中断当前会话 head。" })}</div>
    </aside>`;
  }

  function layoutGlyph(variant) {
    return `<span class="layout-glyph layout-glyph-${variant.toLowerCase()}" aria-hidden="true"><i></i><i></i><i></i></span>`;
  }

  function layoutPicker(variant) {
    const presentation = variantPresentation[variant];
    return `<div class="layout-picker" data-layout-picker>
      <button class="header-button layout-trigger" type="button" data-action="toggle-layout-menu" data-layout-trigger aria-haspopup="menu" aria-controls="zhulong-layout-menu" aria-expanded="${view.layoutMenuOpen}">${layoutGlyph(variant)}<span>视图 · ${presentation.short}</span><b aria-hidden="true">⌄</b></button>
      ${view.layoutMenuOpen ? `<div class="layout-menu" id="zhulong-layout-menu" data-layout-menu role="menu" aria-label="选择会话视图"><div class="layout-menu-heading"><strong>会话视图</strong><small>只改变呈现，不改变记录与授权</small></div>${Object.keys(variants).map((key) => {
        const item = variantPresentation[key];
        const selected = key === variant;
        return `<button class="layout-option${selected ? " selected" : ""}" type="button" role="menuitemradio" data-action="set-variant" data-layout-option data-value="${key}" aria-checked="${selected}" aria-pressed="${selected}">${layoutGlyph(key)}<span><strong>${key} · ${item.short}</strong><small>${item.description}</small></span>${item.default ? `<em>默认</em>` : ""}<b aria-hidden="true">${selected ? "✓" : ""}</b></button>`;
      }).join("")}</div>` : ""}
    </div>`;
  }

  function pageHeader(projection) {
    const eventCount = state.entries.filter((entry) => ["resolution", "correction", "invalidation"].includes(entry.kind) || entry.details.artifactType === "receipt").length;
    const run = projection.activeRun;
    return `<header class="page-header stream-page-header">
      <div class="page-header-copy"><h1>重做烛龙 Agent</h1><p>${state.motionDemo ? "滚动轨迹演示 · " : ""}单一意图 · 本机保存 · ${state.entries.length} 条流式记录 · 当前分支 v${state.branch}</p></div>
      <div class="page-header-actions">
        ${layoutPicker(currentQuery().variant)}
        <button class="header-button" type="button" data-action="visit-previous">回看检查点</button>
        <button class="header-button" type="button" data-action="${run?.status === "paused" ? "resume-run" : "pause-session"}"${run?.status === "cancelling" ? " disabled" : ""}>${run?.status === "cancelling" ? "正在终止" : run?.status === "paused" ? "继续运行" : run ? "暂停运行" : "暂停"}</button>
        <button class="header-button" type="button" data-action="open-events">事件历史 · ${eventCount}</button>
        <button class="header-button icon-only" type="button" data-action="open-session" aria-label="会话菜单">•••</button>
      </div>
    </header>`;
  }

  function refreshPageHeader(focusSelector = "") {
    const header = document.querySelector(".stream-page-header");
    if (!header) {
      view.pendingFocusSelector = focusSelector;
      render();
      return;
    }
    header.outerHTML = pageHeader(projectSession());
    if (focusSelector) {
      scheduleVisualFrame(() => document.querySelector(focusSelector)?.focus({ preventScroll: true }));
    }
  }

  function actorMeta(actor) {
    const values = {
      user: { short: "你", label: "你", className: "user" },
      zhulong: { short: "烛", label: "烛龙", className: "zhulong" },
      system: { short: "系", label: "系统", className: "system" },
    };
    return values[actor] || values.system;
  }

  function kindLabel(kind) {
    const values = {
      message: "消息",
      artifact: "工作产物",
      checkpoint: "检查点",
      resolution: "用户决定",
      activity: "运行记录",
      correction: "追加更正",
      invalidation: "失效回执",
    };
    return values[kind] || kind;
  }

  function entryPayload(entry) {
    return `<div class="entry-payload" data-node-payload>
      <div class="entry-title-row"><h3>${escapeHTML(entry.title)}</h3></div>
      <p class="entry-summary">${escapeHTML(entry.summary)}</p>
      ${entry.points.length ? `<ul class="entry-points">${entry.points.map((point) => `<li>${escapeHTML(point)}</li>`).join("")}</ul>` : ""}
    </div>`;
  }

  function choiceButton(kind, value, title, description) {
    const selected = view.selected[kind] === value;
    return `<button class="stream-choice${selected ? " selected" : ""}" type="button" data-action="choose" data-kind="${kind}" data-value="${value}" aria-pressed="${selected}">
      <span class="stream-radio"><i></i></span><span><strong>${title}</strong><small>${description}</small></span>
    </button>`;
  }

  function previousCheckpoint(projection) {
    if (!projection.canonicalHead) return null;
    return [...state.entries]
      .reverse()
      .find((entry) => entry.kind === "checkpoint" && entry.sequence < projection.canonicalHead.sequence && projection.resolved.has(entry.id) && !projection.invalidatedBy.has(entry.id));
  }

  function activeComposer(entry, projection) {
    if (entry.kind !== "checkpoint") return "";
    if (view.correctionTargetId) return "";
    const previous = previousCheckpoint(projection);
    const backButton = previous ? `<button class="ghost-button" type="button" data-action="visit-previous" data-return-target="${previous.id}">回看上一检查点</button>` : "";
    const stage = entry.stage;

    if (stage === "focus") {
      return `<div class="stream-composer" data-current-action>
        <div class="stream-choice-list">
          ${choiceButton("focus", "daily", "先完整交付每日收尾", "先形成每天可用的收尾闭环")}
          ${choiceButton("focus", "shape", "先完整交付任务成形", "先解决模糊任务的 grill 与委托规划")}
          ${choiceButton("focus", "compare", "先比较，再决定", "只补齐比较材料，不替用户作出取舍")}
        </div>
        <textarea data-response-input="focus" aria-label="补充第一条路径" placeholder="也可以用自己的话说明……">${escapeHTML(view.responseText.focus)}</textarea>
        <div class="composer-actions"><div>${backButton}<button class="text-button" type="button" data-action="inspect-current">为什么现在问</button></div><button class="primary-button" type="button" data-action="confirm-current">确认这项取舍</button></div>
      </div>`;
    }
    if (stage === "criteria") {
      return `<div class="stream-composer" data-current-action>
        <div class="stream-choice-list">
          ${choiceButton("criteria", "usable", "真实 App 端到端每天可用", "从入口到结果回执完整走通")}
          ${choiceButton("criteria", "traceable", "所有关键决定都能追溯", "范围、假设、授权与写入可回到来源")}
          ${choiceButton("criteria", "both", "两者同时满足", "端到端可用，并且全部可追溯")}
        </div>
        <textarea data-response-input="criteria" aria-label="补充完成标准" placeholder="改写或补充最低完成标准……">${escapeHTML(view.responseText.criteria)}</textarea>
        <div class="composer-actions"><div>${backButton}<button class="text-button" type="button" data-action="inspect-current">为什么现在问</button></div><button class="primary-button" type="button" data-action="confirm-current">确认完成标准</button></div>
      </div>`;
    }
    if (stage === "gate") {
      return `<div class="stream-composer gate-composer" data-current-action>
        <div class="stream-choice-list">
          ${choiceButton("gate", "investigate", "先调查，再排日期", "形成工程测量任务；近期计划不写具体日期")}
          ${choiceButton("gate", "range", "只用我确认的工作量区间", "必须在下方写明区间与可投入时间")}
          ${choiceButton("gate", "unresolved", "保留未决并停止", "不生成近期 Todo 草稿")}
        </div>
        <textarea data-response-input="gate" aria-label="补充证据不足处置" placeholder="补充限制，或写明你确认的工作量区间……">${escapeHTML(view.responseText.gate)}</textarea>
        <div class="composer-actions"><div>${backButton}<button class="text-button" type="button" data-action="inspect-current">查看停机依据</button></div><button class="primary-button" type="button" data-action="confirm-current">形成简报修订</button></div>
      </div>`;
    }

    const simpleActions = {
      brief: ["确认简报并委托规划", "只授权本次规划，不包含 Todo 写入。"],
      run: ["运行到下一决策门", "只推进已披露的自主步骤。"],
      amendment: ["确认修订并继续规划", "旧委托不会复用。"],
      draft: ["审查近期 Todo diff", "查看 diff 不等于授权写入。"],
      apply: ["确认并原子应用 3 项", "当前批次全部成功，或 0 项写入。"],
    };
    if (simpleActions[stage]) {
      const [label, help] = simpleActions[stage];
      const capability = stage === "apply" ? ` data-capability="todo-write"${projection.canApply ? "" : " disabled"}` : "";
      return `<div class="stream-composer compact-composer" data-current-action><p>${help}</p><div class="composer-actions"><div>${backButton}<button class="text-button" type="button" data-action="inspect-current">检视依据与边界</button></div><button class="primary-button" type="button" data-action="confirm-current"${capability}>${label}</button></div></div>`;
    }
    if (stage === "receipt") {
      return `<div class="stream-composer receipt-composer" data-current-action><p>本轮授权已经全部结束。完整形成过程仍然保留在上方。</p><div class="composer-actions"><div>${backButton}<button class="ghost-button" type="button" data-action="open-events">查看事件历史</button></div><button class="primary-button" type="button" data-action="finish-session">归档这段会话</button></div></div>`;
    }
    return "";
  }

  function entryActions(entry, projection, isCurrent, allowDisclosure = false, disclosureExpanded = true) {
    const actions = [];
    if (entry.kind === "checkpoint"
      && ["focus", "criteria", "gate"].includes(entry.stage)
      && projection.resolved.has(entry.id)
      && !projection.invalidatedBy.has(entry.id)) {
      actions.push(`<button class="entry-action" type="button" data-action="start-correction" data-entry-id="${entry.id}">从这里调整</button>`);
    }
    if (!isCurrent) actions.push(`<button class="entry-action" type="button" data-action="inspect-entry" data-entry-id="${entry.id}">检视</button>`);
    if (allowDisclosure) actions.push(`<button class="entry-action expand-action" type="button" data-action="toggle-entry" data-entry-id="${entry.id}" aria-expanded="${disclosureExpanded}">${disclosureExpanded ? "收起" : "展开"}</button>`);
    return actions.length ? `<div class="entry-actions">${actions.join("")}</div>` : "";
  }

  function correctionComposer() {
    if (!view.correctionTargetId) return "";
    const target = state.entries.find((entry) => entry.id === view.correctionTargetId);
    if (!target) return "";
    return `<section class="correction-composer" data-current-action data-correction-composer data-correction-target="${target.id}">
      <div class="correction-reference"><span class="status-pill accent">引用 ${target.id}</span><div><strong>${escapeHTML(target.title)}</strong><p>旧记录不会被覆盖；提交后会在这里追加更正与失效回执。</p></div></div>
      <textarea data-correction-input aria-label="追加会话更正" placeholder="说明原决定哪里不准确，以及新的准确表达……">${escapeHTML(view.correctionText)}</textarea>
      <div class="composer-actions"><button class="ghost-button" type="button" data-action="cancel-correction">取消</button><button class="primary-button" type="button" data-action="confirm-correction">追加更正并重新确认</button></div>
    </section>`;
  }

  function liveRunIndicator(projection) {
    const run = projection.activeRun;
    if (!run) return "";
    const paused = run.status === "paused";
    if (paused) return "";
    const cancelling = run.status === "cancelling";
    const finishing = run.status === "finishing";
    return `<section class="live-run-indicator" data-live-run-indicator data-run-id="${run.runId}" data-run-state="${run.status}" data-run-ordinal="${run.ordinal}">
      <span class="live-run-pulse" aria-hidden="true"></span>
      <div><strong>${cancelling ? "正在安全终止本次运行" : finishing ? "正在收束刚形成的产物" : "正在形成下一条可审查记录"}</strong><p>${cancelling ? "尚未执行的步骤不会进入历史。" : "形成后会追加在这里；你仍可滚动查看上文。"}</p></div>
    </section>`;
  }

  function nodeAttributes(entry, projection) {
    const stateName = entryState(entry, projection);
    const invalidatedBy = projection.invalidatedBy.get(entry.id);
    const correctedBy = projection.correctedBy.get(entry.id);
    return `id="${entry.id}" data-stream-node data-node-id="${entry.id}" data-stage="${entry.stage}" data-kind="${entry.kind}" data-state="${stateName}" data-branch="${entry.branch}" data-depends-on="${entry.dependsOn.join(",")}" data-resolves="${entry.details.resolves || ""}" data-authority-id="${entry.details.authorityId || ""}" data-contract-id="${entry.details.contractId || ""}" data-run-id="${entry.details.runId || ""}" data-run-status="${entry.details.runStatus || ""}" data-run-ordinal="${entry.details.ordinal ?? ""}" data-activity-type="${entry.details.activityType || ""}" data-artifact-type="${entry.details.artifactType || ""}" data-invalidates="${(entry.details.invalidates || []).join(",")}" data-diff-hash="${entry.details.diffHash || entry.details.hash || ""}" data-idempotency-key="${entry.details.idempotencyKey || ""}"${invalidatedBy ? ` data-invalidated-by="${invalidatedBy}"` : ""}${entry.details.reopens ? ` data-reopens="${entry.details.reopens}"` : ""}${correctedBy ? ` data-corrected-by="${correctedBy}"` : ""}${stateName === "current" ? ` aria-current="step"` : ""}`;
  }

  function entryBadges(entry, projection) {
    const badges = [];
    const stateName = entryState(entry, projection);
    if (stateName === "current") badges.push(`<span class="stream-state current">当前</span>`);
    if (stateName === "invalidated") badges.push(`<span class="stream-state invalid">已失效 · 仅供审计</span>`);
    if (projection.correctedBy.has(entry.id)) badges.push(`<span class="stream-state corrected">已被 ${projection.correctedBy.get(entry.id)} 更正</span>`);
    if (entry.kind === "correction") badges.push(`<span class="stream-state corrected">追加式更正</span>`);
    if (entry.kind === "invalidation") badges.push(`<span class="stream-state invalid">失效回执</span>`);
    return badges.join("");
  }

  function entryMeta(entry, projection) {
    const actor = actorMeta(entry.actor);
    return `<div class="entry-meta"><span>${actor.label}</span><span>${kindLabel(entry.kind)}</span><span>${stageMeta[entry.stage]?.label || entry.stage}</span>${entryBadges(entry, projection)}</div>`;
  }

  function shouldCompact(entry, projection, index) {
    if (view.expandedEntries.has(entry.id)) return false;
    if (entryState(entry, projection) === "current") return false;
    if (projection.invalidatedBy.has(entry.id) || projection.correctedBy.has(entry.id)) return false;
    if (["correction", "invalidation"].includes(entry.kind)) return false;
    return index < state.entries.length - 2;
  }

  function renderDossierEntry(entry, projection, index) {
    const actor = actorMeta(entry.actor);
    const isCurrent = entryState(entry, projection) === "current";
    const compact = shouldCompact(entry, projection, index);
    return `<article ${nodeAttributes(entry, projection)} class="stream-node dossier-entry actor-${actor.className}${compact ? " is-compact" : ""}${view.locatedEntryId === entry.id ? " is-located" : ""}">
      <div class="dossier-spine"><span class="source-node">${actor.short}</span><i></i></div>
      <div class="entry-main">${entryMeta(entry, projection)}${entryPayload(entry)}${entryActions(entry, projection, isCurrent, true, !compact)}${isCurrent ? activeComposer(entry, projection) : ""}</div>
      <div class="entry-time"><time>${entry.createdAt}</time><span>#${String(entry.sequence).padStart(2, "0")}</span></div>
    </article>`;
  }

  function dossierUnits(projection) {
    const units = [];
    let index = 0;
    while (index < state.entries.length) {
      const entry = state.entries[index];
      if (entry.kind === "activity" && entryState(entry, projection) !== "current") {
        const entries = [entry];
        let next = index + 1;
        while (next < state.entries.length
          && state.entries[next].kind === "activity"
          && stageMeta[state.entries[next].stage]?.phase === stageMeta[entry.stage]?.phase
          && state.entries[next].branch === entry.branch
          && entryState(state.entries[next], projection) !== "current") {
          entries.push(state.entries[next]);
          next += 1;
        }
        if (entries.length >= 3) {
          units.push({ type: "bundle", key: `bundle-${entry.id}`, entries, startIndex: index });
          index = next;
          continue;
        }
      }
      units.push({ type: "entry", entry, startIndex: index });
      index += 1;
    }
    return units;
  }

  function renderVariantA(projection) {
    let previousPhase = "";
    const content = dossierUnits(projection).map((unit) => {
      const first = unit.type === "entry" ? unit.entry : unit.entries[0];
      const phase = stageMeta[first.stage]?.phase || "define";
      const separator = phase !== previousPhase
        ? `<div class="dossier-phase-separator"><span>${stageMeta[first.stage]?.phaseLabel || "会话记录"}</span><i></i></div>`
        : "";
      previousPhase = phase;
      if (unit.type === "entry") return `${separator}${renderDossierEntry(unit.entry, projection, unit.startIndex)}`;
      const expanded = view.expandedSegments.has(unit.key);
      const invalidated = unit.entries.filter((entry) => projection.invalidatedBy.has(entry.id)).length;
      return `${separator}<section class="activity-bundle${expanded ? " expanded" : ""}">
        <button class="activity-bundle-heading" type="button" data-action="toggle-bundle" data-bundle="${unit.key}" aria-expanded="${expanded}"><span class="source-node">烛</span><span><strong>运行记录 · ${unit.entries.length} 步</strong><small>${invalidated ? `${invalidated} 步已失效 · ` : ""}${escapeHTML(unit.entries.at(-1).title)}</small></span><b>${expanded ? "收起" : "展开"}</b></button>
        <div class="activity-bundle-body"${expanded ? "" : " hidden"}>${unit.entries.map((entry, offset) => renderDossierEntry(entry, projection, unit.startIndex + offset)).join("")}</div>
      </section>`;
    }).join("");
    return `<div class="stream-canvas variant-a" data-variant-view="A"><div class="stream-dossier">${content}${liveRunIndicator(projection)}${correctionComposer()}</div></div>`;
  }

  function contiguousSegments() {
    const segments = [];
    state.entries.forEach((entry) => {
      const meta = stageMeta[entry.stage] || stageMeta.scope;
      const last = segments.at(-1);
      if (!last || last.phase !== meta.phase || last.branch !== entry.branch) {
        segments.push({
          key: `segment-${segments.length + 1}`,
          phase: meta.phase,
          title: meta.phaseLabel,
          branch: entry.branch,
          entries: [entry],
        });
      } else {
        last.entries.push(entry);
      }
    });
    return segments;
  }

  function renderChapterEntry(entry, projection) {
    const isCurrent = entryState(entry, projection) === "current";
    return `<article ${nodeAttributes(entry, projection)} class="stream-node chapter-entry actor-${entry.actor}${view.locatedEntryId === entry.id ? " is-located" : ""}">
      <div class="chapter-entry-marker"><span>${actorMeta(entry.actor).short}</span><i></i></div>
      <div class="entry-main">${entryMeta(entry, projection)}${entryPayload(entry)}${entryActions(entry, projection, isCurrent)}${isCurrent ? activeComposer(entry, projection) : ""}</div>
      <time>${entry.createdAt}</time>
    </article>`;
  }

  function renderVariantB(projection) {
    const segments = contiguousSegments();
    const currentIndex = Math.max(0, segments.findIndex((segment) => segment.entries.some((entry) => entry.id === projection.canonicalHead?.id)));
    return `<div class="stream-canvas variant-b" data-variant-view="B"><div class="chapter-stream">${segments.map((segment, index) => {
      const invalidatedCount = segment.entries.filter((entry) => projection.invalidatedBy.has(entry.id)).length;
      const isCurrent = index === currentIndex;
      const defaultOpen = isCurrent || view.expandedSegments.has(segment.key);
      const summary = segment.entries.at(-1)?.title || segment.title;
      const priorKey = `${segment.key}:prior`;
      const decisionComposerIsTall = isCurrent && ["focus", "criteria", "gate"].includes(projection.activeCheckpoint?.stage);
      const visibleCount = decisionComposerIsTall ? 1 : 2;
      const hasPrior = isCurrent && segment.entries.length > visibleCount;
      const priorExpanded = view.expandedSegments.has(priorKey);
      const priorEntries = hasPrior ? segment.entries.slice(0, -visibleCount) : [];
      const visibleEntries = hasPrior ? segment.entries.slice(-visibleCount) : segment.entries;
      return `<section class="stream-chapter${isCurrent ? " current" : ""}${invalidatedCount === segment.entries.length ? " invalidated" : ""}" data-segment="${segment.key}"${isCurrent ? " data-current-segment" : ""}>
        <button class="chapter-heading" type="button" data-action="toggle-segment" data-segment="${segment.key}" aria-expanded="${defaultOpen}">
          <span class="chapter-number">${String(index + 1).padStart(2, "0")}</span><span class="chapter-copy"><strong>${segment.title}</strong><small>${escapeHTML(summary)}</small></span><span class="chapter-status">${isCurrent ? "当前" : invalidatedCount ? `${invalidatedCount} 条失效` : `${segment.entries.length} 条记录`}</span><span class="chapter-chevron">${defaultOpen ? "⌃" : "⌄"}</span>
        </button>
        <div class="chapter-body"${defaultOpen ? "" : " hidden"}>${priorEntries.length ? `<div class="chapter-prior"><button type="button" data-action="toggle-chapter-prior" data-segment="${priorKey}" aria-expanded="${priorExpanded}"><span>较早记录 · ${priorEntries.length} 条</span><small>${escapeHTML(priorEntries.at(-1).title)}</small><b>${priorExpanded ? "收起" : "展开"}</b></button><div${priorExpanded ? "" : " hidden"}>${priorEntries.map((entry) => renderChapterEntry(entry, projection)).join("")}</div></div>` : ""}${visibleEntries.map((entry) => renderChapterEntry(entry, projection)).join("")}</div>
      </section>`;
    }).join("")}${liveRunIndicator(projection)}${correctionComposer()}</div></div>`;
  }

  function wovenPresentationRole(entry) {
    const majorActivity = ["run-contract", "stop-condition", "run-failed", "run-cancelled"].includes(entry.details.activityType);
    if (entry.kind === "checkpoint") return "checkpoint";
    if (["correction", "invalidation"].includes(entry.kind)) return "history-boundary";
    if (entry.details.artifactType === "receipt") return "receipt";
    if (majorActivity) return "system-boundary";
    return entry.actor === "user" ? "user" : "zhulong";
  }

  function wovenLane(role) {
    return ["checkpoint", "history-boundary", "receipt", "system-boundary"].includes(role) ? "full" : role;
  }

  function wovenMilestone(entry, role) {
    if (role === "checkpoint") return "共同决策点";
    if (role === "history-boundary") return "历史边界";
    if (role === "receipt") return "结果回执";
    if (role === "system-boundary" && ["stop-condition", "run-failed", "run-cancelled"].includes(entry.details.activityType)) return "运行边界";
    if (role === "system-boundary") return "系统边界";
    return "";
  }

  function wovenEntryMeta(entry, projection) {
    return `<div class="entry-meta"><span>${kindLabel(entry.kind)}</span><span>${stageMeta[entry.stage]?.label || entry.stage}</span>${entryBadges(entry, projection)}</div>`;
  }

  function renderWovenEntry(entry, projection) {
    const isCurrent = entryState(entry, projection) === "current";
    const role = wovenPresentationRole(entry);
    const lane = wovenLane(role);
    const milestone = wovenMilestone(entry, role);
    const actor = actorMeta(entry.actor);
    const userTextLength = `${entry.title}${entry.summary}${entry.points.join("")}`.length;
    const longUserEntry = lane === "user" && !isCurrent && userTextLength > 120;
    const collapsedUserEntry = longUserEntry && !view.expandedEntries.has(entry.id);
    return `<article ${nodeAttributes(entry, projection)} data-woven-role="${role}" data-woven-lane="${lane}"${milestone ? ` data-woven-milestone="${milestone}"` : ""} class="stream-node woven-entry lane-${lane} actor-${entry.actor}${collapsedUserEntry ? " is-compact-user" : ""}${view.locatedEntryId === entry.id ? " is-located" : ""}">
      <div class="woven-card">${milestone ? `<div class="woven-milestone"><span>${milestone}</span><i></i></div>` : ""}<div class="woven-source"><span class="woven-actor"><i aria-hidden="true"></i>${actor.label}</span><time>${entry.createdAt}</time></div>${wovenEntryMeta(entry, projection)}${entryPayload(entry)}${entryActions(entry, projection, isCurrent, longUserEntry, !collapsedUserEntry)}${isCurrent ? activeComposer(entry, projection) : ""}</div>
      <div class="woven-spine"><span>${actorMeta(entry.actor).short}</span><i></i></div>
    </article>`;
  }

  function renderVariantC(projection) {
    return `<div class="stream-canvas variant-c" data-variant-view="C"><div class="woven-stream"><div class="woven-labels"><span><strong>烛龙</strong><small>分析、选项与执行</small></span><i></i><span><strong>你</strong><small>决定与授权</small></span></div>${state.entries.map((entry) => renderWovenEntry(entry, projection)).join("")}${liveRunIndicator(projection)}${correctionComposer()}</div></div>`;
  }

  function renderStream(variant, projection) {
    if (variant === "B") return renderVariantB(projection);
    if (variant === "C") return renderVariantC(projection);
    return renderVariantA(projection);
  }

  function railHeader(title, subtitle, closable = false) {
    return `<div class="rail-header"><div><h2>${title}</h2>${subtitle ? `<p>${subtitle}</p>` : ""}</div>${closable ? `<button class="rail-close" type="button" data-action="close-panel" aria-label="关闭">×</button>` : ""}</div>`;
  }

  function railList(rows) {
    return `<div class="rail-list">${rows.map((row) => `<div class="rail-list-row">${row}</div>`).join("")}</div>`;
  }

  function railSection(title, content) {
    return `<section class="rail-section"><h3>${title}</h3>${content}</section>`;
  }

  function importantEvents() {
    return state.entries.filter((entry) =>
      ["resolution", "correction", "invalidation"].includes(entry.kind)
      || ["stop-condition", "run-contract", "run-started", "run-paused", "run-cancelled", "run-failed"].includes(entry.details.activityType)
      || Boolean(entry.details.integrityReason)
      || entry.details.artifactType === "receipt"
    );
  }

  function eventRail() {
    const events = importantEvents().slice().reverse();
    return `${railHeader("烛龙事件历史", "跨功能摘要 · 会话正文仍留在中央流", true)}<div class="detail-rail-scroll"><div class="rail-notice">事件不能逐条修改或删除；“查看关联”只移动查看游标，不改变当前工作。</div><div class="native-events">${events.map((entry) => `<div class="native-event"><time>${entry.createdAt}</time><div><strong>${escapeHTML(entry.title)}</strong><p>${escapeHTML(entry.summary)}</p><button class="rail-link" type="button" data-action="inspect-entry" data-entry-id="${entry.id}">查看关联 →</button></div></div>`).join("")}</div><div class="rail-clear"><strong>按连续时间范围清理</strong><p>清理事件摘要不会删除中央会话流。</p><div class="rail-actions"><button class="small-action" type="button" data-notice="Prototype：准备清理最近 1 小时。">最近 1 小时</button><button class="small-action" type="button" data-notice="Prototype：准备清理最近 1 天。">最近 1 天</button><button class="small-action" type="button" data-notice="Prototype：准备清理最近 7 天。">最近 7 天</button></div></div></div>`;
  }

  function returnCurrentCopy() {
    return view.unseenLiveEntries > 0 ? `${view.unseenLiveEntries} 条新运行记录 ↓` : "回到当前 ↓";
  }

  function contextRail(projection) {
    const passivelySelected = view.userOwnsScroll
      ? state.entries.find((entry) => entry.id === view.passiveContextEntryId)
      : null;
    const selected = state.entries.find((entry) => entry.id === view.cursorEntryId)
      || passivelySelected
      || projection.canonicalHead
      || state.entries.at(-1);
    if (!selected) return `${railHeader("依据与边界", "会话流为空")}<div class="detail-rail-scroll"></div>`;
    const stateName = entryState(selected, projection);
    const dependencies = selected.dependsOn.length ? selected.dependsOn : ["没有上游引用"];
    const boundaryByStage = {
      focus: ["只能更新用户取舍", "不能启动规划", "不能写入 Todo"],
      criteria: ["只能确认完成标准", "不能由烛龙降低标准", "不能启动规划"],
      brief: ["只建立单次规划委托", "不包含 Todo 写入", "不包含长期托管"],
      run: ["只推进已授权步骤", "命中停机条件即暂停", "产物仍是草稿"],
      gate: ["最终取舍权属于用户", "无证据不做伪精度", "回答会使旧委托失效"],
      amendment: ["必须重新委托", "不复用旧授权", "Todo 写入仍未授权"],
      draft: ["计划先于 Todo diff", "旧草稿可审计", "无具体 diff 不写入"],
      apply: ["只对当前 diff 和本次点击有效", "全部成功或完整回滚", "不形成承诺快照"],
      receipt: ["授权已经消费", "结果已成为普通 Todo", "更正不能抹除已发生事实"],
    };
    const stateLabel = stateName === "invalidated" ? "已失效" : stateName === "current" ? "当前" : "已完成";
    const identityRows = [
      `来源：${actorMeta(selected.actor).label} · ${kindLabel(selected.kind)}`,
      `分支：v${selected.branch}`,
    ];
    if (selected.details.version) identityRows.push(`版本：${selected.details.version}`);
    if (selected.details.authorityId) identityRows.push(`授权：${selected.details.authorityId}`);
    if (selected.details.contractId) identityRows.push(`契约：${selected.details.contractId}`);
    if (selected.details.runId) identityRows.push(`运行：${selected.details.runId} · #${selected.details.ordinal}`);
    if (selected.details.hash || selected.details.diffHash) identityRows.push(`hash：${selected.details.hash || selected.details.diffHash}`);
    const reviewingVisibleHistory = Boolean(passivelySelected) && !view.cursorEntryId;
    const unreadSuffix = reviewingVisibleHistory && view.unseenLiveEntries ? ` · 当前 head 有 ${view.unseenLiveEntries} 条新记录` : "";
    return `${railHeader(reviewingVisibleHistory ? "查看中的依据" : "依据与边界", `${selected.id} · ${stageMeta[selected.stage]?.label || selected.stage} · ${stateLabel}${unreadSuffix}`, Boolean(view.cursorEntryId))}<div class="detail-rail-scroll">
      <div class="rail-notice">正文与决定保留在中央流；这里仅检视来源、依赖、版本与能力边界。</div>
      ${projection.runIntegrityError ? `<div class="rail-notice warn">运行完整性：${escapeHTML(projection.runIntegrityError)}。运行已 fail-closed，必须从恢复检查点重新确认。</div>` : ""}
      ${railSection("来源与依赖", railList(dependencies))}
      ${railSection("记录身份", railList(identityRows))}
      ${railSection("当前边界", railList(boundaryByStage[selected.stage] || ["记录只读", "不改变 canonical head"]))}
      ${view.cursorEntryId ? `<button class="small-action accent full" type="button" data-action="return-current">${returnCurrentCopy()}</button>` : ""}
    </div>`;
  }

  function sessionRail(projection) {
    const decisions = state.entries.filter((entry) => entry.kind === "checkpoint" && ["focus", "criteria", "gate"].includes(entry.stage) && projection.resolved.has(entry.id) && !projection.invalidatedBy.has(entry.id));
    const target = decisions.at(-1);
    return `${railHeader("会话控制", "一个主要意图 · append-only", true)}<div class="detail-rail-scroll">
      ${railSection("当前 head", `<div class="rail-card accent"><p>${projection.canonicalHead ? `${projection.canonicalHead.id} · ${escapeHTML(projection.canonicalHead.title)}` : "没有当前记录"}</p></div>`)}
      ${railSection("历史语义", `<div class="rail-card"><p>“回看上一检查点”只移动查看游标；更正会在流末端追加，不会覆盖旧决定。</p></div>`)}
      <div class="rail-stack"><button class="small-action" type="button" data-action="visit-previous">回看上一检查点</button>${target ? `<button class="small-action accent" type="button" data-action="start-correction" data-entry-id="${target.id}">追加会话更正</button>` : ""}<button class="small-action" type="button" data-action="${projection.activeRun?.status === "paused" ? "resume-run" : "pause-session"}"${projection.activeRun?.status === "cancelling" ? " disabled" : ""}>${projection.activeRun?.status === "cancelling" ? "正在终止" : projection.activeRun?.status === "paused" ? "继续当前运行" : projection.activeRun ? "暂停当前运行" : "暂停并保存"}</button>${projection.activeRun && projection.activeRun.status !== "cancelling" ? `<button class="small-action" type="button" data-action="cancel-run">终止本次运行</button>` : ""}<button class="small-action" type="button" data-notice="Prototype：整段会话将归档，历史引用仍然有效。">归档会话</button></div>
    </div>`;
  }

  function detailRail(projection) {
    let content = contextRail(projection);
    if (view.panel === "events") content = eventRail();
    if (view.panel === "session") content = sessionRail(projection);
    return `<aside class="detail-rail stream-detail-rail">${content}</aside>`;
  }

  const streamMotion = {
    token: 0,
    frame: null,
    settleTimer: 0,
    active: null,
    preparingMotion: null,
  };

  function cancelVisualFrame(ticket) {
    if (!ticket) return;
    ticket.cancelled = true;
    if (ticket.rafId) window.cancelAnimationFrame(ticket.rafId);
    if (ticket.timerId) window.clearTimeout(ticket.timerId);
  }

  function scheduleVisualFrame(callback) {
    const ticket = { cancelled: false, fired: false, rafId: 0, timerId: 0 };
    const deliver = () => {
      if (ticket.cancelled || ticket.fired) return;
      ticket.fired = true;
      if (ticket.rafId) window.cancelAnimationFrame(ticket.rafId);
      if (ticket.timerId) window.clearTimeout(ticket.timerId);
      callback(performance.now());
    };
    ticket.rafId = window.requestAnimationFrame(deliver);
    ticket.timerId = window.setTimeout(() => deliver(performance.now()), 17);
    return ticket;
  }

  function renderToast() {
    const host = document.querySelector("[data-toast-host]");
    if (!host) return;
    host.innerHTML = view.toast
      ? `<div class="toast stream-toast" role="status" aria-live="polite">${escapeHTML(view.toast)}</div>`
      : "";
  }

  function showToast(message) {
    view.toast = message;
    if (view.toastTimer) window.clearTimeout(view.toastTimer);
    renderToast();
    view.toastTimer = window.setTimeout(() => {
      view.toast = "";
      renderToast();
    }, 2600);
  }

  function markFollowTail() {
    view.followTail = true;
    view.userOwnsScroll = false;
    view.unseenLiveEntries = 0;
    view.returningToTail = false;
    view.passiveContextEntryId = "";
    view.cursorEntryId = null;
    view.locatedEntryId = null;
    replaceQuery({ entry: "" });
  }

  function expandEntryContainer(entryId) {
    view.expandedEntries.add(entryId);
    const segment = contiguousSegments().find((candidate) => candidate.entries.some((entry) => entry.id === entryId));
    if (segment) {
      view.expandedSegments.add(segment.key);
      view.expandedSegments.add(`${segment.key}:prior`);
    }
    const bundle = dossierUnits(projectSession()).find(
      (candidate) => candidate.type === "bundle" && candidate.entries.some((entry) => entry.id === entryId),
    );
    if (bundle) view.expandedSegments.add(bundle.key);
  }

  function updateReturnCurrentVisibility() {
    const button = document.querySelector("[data-return-current]");
    const scroller = document.querySelector("[data-stream-scroll]");
    if (!button || !scroller) return;
    button.textContent = returnCurrentCopy();
    button.dataset.unseenCount = String(view.unseenLiveEntries);
    button.classList.toggle("visible", Boolean(view.cursorEntryId) || view.userOwnsScroll || view.returningToTail || view.unseenLiveEntries > 0);
  }

  function currentDecisionActionIsVisible(scroller) {
    if (view.cursorEntryId) return false;
    const current = document.querySelector('[data-stream-node][data-state="current"]');
    const action = current?.querySelector("[data-current-action] .primary-button")
      || current?.querySelector("[data-current-action]");
    if (!action) return false;
    const scrollerRect = scroller.getBoundingClientRect();
    const actionRect = action.getBoundingClientRect();
    const visibleTop = scrollerRect.top + scrollViewportInset();
    return actionRect.top >= visibleTop - 1 && actionRect.bottom <= scrollerRect.bottom - 2;
  }

  function refreshPassiveContextRail() {
    if (["events", "session"].includes(view.panel)) return;
    cancelVisualFrame(view.passiveRailFrame);
    view.passiveRailFrame = scheduleVisualFrame(() => {
      view.passiveRailFrame = null;
      const rail = document.querySelector(".stream-detail-rail");
      if (rail) rail.outerHTML = detailRail(projectSession());
    });
  }

  function attachScrollBehaviour() {
    const scroller = document.querySelector("[data-stream-scroll]");
    if (!scroller) return;
    scroller.addEventListener("scroll", () => {
      const distanceFromTail = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
      const nearTail = distanceFromTail <= 56;
      const currentDecisionVisible = currentDecisionActionIsVisible(scroller);
      const programmaticMotion = view.restoringViewport
        || Boolean(streamMotion.active)
        || ["preparing", "traveling"].includes(scroller.dataset.scrollMotionState);
      if (!programmaticMotion) {
        if ((nearTail || currentDecisionVisible) && !view.cursorEntryId) {
          view.followTail = true;
          view.userOwnsScroll = false;
          if (view.passiveContextEntryId) {
            view.passiveContextEntryId = "";
            refreshPassiveContextRail();
          }
        } else {
          view.followTail = false;
          view.userOwnsScroll = true;
          const passiveEntryId = captureViewportAnchor().entryId;
          if (passiveEntryId && passiveEntryId !== view.passiveContextEntryId) {
            view.passiveContextEntryId = passiveEntryId;
            refreshPassiveContextRail();
          }
        }
      }
      updateReturnCurrentVisibility();
    }, { passive: true });
    const cancelForUser = () => cancelScrollMotion("user");
    scroller.addEventListener("wheel", cancelForUser, { passive: true });
    scroller.addEventListener("touchstart", cancelForUser, { passive: true });
    scroller.addEventListener("pointerdown", cancelForUser, { passive: true });
  }

  function setScrollTopImmediately(scroller, top) {
    const previous = scroller.style.scrollBehavior;
    scroller.style.scrollBehavior = "auto";
    scroller.scrollTop = Math.max(0, top);
    scroller.style.scrollBehavior = previous;
  }

  function topWithinScroller(element, scroller) {
    const elementRect = element.getBoundingClientRect();
    const scrollerRect = scroller.getBoundingClientRect();
    return scroller.scrollTop + elementRect.top - scrollerRect.top;
  }

  function clampScrollTop(scroller, top) {
    return Math.max(0, Math.min(Math.max(0, scroller.scrollHeight - scroller.clientHeight), top));
  }

  function scrollViewportInset(variant = currentQuery().variant) {
    return variant === "C" ? 42 : 0;
  }

  function currentContextTop(scroller, variant) {
    const current = document.querySelector('[data-stream-node][data-state="current"]');
    if (!current) return scroller.scrollHeight;
    if (variant === "B") {
      const chapter = current.closest("[data-current-segment]") || current;
      return clampScrollTop(scroller, topWithinScroller(chapter, scroller) - 8);
    }
    const visibleNodes = [...document.querySelectorAll("[data-stream-node]")].filter((node) => node.offsetParent !== null);
    const currentIndex = visibleNodes.indexOf(current);
    const previous = currentIndex > 0 ? visibleNodes[currentIndex - 1] : null;
    const contextFits = previous && previous.offsetHeight + current.offsetHeight <= scroller.clientHeight - 20;
    const anchor = contextFits ? previous : current;
    return clampScrollTop(scroller, topWithinScroller(anchor, scroller) - scrollViewportInset(variant) - 8);
  }

  function captureViewportAnchor(preferredId = "") {
    const scroller = document.querySelector("[data-stream-scroll]");
    if (!scroller) return { scrollTop: 0, entryId: "", viewportOffset: 0, viewportInset: 0 };
    const scrollerRect = scroller.getBoundingClientRect();
    const viewportInset = scrollViewportInset();
    const visibleTop = scrollerRect.top + viewportInset;
    const preferred = preferredId ? document.getElementById(preferredId) : null;
    const visibleNodes = [...document.querySelectorAll("[data-stream-node]")].filter((node) => {
      if (node.offsetParent === null) return false;
      const rect = node.getBoundingClientRect();
      return rect.bottom > visibleTop + 1 && rect.top < scrollerRect.bottom - 1;
    });
    const preferredRect = preferred?.getBoundingClientRect();
    const preferredVisible = preferred && preferred.offsetParent !== null
      && preferredRect.bottom > visibleTop + 1
      && preferredRect.top < scrollerRect.bottom - 1;
    const anchor = preferredVisible ? preferred : visibleNodes[0];
    return {
      scrollTop: scroller.scrollTop,
      entryId: anchor?.dataset.nodeId || "",
      viewportOffset: anchor ? anchor.getBoundingClientRect().top - scrollerRect.top : 0,
      viewportInset,
    };
  }

  function restoreViewportAnchor(scroller, anchor) {
    if (!anchor) return;
    const element = anchor.entryId ? document.getElementById(anchor.entryId) : null;
    if (element && element.offsetParent !== null) {
      const visibleContentOffset = anchor.viewportOffset - (anchor.viewportInset || 0);
      const targetViewportOffset = scrollViewportInset() + visibleContentOffset;
      setScrollTopImmediately(scroller, topWithinScroller(element, scroller) - targetViewportOffset);
      return;
    }
    setScrollTopImmediately(scroller, anchor.scrollTop);
  }

  function cancelScrollMotion(reason = "superseded") {
    streamMotion.token += 1;
    cancelVisualFrame(streamMotion.frame);
    if (streamMotion.settleTimer) window.clearTimeout(streamMotion.settleTimer);
    streamMotion.frame = null;
    streamMotion.settleTimer = 0;
    streamMotion.preparingMotion = null;
    const active = streamMotion.active;
    if (active) {
      const heldTop = active.scroller.scrollTop;
      active.scroller.style.scrollBehavior = "auto";
      active.scroller.scrollTop = heldTop;
      active.scroller.scrollTo({ top: heldTop, behavior: "auto" });
      active.scroller.dataset.scrollMotionCancelTop = String(heldTop);
      if (reason !== "user") active.scroller.style.scrollBehavior = active.previousScrollBehavior;
      active.source?.classList.remove("is-navigation-origin");
      active.target?.classList.remove("is-navigation-target");
      active.scroller.dataset.scrollMotionState = reason === "user" ? "cancelled" : "superseded";
      active.scroller.dataset.scrollMotionReason = reason;
    }
    streamMotion.active = null;
    if (reason === "user") {
      const scroller = document.querySelector("[data-stream-scroll]");
      if (scroller && !active) {
        scroller.dataset.scrollMotionState = "cancelled";
        scroller.dataset.scrollMotionReason = reason;
      }
      view.pendingScrollMotion = null;
      view.followTail = false;
      view.userOwnsScroll = true;
      view.returningToTail = false;
      updateReturnCurrentVisibility();
    }
  }

  function queueScrollMotion({ kind, targetRole, targetId = "", sourceId = "", direction = "" }, origin = null) {
    cancelScrollMotion("superseded");
    const captured = origin || captureViewportAnchor(sourceId);
    const effectiveSource = captured.entryId || sourceId;
    if (effectiveSource) expandEntryContainer(effectiveSource);
    if (targetId) expandEntryContainer(targetId);
    view.pendingScrollMotion = {
      kind,
      targetRole,
      targetId,
      sourceId: effectiveSource,
      direction,
      origin: { ...captured, entryId: effectiveSource || captured.entryId },
    };
  }

  function motionTarget(scroller, motion, variant) {
    let target = null;
    let top = 0;
    if (motion.targetRole === "entry") {
      target = document.getElementById(motion.targetId);
      if (target) top = topWithinScroller(target, scroller) - (scroller.clientHeight * 0.3);
    } else if (motion.targetRole === "correction") {
      target = document.querySelector("[data-correction-composer]");
      if (target) top = topWithinScroller(target, scroller) - scrollViewportInset(variant) - 18;
    } else if (motion.targetRole === "tail") {
      target = document.querySelector("[data-live-run-indicator]")
        || document.querySelector('[data-stream-node][data-state="current"]');
      top = scroller.scrollHeight - scroller.clientHeight;
    } else {
      target = document.querySelector('[data-stream-node][data-state="current"]');
      top = currentContextTop(scroller, variant);
    }
    return { target, top: clampScrollTop(scroller, top) };
  }

  function scrollMotionDuration(distance, viewportHeight) {
    const viewports = distance / Math.max(1, viewportHeight);
    if (viewports <= 0.35) return 240;
    if (viewports <= 1) return 320;
    if (viewports <= 2.5) return 440;
    return Math.min(760, Math.max(620, viewports * 200));
  }

  function easeScroll(progress) {
    return (6 * (progress ** 5)) - (15 * (progress ** 4)) + (10 * (progress ** 3));
  }

  function announceMotion(motion, target) {
    const status = document.querySelector("[data-stream-motion-status]");
    if (!status) return;
    const title = target?.querySelector("h3")?.textContent?.trim() || "目标位置";
    status.textContent = ["current", "tail"].includes(motion.targetRole) ? `已回到当前：${title}` : `已定位：${title}`;
  }

  function finishScrollMotion(active) {
    if (streamMotion.active !== active) return;
    active.scroller.scrollTop = active.targetTop;
    active.scroller.style.scrollBehavior = active.previousScrollBehavior;
    active.source?.classList.remove("is-navigation-origin");
    active.target?.classList.remove("is-navigation-target");
    active.target?.classList.add("is-arrived");
    active.scroller.dataset.scrollMotionState = "settled";
    active.scroller.dataset.scrollMotionEnd = String(active.scroller.scrollTop);
    streamMotion.active = null;
    streamMotion.frame = null;
    if (["current", "tail"].includes(active.motion.targetRole)) {
      view.followTail = true;
      view.userOwnsScroll = false;
      view.unseenLiveEntries = 0;
      view.returningToTail = false;
      view.passiveContextEntryId = "";
    }
    updateReturnCurrentVisibility();
    refreshPassiveContextRail();
    announceMotion(active.motion, active.target);
    if (active.focusSelector) document.querySelector(active.focusSelector)?.focus({ preventScroll: true });
    document.dispatchEvent(new CustomEvent("streamscrollmotionend", {
      detail: { kind: active.motion.kind, targetId: active.target?.dataset.nodeId || active.motion.targetId || "" },
    }));
    streamMotion.settleTimer = window.setTimeout(() => {
      active.target?.classList.remove("is-arrived");
      if (active.scroller.dataset.scrollMotionState === "settled") active.scroller.dataset.scrollMotionState = "idle";
    }, 1200);
  }

  function startScrollMotion(motion, focusSelector, generation) {
    if (generation !== view.renderGeneration) return;
    streamMotion.preparingMotion = null;
    const scroller = document.querySelector("[data-stream-scroll]");
    if (!scroller) return;
    const destination = motionTarget(scroller, motion, currentQuery().variant);
    if (!destination.target) return;
    const startTop = scroller.scrollTop;
    const targetTop = destination.top;
    const distance = Math.abs(targetTop - startTop);
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const duration = reducedMotion ? 0 : scrollMotionDuration(distance, scroller.clientHeight);
    const token = ++streamMotion.token;
    const source = motion.sourceId ? document.getElementById(motion.sourceId) : null;
    source?.classList.add("is-navigation-origin");
    destination.target.classList.add("is-navigation-target");
    scroller.dataset.scrollMotionState = "traveling";
    scroller.dataset.scrollMotionKind = motion.kind;
    scroller.dataset.scrollMotionDirection = motion.direction || (targetTop >= startTop ? "forward" : "backward");
    scroller.dataset.scrollMotionStart = String(startTop);
    scroller.dataset.scrollMotionTarget = String(targetTop);
    scroller.dataset.scrollMotionMaxStep = "0";
    const active = {
      token,
      motion,
      scroller,
      source,
      target: destination.target,
      startTop,
      targetTop,
      duration,
      focusSelector,
      startedAt: performance.now(),
      previousScrollBehavior: scroller.style.scrollBehavior,
    };
    streamMotion.active = active;
    scroller.style.scrollBehavior = "auto";
    if (duration === 0 || distance < 1) {
      finishScrollMotion(active);
      return;
    }
    const step = (now) => {
      if (streamMotion.active !== active || token !== streamMotion.token) return;
      const progress = Math.min(1, (now - active.startedAt) / duration);
      const desiredTop = startTop + ((targetTop - startTop) * easeScroll(progress));
      const currentTop = scroller.scrollTop;
      const desiredDelta = desiredTop - currentTop;
      const maxFrameDistance = scroller.clientHeight * 0.17;
      const nextTop = Math.abs(desiredDelta) <= maxFrameDistance
        ? desiredTop
        : currentTop + (Math.sign(desiredDelta) * maxFrameDistance);
      const stepDistance = Math.abs(nextTop - currentTop);
      scroller.dataset.scrollMotionMaxStep = String(Math.max(Number(scroller.dataset.scrollMotionMaxStep || 0), stepDistance));
      scroller.scrollTop = nextTop;
      const reachedTarget = Math.abs(targetTop - scroller.scrollTop) <= 0.75;
      if (progress >= 1 && reachedTarget) finishScrollMotion(active);
      else streamMotion.frame = scheduleVisualFrame(step);
    };
    streamMotion.frame = scheduleVisualFrame(step);
  }

  function inputSelectionKey(element) {
    if (element?.matches("[data-correction-input]")) return "correction";
    if (element?.matches("[data-response-input]")) return `response-${element.dataset.responseInput}`;
    return "";
  }

  function rememberInputSelection(element) {
    const key = inputSelectionKey(element);
    if (!key || typeof element.selectionStart !== "number") return;
    view.inputSelections[key] = {
      start: element.selectionStart,
      end: element.selectionEnd,
      direction: element.selectionDirection || "none",
    };
  }

  function restoreInputSelections() {
    document.querySelectorAll("[data-response-input], [data-correction-input]").forEach((element) => {
      const selection = view.inputSelections[inputSelectionKey(element)];
      if (!selection || typeof element.setSelectionRange !== "function") return;
      const length = element.value.length;
      element.setSelectionRange(
        Math.min(selection.start, length),
        Math.min(selection.end, length),
        selection.direction,
      );
    });
  }

  function rememberAllInputSelections() {
    document.querySelectorAll("[data-response-input], [data-correction-input]").forEach(rememberInputSelection);
  }

  function captureFocusSelector() {
    const active = document.activeElement;
    if (!active || active === document.body) return "";
    if (active.matches("[data-response-input]")) return `[data-response-input="${active.dataset.responseInput}"]`;
    if (active.matches("[data-correction-input]")) return "[data-correction-input]";
    if (!active.dataset.action) return "";
    let selector = `[data-action="${active.dataset.action}"]`;
    ["kind", "value", "entryId", "segment", "bundle"].forEach((key) => {
      if (active.dataset[key]) selector += `[data-${key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}="${active.dataset[key]}"]`;
    });
    return selector;
  }

  function render() {
    rememberAllInputSelections();
    const capturedFocusSelector = captureFocusSelector();
    const explicitFocusSelector = view.pendingFocusSelector;
    view.pendingFocusSelector = "";
    const motion = view.pendingScrollMotion;
    view.pendingScrollMotion = null;
    if (streamMotion.active || streamMotion.frame) cancelScrollMotion("render");
    const query = currentQuery();
    view.panel = query.panel;
    const anchoredEntry = state.entries.find((entry) => entry.id === query.entry);
    if (anchoredEntry) {
      view.cursorEntryId = anchoredEntry.id;
      view.locatedEntryId = anchoredEntry.id;
      view.followTail = false;
      expandEntryContainer(anchoredEntry.id);
    } else {
      view.cursorEntryId = null;
      view.locatedEntryId = null;
    }
    const projection = projectSession();
    const activeId = projection.canonicalHead?.id || "";
    const wasMounted = view.shellMounted;
    const oldScroller = document.querySelector("[data-stream-scroll]");
    const variantChanged = Boolean(view.renderedVariant) && view.renderedVariant !== query.variant;
    const preserveAnchor = view.pendingLayoutAnchor || motion?.origin || captureViewportAnchor();
    view.pendingLayoutAnchor = null;
    if (variantChanged && preserveAnchor.entryId) expandEntryContainer(preserveAnchor.entryId);
    view.restoringViewport = !wasMounted || variantChanged;
    if (motion && oldScroller) oldScroller.dataset.scrollMotionState = "preparing";
    if (!wasMounted) {
      app.innerHTML = `<div class="mac-window stream-window" data-variant="${query.variant}">
        ${sidebar()}
        <main class="app-main"><div class="native-page stream-page" data-stream-session data-session-id="${state.sessionId}" data-active-node-id="${activeId}" data-plan-state="${projection.planState}" data-run-id="${projection.activeRun?.runId || ""}" data-run-state="${projection.activeRun?.status || "idle"}" data-run-integrity="${escapeHTML(projection.runIntegrityError)}">
          ${pageHeader(projection)}
          <div class="native-columns"><div class="stream-scroll" data-stream-scroll data-scroll-motion-state="idle"><div class="stream-log" data-stream-log>${renderStream(query.variant, projection)}</div></div>${detailRail(projection)}</div>
          <button class="return-current${view.cursorEntryId || view.userOwnsScroll || view.unseenLiveEntries || view.returningToTail ? " visible" : ""}" type="button" data-action="return-current" data-return-current data-unseen-count="${view.unseenLiveEntries}">${returnCurrentCopy()}</button>
        </div></main>
        <div class="toast-host" data-toast-host></div>
        <div class="stream-motion-status" data-stream-motion-status aria-live="polite" aria-atomic="true"></div>
      </div>`;
      view.shellMounted = true;
      attachScrollBehaviour();
    } else {
      const windowElement = document.querySelector(".mac-window");
      const session = document.querySelector("[data-stream-session]");
      windowElement.dataset.variant = query.variant;
      session.dataset.activeNodeId = activeId;
      session.dataset.planState = projection.planState;
      session.dataset.runId = projection.activeRun?.runId || "";
      session.dataset.runState = projection.activeRun?.status || "idle";
      session.dataset.runIntegrity = projection.runIntegrityError;
      // Keep the open menu node and its keyboard focus stable while live
      // records repaint the stream. Closing or choosing a layout refreshes the
      // Header with the latest run controls and event count.
      if (!view.layoutMenuOpen) document.querySelector(".stream-page-header").outerHTML = pageHeader(projection);
      document.querySelector("[data-stream-log]").innerHTML = renderStream(query.variant, projection);
      document.querySelector(".stream-detail-rail").outerHTML = detailRail(projection);
      const returnButton = document.querySelector("[data-return-current]");
      returnButton.textContent = returnCurrentCopy();
      returnButton.dataset.unseenCount = String(view.unseenLiveEntries);
      returnButton.classList.toggle("visible", Boolean(view.cursorEntryId) || view.userOwnsScroll || Boolean(view.unseenLiveEntries) || view.returningToTail);
      restoreViewportAnchor(oldScroller, preserveAnchor);
    }
    // Restore the draft selection in the same task as the DOM replacement. A
    // fast second action (for example choosing a layout option immediately
    // after opening the menu) must not observe the replacement input's 0/0
    // selection and overwrite the user's saved caret range.
    restoreInputSelections();
    view.renderedVariant = query.variant;
    renderToast();
    view.renderGeneration += 1;
    const generation = view.renderGeneration;
    const focusSelector = motion ? explicitFocusSelector : (explicitFocusSelector || capturedFocusSelector);
    const scroller = document.querySelector("[data-stream-scroll]");
    if (motion) {
      scroller.dataset.scrollMotionState = "preparing";
      streamMotion.preparingMotion = motion;
      streamMotion.frame = scheduleVisualFrame(() => {
        if (generation !== view.renderGeneration) return;
        streamMotion.frame = scheduleVisualFrame(() => {
          view.restoringViewport = false;
          restoreInputSelections();
          startScrollMotion(motion, focusSelector, generation);
        });
      });
      updateReturnCurrentVisibility();
      return;
    }
    scheduleVisualFrame(() => {
      scheduleVisualFrame(() => {
        if (generation !== view.renderGeneration) return;
        if (!wasMounted) {
          if (view.cursorEntryId) {
            const target = document.getElementById(view.cursorEntryId);
            if (target) setScrollTopImmediately(scroller, topWithinScroller(target, scroller) - (scroller.clientHeight * 0.3));
          } else if (query.scroll === "top") {
            setScrollTopImmediately(scroller, 0);
            view.followTail = false;
            view.userOwnsScroll = true;
            view.passiveContextEntryId = captureViewportAnchor().entryId;
            refreshPassiveContextRail();
          } else if (query.scroll === "bottom") setScrollTopImmediately(scroller, scroller.scrollHeight);
          else if (view.followTail) setScrollTopImmediately(scroller, currentContextTop(scroller, query.variant));
        }
        updateReturnCurrentVisibility();
        restoreInputSelections();
        if (focusSelector) document.querySelector(focusSelector)?.focus({ preventScroll: true });
        view.restoringViewport = false;
      });
    });
  }

  function appendComparison() {
    const checkpoint = activeCheckpoint("focus");
    if (!checkpoint) return false;
    const request = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "focus",
      title: "先补齐两条路径的比较",
      summary: "这是一项调查请求，不是对第一条路径的最终取舍。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "comparison-request" },
    });
    const comparison = appendEntry({
      actor: "zhulong",
      kind: "artifact",
      stage: "focus",
      title: "两条路径的验证面已经补齐",
      summary: "任务成形先验证模糊任务进入 Todo；每日收尾先验证承诺、实际与明日计划闭环。",
      points: ["共享：会话、事件、权限、diff", "差异：触发情境与最终回执", "仍需用户选择第一条完整路径"],
      dependsOn: [request.id],
      details: { artifactType: "comparison" },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "focus",
      title: "比较已经补齐，现在先完整交付哪一条？",
      summary: "烛龙不会把“先比较”伪装成已经作出的产品取舍。",
      dependsOn: [comparison.id],
      details: { checkpointType: "decision" },
    });
    return true;
  }

  function keepGateUnresolved() {
    const checkpoint = activeCheckpoint("gate");
    if (!checkpoint) return false;
    const resolution = appendEntry({
      actor: "user",
      kind: "resolution",
      stage: "gate",
      title: "暂时保留未决",
      summary: "不形成近期 Todo 草稿，也不消费新的规划授权。",
      dependsOn: [checkpoint.id],
      details: { resolves: checkpoint.id, resolutionType: "pause" },
    });
    const paused = appendEntry({
      actor: "system",
      kind: "activity",
      stage: "gate",
      title: "规划运行保持暂停",
      summary: "原有记录与输入已经保存在本机；没有静默继续。",
      dependsOn: [resolution.id],
      details: { activityType: "paused" },
    });
    appendEntry({
      actor: "zhulong",
      kind: "checkpoint",
      stage: "gate",
      title: "证据条件变化后，再决定怎样继续",
      summary: "可以继续保留未决，也可以在取得测量后追加新的处置决定。",
      dependsOn: [paused.id],
      details: { checkpointType: "decision" },
    });
    return true;
  }

  function confirmCurrent() {
    const projection = projectSession();
    const active = projection.activeCheckpoint;
    if (!active) {
      showToast("当前没有可确认的检查点。");
      return;
    }
    const motionOrigin = captureViewportAnchor(active.id);
    const motionSourceId = active.id;
    const stage = active.stage;
    let changed = false;
    let message = "记录已经追加。";

    if (stage === "focus") {
      const selected = view.selected.focus;
      const text = view.responseText.focus.trim();
      if (!selected && !text) {
        showToast("先选择一项或写下你的判断；空回答不会追加到记录。");
        return;
      }
      if (selected === "compare" && !text) {
        changed = appendComparison();
        message = "比较材料已经追加；第一条路径仍等待你的取舍。";
      } else {
        changed = resolveFocus(selected || "custom", text);
        message = "用户取舍与活简报新版本已经追加。";
      }
    } else if (stage === "criteria") {
      const selected = view.selected.criteria;
      const text = view.responseText.criteria.trim();
      if (!selected && !text) {
        showToast("先确认最低完成标准；烛龙不会替你猜一个标准。");
        return;
      }
      changed = resolveCriteria(selected || "custom", text);
      message = "完成标准与规划简报已经追加。";
    } else if (stage === "brief") {
      changed = delegatePlanning();
      message = "一次性规划委托已经追加；Todo 写入仍未授权。";
    } else if (stage === "run") {
      changed = beginLiveRun("gate");
      message = "运行授权已经追加；后续记录会在真实形成后逐条进入。";
    } else if (stage === "gate") {
      const selected = view.selected.gate;
      const text = view.responseText.gate.trim();
      if (!selected && !text) {
        showToast("先选择处置方式或写下限制；证据不足时不会自行继续。");
        return;
      }
      if (selected === "range" && !text) {
        showToast("请写明你确认的工作量区间与可投入时间；烛龙不会补造这个依据。");
        return;
      }
      if (selected === "unresolved" && !text) {
        changed = keepGateUnresolved();
        message = "保留未决与暂停回执已经追加；规划没有继续。";
      } else {
        changed = resolveGate(selected || "custom", text);
        message = "证据不足处置与简报修订已经追加；旧委托不再生效。";
      }
    } else if (stage === "amendment") {
      changed = beginLiveRun("draft");
      message = "新委托已经追加；剩余步骤与计划会逐条形成。";
    } else if (stage === "draft") {
      changed = openTodoDiff();
      message = "Todo diff 已追加；写入仍等待当前批次授权。";
    } else if (stage === "apply") {
      changed = applyTodoDiff();
      message = changed ? "Todo 批次与结果回执已经原子追加。" : "当前写入能力已经失效，不能应用。";
    } else if (stage === "receipt") {
      showToast("本次授权已经结束；可以归档或继续查看记录。");
      return;
    }

    if (!changed) {
      showToast("当前检查点没有改变；旧能力没有被恢复。");
      return;
    }
    if (view.selected[stage] !== undefined) view.selected[stage] = "";
    if (view.responseText[stage] !== undefined) view.responseText[stage] = "";
    const targetRole = projectSession().activeRun ? "tail" : "current";
    queueScrollMotion({
      kind: "advance",
      targetRole,
      sourceId: motionSourceId,
      direction: "forward",
    }, motionOrigin);
    markFollowTail();
    render();
    if (!["run", "amendment"].includes(stage)) showToast(message);
  }

  function locatePrevious(explicitTarget = "") {
    const projection = projectSession();
    const target = explicitTarget
      ? state.entries.find((entry) => entry.id === explicitTarget)
      : previousCheckpoint(projection);
    if (!target) {
      showToast("当前已经是最早的用户检查点。");
      return;
    }
    const sourceId = view.locatedEntryId || projection.canonicalHead?.id || "";
    const motionOrigin = captureViewportAnchor(sourceId);
    queueScrollMotion({
      kind: "visit-previous",
      targetRole: "entry",
      targetId: target.id,
      sourceId,
      direction: "backward",
    }, motionOrigin);
    view.followTail = false;
    view.cursorEntryId = target.id;
    view.locatedEntryId = target.id;
    view.panel = "context";
    expandEntryContainer(target.id);
    replaceQuery({ entry: target.id, panel: "context" });
    render();
  }

  function correctionDefaultTarget() {
    const projection = projectSession();
    return [...state.entries]
      .reverse()
      .find((entry) => entry.kind === "checkpoint" && ["focus", "criteria", "gate"].includes(entry.stage) && projection.resolved.has(entry.id) && !projection.invalidatedBy.has(entry.id));
  }

  function startCorrection(entryId = "") {
    if (projectSession().activeRun) {
      showToast("当前规划运行尚未结束；先暂停查看，待本轮安全结束后再从旧决定追加更正。");
      return;
    }
    const target = state.entries.find((entry) => entry.id === entryId) || correctionDefaultTarget();
    if (!target || target.kind !== "checkpoint") {
      showToast("当前还没有可以更正的旧决定。");
      return;
    }
    const motionOrigin = captureViewportAnchor(target.id);
    queueScrollMotion({
      kind: "start-correction",
      targetRole: "correction",
      sourceId: target.id,
      direction: "forward",
    }, motionOrigin);
    view.correctionTargetId = target.id;
    view.correctionText = "";
    view.pendingFocusSelector = "[data-correction-input]";
    markFollowTail();
    render();
  }

  function selectVariant(variant) {
    if (!Object.hasOwn(variants, variant)) return false;
    const previousVariant = currentQuery().variant;
    try {
      window.localStorage.setItem(variantPreferenceKey, variant);
    } catch (_error) {
      // URL remains the shareable source when browser storage is unavailable.
    }
    view.layoutMenuOpen = false;
    if (variant === previousVariant) {
      replaceQuery({ variant });
      refreshPageHeader("[data-layout-trigger]");
      return true;
    }
    const interruptedMotion = streamMotion.active?.motion || streamMotion.preparingMotion || view.pendingScrollMotion;
    const anchor = captureViewportAnchor();
    cancelScrollMotion("layout-change");
    if (anchor.entryId) expandEntryContainer(anchor.entryId);
    view.pendingLayoutAnchor = anchor;
    view.pendingFocusSelector = "[data-layout-trigger]";
    if (interruptedMotion) {
      if (interruptedMotion.targetId) expandEntryContainer(interruptedMotion.targetId);
      view.pendingScrollMotion = {
        ...interruptedMotion,
        sourceId: anchor.entryId || interruptedMotion.sourceId,
        origin: { ...anchor, entryId: anchor.entryId || interruptedMotion.sourceId },
      };
    }
    replaceQuery({ variant });
    render();
    return true;
  }

  document.addEventListener("click", (event) => {
    if (view.layoutMenuOpen && !event.target.closest("[data-layout-picker]")) {
      view.layoutMenuOpen = false;
      refreshPageHeader();
    }
    const element = event.target.closest("button, [data-action]");
    if (!element || element.disabled) return;
    const action = element.dataset.action;

    if (element.dataset.notice) {
      showToast(element.dataset.notice);
      return;
    }
    if (!action) return;
    if (["pause-session", "resume-run", "cancel-run"].includes(action) && event.detail > 1) return;

    if (action === "choose") {
      view.selected[element.dataset.kind] = element.dataset.value;
      render();
    } else if (action === "confirm-current") {
      confirmCurrent();
    } else if (action === "visit-previous") {
      locatePrevious(element.dataset.returnTarget || "");
    } else if (action === "return-current") {
      const sourceId = view.locatedEntryId || captureViewportAnchor().entryId;
      const motionOrigin = captureViewportAnchor(sourceId);
      const targetRole = projectSession().activeRun ? "tail" : "current";
      view.returningToTail = true;
      queueScrollMotion({
        kind: "return-current",
        targetRole,
        sourceId,
        direction: "forward",
      }, motionOrigin);
      view.cursorEntryId = null;
      view.locatedEntryId = null;
      replaceQuery({ entry: "" });
      render();
    } else if (action === "inspect-entry") {
      const entryId = element.dataset.entryId;
      if (!state.entries.some((entry) => entry.id === entryId)) return;
      const projection = projectSession();
      const sourceId = view.locatedEntryId || projection.canonicalHead?.id || captureViewportAnchor().entryId;
      const sourceSequence = state.entries.find((entry) => entry.id === sourceId)?.sequence || Number.POSITIVE_INFINITY;
      const targetSequence = state.entries.find((entry) => entry.id === entryId)?.sequence || 0;
      const motionOrigin = captureViewportAnchor(sourceId);
      queueScrollMotion({
        kind: "inspect-entry",
        targetRole: "entry",
        targetId: entryId,
        sourceId,
        direction: targetSequence < sourceSequence ? "backward" : "forward",
      }, motionOrigin);
      view.cursorEntryId = entryId;
      view.locatedEntryId = entryId;
      view.followTail = false;
      view.panel = "context";
      expandEntryContainer(entryId);
      replaceQuery({ panel: "context", entry: entryId });
      render();
    } else if (action === "inspect-current") {
      if (view.cursorEntryId) {
        const motionOrigin = captureViewportAnchor(view.cursorEntryId);
        queueScrollMotion({
          kind: "inspect-current",
          targetRole: projectSession().activeRun ? "tail" : "current",
          sourceId: view.cursorEntryId,
          direction: "forward",
        }, motionOrigin);
      }
      view.cursorEntryId = null;
      view.locatedEntryId = null;
      view.panel = "context";
      replaceQuery({ panel: "context", entry: "" });
      render();
    } else if (action === "toggle-entry") {
      const entryId = element.dataset.entryId;
      if (view.expandedEntries.has(entryId)) view.expandedEntries.delete(entryId);
      else view.expandedEntries.add(entryId);
      render();
    } else if (action === "toggle-segment") {
      const segment = element.dataset.segment;
      if (view.expandedSegments.has(segment)) view.expandedSegments.delete(segment);
      else view.expandedSegments.add(segment);
      render();
    } else if (action === "toggle-chapter-prior") {
      const segment = element.dataset.segment;
      if (view.expandedSegments.has(segment)) view.expandedSegments.delete(segment);
      else view.expandedSegments.add(segment);
      render();
    } else if (action === "toggle-bundle") {
      const bundle = element.dataset.bundle;
      if (view.expandedSegments.has(bundle)) view.expandedSegments.delete(bundle);
      else view.expandedSegments.add(bundle);
      render();
    } else if (action === "start-correction") {
      startCorrection(element.dataset.entryId || "");
    } else if (action === "cancel-correction") {
      const motionOrigin = captureViewportAnchor();
      queueScrollMotion({
        kind: "cancel-correction",
        targetRole: "current",
        sourceId: motionOrigin.entryId,
        direction: "backward",
      }, motionOrigin);
      view.correctionTargetId = null;
      view.correctionText = "";
      render();
    } else if (action === "confirm-correction") {
      if (!view.correctionText.trim()) {
        showToast("先写明新的准确表达；空更正不会进入历史。");
        return;
      }
      const motionOrigin = captureViewportAnchor();
      const target = view.correctionTargetId;
      const text = view.correctionText;
      if (!appendCorrection(target, text)) {
        showToast("更正没有追加；目标检查点已经不可用。");
        return;
      }
      queueScrollMotion({
        kind: "confirm-correction",
        targetRole: "current",
        sourceId: motionOrigin.entryId,
        direction: "forward",
      }, motionOrigin);
      markFollowTail();
      render();
      showToast("更正、失效回执和重新打开的检查点已经依次追加。旧记录没有被覆盖。");
    } else if (action === "open-events") {
      view.panel = "events";
      replaceQuery({ panel: "events" });
      render();
    } else if (action === "open-session") {
      view.panel = "session";
      replaceQuery({ panel: "session" });
      render();
    } else if (action === "close-panel") {
      if (view.cursorEntryId) {
        const motionOrigin = captureViewportAnchor(view.cursorEntryId);
        queueScrollMotion({
          kind: "close-selected-context",
          targetRole: projectSession().activeRun ? "tail" : "current",
          sourceId: view.cursorEntryId,
          direction: "forward",
        }, motionOrigin);
      }
      view.panel = "";
      view.cursorEntryId = null;
      view.locatedEntryId = null;
      replaceQuery({ panel: "", entry: "" });
      render();
    } else if (action === "pause-session") {
      if (projectSession().activeRun) {
        if (!pauseLiveRun()) showToast("运行控制正在结算上一操作，请稍后再试。");
      } else {
        showToast("会话 head 与完整记录已保存在本机；当前没有正在执行的规划运行。");
      }
    } else if (action === "resume-run") {
      if (!resumeLiveRun()) showToast("当前运行不能继续，或运行控制正在结算上一操作。");
    } else if (action === "cancel-run") {
      if (!cancelLiveRun()) showToast("当前没有可以终止的运行，或终止请求已经生效。");
    } else if (action === "finish-session") {
      showToast("Prototype：会话已经归档；已应用 Todo 与事件引用保持不变。");
    } else if (action === "toggle-layout-menu") {
      view.layoutMenuOpen = !view.layoutMenuOpen;
      const focusSelector = view.layoutMenuOpen
        ? `[data-layout-option][data-value="${currentQuery().variant}"]`
        : "[data-layout-trigger]";
      refreshPageHeader(focusSelector);
    } else if (action === "set-variant") {
      selectVariant(element.dataset.value);
    }
  });

  document.addEventListener("input", (event) => {
    if (event.target.matches("[data-correction-input]")) {
      view.correctionText = event.target.value;
      rememberInputSelection(event.target);
      return;
    }
    if (event.target.matches("[data-response-input]")) {
      view.responseText[event.target.dataset.responseInput] = event.target.value;
      rememberInputSelection(event.target);
    }
  });

  document.addEventListener("select", (event) => rememberInputSelection(event.target));

  document.addEventListener("keydown", (event) => {
    if (view.layoutMenuOpen && event.key === "Escape") {
      event.preventDefault();
      view.layoutMenuOpen = false;
      refreshPageHeader("[data-layout-trigger]");
      return;
    }
    if (view.layoutMenuOpen
      && event.target.closest("[data-layout-picker]")
      && ["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
      const options = [...document.querySelectorAll("[data-layout-option]")];
      const currentIndex = Math.max(0, options.indexOf(document.activeElement));
      const nextIndex = event.key === "Home"
        ? 0
        : event.key === "End"
          ? options.length - 1
          : (currentIndex + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length;
      event.preventDefault();
      options[nextIndex]?.focus();
      return;
    }
    if (view.layoutMenuOpen
      && event.target.matches("[data-layout-option]")
      && ["Enter", " "].includes(event.key)) {
      event.preventDefault();
      selectVariant(event.target.dataset.value);
      return;
    }
    const editing = Boolean(event.target.closest("input, textarea, [contenteditable]"));
    const motionCancelKeys = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " ", "Escape"]);
    if ((streamMotion.active || view.pendingScrollMotion)
      && (motionCancelKeys.has(event.key) || (!editing && ["ArrowLeft", "ArrowRight"].includes(event.key)))) {
      cancelScrollMotion("user");
      if (event.key === "Escape") event.preventDefault();
      return;
    }
  });

  window.addEventListener("popstate", () => {
    const nextQuery = currentQuery();
    const previousEntryId = view.cursorEntryId || "";
    if (nextQuery.entry !== previousEntryId) {
      const projection = projectSession();
      const sourceId = previousEntryId || projection.canonicalHead?.id || captureViewportAnchor().entryId;
      const origin = captureViewportAnchor(sourceId);
      if (nextQuery.entry) {
        const sourceSequence = state.entries.find((entry) => entry.id === sourceId)?.sequence || Number.POSITIVE_INFINITY;
        const targetSequence = state.entries.find((entry) => entry.id === nextQuery.entry)?.sequence || 0;
        queueScrollMotion({
          kind: "history-entry",
          targetRole: "entry",
          targetId: nextQuery.entry,
          sourceId,
          direction: targetSequence < sourceSequence ? "backward" : "forward",
        }, origin);
      } else {
        queueScrollMotion({
          kind: "history-current",
          targetRole: projection.activeRun ? "tail" : "current",
          sourceId,
          direction: "forward",
        }, origin);
      }
    }
    view.panel = nextQuery.panel;
    render();
  });

  seedScenario(launchScenario);
  if (state.motionDemo) {
    dossierUnits(projectSession())
      .filter((unit) => unit.type === "bundle")
      .forEach((unit) => view.expandedSegments.add(unit.key));
  }
  render();
})();
