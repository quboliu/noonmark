import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import {
    APIError,
    errorMessage,
    getReceipt,
    getSnapshot,
    request,
    submit,
} from "./api";
import { Settings } from "./Settings";
import { usePreferences } from "./preferences";
import {
    Calendar,
    DateStrip,
    DaySummary,
    InlineTask,
    PoolPicker,
    visibleTrace,
} from "./Workspace";
import { clearDrafts, draftScope } from "./drafts";
import { Flylight, Review } from "./Notes";
import { NewTask, TaskDetail, TaskList } from "./Tasks";
import type { Chain, Command, Snapshot, Trace } from "./types";
import {
    Icon,
    Modal,
    UIStatus,
    compositionKeyGuard,
    dateLabel,
    nextDate,
} from "./ui";
import type { IconName } from "./ui";

type View =
    | "day"
    | "pool"
    | "future"
    | "completed"
    | "unfinished"
    | "ideas"
    | "sticky"
    | "calendar";
const navigation: {
    view: View;
    label: string;
    icon: IconName;
    section?: string;
}[] = [
    { view: "day", label: "Day Todo", icon: "clock", section: "计划" },
    { view: "pool", label: "任务池", icon: "pool" },
    { view: "future", label: "未来计划", icon: "calendar" },
    { view: "unfinished", label: "未完成", icon: "clock", section: "轨迹" },
    { view: "completed", label: "已完成", icon: "check" },
    { view: "calendar", label: "日历", icon: "calendar" },
    { view: "sticky", label: "Sticky Note", icon: "review", section: "札记" },
    { view: "ideas", label: "飞光", icon: "spark" },
];
const descriptions: Record<View, string> = {
    day: "",
    pool: "尚未安排日期的任务。排期后会出现在对应的 Day Todo。",
    future: "已安排在未来的任务，按日期查看。",
    completed: "已经完成的任务与子任务，保留真实的完成轨迹。",
    unfinished: "按任务链去重的未完成轨迹。延续它，或明确废弃。",
    ideas: "先记下来，再决定它要去哪里。",
    sticky: "把值得反复看见的内容，留在手边。",
    calendar: "",
};
const identity = (snapshot: Snapshot) =>
    `${snapshot.instance_id}:${snapshot.instance_epoch}:${snapshot.dataset_id}:${snapshot.owner_id}`;
function pendingKey(snapshot: Snapshot) {
    return `noonmark.pending:${draftScope(snapshot)}`;
}

export default function App() {
    const [token, setToken] = useState<string | null>(null);
    const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
    const [view, setView] = useState<View>("day");
    const [date, setDate] = useState("");
    const [mobileMenu, setMobileMenu] = useState(false);
    const [newTask, setNewTask] = useState(false);
    const [selected, setSelected] = useState<{
        chainID: string;
        traceID?: string;
    } | null>(null);
    const [busy, setBusy] = useState(false);
    const [connected, setConnected] = useState(true);
    const busyRef = useRef(busy);
    busyRef.current = busy;
    const [error, setError] = useState("");
    const [notice, setNotice] = useState("");
    const [unknownChecked, setUnknownChecked] = useState(false);
    const [unknown, setUnknown] = useState<{
        id: string;
        command?: Command;
    } | null>(null);
    const [logoutOpen, setLogoutOpen] = useState(false);
    const [keepDrafts, setKeepDrafts] = useState(false);
    const [query, setQuery] = useState("");
    const [settingsOpen, setSettingsOpen] = useState(false);
    const [compact, setCompact] = useState(false);
    const [railOpen, setRailOpen] = useState(false);
    const [poolPicker, setPoolPicker] = useState(false);
    const [sort, setSort] = useState("priority");
    const [sourceIdea, setSourceIdea] = useState<string>();
    const [narrow, setNarrow] = useState(
        () => matchMedia("(max-width:700px)").matches,
    );
    const mainRef = useRef<HTMLElement>(null);
    const mobileTrigger = useRef<HTMLButtonElement>(null);
    const sidebarRef = useRef<HTMLElement>(null);
    const railRef = useRef<HTMLElement>(null);
    const detailTrigger = useRef<HTMLElement | null>(null);
    const touchOrigin = useRef<{ x: number; y: number } | null>(null);
    const { preferences, updatePreference, storageError } = usePreferences(
        snapshot ? `${snapshot.instance_id}:${snapshot.owner_id}` : "",
    );
    const authenticated = Boolean(token && snapshot);
    useEffect(() => {
        document.documentElement.dataset.theme = preferences.theme;
    }, [preferences.theme]);
    useEffect(() => {
        const query = matchMedia("(max-width:700px)");
        const changed = () => setNarrow(query.matches);
        query.addEventListener("change", changed);
        return () => query.removeEventListener("change", changed);
    }, []);
    useEffect(() => {
        if (!authenticated || !railOpen || !narrow) return;
        const opener = document.activeElement as HTMLElement | null;
        railRef.current?.querySelector<HTMLButtonElement>("button")?.focus();
        const key = (event: KeyboardEvent) => {
            if (event.isComposing || document.querySelector("dialog[open]"))
                return;
            if (event.key === "Escape" && !busyRef.current) {
                setRailOpen(false);
                setSelected(null);
            }
            if (event.key !== "Tab") return;
            const controls = [
                ...(railRef.current?.querySelectorAll<HTMLElement>(
                    'button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),[tabindex="0"]',
                ) ?? []),
            ].filter(
                (el) =>
                    el.getClientRects().length > 0 && !el.matches(":disabled"),
            );
            const first = controls[0];
            const last = controls.at(-1);
            if (
                event.shiftKey &&
                (document.activeElement === first ||
                    !controls.includes(document.activeElement as HTMLElement))
            ) {
                event.preventDefault();
                last?.focus();
            } else if (!event.shiftKey && document.activeElement === last) {
                event.preventDefault();
                first?.focus();
            }
        };
        window.addEventListener("keydown", key);
        return () => {
            window.removeEventListener("keydown", key);
            if (opener?.isConnected) opener.focus();
        };
    }, [authenticated, railOpen, narrow]);
    useEffect(() => {
        if (mobileMenu)
            sidebarRef.current
                ?.querySelector<HTMLButtonElement>(".nav-item")
                ?.focus();
        const handle = (event: KeyboardEvent) => {
            if (event.key === "Escape" && mobileMenu) {
                setMobileMenu(false);
                mobileTrigger.current?.focus();
            }
            if (event.key !== "Tab" || !mobileMenu) return;
            const buttons = [
                ...(sidebarRef.current?.querySelectorAll<HTMLButtonElement>(
                    "button:not([disabled])",
                ) ?? []),
            ].filter(
                (el) =>
                    el.getClientRects().length > 0 && !el.matches(":disabled"),
            );
            const first = buttons[0];
            const last = buttons.at(-1);
            if (event.shiftKey && document.activeElement === first) {
                event.preventDefault();
                last?.focus();
            } else if (!event.shiftKey && document.activeElement === last) {
                event.preventDefault();
                first?.focus();
            }
        };
        window.addEventListener("keydown", handle);
        return () => window.removeEventListener("keydown", handle);
    }, [mobileMenu]);
    const snapshotRef = useRef(snapshot);
    const tokenRef = useRef(token);
    const inFlight = useRef(false);
    const refreshVersion = useRef(0);
    snapshotRef.current = snapshot;
    tokenRef.current = token;
    const clearSessionUI = useCallback(() => {
        setRailOpen(false);
        setMobileMenu(false);
        setSettingsOpen(false);
        setPoolPicker(false);
        setLogoutOpen(false);
        setSelected(null);
        setNewTask(false);
        setSourceIdea(undefined);
    }, []);
    const expire = useCallback(
        (message: string) => {
            tokenRef.current = null;
            setToken(null);
            setSnapshot(null);
            clearSessionUI();
            setError(message);
        },
        [clearSessionUI],
    );
    const refresh = useCallback(
        async (auth: string) => {
            const requestVersion = ++refreshVersion.current;
            try {
                const next = await getSnapshot(auth);
                if (
                    tokenRef.current !== auth ||
                    requestVersion !== refreshVersion.current
                )
                    return;
                if (
                    snapshotRef.current &&
                    identity(snapshotRef.current) !== identity(next)
                ) {
                    expire("实例资料已变更，请重新登录。旧输入不会自动提交。");
                    return;
                }
                if (next.schema_version !== 1) {
                    expire("此页面版本与服务器不兼容，请刷新页面。");
                    return;
                }
                const previousToday = snapshotRef.current?.today;
                snapshotRef.current = next;
                setSnapshot(next);
                setConnected(true);
                setDate((current) =>
                    !current || current === previousToday
                        ? next.today
                        : current,
                );
            } catch (cause) {
                if (tokenRef.current !== auth) return;
                if (cause instanceof APIError && cause.status === 401)
                    expire(errorMessage(cause));
                else {
                    setConnected(false);
                    throw cause;
                }
            }
        },
        [expire],
    );
    useEffect(() => {
        if (!token) return;
        let stopped = false;
        let timer: ReturnType<typeof setTimeout> | undefined;
        const controller = new AbortController();
        const updates = async () => {
            while (!stopped) {
                try {
                    const response = await fetch("/api/v1/events", {
                        headers: { Authorization: `Bearer ${token}` },
                        credentials: "omit",
                        cache: "no-store",
                        signal: controller.signal,
                    });
                    if (response.status === 401) {
                        expire("登录已失效，请重新登录。输入草稿会保留。");
                        return;
                    }
                    if (!response.ok || !response.body)
                        throw new Error("EVENT_STREAM_UNAVAILABLE");
                    const reader = response.body.getReader();
                    const decoder = new TextDecoder();
                    let buffer = "";
                    while (!stopped) {
                        const part = await reader.read();
                        if (part.done) break;
                        buffer += decoder.decode(part.value, { stream: true });
                        if (buffer.length > 100_000)
                            throw new Error("EVENT_TOO_LARGE");
                        const lines = buffer.split("\n");
                        buffer = lines.pop() ?? "";
                        for (const line of lines) {
                            if (line.startsWith("data:")) {
                                const update = JSON.parse(line.slice(5)) as {
                                    sequence?: string;
                                };
                                if (
                                    update.sequence &&
                                    update.sequence !==
                                        snapshotRef.current?.sequence
                                )
                                    void refresh(token).catch(() => {});
                            }
                        }
                    }
                } catch {
                    /* 已由定期一致读确认连接；流消息只作刷新提示。 */
                }
                if (!stopped)
                    await new Promise<void>((resolve) => {
                        timer = setTimeout(resolve, 3000);
                    });
            }
        };
        void updates();
        const poll = setInterval(() => {
            if (!document.hidden) void refresh(token).catch(() => {});
        }, 5000);
        const onVisible = () => {
            if (!document.hidden) void refresh(token).catch(() => {});
        };
        window.addEventListener("online", onVisible);
        document.addEventListener("visibilitychange", onVisible);
        return () => {
            stopped = true;
            controller.abort();
            clearTimeout(timer);
            clearInterval(poll);
            window.removeEventListener("online", onVisible);
            document.removeEventListener("visibilitychange", onVisible);
        };
    }, [token, refresh, expire]);
    useEffect(() => {
        const quickEntry = (event: KeyboardEvent) => {
            if (
                preferences.shortcutsEnabled &&
                token &&
                (event.metaKey || event.ctrlKey) &&
                event.key.toLowerCase() === "k" &&
                !event.isComposing &&
                !document.querySelector("dialog[open]")
            ) {
                event.preventDefault();
                setNewTask(true);
            }
        };
        window.addEventListener("keydown", quickEntry);
        return () => window.removeEventListener("keydown", quickEntry);
    }, [token, preferences.shortcutsEnabled]);
    const login = async (password: string) => {
        setError("");
        try {
            const session = await request<{
                token: string;
                expires_at: number;
            }>("/api/v1/auth/login", undefined, { password });
            tokenRef.current = session.token;
            const next = await getSnapshot(session.token);
            if (next.schema_version !== 1)
                throw new APIError("SCHEMA_UNSUPPORTED", 409);
            snapshotRef.current = next;
            setSnapshot(next);
            setToken(session.token);
            setConnected(true);
            setDate((current) => current || next.today);
            try {
                const pending = localStorage.getItem(pendingKey(next));
                setUnknown(pending ? { id: pending } : null);
                setUnknownChecked(false);
            } catch {
                setUnknown(null);
            }
            return true;
        } catch (cause) {
            setError(
                cause instanceof APIError && cause.status === 401
                    ? "密码不正确，请重试。"
                    : errorMessage(cause),
            );
            return false;
        }
    };
    const markUnknown = (command: Command) => {
        setUnknown({ id: command.command_id, command });
        setUnknownChecked(false);
        if (snapshotRef.current) {
            try {
                localStorage.setItem(
                    pendingKey(snapshotRef.current),
                    command.command_id,
                );
            } catch {
                setNotice("请保持页面打开，以便核对这次提交结果。");
            }
        }
    };
    const clearUnknown = () => {
        if (snapshotRef.current) {
            try {
                localStorage.removeItem(pendingKey(snapshotRef.current));
            } catch {
                /* 仅影响下一次结果提示。 */
            }
        }
        setUnknown(null);
        setUnknownChecked(false);
    };
    const execute = async (
        type: string,
        revision: string,
        payload: Record<string, unknown>,
    ) => {
        const current = snapshotRef.current;
        const auth = tokenRef.current;
        if (!current || !auth || inFlight.current || unknown || !connected)
            return false;
        const command: Command = {
            instance_id: current.instance_id,
            instance_epoch: current.instance_epoch,
            dataset_id: current.dataset_id,
            command_id: crypto.randomUUID(),
            schema_version: 1,
            type,
            expected_revision: revision,
            payload,
        };
        inFlight.current = true;
        setBusy(true);
        setError("");
        setNotice("");
        let committed = false;
        try {
            await submit(auth, command);
            committed = true;
            await refresh(auth);
            setNotice("已保存到实例。");
            return true;
        } catch (cause) {
            if (committed) {
                setNotice(
                    "服务器已保存，但暂时无法刷新。请恢复连接后重新读取。",
                );
                return true;
            }
            if (!(cause instanceof APIError) || cause.status >= 500) {
                markUnknown(command);
                setConnected(false);
                setError(
                    "请求已发出，但还不能确认是否保存。请先核对结果，避免重复创建。",
                );
            } else {
                setError(errorMessage(cause));
                if (
                    cause.status === 401 ||
                    ["INSTANCE_CHANGED", "DATASET_INACTIVE"].includes(
                        cause.code,
                    )
                )
                    expire(errorMessage(cause));
                else await refresh(auth).catch(() => {});
            }
            return false;
        } finally {
            inFlight.current = false;
            setBusy(false);
        }
    };
    const checkUnknown = async (retry = false) => {
        if (!unknown || !token || busy) return;
        setBusy(true);
        setError("");
        try {
            if (retry && unknown.command) await submit(token, unknown.command);
            else await getReceipt(token, unknown.id);
            clearUnknown();
            await refresh(token);
            setNotice("已确认：这次操作已保存。请核对最新内容。");
        } catch (cause) {
            if (cause instanceof APIError && cause.status === 404) {
                await refresh(token)
                    .then(() => setUnknownChecked(true))
                    .catch(() => {});
                setError(
                    "尚未查到这次提交的结果。请核对当前内容；不要把同一操作当成新操作重复提交。",
                );
            } else if (cause instanceof APIError && cause.status === 401)
                expire(errorMessage(cause));
            else setError(errorMessage(cause));
        } finally {
            setBusy(false);
        }
    };
    const logout = async () => {
        if (!token || !snapshot) return;
        setBusy(true);
        try {
            if (!keepDrafts) await clearDrafts(draftScope(snapshot));
            await request("/api/v1/auth/logout", token, {});
            setLogoutOpen(false);
            setToken(null);
            tokenRef.current = null;
            setSnapshot(null);
            snapshotRef.current = null;
            setUnknown(null);
            setNotice("");
            setError("");
            clearSessionUI();
        } catch (cause) {
            setError(errorMessage(cause));
        } finally {
            setBusy(false);
        }
    };
    if (!token || !snapshot) return <Login login={login} error={error} />;
    const scope = draftScope(snapshot);
    const selectedDate = date || snapshot.today;
    const activeNav = navigation.find((item) => item.view === view)!;
    const disabled = busy || !connected || Boolean(unknown);
    const byTitle = (chain: Chain, trace?: Trace) =>
        !query ||
        snapshot.definitions
            .find(
                (item) =>
                    item.id === (trace?.definition_id ?? chain.definition_id),
            )
            ?.title.toLocaleLowerCase()
            .includes(query.toLocaleLowerCase());
    const pool = snapshot.chains.filter(
        (chain) => chain.location === "pool" && byTitle(chain),
    );
    const filterTraces = (traces: Trace[]) =>
        traces.filter((trace) => {
            const chain = snapshot.chains.find(
                (chain) => chain.id === trace.chain_id,
            );
            return chain && byTitle(chain, trace);
        });
    const candidateTraces = filterTraces(
        snapshot.traces.filter(
            (trace) =>
                (view === "day"
                    ? visibleTrace(trace)
                    : trace.status !== "cancelledDraft") &&
                (view === "day"
                    ? trace.date === selectedDate
                    : view === "future"
                      ? trace.date > snapshot.today &&
                        trace.status === "pending"
                      : view === "completed"
                        ? trace.status === "completed" ||
                          snapshot.subtasks.some(
                              (item) =>
                                  item.trace_id === trace.id &&
                                  item.status === "completed",
                          )
                        : view === "unfinished"
                          ? ["unfinished", "abandoned"].includes(trace.status)
                          : false),
        ),
    ).sort((a, b) =>
        view === "future"
            ? a.date.localeCompare(b.date) || a.priority - b.priority
            : b.date.localeCompare(a.date) || a.priority - b.priority,
    );
    const seenChains = new Set<string>();
    let selectedTraces = ["completed", "unfinished"].includes(view)
        ? candidateTraces.filter((trace) => {
              if (seenChains.has(trace.chain_id)) return false;
              seenChains.add(trace.chain_id);
              return true;
          })
        : candidateTraces;
    if (sort === "title") {
        const title = (id: string) =>
            snapshot.definitions.find((d) => d.id === id)?.title ?? "";
        selectedTraces = [...selectedTraces].sort((a, b) =>
            title(a.definition_id).localeCompare(
                title(b.definition_id),
                "zh-CN",
            ),
        );
        pool.sort((a, b) =>
            title(a.definition_id).localeCompare(
                title(b.definition_id),
                "zh-CN",
            ),
        );
    } else if (sort === "progress")
        selectedTraces = [...selectedTraces].sort(
            (a, b) => b.progress - a.progress,
        );
    const navigate = (next: View) => {
        setView(next);
        setMobileMenu(false);
        setQuery("");
        setNotice("");
        setSelected(null);
        setRailOpen(false);
        setSourceIdea(undefined);
        mainRef.current?.scrollTo(0, 0);
    };
    const select = (chain: Chain, trace?: Trace) => {
        const active = document.activeElement as HTMLElement;
        detailTrigger.current =
            active
                .closest(".task-row")
                ?.querySelector<HTMLElement>(".task-open") ?? active;
        setSelected({ chainID: chain.id, traceID: trace?.id });
        setRailOpen(true);
    };
    const closeDetail = () => {
        setSelected(null);
        if (matchMedia("(max-width:700px)").matches) setRailOpen(false);
        const id = selected?.traceID ?? selected?.chainID;
        requestAnimationFrame(() => {
            const previous = detailTrigger.current;
            if (previous?.isConnected && previous.getClientRects().length)
                previous.focus();
            else
                (id
                    ? document.querySelector<HTMLElement>(
                          `[data-task-id="${CSS.escape(id)}"] .task-open`,
                      )
                    : null
                )?.focus();
        });
    };
    const changeDate = (day: string) => {
        setDate(day);
        setSelected(null);
    };
    const openDate = (day: string) => {
        navigate("day");
        changeDate(day);
    };
    const closeSettings = () => {
        setSettingsOpen(false);
        if (narrow) requestAnimationFrame(() => mobileTrigger.current?.focus());
    };
    const countFor = (name: View) =>
        name === "pool"
            ? snapshot.chains.filter((c) => c.location === "pool").length
            : name === "day"
              ? snapshot.traces.filter(
                    (t) => t.date === snapshot.today && t.status === "pending",
                ).length
              : name === "future"
                ? snapshot.traces.filter(
                      (t) => t.date > snapshot.today && t.status === "pending",
                  ).length
                : name === "completed"
                  ? new Set(
                        snapshot.traces
                            .filter((t) => t.status === "completed")
                            .map((t) => t.chain_id),
                    ).size
                  : name === "unfinished"
                    ? new Set(
                          snapshot.traces
                              .filter((t) =>
                                  ["unfinished", "abandoned"].includes(
                                      t.status,
                                  ),
                              )
                              .map((t) => t.chain_id),
                      ).size
                    : undefined;
    const taskPage = [
        "day",
        "pool",
        "future",
        "completed",
        "unfinished",
    ].includes(view);
    const futureDates = [...new Set(selectedTraces.map((t) => t.date))].sort();
    return (
        <UIStatus.Provider value={{ error, pending: busy }}>
            <div
                className={`app-shell ${compact ? "sidebar-compact" : ""} ${railOpen ? "has-rail" : ""} ${view === "calendar" ? "calendar-workspace" : ""}`}
            >
                <a className="skip-link" href="#main-content">
                    跳到主要内容
                </a>
                {mobileMenu && (
                    <button
                        className="sidebar-scrim"
                        aria-label="关闭导航"
                        onClick={() => {
                            setMobileMenu(false);
                            mobileTrigger.current?.focus();
                        }}
                    />
                )}
                <aside
                    ref={sidebarRef}
                    inert={narrow && railOpen}
                    className={`sidebar ${mobileMenu ? "mobile-open" : ""}`}
                >
                    <div className="sidebar-top">
                        <span>计划</span>
                        <button
                            className="pane-toggle"
                            aria-label={compact ? "展开侧栏" : "收起侧栏"}
                            title={compact ? "展开侧栏" : "收起侧栏"}
                            onClick={() => setCompact(!compact)}
                        >
                            <span aria-hidden="true">
                                {compact ? "»" : "«"}
                            </span>
                        </button>
                    </div>
                    <nav aria-label="主要导航">
                        {navigation.map((item) => (
                            <div key={item.view}>
                                {item.section && item.section !== "计划" && (
                                    <p className="nav-section">
                                        {item.section}
                                    </p>
                                )}
                                <button
                                    className={`nav-item nav-${item.view} ${view === item.view ? "active" : ""}`}
                                    aria-label={item.label}
                                    title={compact ? item.label : undefined}
                                    aria-current={
                                        view === item.view ? "page" : undefined
                                    }
                                    onClick={() => navigate(item.view)}
                                >
                                    <Icon name={item.icon} size={16} />
                                    <span>{item.label}</span>
                                    {countFor(item.view) !== undefined && (
                                        <small>{countFor(item.view)}</small>
                                    )}
                                </button>
                            </div>
                        ))}
                    </nav>
                    <div className="sidebar-bottom">
                        <button
                            className="nav-item"
                            aria-label="设置"
                            title={compact ? "设置" : undefined}
                            onClick={() => {
                                setMobileMenu(false);
                                setSettingsOpen(true);
                            }}
                        >
                            <Icon name="settings" size={16} />
                            <span>设置</span>
                        </button>
                        <div
                            className="instance-note"
                            title={
                                connected
                                    ? "个人实例 · 已连接"
                                    : "个人实例 · 连接中断"
                            }
                        >
                            <span
                                className={`connection-dot ${connected ? "" : "offline"}`}
                            />
                            <span>{connected ? "已连接" : "连接中断"}</span>
                        </div>
                    </div>
                </aside>
                <main
                    ref={mainRef}
                    inert={mobileMenu || (narrow && railOpen)}
                    id="main-content"
                    className="main-content"
                    onTouchStart={(event) => {
                        if (
                            (event.target as HTMLElement).closest(
                                'input,textarea,button,select,[role="dialog"]',
                            )
                        )
                            return;
                        const touch = event.touches[0];
                        touchOrigin.current = {
                            x: touch.clientX,
                            y: touch.clientY,
                        };
                    }}
                    onTouchEnd={(event) => {
                        const start = touchOrigin.current;
                        touchOrigin.current = null;
                        if (!start || view !== "day") return;
                        const end = event.changedTouches[0];
                        if (
                            Math.abs(end.clientX - start.x) < 80 ||
                            Math.abs(end.clientY - start.y) > 40
                        )
                            return;
                        const step = end.clientX < start.x ? 1 : -1;
                        changeDate(
                            nextDate(
                                selectedDate,
                                preferences.swipeDirection === "book"
                                    ? step
                                    : -step,
                            ),
                        );
                    }}
                >
                    <div className="mobile-top">
                        <button
                            ref={mobileTrigger}
                            className="icon-button"
                            aria-label="打开导航"
                            onClick={() => setMobileMenu(true)}
                        >
                            <Icon name="menu" />
                        </button>
                        <span>晷迹</span>
                    </div>
                    <div className="page-content">
                        <header className="page-heading">
                            <div>
                                <div className="page-title-line">
                                    <h1 aria-label={activeNav.label}>
                                        {view === "day"
                                            ? dateLabel(selectedDate, {
                                                  year: "numeric",
                                                  month: "long",
                                                  day: "numeric",
                                              })
                                            : activeNav.label}
                                    </h1>
                                    {view === "day" && (
                                        <>
                                            <span className="weekday-label">
                                                {dateLabel(selectedDate, {
                                                    weekday: "short",
                                                })}
                                            </span>
                                            <span
                                                className={`day-badge ${selectedDate === snapshot.today ? "is-today" : ""}`}
                                            >
                                                {selectedDate === snapshot.today
                                                    ? "今日"
                                                    : selectedDate <
                                                        snapshot.today
                                                      ? "历史"
                                                      : "未来"}
                                            </span>
                                        </>
                                    )}
                                </div>
                                {descriptions[view] && (
                                    <p className="page-description">
                                        {descriptions[view]}
                                    </p>
                                )}
                            </div>
                            <div className="page-actions">
                                {taskPage && (
                                    <details className="view-menu">
                                        <summary>↕ 视图</summary>
                                        <div>
                                            <label>
                                                查看排序
                                                <select
                                                    aria-label="查看排序"
                                                    value={sort}
                                                    onChange={(event) =>
                                                        setSort(
                                                            event.target.value,
                                                        )
                                                    }
                                                >
                                                    <option value="priority">
                                                        {view === "pool"
                                                            ? "默认顺序"
                                                            : "当日优先级"}
                                                    </option>
                                                    <option value="title">
                                                        任务名称
                                                    </option>
                                                    {view !== "pool" && (
                                                        <option value="progress">
                                                            进度
                                                        </option>
                                                    )}
                                                </select>
                                            </label>
                                            <button
                                                className="text-button"
                                                onClick={() => setNewTask(true)}
                                                disabled={Boolean(unknown)}
                                            >
                                                快速记录…
                                            </button>
                                        </div>
                                    </details>
                                )}
                                {(view === "ideas" || view === "sticky") && (
                                    <div id="notes-page-actions" />
                                )}
                                {view === "day" && (
                                    <div className="date-navigation">
                                        <button
                                            className="icon-button"
                                            aria-label="前一天"
                                            onClick={() =>
                                                changeDate(
                                                    nextDate(selectedDate, -1),
                                                )
                                            }
                                        >
                                            <Icon name="left" size={14} />
                                        </button>
                                        <button
                                            className="icon-button"
                                            aria-label="后一天"
                                            onClick={() =>
                                                changeDate(
                                                    nextDate(selectedDate, 1),
                                                )
                                            }
                                        >
                                            <Icon name="right" size={14} />
                                        </button>
                                        <label className="date-picker-button">
                                            选日期
                                            <input
                                                id="view-date"
                                                type="date"
                                                aria-label="查看日期"
                                                value={selectedDate}
                                                onChange={(event) =>
                                                    event.target.value &&
                                                    changeDate(
                                                        event.target.value,
                                                    )
                                                }
                                            />
                                        </label>
                                        {selectedDate !== snapshot.today && (
                                            <button
                                                className="text-button"
                                                onClick={() =>
                                                    changeDate(snapshot.today)
                                                }
                                            >
                                                今天
                                            </button>
                                        )}
                                    </div>
                                )}
                                <button
                                    className="pane-toggle detail-toggle"
                                    aria-label={
                                        railOpen ? "收起右栏" : "展开右栏"
                                    }
                                    onClick={() => {
                                        setRailOpen(!railOpen);
                                        if (railOpen) setSelected(null);
                                    }}
                                    title={railOpen ? "收起右栏" : "展开右栏"}
                                >
                                    <span aria-hidden="true">
                                        {railOpen ? "»" : "«"}
                                    </span>
                                </button>
                            </div>
                        </header>
                        {!connected && (
                            <div
                                className="status-banner warning"
                                role="status"
                            >
                                <span>
                                    暂时无法连接实例。可继续写草稿，恢复连接后再提交。
                                </span>
                                <button
                                    onClick={() =>
                                        void refresh(token).catch(() => {})
                                    }
                                    className="text-button"
                                >
                                    <Icon name="refresh" size={15} />
                                    重新连接
                                </button>
                            </div>
                        )}
                        {unknown && (
                            <div className="status-banner warning">
                                <div>
                                    <strong>有一次操作结果待确认</strong>
                                    <p>先核对服务端结果，再继续修改。</p>
                                    <div className="detail-actions">
                                        <button
                                            disabled={busy}
                                            onClick={() => void checkUnknown()}
                                        >
                                            核对结果
                                        </button>
                                        {unknown.command && (
                                            <button
                                                disabled={busy}
                                                onClick={() =>
                                                    void checkUnknown(true)
                                                }
                                            >
                                                以原请求重试
                                            </button>
                                        )}
                                        <button
                                            className="text-button"
                                            disabled={
                                                busy ||
                                                !unknownChecked ||
                                                !connected
                                            }
                                            onClick={() => {
                                                clearUnknown();
                                                setError("");
                                                setNotice(
                                                    "请先检查最新内容，再决定下一次操作。",
                                                );
                                            }}
                                        >
                                            已核对当前内容，继续使用
                                        </button>
                                    </div>
                                </div>
                            </div>
                        )}
                        {error && (
                            <div className="status-banner error" role="alert">
                                <span>{error}</span>
                                <button
                                    className="icon-button"
                                    aria-label="关闭提示"
                                    onClick={() => setError("")}
                                >
                                    <Icon name="close" size={16} />
                                </button>
                            </div>
                        )}
                        <div
                            className="save-status"
                            role="status"
                            aria-live="polite"
                        >
                            {busy ? "正在与实例确认…" : notice}
                        </div>
                        {view === "day" && (
                            <DateStrip
                                date={selectedDate}
                                today={snapshot.today}
                                snapshot={snapshot}
                                onChange={changeDate}
                            />
                        )}
                        {(view === "pool" ||
                            (view === "day" &&
                                selectedDate >= snapshot.today)) && (
                            <InlineTask
                                key={view === "pool" ? "pool" : selectedDate}
                                date={view === "pool" ? "" : selectedDate}
                                today={snapshot.today}
                                scope={scope}
                                execute={execute}
                                busy={disabled}
                                openPool={
                                    view === "day"
                                        ? () => setPoolPicker(true)
                                        : undefined
                                }
                            />
                        )}
                        {taskPage && (
                            <>
                                <div className="list-toolbar">
                                    <span>
                                        {view === "pool"
                                            ? pool.length
                                            : selectedTraces.length}{" "}
                                        项任务
                                    </span>
                                    <input
                                        id="task-search"
                                        aria-label="搜索任务"
                                        className="search-input"
                                        type="search"
                                        placeholder="搜索任务"
                                        value={query}
                                        onChange={(event) =>
                                            setQuery(event.target.value)
                                        }
                                    />
                                </div>
                                {view === "future" ? (
                                    futureDates.map((day) => (
                                        <section
                                            className="future-section"
                                            key={day}
                                        >
                                            <div className="list-section-heading">
                                                <h2>{dateLabel(day)}</h2>
                                                <span>
                                                    {
                                                        selectedTraces.filter(
                                                            (t) =>
                                                                t.date === day,
                                                        ).length
                                                    }
                                                </span>
                                                <button
                                                    className="text-button"
                                                    onClick={() =>
                                                        openDate(day)
                                                    }
                                                >
                                                    查看当天
                                                    <Icon
                                                        name="right"
                                                        size={13}
                                                    />
                                                </button>
                                            </div>
                                            <TaskList
                                                snapshot={snapshot}
                                                execute={execute}
                                                disabled={disabled}
                                                traces={selectedTraces.filter(
                                                    (t) => t.date === day,
                                                )}
                                                onSelect={select}
                                                selectedID={
                                                    selected?.traceID ??
                                                    selected?.chainID
                                                }
                                            />
                                        </section>
                                    ))
                                ) : (
                                    <TaskList
                                        snapshot={snapshot}
                                        execute={execute}
                                        disabled={disabled}
                                        historyView={
                                            view === "completed" ||
                                            view === "unfinished"
                                        }
                                        completedChildren={view === "completed"}
                                        chains={
                                            view === "pool" ? pool : undefined
                                        }
                                        traces={
                                            view === "pool"
                                                ? undefined
                                                : selectedTraces
                                        }
                                        onSelect={select}
                                        selectedID={
                                            selected?.traceID ??
                                            selected?.chainID
                                        }
                                    />
                                )}
                                {view === "day" &&
                                    selectedDate <= snapshot.today && (
                                        <button
                                            className="review-link text-button"
                                            onClick={() => {
                                                setSelected(null);
                                                setRailOpen(true);
                                            }}
                                        >
                                            每日复盘
                                            <Icon name="right" size={14} />
                                        </button>
                                    )}
                            </>
                        )}
                        {view === "calendar" && (
                            <Calendar
                                snapshot={snapshot}
                                date={selectedDate}
                                setDate={(day) => {
                                    changeDate(day);
                                    setRailOpen(true);
                                }}
                                openDay={openDate}
                                swipeDirection={preferences.swipeDirection}
                            />
                        )}
                        {(view === "ideas" || view === "sticky") && (
                            <Flylight
                                key={view}
                                snapshot={snapshot}
                                scope={scope}
                                execute={execute}
                                pinned={view === "sticky"}
                                busy={disabled}
                                stickyView={preferences.stickyView}
                                onStickyViewChange={(value) =>
                                    updatePreference("stickyView", value)
                                }
                                initialIdeaID={sourceIdea}
                                shortcutsEnabled={preferences.shortcutsEnabled}
                                onOpenSource={(id) => {
                                    navigate("ideas");
                                    setSourceIdea(id);
                                }}
                            />
                        )}
                    </div>
                </main>
                {railOpen && (
                    <aside
                        ref={railRef}
                        className="detail-rail"
                        aria-label="上下文右栏"
                        role={narrow ? "dialog" : undefined}
                        aria-modal={narrow ? true : undefined}
                    >
                        <div className="rail-toolbar">
                            <button
                                className="pane-toggle"
                                aria-label="关闭右栏"
                                onClick={() => {
                                    setRailOpen(false);
                                    setSelected(null);
                                }}
                            >
                                <span aria-hidden="true">»</span>
                            </button>
                            {taskPage && (
                                <input
                                    type="search"
                                    aria-label="右栏搜索任务"
                                    placeholder="搜索"
                                    value={query}
                                    onChange={(event) =>
                                        setQuery(event.target.value)
                                    }
                                />
                            )}
                        </div>
                        <div className="rail-content">
                            {selected ? (
                                <TaskDetail
                                    mobile={narrow}
                                    snapshot={snapshot}
                                    scope={scope}
                                    execute={execute}
                                    {...selected}
                                    busy={disabled}
                                    close={closeDetail}
                                />
                            ) : view === "day" ? (
                                <>
                                    <DaySummary
                                        snapshot={snapshot}
                                        date={selectedDate}
                                    />
                                    {selectedDate <= snapshot.today && (
                                        <Review
                                            date={selectedDate}
                                            snapshot={snapshot}
                                            scope={scope}
                                            execute={execute}
                                            busy={disabled}
                                            compact
                                        />
                                    )}
                                </>
                            ) : view === "calendar" ? (
                                <>
                                    <h2>{dateLabel(selectedDate)}</h2>
                                    <button
                                        className="text-button"
                                        onClick={() => openDate(selectedDate)}
                                    >
                                        查看当天
                                        <Icon name="right" size={13} />
                                    </button>
                                    <TaskList
                                        snapshot={snapshot}
                                        execute={execute}
                                        disabled={disabled}
                                        traces={snapshot.traces.filter(
                                            (t) =>
                                                t.date === selectedDate &&
                                                visibleTrace(t),
                                        )}
                                        onSelect={select}
                                    />
                                </>
                            ) : taskPage ? (
                                <>
                                    <h2>{activeNav.label}统计</h2>
                                    <div className="summary-rate">
                                        <span>任务总量</span>
                                        <strong>
                                            {view === "pool"
                                                ? pool.length
                                                : selectedTraces.length}
                                        </strong>
                                    </div>
                                    <p className="muted">
                                        根据当前实例的任务与历史记录统计。
                                    </p>
                                </>
                            ) : null}
                        </div>
                    </aside>
                )}
                {newTask && (
                    <NewTask
                        snapshot={snapshot}
                        scope={scope}
                        execute={execute}
                        busy={disabled}
                        date={
                            view === "pool"
                                ? ""
                                : selectedDate >= snapshot.today
                                  ? selectedDate
                                  : snapshot.today
                        }
                        close={() => setNewTask(false)}
                    />
                )}
                {poolPicker && (
                    <PoolPicker
                        snapshot={snapshot}
                        date={selectedDate}
                        execute={execute}
                        busy={disabled}
                        close={() => setPoolPicker(false)}
                    />
                )}
                {settingsOpen && (
                    <Settings
                        token={token}
                        snapshot={snapshot}
                        connected={connected}
                        close={closeSettings}
                        logout={() => {
                            setSettingsOpen(false);
                            setLogoutOpen(true);
                        }}
                        preferences={preferences}
                        updatePreference={updatePreference}
                        storageError={storageError}
                    />
                )}
                {logoutOpen && (
                    <Modal title="退出登录" close={() => setLogoutOpen(false)}>
                        <p>退出后，需要密码才能再次访问这个实例。</p>
                        <label className="checkbox-label">
                            <input
                                type="checkbox"
                                checked={keepDrafts}
                                onChange={(event) =>
                                    setKeepDrafts(event.target.checked)
                                }
                            />
                            在此浏览器保留未提交的草稿
                        </label>
                        <p className="field-hint">在共用设备上，请清除草稿。</p>
                        <div className="form-actions">
                            <button
                                className="text-button"
                                onClick={() => setLogoutOpen(false)}
                            >
                                取消
                            </button>
                            <button
                                className="primary"
                                disabled={busy}
                                onClick={() => void logout()}
                            >
                                {keepDrafts
                                    ? "保留草稿并退出"
                                    : "清除草稿并退出"}
                            </button>
                        </div>
                    </Modal>
                )}
            </div>
        </UIStatus.Provider>
    );
}

function Login({
    login,
    error,
}: {
    login: (password: string) => Promise<boolean>;
    error: string;
}) {
    const [password, setPassword] = useState("");
    const [busy, setBusy] = useState(false);
    const composing = useRef(false);
    const onSubmit = async (event: FormEvent) => {
        event.preventDefault();
        if (busy || composing.current || !password) return;
        setBusy(true);
        if (await login(password)) setPassword("");
        setBusy(false);
    };
    return (
        <main className="login-page">
            <div className="login-brand">
                <Icon name="sun" size={38} />
                <span>
                    晷迹 <small>NOONMARK</small>
                </span>
            </div>
            <div className="login-content">
                <p className="eyebrow">你的每一天，都有迹可循</p>
                <h1>回到自己的节奏。</h1>
                <p className="muted">登录你的个人实例，继续今天的安排。</p>
                <form
                    onKeyDownCapture={compositionKeyGuard}
                    onSubmit={onSubmit}
                    onCompositionStart={() => {
                        composing.current = true;
                    }}
                    onCompositionEnd={() => {
                        composing.current = false;
                    }}
                >
                    <input
                        className="sr-only"
                        type="text"
                        autoComplete="username"
                        value="owner"
                        readOnly
                        aria-label="账号"
                    />
                    <label htmlFor="login-password">实例密码</label>
                    <input
                        id="login-password"
                        type="password"
                        autoComplete="current-password"
                        autoFocus
                        required
                        value={password}
                        onChange={(event) => setPassword(event.target.value)}
                        disabled={busy}
                    />
                    {error && (
                        <p className="login-error" role="alert">
                            {error}
                        </p>
                    )}
                    <button
                        className="primary"
                        type="submit"
                        disabled={busy || !password}
                    >
                        {busy ? "正在登录…" : "进入晷迹"}
                        <Icon name="arrow" size={17} />
                    </button>
                </form>
                <p className="login-footnote">
                    数据保存在你部署的服务上。
                    <br />
                    无需官方账号。
                </p>
            </div>
            <footer>
                NOONMARK <span>·</span> 个人自部署版
            </footer>
        </main>
    );
}
