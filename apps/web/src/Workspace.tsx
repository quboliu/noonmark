import { useContext, useEffect, useRef, useState } from "react";
import type { Execute, Snapshot, Trace } from "./types";
import { useDraft } from "./drafts";
import {
    DraftHint,
    Icon,
    Modal,
    UIStatus,
    compositionKeyGuard,
    dateLabel,
    nextDate,
} from "./ui";

export const visibleTrace = (trace: Trace) =>
    !["cancelledDraft", "returnedToPool", "changed"].includes(trace.status);

export function DateStrip({
    date,
    today,
    snapshot,
    onChange,
}: {
    date: string;
    today: string;
    snapshot: Snapshot;
    onChange: (date: string) => void;
}) {
    const [start, setStart] = useState(() => nextDate(date, -6));
    const strip = useRef<HTMLDivElement>(null);
    useEffect(() => {
        if (date < start || date > nextDate(start, 13))
            setStart(nextDate(date, -6));
    }, [date, start]);
    useEffect(() => {
        const selected = strip.current?.querySelector<HTMLButtonElement>(
            '[aria-pressed="true"]',
        );
        if (
            selected &&
            strip.current &&
            strip.current.scrollWidth > strip.current.clientWidth
        )
            strip.current.scrollTo({
                left: Math.max(
                    0,
                    selected.offsetLeft -
                        strip.current.offsetLeft -
                        strip.current.clientWidth / 2 +
                        selected.clientWidth / 2,
                ),
            });
    }, [date, start]);
    return (
        <div
            className="date-strip"
            role="group"
            aria-label="日期导航"
            ref={strip}
        >
            {Array.from({ length: 14 }, (_, index) => {
                const day = nextDate(start, index);
                const hasTasks = snapshot.traces.some(
                    (trace) => trace.date === day && visibleTrace(trace),
                );
                return (
                    <button
                        key={day}
                        className={`date-cell ${day === date ? "selected" : ""} ${day === today ? "today" : ""}`}
                        aria-label={dateLabel(day, {
                            year: "numeric",
                            month: "long",
                            day: "numeric",
                            weekday: "long",
                        })}
                        aria-pressed={day === date}
                        tabIndex={day === date ? 0 : -1}
                        onClick={() => onChange(day)}
                        onKeyDown={(event) => {
                            const step =
                                event.key === "ArrowLeft"
                                    ? -1
                                    : event.key === "ArrowRight"
                                      ? 1
                                      : 0;
                            if (!step) return;
                            event.preventDefault();
                            const next = nextDate(day, step);
                            onChange(next);
                            requestAnimationFrame(() =>
                                strip.current
                                    ?.querySelector<HTMLButtonElement>(
                                        '[aria-pressed="true"]',
                                    )
                                    ?.focus(),
                            );
                        }}
                    >
                        <span className="date-weekday">
                            {dateLabel(day, { weekday: "narrow" })}
                        </span>
                        <span className="date-number">
                            {Number(day.slice(8))}
                        </span>
                        <span
                            className={`date-dot ${hasTasks ? "has-tasks" : ""}`}
                        />
                    </button>
                );
            })}
        </div>
    );
}

export function InlineTask({
    date,
    today,
    scope,
    execute,
    busy,
    openPool,
}: {
    date: string;
    today: string;
    scope: string;
    execute: Execute;
    busy: boolean;
    openPool?: () => void;
}) {
    const { pending } = useContext(UIStatus);
    const draft = useDraft(scope, `inline-task:${date || "pool"}`, "0", "");
    const input = useRef<HTMLInputElement>(null);
    const label = !date
        ? "新建到任务池"
        : date === today
          ? "添加今日任务"
          : "添加当天任务";
    return (
        <div className="inline-task-area">
            <div className="inline-task-line">
                <form
                    onKeyDownCapture={compositionKeyGuard}
                    onCompositionStart={draft.onCompositionStart}
                    onCompositionEnd={draft.onCompositionEnd}
                    onSubmit={async (event) => {
                        event.preventDefault();
                        if (
                            draft.composing.current ||
                            busy ||
                            !draft.ready ||
                            !draft.value.trim()
                        )
                            return;
                        if (
                            await execute("CreateTask", "0", {
                                title: draft.value.trim(),
                                description: "",
                                date,
                            })
                        ) {
                            await draft.clear("");
                            input.current?.focus();
                        }
                    }}
                >
                    <input
                        ref={input}
                        aria-label={label}
                        placeholder={`${label}，按 Enter 保存`}
                        value={draft.value}
                        maxLength={2000}
                        readOnly={pending || !draft.ready}
                        onChange={(event) => draft.update(event.target.value)}
                    />
                    <button
                        className="inline-add-action icon-button"
                        type="submit"
                        aria-label="保存行内任务"
                        disabled={busy || !draft.ready || !draft.value.trim()}
                    >
                        <Icon name="plus" size={15} />
                    </button>
                </form>
                {openPool && (
                    <button className="quiet-button" onClick={openPool}>
                        从任务池排期…
                    </button>
                )}
            </div>
            {(draft.storageError || draft.stale) && <DraftHint {...draft} />}
        </div>
    );
}

export function PoolPicker({
    snapshot,
    date,
    execute,
    busy,
    close,
}: {
    snapshot: Snapshot;
    date: string;
    execute: Execute;
    busy: boolean;
    close: () => void;
}) {
    const [search, setSearch] = useState("");
    const pool = snapshot.chains
        .filter((chain) => chain.location === "pool")
        .map((chain) => ({
            chain,
            title:
                snapshot.definitions.find(
                    (item) => item.id === chain.definition_id,
                )?.title ?? "无标题",
        }))
        .filter((item) => item.title.includes(search));
    return (
        <Modal title="从任务池排期" close={close}>
            <p className="muted">
                安排到 {dateLabel(date)}，任务原有轨迹会保留。
            </p>
            <input
                type="search"
                aria-label="筛选任务池"
                placeholder="搜索任务"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
            />
            <ul className="schedule-pool-list">
                {pool.map(({ chain, title }) => (
                    <li key={chain.id}>
                        <span>{title}</span>
                        <button
                            disabled={busy}
                            onClick={async () => {
                                if (
                                    await execute(
                                        "ScheduleTask",
                                        chain.revision,
                                        { chain_id: chain.id, date },
                                    )
                                )
                                    close();
                            }}
                        >
                            排期
                        </button>
                    </li>
                ))}
            </ul>
            {!pool.length && (
                <p className="muted">没有符合条件的未排期任务。</p>
            )}
        </Modal>
    );
}

export function DaySummary({
    snapshot,
    date,
}: {
    snapshot: Snapshot;
    date: string;
}) {
    const traces = snapshot.traces.filter(
        (trace) => trace.date === date && visibleTrace(trace),
    );
    const total = traces.length;
    const complete = traces.filter(
        (trace) => trace.status === "completed",
    ).length;
    const rate = total ? Math.round((100 * complete) / total) : 0;
    return (
        <div className="day-summary">
            <div className="rail-caption">
                <span>每日复盘</span>
                <time>
                    {dateLabel(date, {
                        month: "long",
                        day: "numeric",
                        weekday: "short",
                    })}
                </time>
            </div>
            <div className="summary-rate">
                <span>完成率</span>
                <strong>{rate}%</strong>
            </div>
            <h3>近 7 天完成率</h3>
            <div className="week-chart" aria-label="近 7 天完成率">
                {Array.from({ length: 7 }, (_, i) => {
                    const day = nextDate(date, i - 6);
                    const items = snapshot.traces.filter(
                        (t) => t.date === day && visibleTrace(t),
                    );
                    const value = items.length
                        ? Math.round(
                              (items.filter((t) => t.status === "completed")
                                  .length *
                                  100) /
                                  items.length,
                          )
                        : 0;
                    return (
                        <div key={day} title={`${day}：${value}%`}>
                            <div className="chart-column">
                                <i
                                    style={{
                                        height: Math.max(3, value * 0.45),
                                    }}
                                />
                            </div>
                            <small>
                                {dateLabel(day, { weekday: "narrow" })}
                            </small>
                        </div>
                    );
                })}
            </div>
            <dl className="summary-counts">
                <div>
                    <dt>总任务</dt>
                    <dd>{total}</dd>
                </div>
                {[
                    ["pending", "待完成"],
                    ["completed", "已完成"],
                    ["unfinished", "未完成"],
                    ["deferred", "已延期"],
                    ["abandoned", "已废弃"],
                ].map(([status, label]) => (
                    <div key={status}>
                        <dt>{label}</dt>
                        <dd className={`count-${status}`}>
                            {traces.filter((t) => t.status === status).length}
                        </dd>
                    </div>
                ))}
            </dl>
        </div>
    );
}

export function Calendar({
    snapshot,
    date,
    setDate,
    openDay,
    swipeDirection,
}: {
    snapshot: Snapshot;
    date: string;
    setDate: (date: string) => void;
    openDay: (date: string) => void;
    swipeDirection: "book" | "reversed";
}) {
    const [month, setMonth] = useState(date.slice(0, 7));
    const touch = useRef<{ x: number; y: number } | null>(null);
    const first = `${month}-01`;
    const weekday = (new Date(`${first}T12:00:00Z`).getUTCDay() + 6) % 7;
    const start = nextDate(first, -weekday);
    const shiftMonth = (offset: number) => {
        const value = new Date(`${first}T12:00:00Z`);
        value.setUTCMonth(value.getUTCMonth() + offset);
        setMonth(value.toISOString().slice(0, 7));
    };
    return (
        <section
            className="calendar-page"
            onTouchStart={(event) => {
                const point = event.touches[0];
                touch.current = { x: point.clientX, y: point.clientY };
            }}
            onTouchEnd={(event) => {
                const origin = touch.current;
                touch.current = null;
                if (!origin) return;
                const end = event.changedTouches[0];
                if (
                    Math.abs(end.clientX - origin.x) < 80 ||
                    Math.abs(end.clientY - origin.y) > 40
                )
                    return;
                const step = end.clientX < origin.x ? 1 : -1;
                shiftMonth(swipeDirection === "book" ? step : -step);
            }}
        >
            <div className="calendar-toolbar">
                <h2>{dateLabel(first, { year: "numeric", month: "long" })}</h2>
                <div>
                    <button
                        className="icon-button"
                        aria-label="上个月"
                        onClick={() => shiftMonth(-1)}
                    >
                        <Icon name="left" size={15} />
                    </button>
                    <button
                        className="text-button"
                        onClick={() => {
                            setMonth(snapshot.today.slice(0, 7));
                            setDate(snapshot.today);
                        }}
                    >
                        本月
                    </button>
                    <button
                        className="icon-button"
                        aria-label="下个月"
                        onClick={() => shiftMonth(1)}
                    >
                        <Icon name="right" size={15} />
                    </button>
                </div>
            </div>
            <div className="calendar-weekdays">
                {["一", "二", "三", "四", "五", "六", "日"].map((day) => (
                    <span key={day}>{day}</span>
                ))}
            </div>
            <div className="calendar-grid" role="grid" aria-label="月历">
                {Array.from({ length: 6 }, (_, row) => (
                    <div role="row" className="calendar-week" key={row}>
                        {Array.from({ length: 7 }, (_, column) => {
                            const day = nextDate(start, row * 7 + column);
                            const items = snapshot.traces.filter(
                                (t) => t.date === day && visibleTrace(t),
                            );
                            return (
                                <div
                                    role="gridcell"
                                    key={day}
                                    aria-selected={day === date}
                                >
                                    <button
                                        className={`calendar-day ${day === snapshot.today ? "today" : ""} ${day === date ? "selected" : ""} ${day.slice(0, 7) !== month ? "other-month" : ""}`}
                                        aria-label={`${day} ${items.length} 项任务`}
                                        onClick={() => setDate(day)}
                                        onDoubleClick={() => openDay(day)}
                                        onKeyDown={(event) => {
                                            const step = (
                                                {
                                                    ArrowLeft: -1,
                                                    ArrowRight: 1,
                                                    ArrowUp: -7,
                                                    ArrowDown: 7,
                                                } as Record<string, number>
                                            )[event.key];
                                            if (!step) return;
                                            event.preventDefault();
                                            const next = nextDate(day, step);
                                            setDate(next);
                                            if (
                                                next < start ||
                                                next > nextDate(start, 41)
                                            )
                                                setMonth(next.slice(0, 7));
                                            requestAnimationFrame(() =>
                                                document
                                                    .querySelector<HTMLButtonElement>(
                                                        `.calendar-day[aria-label^="${next} "]`,
                                                    )
                                                    ?.focus(),
                                            );
                                        }}
                                    >
                                        <time>{Number(day.slice(8))}</time>
                                        {items.length > 0 && (
                                            <>
                                                <small>
                                                    {items.length} 项任务
                                                </small>
                                                <span className="calendar-dots">
                                                    {items
                                                        .slice(0, 5)
                                                        .map((t) => (
                                                            <i
                                                                className={
                                                                    t.status ===
                                                                    "completed"
                                                                        ? "complete"
                                                                        : ""
                                                                }
                                                                key={t.id}
                                                            />
                                                        ))}
                                                </span>
                                            </>
                                        )}
                                    </button>
                                </div>
                            );
                        })}
                    </div>
                ))}
            </div>
        </section>
    );
}
