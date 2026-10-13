import {
    useContext,
    useEffect,
    useId,
    useLayoutEffect,
    useMemo,
    useRef,
    useState,
} from "react";
import { createPortal } from "react-dom";
import type { ReactNode } from "react";
import { useDraft } from "./drafts";
import type { Day, Execute, Idea, Snapshot } from "./types";
import {
    DraftHint,
    Empty,
    FormFields,
    Icon,
    UIStatus,
    compositionKeyGuard,
    dateLabel,
} from "./ui";
import "./notes.css";

type StickyView = "stream" | "wall";
type FlylightProps = {
    snapshot: Snapshot;
    scope: string;
    pinned: boolean;
    execute: Execute;
    busy: boolean;
    stickyView?: StickyView;
    onStickyViewChange?: (view: StickyView) => void;
    initialIdeaID?: string;
    onOpenSource?: (id: string) => void;
    shortcutsEnabled?: boolean;
};

function civilDate(instant: string, timezone: string) {
    const parts = new Intl.DateTimeFormat("en", {
        timeZone: timezone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
    }).formatToParts(new Date(instant));
    return ["year", "month", "day"]
        .map((type) => parts.find((part) => part.type === type)!.value)
        .join("-");
}

function noteTime(instant: string, timezone: string, full = false) {
    return new Intl.DateTimeFormat("zh-CN", {
        timeZone: timezone,
        ...(full
            ? ({ year: "numeric", month: "2-digit", day: "2-digit" } as const)
            : {}),
        hour: "2-digit",
        minute: "2-digit",
        hourCycle: "h23",
    }).format(new Date(instant));
}

function NotesToolbar({ children }: { children: ReactNode }) {
    const [target, setTarget] = useState<HTMLElement | null>(null);
    useLayoutEffect(() => {
        setTarget(document.getElementById("notes-page-actions"));
    }, []);
    const toolbar = <div className="notes-toolbar">{children}</div>;
    return target ? createPortal(toolbar, target) : toolbar;
}

export function Flylight({
    snapshot,
    scope,
    pinned,
    execute,
    busy,
    stickyView,
    onStickyViewChange,
    initialIdeaID,
    onOpenSource,
    shortcutsEnabled = true,
}: FlylightProps) {
    const { pending } = useContext(UIStatus);
    const [localView, setLocalView] = useState<StickyView>("stream");
    const [selected, setSelected] = useState<string | null>(null);
    const [editing, setEditing] = useState<string | null>(null);
    const [deleting, setDeleting] = useState<string | null>(null);
    const [saved, setSaved] = useState<string | null>(null);
    const [searchOpen, setSearchOpen] = useState(false);
    const [search, setSearch] = useState("");
    const searchField = useRef<HTMLInputElement>(null);
    const rows = useRef(new Map<string, HTMLLIElement>());
    const mode = stickyView ?? localView;
    const ideas = useMemo(
        () =>
            snapshot.ideas
                .filter(
                    (idea) =>
                        !idea.deleted_at &&
                        (!pinned || idea.pinned_at) &&
                        (!search.trim() ||
                            idea.body
                                .toLocaleLowerCase()
                                .includes(search.trim().toLocaleLowerCase())),
                )
                .sort(
                    (a, b) =>
                        (pinned ? b.pinned_at! : b.created_at).localeCompare(
                            pinned ? a.pinned_at! : a.created_at,
                        ) || b.id.localeCompare(a.id),
                ),
        [snapshot.ideas, pinned, search],
    );
    const groups = useMemo(() => {
        const result = new Map<string, Idea[]>();
        for (const idea of ideas) {
            const day = civilDate(idea.created_at, snapshot.timezone);
            const group = result.get(day) ?? [];
            group.push(idea);
            result.set(day, group);
        }
        return [...result];
    }, [ideas, snapshot.timezone]);

    useEffect(() => {
        if (!initialIdeaID || pinned) return;
        setSearch("");
        setSelected(initialIdeaID);
        const frame = requestAnimationFrame(() => {
            const target = rows.current.get(initialIdeaID);
            target?.scrollIntoView({ block: "center" });
            target?.focus({ preventScroll: true });
        });
        return () => cancelAnimationFrame(frame);
    }, [initialIdeaID, pinned]);
    useEffect(() => {
        if (searchOpen) searchField.current?.focus();
    }, [searchOpen]);

    function finishEditing(id: string, didSave: boolean, restoreFocus = true) {
        setEditing((current) => (current === id ? null : current));
        if (didSave) setSaved(id);
        if (restoreFocus)
            requestAnimationFrame(() =>
                rows.current.get(id)?.focus({ preventScroll: true }),
            );
    }
    function openEditor(id: string) {
        if (pending) return;
        setSelected(id);
        setEditing(id);
        setDeleting(null);
        setSaved(null);
    }
    function renderIdea(idea: Idea) {
        const isEditing = !pinned && editing === idea.id;
        return (
            <li
                key={idea.id}
                ref={(node) => {
                    if (node) rows.current.set(idea.id, node);
                    else rows.current.delete(idea.id);
                }}
                className={`notes-entry ${pinned ? "notes-sticky-entry" : ""} ${selected === idea.id ? "is-selected" : ""} ${isEditing ? "is-editing" : ""}`}
                data-idea-id={idea.id}
                tabIndex={0}
                aria-label={pinned ? "Sticky Note 条目" : "飞光条目"}
                onClick={() => setSelected(idea.id)}
                onKeyDown={(event) => {
                    if (
                        event.target !== event.currentTarget ||
                        event.nativeEvent.isComposing ||
                        event.nativeEvent.keyCode === 229
                    )
                        return;
                    if (event.key === "Enter" && !pending) {
                        event.preventDefault();
                        if (pinned) onOpenSource?.(idea.id);
                        else openEditor(idea.id);
                    }
                }}
            >
                {isEditing ? (
                    <InlineIdeaEditor
                        key={idea.id}
                        {...{ idea, scope, execute, busy, shortcutsEnabled }}
                        close={(didSave, restoreFocus) =>
                            finishEditing(idea.id, didSave, restoreFocus)
                        }
                    />
                ) : (
                    <>
                        <p
                            className="idea-body notes-body"
                            onDoubleClick={() => {
                                if (pinned) onOpenSource?.(idea.id);
                                else openEditor(idea.id);
                            }}
                        >
                            {idea.body}
                        </p>
                        <div className="notes-meta">
                            <time dateTime={idea.created_at}>
                                {noteTime(
                                    idea.created_at,
                                    snapshot.timezone,
                                    pinned,
                                )}
                            </time>
                            {!pinned && idea.pinned_at && (
                                <span className="notes-sticky-mark">
                                    <Icon name="pin" size={11} />
                                    Sticky Note
                                </span>
                            )}
                            {saved === idea.id && (
                                <span className="success-text" role="status">
                                    ✓ 已保存
                                </span>
                            )}
                            <IdeaActions disabled={pending}>
                                {pinned ? (
                                    <>
                                        <button
                                            type="button"
                                            disabled={!onOpenSource}
                                            onClick={() =>
                                                onOpenSource?.(idea.id)
                                            }
                                        >
                                            在飞光中打开
                                        </button>
                                        <button
                                            type="button"
                                            disabled={busy}
                                            onClick={() =>
                                                void execute(
                                                    "UnpinIdea",
                                                    idea.revision,
                                                    { idea_id: idea.id },
                                                )
                                            }
                                        >
                                            从 Sticky Note 移除
                                        </button>
                                    </>
                                ) : (
                                    <>
                                        <button
                                            type="button"
                                            disabled={busy}
                                            onClick={() =>
                                                void execute(
                                                    idea.pinned_at
                                                        ? "UnpinIdea"
                                                        : "PinIdea",
                                                    idea.revision,
                                                    { idea_id: idea.id },
                                                )
                                            }
                                        >
                                            {idea.pinned_at
                                                ? "从 Sticky Note 移除"
                                                : "加入 Sticky Note"}
                                        </button>
                                        <button
                                            type="button"
                                            onClick={() => openEditor(idea.id)}
                                        >
                                            编辑记录
                                        </button>
                                        <button
                                            type="button"
                                            className="danger"
                                            disabled={busy}
                                            onClick={() => setDeleting(idea.id)}
                                        >
                                            删除记录
                                        </button>
                                    </>
                                )}
                            </IdeaActions>
                        </div>
                    </>
                )}
                {deleting === idea.id && (
                    <DeleteIdeaConfirmation
                        {...{ idea, execute, busy }}
                        close={() => {
                            setDeleting(null);
                            requestAnimationFrame(() =>
                                rows.current
                                    .get(idea.id)
                                    ?.focus({ preventScroll: true }),
                            );
                        }}
                    />
                )}
            </li>
        );
    }

    return (
        <section
            className={`notes-page ${pinned ? `notes-sticky notes-sticky-${mode}` : "notes-flylight"}`}
            aria-label={pinned ? "Sticky Note" : "飞光时间线"}
        >
            <NotesToolbar>
                {pinned ? (
                    <label className="notes-view-switch">
                        <span className="sr-only">展示视图</span>
                        <select
                            aria-label="展示视图"
                            value={mode}
                            onChange={(event) => {
                                const next = event.target.value as StickyView;
                                setLocalView(next);
                                onStickyViewChange?.(next);
                            }}
                        >
                            <option value="stream">清单流</option>
                            <option value="wall">便签墙</option>
                        </select>
                    </label>
                ) : (
                    <button
                        type="button"
                        className="notes-toolbar-button"
                        aria-pressed={searchOpen}
                        onClick={() => {
                            setSearchOpen(!searchOpen);
                            if (searchOpen) setSearch("");
                        }}
                    >
                        <svg
                            width="14"
                            height="14"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            strokeWidth="1.7"
                            aria-hidden="true"
                        >
                            <circle cx="10" cy="10" r="6.5" />
                            <path d="m15 15 5 5" />
                        </svg>
                        搜索
                    </button>
                )}
            </NotesToolbar>
            {!pinned && (
                <div className="notes-timeline-header">
                    <IdeaComposer
                        {...{ scope, execute, busy, shortcutsEnabled }}
                    />
                    {searchOpen && (
                        <input
                            ref={searchField}
                            className="notes-search"
                            aria-label="搜索飞光"
                            placeholder="搜索正文…"
                            type="search"
                            value={search}
                            onChange={(event) => setSearch(event.target.value)}
                            onKeyDown={(event) => {
                                if (
                                    event.key === "Escape" &&
                                    !event.nativeEvent.isComposing
                                ) {
                                    setSearchOpen(false);
                                    setSearch("");
                                }
                            }}
                        />
                    )}
                    <p className="notes-collection">
                        {search.trim() ? "搜索结果" : "最近"} · {ideas.length}
                    </p>
                </div>
            )}
            {ideas.length ? (
                pinned ? (
                    <ol className="idea-list notes-list notes-sticky-list">
                        {ideas.map(renderIdea)}
                    </ol>
                ) : (
                    <div className="notes-timeline">
                        {groups.map(([day, entries]) => (
                            <section
                                className="notes-day"
                                key={day}
                                data-civil-date={day}
                            >
                                <h2 className="notes-day-heading">
                                    <time dateTime={day}>
                                        {dateLabel(day, {
                                            year: "numeric",
                                            month: "long",
                                            day: "numeric",
                                        })}
                                    </time>
                                    <span>{entries.length}</span>
                                </h2>
                                <ol className="idea-list notes-list">
                                    {entries.map(renderIdea)}
                                </ol>
                            </section>
                        ))}
                    </div>
                )
            ) : (
                <Empty>
                    {pinned
                        ? "还没有 Sticky Note。请从飞光中挑选值得常看的条目。"
                        : search.trim()
                          ? "飞光里没有匹配这个过滤词的内容。"
                          : "飞光里还没有记录。把第一条写在上面的速记框里。"}
                </Empty>
            )}
        </section>
    );
}

function IdeaActions({
    children,
    disabled,
}: {
    children: ReactNode;
    disabled: boolean;
}) {
    const [open, setOpen] = useState(false);
    const root = useRef<HTMLDivElement>(null);
    const trigger = useRef<HTMLButtonElement>(null);
    const id = useId();
    useEffect(() => {
        if (!open) return;
        root.current
            ?.querySelector<HTMLButtonElement>(
                ".notes-menu-panel button:not(:disabled)",
            )
            ?.focus();
        function dismiss(event: PointerEvent) {
            if (!root.current?.contains(event.target as Node)) setOpen(false);
        }
        document.addEventListener("pointerdown", dismiss);
        return () => document.removeEventListener("pointerdown", dismiss);
    }, [open]);
    return (
        <div
            className="notes-actions"
            ref={root}
            onKeyDown={(event) => {
                if (event.key === "Escape") {
                    event.preventDefault();
                    event.stopPropagation();
                    setOpen(false);
                    trigger.current?.focus();
                }
            }}
            onBlur={(event) => {
                if (!event.currentTarget.contains(event.relatedTarget))
                    setOpen(false);
            }}
        >
            <button
                ref={trigger}
                type="button"
                className="notes-more"
                aria-label="记录操作"
                aria-expanded={open}
                aria-controls={open ? id : undefined}
                disabled={disabled}
                onClick={() => setOpen(!open)}
            >
                <svg
                    width="16"
                    height="16"
                    viewBox="0 0 24 24"
                    fill="currentColor"
                    aria-hidden="true"
                >
                    <circle cx="5" cy="12" r="1.7" />
                    <circle cx="12" cy="12" r="1.7" />
                    <circle cx="19" cy="12" r="1.7" />
                </svg>
            </button>
            {open && (
                <div
                    id={id}
                    className="notes-menu-panel"
                    role="group"
                    aria-label="记录操作"
                    onClick={(event) => {
                        if (
                            (event.target as HTMLElement).closest(
                                "button:not(:disabled)",
                            )
                        )
                            setOpen(false);
                    }}
                >
                    {children}
                </div>
            )}
        </div>
    );
}

function IdeaComposer({
    scope,
    execute,
    busy,
    shortcutsEnabled,
}: {
    scope: string;
    execute: Execute;
    busy: boolean;
    shortcutsEnabled: boolean;
}) {
    const { pending } = useContext(UIStatus);
    const draft = useDraft(scope, "new-idea", "0", "");
    const input = useRef<HTMLTextAreaElement>(null);
    const submitting = useRef(false);
    const [message, setMessage] = useState("");
    return (
        <form
            className="notes-composer"
            onKeyDownCapture={(event) => {
                compositionKeyGuard(event);
                if (
                    shortcutsEnabled &&
                    event.key === "Enter" &&
                    (event.metaKey || event.ctrlKey) &&
                    !event.defaultPrevented &&
                    !draft.composing.current
                ) {
                    event.preventDefault();
                    event.currentTarget.requestSubmit();
                }
            }}
            onCompositionStart={draft.onCompositionStart}
            onCompositionEnd={draft.onCompositionEnd}
            onSubmit={async (event) => {
                event.preventDefault();
                if (
                    draft.composing.current ||
                    !draft.ready ||
                    !draft.value.trim() ||
                    busy ||
                    submitting.current
                )
                    return;
                submitting.current = true;
                setMessage("");
                try {
                    if (
                        await execute("CreateIdea", "0", {
                            body: draft.value.trim(),
                        })
                    ) {
                        await draft.clear("");
                        setMessage("✓ 已记录");
                        requestAnimationFrame(() => input.current?.focus());
                    } else setMessage("发布失败，草稿仍在这里，请重试。");
                } finally {
                    submitting.current = false;
                }
            }}
        >
            <FormFields ready={draft.ready}>
                <label className="sr-only" htmlFor="flylight-body">
                    记录内容
                </label>
                <textarea
                    ref={input}
                    id="flylight-body"
                    rows={3}
                    placeholder={
                        shortcutsEnabled
                            ? "你在想什么？回车换行，⌘/Ctrl+Enter 保存，草稿自动保留"
                            : "你在想什么？回车换行，草稿自动保留"
                    }
                    value={draft.value}
                    maxLength={20000}
                    disabled={!draft.ready}
                    onChange={(event) => {
                        draft.update(event.target.value);
                        setMessage("");
                    }}
                />
                <div className="notes-composer-actions">
                    <span
                        className="notes-save-hint"
                        role="status"
                        title="输入草稿仅保存在此浏览器，7 天后过期。"
                    >
                        {message || "草稿自动保留"}
                    </span>
                    <button
                        className="primary"
                        disabled={busy || !draft.ready || !draft.value.trim()}
                        type="submit"
                    >
                        {pending ? "发布中" : "发布"}
                        <span aria-hidden="true">↑</span>
                    </button>
                </div>
                {(draft.storageError || draft.stale) && (
                    <DraftHint {...draft} />
                )}
            </FormFields>
        </form>
    );
}

function InlineIdeaEditor({
    idea,
    scope,
    execute,
    busy,
    shortcutsEnabled,
    close,
}: {
    idea: Idea;
    scope: string;
    execute: Execute;
    busy: boolean;
    shortcutsEnabled: boolean;
    close: (saved: boolean, restoreFocus?: boolean) => void;
}) {
    const { pending, error } = useContext(UIStatus);
    const draft = useDraft(
        scope,
        `edit-idea:${idea.id}`,
        idea.revision,
        idea.body,
    );
    const submitting = useRef(false);
    const pointerInside = useRef(false);
    const [failed, setFailed] = useState(false);
    useEffect(() => {
        const release = () => {
            pointerInside.current = false;
        };
        document.addEventListener("pointerup", release, true);
        document.addEventListener("pointercancel", release, true);
        return () => {
            document.removeEventListener("pointerup", release, true);
            document.removeEventListener("pointercancel", release, true);
        };
    }, []);
    const cancel = async () => {
        if (pending || submitting.current || draft.composing.current) return;
        submitting.current = true;
        try {
            await draft.clear(idea.body);
            close(false);
        } finally {
            submitting.current = false;
        }
    };
    const save = async (restoreFocus: boolean) => {
        if (
            draft.composing.current ||
            !draft.ready ||
            pending ||
            busy ||
            submitting.current
        )
            return;
        const body = draft.value.trim();
        if (!body) return;
        submitting.current = true;
        setFailed(false);
        try {
            if (body === idea.body) {
                await draft.clear(body);
                close(false, restoreFocus);
                return;
            }
            if (
                await execute("EditIdea", draft.baseRevision, {
                    idea_id: idea.id,
                    body,
                })
            ) {
                await draft.clear(body);
                close(true, restoreFocus);
            } else setFailed(true);
        } finally {
            submitting.current = false;
        }
    };
    return (
        <form
            className="notes-composer notes-inline-editor"
            aria-label="编辑记录"
            onPointerDownCapture={() => {
                pointerInside.current = true;
            }}
            onBlur={(event) => {
                // Some browsers do not focus clicked buttons; cancelling is still an internal transition.
                if (
                    !pointerInside.current &&
                    !event.currentTarget.contains(event.relatedTarget)
                )
                    void save(false);
            }}
            onKeyDownCapture={(event) => {
                compositionKeyGuard(event);
                if (
                    draft.composing.current ||
                    event.nativeEvent.isComposing ||
                    event.nativeEvent.keyCode === 229
                )
                    return;
                if (event.key === "Escape") {
                    event.preventDefault();
                    event.stopPropagation();
                    void cancel();
                }
                if (
                    shortcutsEnabled &&
                    event.key === "Enter" &&
                    (event.metaKey || event.ctrlKey) &&
                    !event.defaultPrevented
                ) {
                    event.preventDefault();
                    event.currentTarget.requestSubmit();
                }
            }}
            onCompositionStart={draft.onCompositionStart}
            onCompositionEnd={draft.onCompositionEnd}
            onSubmit={(event) => {
                event.preventDefault();
                void save(true);
            }}
        >
            <FormFields ready={draft.ready}>
                <textarea
                    aria-label="内容"
                    data-autofocus
                    rows={3}
                    maxLength={20000}
                    value={draft.value}
                    required
                    onChange={(event) => {
                        draft.update(event.target.value);
                        setFailed(false);
                    }}
                />
                <div className="notes-composer-actions">
                    <span className="notes-save-hint">
                        {shortcutsEnabled
                            ? "⌘/Ctrl+Enter 保存"
                            : "草稿自动保留"}
                    </span>
                    <button
                        type="button"
                        className="notes-cancel"
                        disabled={pending}
                        onClick={() => void cancel()}
                    >
                        取消
                    </button>
                    <button
                        type="submit"
                        disabled={busy || !draft.value.trim()}
                        className="primary"
                    >
                        {pending ? "保存中" : "保存修改"}
                        <span aria-hidden="true">↑</span>
                    </button>
                </div>
                {failed && (
                    <p className="notes-inline-error" role="alert">
                        {error || "保存失败，修改仍保留在这里，请重试。"}
                    </p>
                )}
                {(draft.storageError || draft.stale) && (
                    <DraftHint {...draft} />
                )}
            </FormFields>
        </form>
    );
}

function DeleteIdeaConfirmation({
    idea,
    execute,
    busy,
    close,
}: {
    idea: Idea;
    execute: Execute;
    busy: boolean;
    close: () => void;
}) {
    const cancel = useRef<HTMLButtonElement>(null);
    const submitting = useRef(false);
    const [failed, setFailed] = useState(false);
    useEffect(() => {
        cancel.current?.focus();
    }, []);
    return (
        <div
            className="notes-delete-confirm"
            role="group"
            aria-label="删除记录确认"
            onKeyDown={(event) => {
                if (event.key === "Escape" && !busy && !submitting.current) {
                    event.stopPropagation();
                    close();
                }
            }}
        >
            <p>删除这条记录？它将从飞光和 Sticky Note 中一并移除。</p>
            <div>
                <button
                    type="button"
                    className="danger"
                    disabled={busy}
                    onClick={async () => {
                        if (busy || submitting.current) return;
                        submitting.current = true;
                        try {
                            if (
                                await execute("DeleteIdea", idea.revision, {
                                    idea_id: idea.id,
                                })
                            )
                                close();
                            else setFailed(true);
                        } finally {
                            submitting.current = false;
                        }
                    }}
                >
                    确认删除
                </button>
                <button
                    type="button"
                    ref={cancel}
                    className="text-button"
                    disabled={busy}
                    onClick={close}
                >
                    取消
                </button>
            </div>
            {failed && <p role="alert">删除失败，记录仍保留。请重试。</p>}
        </div>
    );
}

type ReviewProps = {
    date: string;
    snapshot: Snapshot;
    scope: string;
    execute: Execute;
    busy: boolean;
    compact?: boolean;
};
export function Review({
    date,
    snapshot,
    scope,
    execute,
    busy,
    compact = false,
}: ReviewProps) {
    const day = snapshot.days.find((day) => day.date === date);
    return (
        <ReviewForm
            key={date}
            {...{ date, day, snapshot, scope, execute, busy, compact }}
        />
    );
}

function ReviewForm({
    date,
    day,
    snapshot,
    scope,
    execute,
    busy,
    compact,
}: ReviewProps & { day?: Day }) {
    const { pending, error } = useContext(UIStatus);
    const draft = useDraft(scope, `review:${date}`, day?.revision ?? "0", {
        summary: day?.summary ?? "",
        unfinished_reason: day?.unfinished_reason ?? "",
        tomorrow_note: day?.tomorrow_note ?? "",
    });
    const [saved, setSaved] = useState(false);
    const [failed, setFailed] = useState(false);
    const submitting = useRef(false);
    const future = date > snapshot.today;
    const save = async () => {
        if (
            draft.composing.current ||
            !draft.ready ||
            pending ||
            busy ||
            future ||
            submitting.current
        )
            return;
        const value = draft.value;
        if (
            value.summary === (day?.summary ?? "") &&
            value.unfinished_reason === (day?.unfinished_reason ?? "") &&
            value.tomorrow_note === (day?.tomorrow_note ?? "")
        )
            return;
        submitting.current = true;
        setFailed(false);
        try {
            if (
                await execute("UpdateReview", draft.baseRevision, {
                    date,
                    ...value,
                })
            ) {
                await draft.clear(value);
                setSaved(true);
            } else setFailed(true);
        } finally {
            submitting.current = false;
        }
    };
    return (
        <div
            className={`notes-review ${compact ? "notes-review-compact" : ""}`}
        >
            {!compact && (
                <p className="notes-review-context">
                    {dateLabel(date)}
                    {day?.locked_at
                        ? " · 这一天已经收好，仍可补写复盘。"
                        : " · 用几句话，为这一天留个注脚。"}
                </p>
            )}
            {future ? (
                <p className="notes-review-context">
                    未来的日子尚未发生，到时再写下复盘。
                </p>
            ) : (
                <>
                    {compact && day?.locked_at && (
                        <p className="notes-review-history">
                            历史轨迹已锁定，仍可补写复盘。
                        </p>
                    )}
                    <form
                        className="notes-review-form"
                        onBlur={(event) => {
                            if (
                                !event.currentTarget.contains(
                                    event.relatedTarget,
                                )
                            )
                                void save();
                        }}
                        onKeyDownCapture={compositionKeyGuard}
                        onCompositionStart={draft.onCompositionStart}
                        onCompositionEnd={draft.onCompositionEnd}
                        onSubmit={(event) => {
                            event.preventDefault();
                            void save();
                        }}
                    >
                        <FormFields ready={draft.ready}>
                            <label>
                                今日总结
                                <textarea
                                    rows={compact ? 3 : 5}
                                    placeholder="今天做了什么？有什么值得记住？"
                                    value={draft.value.summary}
                                    maxLength={20000}
                                    onChange={(event) => {
                                        draft.update({
                                            ...draft.value,
                                            summary: event.target.value,
                                        });
                                        setSaved(false);
                                    }}
                                />
                            </label>
                            <label>
                                未完成原因
                                <textarea
                                    rows={3}
                                    placeholder="是什么挡住了进展？"
                                    value={draft.value.unfinished_reason}
                                    maxLength={20000}
                                    onChange={(event) => {
                                        draft.update({
                                            ...draft.value,
                                            unfinished_reason:
                                                event.target.value,
                                        });
                                        setSaved(false);
                                    }}
                                />
                            </label>
                            <label>
                                明日注意事项
                                <textarea
                                    rows={3}
                                    placeholder="明天开始前，需要提醒自己什么？"
                                    value={draft.value.tomorrow_note}
                                    maxLength={20000}
                                    onChange={(event) => {
                                        draft.update({
                                            ...draft.value,
                                            tomorrow_note: event.target.value,
                                        });
                                        setSaved(false);
                                    }}
                                />
                            </label>
                            {(draft.storageError || draft.stale) && (
                                <DraftHint {...draft} />
                            )}
                            {failed && (
                                <p className="notes-inline-error" role="alert">
                                    {error ||
                                        "保存失败，复盘草稿仍保留在这里，请重试。"}
                                </p>
                            )}
                            <div className="notes-review-save">
                                <span className="success-text" role="status">
                                    {saved ? "✓ 复盘已保存" : ""}
                                </span>
                                <button
                                    className="primary"
                                    disabled={busy}
                                    type="submit"
                                >
                                    {pending ? "正在保存…" : "保存复盘"}
                                </button>
                            </div>
                        </FormFields>
                    </form>
                </>
            )}
        </div>
    );
}
