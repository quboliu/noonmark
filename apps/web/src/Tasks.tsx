import { useContext, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useDraft } from "./drafts";
import type { Chain, Execute, Snapshot, Subtask, Trace } from "./types";
import {
    DraftHint,
    Empty,
    FormFields,
    Icon,
    Modal,
    UIStatus,
    compositionKeyGuard,
    dateLabel,
    nextDate,
} from "./ui";

export const statuses: Record<string, string> = {
    pending: "待完成",
    completed: "已完成",
    unfinished: "未完成",
    deferred: "已延期",
    changed: "已变更",
    returnedToPool: "已回池",
    cancelledDraft: "已撤销计划",
    abandoned: "已废弃",
};
export function NewTask({
    snapshot,
    scope,
    date,
    close,
    execute,
    busy,
}: {
    snapshot: Snapshot;
    scope: string;
    date: string;
    close: () => void;
    execute: Execute;
    busy: boolean;
}) {
    const draft = useDraft(scope, "new-task", "0", {
        title: "",
        description: "",
        date,
    });
    const submit = async (event: FormEvent) => {
        event.preventDefault();
        if (
            draft.composing.current ||
            !draft.ready ||
            busy ||
            !draft.value.title.trim()
        )
            return;
        if (
            await execute("CreateTask", "0", {
                ...draft.value,
                title: draft.value.title.trim(),
            })
        ) {
            await draft.clear({ title: "", description: "", date });
            close();
        }
    };
    return (
        <Modal title="添加任务" close={close}>
            <form
                onSubmit={submit}
                onKeyDownCapture={compositionKeyGuard}
                onCompositionStart={draft.onCompositionStart}
                onCompositionEnd={draft.onCompositionEnd}
            >
                <FormFields ready={draft.ready}>
                    <label>
                        任务名称
                        <input
                            data-autofocus
                            name="task-title"
                            value={draft.value.title}
                            maxLength={2000}
                            required
                            placeholder="接下来想做什么？"
                            onChange={(event) =>
                                draft.update({
                                    ...draft.value,
                                    title: event.target.value,
                                })
                            }
                        />
                    </label>
                    <label>
                        描述 <span className="optional">可选</span>
                        <textarea
                            name="task-description"
                            rows={3}
                            value={draft.value.description}
                            maxLength={20000}
                            onChange={(event) =>
                                draft.update({
                                    ...draft.value,
                                    description: event.target.value,
                                })
                            }
                            placeholder="补充一点背景，留给开始时的自己。"
                        />
                    </label>
                    <label>
                        安排日期
                        <input
                            type="date"
                            aria-label="安排日期"
                            min={snapshot.today}
                            value={draft.value.date}
                            onChange={(event) =>
                                draft.update({
                                    ...draft.value,
                                    date: event.target.value,
                                })
                            }
                        />
                    </label>
                    <p className="field-hint">不选日期，先放入任务池。</p>
                    <DraftHint {...draft} />
                    <div className="form-actions">
                        <button
                            type="button"
                            className="text-button"
                            onClick={close}
                        >
                            取消
                        </button>
                        <button
                            className="primary"
                            disabled={busy}
                            type="submit"
                        >
                            {busy ? "正在提交…" : "添加任务"}
                        </button>
                    </div>
                </FormFields>
            </form>
        </Modal>
    );
}

export function TaskList({
    snapshot,
    chains,
    traces,
    onSelect,
    execute,
    disabled,
    historyView,
    completedChildren,
    selectedID,
}: {
    snapshot: Snapshot;
    chains?: Chain[];
    traces?: Trace[];
    onSelect: (chain: Chain, trace?: Trace) => void;
    execute: Execute;
    disabled: boolean;
    historyView?: boolean;
    completedChildren?: boolean;
    selectedID?: string;
}) {
    const [expanded, setExpanded] = useState<Set<string>>(new Set());
    const [contextID, setContextID] = useState<string>();
    const entries = traces
        ? traces.map((trace) => ({
              chain: snapshot.chains.find(
                  (chain) => chain.id === trace.chain_id,
              )!,
              trace,
          }))
        : (chains ?? []).map((chain) => ({
              chain,
              trace: undefined as Trace | undefined,
          }));
    if (!entries.length) return <Empty>暂无任务</Empty>;
    return (
        <ul className="task-list">
            {entries.map(({ chain, trace }) => {
                if (!chain) return null;
                const id = trace?.id ?? chain.id;
                const isExpanded = completedChildren
                    ? !expanded.has(id)
                    : expanded.has(id);
                const definition = snapshot.definitions.find(
                    (definition) =>
                        definition.id ===
                        (trace?.definition_id ?? chain.definition_id),
                );
                const editable =
                    !historyView &&
                    trace?.date === snapshot.today &&
                    ["pending", "completed"].includes(trace.status);
                const childLineages = new Set<string>();
                const children = completedChildren
                    ? snapshot.subtasks.filter((item) => {
                          if (
                              item.status !== "completed" ||
                              childLineages.has(item.lineage_id) ||
                              !snapshot.traces.some(
                                  (parent) =>
                                      parent.id === item.trace_id &&
                                      parent.chain_id === chain.id,
                              )
                          )
                              return false;
                          childLineages.add(item.lineage_id);
                          return true;
                      })
                    : snapshot.subtasks.filter(
                          (item) =>
                              item.trace_id === trace?.id &&
                              item.status !== "cancelledDraft",
                      );
                const history = snapshot.traces.filter(
                    (item) =>
                        item.chain_id === chain.id &&
                        item.status !== "cancelledDraft",
                );
                const title = definition?.title || "无标题";
                const completedTime = trace?.completed_at
                    ? new Intl.DateTimeFormat("zh-CN", {
                          hour: "2-digit",
                          minute: "2-digit",
                          timeZone: snapshot.timezone,
                      }).format(new Date(trace.completed_at))
                    : "";
                return (
                    <li
                        className={`task-row ${trace?.status === "completed" ? "is-complete" : ""} ${selectedID === id ? "is-selected" : ""}`}
                        key={id}
                        data-task-id={id}
                        onContextMenu={(event) => {
                            event.preventDefault();
                            setContextID(id);
                        }}
                    >
                        <div className="task-row-main">
                            {editable ? (
                                <button
                                    disabled={disabled}
                                    className={`task-check ${trace.status === "completed" ? "checked" : ""}`}
                                    aria-label={`${trace.status === "completed" ? "撤销完成" : "完成"}：${title}`}
                                    onClick={() => {
                                        void execute(
                                            trace.status === "completed"
                                                ? "UndoCompleteTrace"
                                                : "CompleteTrace",
                                            chain.revision,
                                            { trace_id: trace.id },
                                        );
                                    }}
                                >
                                    {trace.status === "completed" && (
                                        <Icon name="check" size={13} />
                                    )}
                                </button>
                            ) : (
                                <span
                                    className={`task-check static ${!trace ? "pool-check" : ""} ${trace?.status === "completed" ? "checked" : ""}`}
                                    aria-hidden="true"
                                >
                                    {trace?.status === "completed" && (
                                        <Icon name="check" size={13} />
                                    )}
                                </span>
                            )}
                            <button
                                className="task-open"
                                aria-label={title}
                                onClick={() => onSelect(chain, trace)}
                            >
                                <span className="task-title">{title}</span>
                                {historyView && (
                                    <span className="task-history-meta">
                                        {completedChildren
                                            ? `${trace?.date ?? ""} ${completedTime}`
                                            : `${history.filter((item) => item.status === "unfinished").length} 次未完成 · ${history.filter((item) => item.carried_from_trace_id).length} 次延续 · 最近 ${trace?.date}`}
                                    </span>
                                )}
                            </button>
                            {children.length > 0 && (
                                <button
                                    className="subtask-disclosure"
                                    aria-expanded={isExpanded}
                                    aria-label={`${isExpanded ? "收起" : "展开"}子任务：${title}`}
                                    onClick={() =>
                                        setExpanded((current) => {
                                            const next = new Set(current);
                                            if (next.has(id)) next.delete(id);
                                            else next.add(id);
                                            return next;
                                        })
                                    }
                                >
                                    <Icon
                                        name={isExpanded ? "close" : "right"}
                                        size={12}
                                    />
                                    {children.length} 子任务
                                </button>
                            )}
                            {trace &&
                                !["pending", "completed"].includes(
                                    trace.status,
                                ) && (
                                    <span
                                        className={`row-meta status-${trace.status}`}
                                    >
                                        {statuses[trace.status]}
                                    </span>
                                )}
                            <details
                                className="task-menu"
                                open={contextID === id}
                                onToggle={(event) => {
                                    if (
                                        !(event.target as HTMLDetailsElement)
                                            .open &&
                                        contextID === id
                                    )
                                        setContextID(undefined);
                                }}
                            >
                                <summary
                                    aria-label={`任务操作：${title}`}
                                    onClick={(event) => {
                                        event.preventDefault();
                                        setContextID(
                                            contextID === id ? undefined : id,
                                        );
                                    }}
                                >
                                    …
                                </summary>
                                <div>
                                    <button
                                        onClick={() => {
                                            setContextID(undefined);
                                            onSelect(chain, trace);
                                        }}
                                    >
                                        查看详情
                                    </button>
                                    {editable && (
                                        <button
                                            disabled={disabled}
                                            onClick={() => {
                                                setContextID(undefined);
                                                void execute(
                                                    trace.status === "completed"
                                                        ? "UndoCompleteTrace"
                                                        : "CompleteTrace",
                                                    chain.revision,
                                                    { trace_id: trace.id },
                                                );
                                            }}
                                        >
                                            {trace.status === "completed"
                                                ? "撤销今日完成"
                                                : "标为完成"}
                                        </button>
                                    )}
                                    {trace?.status === "pending" &&
                                        trace.date >= snapshot.today && (
                                            <button
                                                disabled={disabled}
                                                onClick={() => {
                                                    setContextID(undefined);
                                                    void execute(
                                                        "ReturnToPool",
                                                        chain.revision,
                                                        { trace_id: trace.id },
                                                    );
                                                }}
                                            >
                                                回到任务池
                                            </button>
                                        )}
                                </div>
                            </details>
                        </div>
                        {trace &&
                            trace.status === "pending" &&
                            trace.progress > 0 && (
                                <div
                                    className="task-progress"
                                    aria-label={`进度 ${trace.progress}%`}
                                >
                                    <span>
                                        <i
                                            style={{
                                                width: `${trace.progress}%`,
                                            }}
                                        />
                                    </span>
                                    <small>{trace.progress}%</small>
                                </div>
                            )}
                        {children.length > 0 && isExpanded && (
                            <ul className="completed-children">
                                {children.map((child) => (
                                    <li key={child.lineage_id}>
                                        <button
                                            className="text-button"
                                            onClick={() =>
                                                onSelect(
                                                    chain,
                                                    snapshot.traces.find(
                                                        (item) =>
                                                            item.id ===
                                                            child.trace_id,
                                                    ),
                                                )
                                            }
                                        >
                                            {child.status === "completed" ? (
                                                <Icon name="check" size={13} />
                                            ) : (
                                                <span className="child-pending" />
                                            )}
                                            <span>{child.title}</span>
                                            <small>
                                                {completedChildren
                                                    ? snapshot.traces.find(
                                                          (item) =>
                                                              item.id ===
                                                              child.trace_id,
                                                      )?.date
                                                    : statuses[child.status]}
                                            </small>
                                        </button>
                                    </li>
                                ))}
                            </ul>
                        )}
                    </li>
                );
            })}
        </ul>
    );
}

export function TaskDetail({
    snapshot,
    chainID,
    traceID,
    scope,
    execute,
    busy,
    close,
    mobile,
}: {
    mobile?: boolean;
    snapshot: Snapshot;
    chainID: string;
    traceID?: string;
    scope: string;
    execute: Execute;
    busy: boolean;
    close: () => void;
}) {
    const chain = snapshot.chains.find((chain) => chain.id === chainID);
    const trace = traceID
        ? snapshot.traces.find(
              (trace) =>
                  trace.id === traceID && trace.status !== "cancelledDraft",
          )
        : snapshot.traces
              .filter(
                  (trace) =>
                      trace.chain_id === chainID && trace.status === "pending",
              )
              .sort((a, b) => b.date.localeCompare(a.date))[0];
    if (!chain) return null;
    return (
        <TaskDetailForm
            key={`${chain.id}:${trace?.id ?? "pool"}`}
            {...{ snapshot, chain, trace, scope, execute, busy, close, mobile }}
        />
    );
}
function TaskDetailForm({
    snapshot,
    chain,
    trace,
    scope,
    execute,
    busy,
    close,
    mobile,
}: {
    mobile?: boolean;
    snapshot: Snapshot;
    chain: Chain;
    trace?: Trace;
    scope: string;
    execute: Execute;
    busy: boolean;
    close: () => void;
}) {
    const definition = snapshot.definitions.find(
        (definition) =>
            definition.id === (trace?.definition_id ?? chain.definition_id),
    );
    const draft = useDraft(
        scope,
        `edit-task:${chain.id}:${trace?.id ?? "pool"}`,
        chain.revision,
        {
            title: definition?.title ?? "",
            description: definition?.description ?? "",
        },
    );
    const [date, setDate] = useState(
        trace?.date && trace.date > snapshot.today
            ? trace.date
            : snapshot.today,
    );
    const [showEdit, setShowEdit] = useState(false);
    const container = useRef<HTMLElement>(null);
    const { error } = useContext(UIStatus);
    useEffect(() => {
        container.current?.focus();
    }, []);
    const [confirmAbandon, setConfirmAbandon] = useState(false);
    const future = Boolean(
        trace && trace.date > snapshot.today && trace.status === "pending",
    );
    const editable =
        chain.state === "active" &&
        ((chain.location === "pool" && !trace) ||
            (trace?.status === "pending" && trace.date >= snapshot.today));
    const todayPending =
        trace?.date === snapshot.today && trace.status === "pending";
    const todayComplete =
        trace?.date === snapshot.today && trace.status === "completed";
    const traces = snapshot.traces
        .filter(
            (item) =>
                item.chain_id === chain.id && item.status !== "cancelledDraft",
        )
        .sort(
            (a, b) =>
                b.date.localeCompare(a.date) ||
                b.created_at.localeCompare(a.created_at),
        );
    const latest = trace?.id === traces[0]?.id;
    const continuable = Boolean(
        latest &&
            trace?.status === "unfinished" &&
            chain.location === "followup",
    );
    const abandonable = Boolean(
        latest &&
            trace &&
            chain.state === "active" &&
            (todayPending || future || continuable),
    );
    const reactivateable = Boolean(
        latest && trace && chain.state === "abandoned",
    );
    const action = async (type: string, payload: Record<string, unknown>) => {
        const success = await execute(type, chain.revision, payload);
        if (success) {
            setConfirmAbandon(false);
        }
        return success;
    };
    const save = async (event: FormEvent) => {
        event.preventDefault();
        if (draft.composing.current || !draft.value.title.trim()) return;
        if (
            await execute("EditTask", draft.baseRevision, {
                chain_id: chain.id,
                ...draft.value,
                title: draft.value.title.trim(),
            })
        ) {
            await draft.clear(draft.value);
            setShowEdit(false);
        }
    };
    const subtasks = snapshot.subtasks
        .filter(
            (subtask) =>
                subtask.trace_id === trace?.id &&
                subtask.status !== "cancelledDraft",
        )
        .sort((a, b) => a.position - b.position);
    return (
        <section
            ref={container}
            tabIndex={-1}
            role={mobile ? "group" : "dialog"}
            aria-label="任务详情"
            aria-modal={mobile ? undefined : false}
            className="task-detail"
            onKeyDown={(event) => {
                if (
                    event.key === "Escape" &&
                    !event.nativeEvent.isComposing &&
                    !busy
                ) {
                    event.stopPropagation();
                    close();
                }
            }}
        >
            <div className="detail-header">
                <span>任务详情</span>
                <button
                    className="icon-button"
                    aria-label="关闭"
                    disabled={busy}
                    onClick={close}
                >
                    <Icon name="close" size={15} />
                </button>
            </div>
            {error && (
                <p className="modal-feedback" role="alert">
                    {error}
                </p>
            )}
            <div className="detail-heading">
                <p className="eyebrow">
                    {trace
                        ? `${dateLabel(trace.date)} · ${statuses[trace.status]}`
                        : "任务池"}
                </p>
                <h3 onDoubleClick={() => editable && setShowEdit(true)}>
                    {definition?.title || "无标题"}
                </h3>
                {definition?.description && (
                    <p className="preserve-lines muted">
                        {definition.description}
                    </p>
                )}
            </div>
            {editable && !showEdit && (
                <button
                    className="text-button"
                    onClick={() => setShowEdit(true)}
                >
                    编辑任务
                </button>
            )}
            {showEdit && (
                <form
                    className="inline-edit"
                    onSubmit={save}
                    onKeyDownCapture={compositionKeyGuard}
                    onCompositionStart={draft.onCompositionStart}
                    onCompositionEnd={draft.onCompositionEnd}
                >
                    <FormFields ready={draft.ready}>
                        <label>
                            任务名称
                            <input
                                value={draft.value.title}
                                maxLength={2000}
                                required
                                onChange={(event) =>
                                    draft.update({
                                        ...draft.value,
                                        title: event.target.value,
                                    })
                                }
                            />
                        </label>
                        <label>
                            描述
                            <textarea
                                rows={3}
                                value={draft.value.description}
                                maxLength={20000}
                                onChange={(event) =>
                                    draft.update({
                                        ...draft.value,
                                        description: event.target.value,
                                    })
                                }
                            />
                        </label>
                        <DraftHint {...draft} />
                        <div className="form-actions">
                            <button
                                className="text-button"
                                type="button"
                                onClick={() => setShowEdit(false)}
                            >
                                收起
                            </button>
                            <button
                                className="primary"
                                disabled={busy}
                                type="submit"
                            >
                                保存修改
                            </button>
                        </div>
                    </FormFields>
                </form>
            )}
            <div className="detail-actions">
                {todayPending && (
                    <button
                        className="primary"
                        disabled={busy}
                        onClick={() =>
                            void action("CompleteTrace", {
                                trace_id: trace!.id,
                            })
                        }
                    >
                        <Icon name="check" size={16} />
                        标为完成
                    </button>
                )}
                {todayComplete && (
                    <button
                        disabled={busy}
                        onClick={() =>
                            void action("UndoCompleteTrace", {
                                trace_id: trace!.id,
                            })
                        }
                    >
                        撤销今日完成
                    </button>
                )}
                {(todayPending || future) && (
                    <button
                        disabled={busy}
                        onClick={() =>
                            void action("ReturnToPool", { trace_id: trace!.id })
                        }
                    >
                        回到任务池
                    </button>
                )}
                {reactivateable && (
                    <button
                        disabled={busy}
                        onClick={() =>
                            void action("ReactivateChain", {
                                trace_id: trace!.id,
                            })
                        }
                    >
                        重新激活
                    </button>
                )}
            </div>
            {((chain.location === "pool" && !trace) ||
                future ||
                todayPending ||
                continuable) && (
                <form
                    className="schedule-form"
                    onSubmit={(event) => {
                        event.preventDefault();
                        const type = !trace
                            ? "ScheduleTask"
                            : future
                              ? "RescheduleTrace"
                              : continuable
                                ? "ContinueTrace"
                                : "DeferTrace";
                        void action(
                            type,
                            trace
                                ? { trace_id: trace.id, date }
                                : { chain_id: chain.id, date },
                        );
                    }}
                >
                    <label>
                        {continuable
                            ? "延续到"
                            : todayPending
                              ? "延期到"
                              : "安排到"}
                        <input
                            type="date"
                            required
                            min={
                                todayPending || future
                                    ? nextDate(snapshot.today, 1)
                                    : snapshot.today
                            }
                            value={date}
                            onChange={(event) => setDate(event.target.value)}
                            disabled={busy}
                        />
                    </label>
                    <button
                        type="submit"
                        disabled={
                            busy ||
                            !date ||
                            ((todayPending || future) && date <= snapshot.today)
                        }
                    >
                        {continuable
                            ? "延续任务"
                            : todayPending
                              ? "确认延期"
                              : "确认排期"}
                    </button>
                </form>
            )}
            {!trace && (definition?.planned_subtasks?.length ?? 0) > 0 && (
                <section className="detail-section">
                    <h4>计划子任务</h4>
                    <ul className="planned-subtasks">
                        {definition!.planned_subtasks.map((item) => (
                            <li key={item.id}>
                                {item.title}
                                <small>
                                    {
                                        {
                                            simple: "简单",
                                            medium: "中等",
                                            hard: "困难",
                                        }[item.difficulty]
                                    }
                                </small>
                            </li>
                        ))}
                    </ul>
                    <p className="muted">
                        排期后，可在当天的任务详情中继续处理。
                    </p>
                </section>
            )}
            {trace && (
                <section className="detail-section">
                    <h4>
                        子任务{" "}
                        <span className="muted">
                            {
                                subtasks.filter(
                                    (item) => item.status === "completed",
                                ).length
                            }
                            /{subtasks.length}
                        </span>
                    </h4>
                    {!subtasks.length && (
                        <p className="muted">
                            把复杂的事拆成可以开始的一小步。
                        </p>
                    )}
                    <ul className="subtask-list">
                        {subtasks.map((subtask) => (
                            <SubtaskRow
                                key={subtask.id}
                                {...{
                                    subtask,
                                    snapshot,
                                    chain,
                                    trace,
                                    busy,
                                    execute,
                                    scope,
                                }}
                            />
                        ))}
                    </ul>
                    {editable && (
                        <NewSubtask
                            {...{ scope, trace, chain, busy, execute }}
                        />
                    )}
                    {todayPending &&
                        !snapshot.subtasks.some(
                            (item) =>
                                item.status !== "cancelledDraft" &&
                                snapshot.traces.some(
                                    (parent) =>
                                        parent.id === item.trace_id &&
                                        parent.chain_id === chain.id,
                                ),
                        ) && (
                            <ProgressEditor
                                trace={trace}
                                chain={chain}
                                busy={busy}
                                execute={execute}
                            />
                        )}
                </section>
            )}
            <section className="detail-section">
                <h4>
                    <Icon name="history" size={16} />
                    任务轨迹
                </h4>
                {traces.length ? (
                    <ol className="history-list">
                        {traces.map((item) => (
                            <li key={item.id}>
                                <time dateTime={item.date}>{item.date}</time>
                                <span>{statuses[item.status]}</span>
                                {item.carried_from_trace_id && (
                                    <small>延续自此前轨迹</small>
                                )}
                            </li>
                        ))}
                    </ol>
                ) : (
                    <p className="muted">还未安排日期，暂时没有日轨迹。</p>
                )}
            </section>
            {abandonable && (
                <div className="danger-zone">
                    {confirmAbandon ? (
                        <>
                            <p>废弃这条任务链？已经发生的轨迹仍会保留。</p>
                            <div className="detail-actions">
                                <button
                                    className="danger"
                                    disabled={busy}
                                    onClick={() =>
                                        void action("AbandonChain", {
                                            trace_id: trace!.id,
                                        })
                                    }
                                >
                                    确认废弃
                                </button>
                                <button
                                    className="text-button"
                                    onClick={() => setConfirmAbandon(false)}
                                >
                                    保留任务
                                </button>
                            </div>
                        </>
                    ) : (
                        <button
                            className="text-button danger"
                            onClick={() => setConfirmAbandon(true)}
                        >
                            废弃任务
                        </button>
                    )}
                </div>
            )}
        </section>
    );
}
function NewSubtask({
    scope,
    trace,
    chain,
    busy,
    execute,
}: {
    scope: string;
    trace: Trace;
    chain: Chain;
    busy: boolean;
    execute: Execute;
}) {
    const draft = useDraft(scope, `new-subtask:${trace.id}`, chain.revision, {
        title: "",
        difficulty: "simple",
    });
    return (
        <form
            className="subtask-add"
            onKeyDownCapture={compositionKeyGuard}
            onCompositionStart={draft.onCompositionStart}
            onCompositionEnd={draft.onCompositionEnd}
            onSubmit={async (event) => {
                event.preventDefault();
                if (draft.composing.current || !draft.value.title.trim())
                    return;
                if (
                    await execute("AddSubtask", draft.baseRevision, {
                        trace_id: trace.id,
                        ...draft.value,
                        title: draft.value.title.trim(),
                    })
                )
                    await draft.clear({ title: "", difficulty: "simple" });
            }}
        >
            <FormFields ready={draft.ready}>
                <div className="inline-controls">
                    <input
                        aria-label="子任务名称"
                        placeholder="添加一个子任务"
                        value={draft.value.title}
                        maxLength={2000}
                        required
                        onChange={(event) =>
                            draft.update({
                                ...draft.value,
                                title: event.target.value,
                            })
                        }
                    />
                    <select
                        aria-label="子任务难度"
                        value={draft.value.difficulty}
                        onChange={(event) =>
                            draft.update({
                                ...draft.value,
                                difficulty: event.target.value,
                            })
                        }
                    >
                        <option value="simple">简单</option>
                        <option value="medium">中等</option>
                        <option value="hard">困难</option>
                    </select>
                    <button
                        type="submit"
                        disabled={busy}
                        aria-label="添加子任务"
                    >
                        <Icon name="plus" />
                    </button>
                </div>
                {(draft.storageError || draft.stale) && (
                    <DraftHint {...draft} />
                )}
            </FormFields>
        </form>
    );
}
function SubtaskRow({
    subtask,
    snapshot,
    chain,
    trace,
    busy,
    execute,
    scope,
}: {
    subtask: Subtask;
    snapshot: Snapshot;
    chain: Chain;
    trace: Trace;
    busy: boolean;
    execute: Execute;
    scope: string;
}) {
    const [editing, setEditing] = useState(false);
    const [confirmDelete, setConfirmDelete] = useState(false);
    const draft = useDraft(
        scope,
        `edit-subtask:${subtask.id}`,
        chain.revision,
        { title: subtask.title, difficulty: subtask.difficulty },
    );
    const editable = trace.status === "pending" && trace.date >= snapshot.today;
    const canComplete = editable && trace.date === snapshot.today;
    return (
        <li className="subtask-row">
            <div className="subtask-line">
                <button
                    className={`task-check ${subtask.status === "completed" ? "checked" : ""}`}
                    disabled={
                        busy || !canComplete || subtask.status === "abandoned"
                    }
                    aria-label={`${subtask.status === "completed" ? "撤销子任务完成" : "完成子任务"}：${subtask.title}`}
                    onClick={() =>
                        void execute(
                            subtask.status === "completed"
                                ? "UndoCompleteSubtask"
                                : "CompleteSubtask",
                            chain.revision,
                            { subtask_id: subtask.id },
                        )
                    }
                >
                    {subtask.status === "completed" && (
                        <Icon name="check" size={13} />
                    )}
                </button>
                <span className={subtask.status !== "pending" ? "muted" : ""}>
                    {subtask.title}
                </span>
                <small className="muted">
                    {
                        { simple: "简单", medium: "中等", hard: "困难" }[
                            subtask.difficulty
                        ]
                    }
                    {subtask.status === "abandoned" ? " · 已废弃" : ""}
                </small>
                {editable && (
                    <button
                        className="text-button small"
                        onClick={() => setEditing(!editing)}
                    >
                        编辑
                    </button>
                )}
            </div>
            {editing && (
                <form
                    className="inline-edit"
                    onKeyDownCapture={compositionKeyGuard}
                    onCompositionStart={draft.onCompositionStart}
                    onCompositionEnd={draft.onCompositionEnd}
                    onSubmit={async (event) => {
                        event.preventDefault();
                        if (draft.composing.current) return;
                        if (
                            await execute("EditSubtask", draft.baseRevision, {
                                subtask_id: subtask.id,
                                ...draft.value,
                            })
                        ) {
                            await draft.clear(draft.value);
                            setEditing(false);
                        }
                    }}
                >
                    <FormFields ready={draft.ready}>
                        <label>
                            子任务名称
                            <input
                                value={draft.value.title}
                                maxLength={2000}
                                required
                                onChange={(event) =>
                                    draft.update({
                                        ...draft.value,
                                        title: event.target.value,
                                    })
                                }
                            />
                        </label>
                        <label>
                            难度
                            <select
                                value={draft.value.difficulty}
                                onChange={(event) =>
                                    draft.update({
                                        ...draft.value,
                                        difficulty: event.target
                                            .value as Subtask["difficulty"],
                                    })
                                }
                            >
                                <option value="simple">简单</option>
                                <option value="medium">中等</option>
                                <option value="hard">困难</option>
                            </select>
                        </label>
                        <DraftHint {...draft} />
                        <div className="detail-actions">
                            <button type="submit" disabled={busy}>
                                保存子任务
                            </button>
                            {canComplete && subtask.status === "pending" && (
                                <button
                                    className="text-button"
                                    type="button"
                                    onClick={() =>
                                        void execute(
                                            "AbandonSubtask",
                                            chain.revision,
                                            { subtask_id: subtask.id },
                                        )
                                    }
                                >
                                    废弃子任务
                                </button>
                            )}
                            <button
                                className="text-button danger"
                                type="button"
                                onClick={() => setConfirmDelete(true)}
                            >
                                删除子任务
                            </button>
                        </div>
                        {confirmDelete && (
                            <div className="inline-confirm">
                                <span>删除这个子任务？</span>
                                <button
                                    className="danger"
                                    type="button"
                                    onClick={() =>
                                        void execute(
                                            "DeleteSubtask",
                                            chain.revision,
                                            { subtask_id: subtask.id },
                                        )
                                    }
                                >
                                    确认删除
                                </button>
                                <button
                                    type="button"
                                    className="text-button"
                                    onClick={() => setConfirmDelete(false)}
                                >
                                    取消
                                </button>
                            </div>
                        )}
                    </FormFields>
                </form>
            )}
        </li>
    );
}
function ProgressEditor({
    trace,
    chain,
    busy,
    execute,
}: {
    trace: Trace;
    chain: Chain;
    busy: boolean;
    execute: Execute;
}) {
    const [progress, setProgress] = useState(trace.manual_progress);
    return (
        <form
            className="progress-form"
            onSubmit={(event) => {
                event.preventDefault();
                void execute("UpdateProgress", chain.revision, {
                    trace_id: trace.id,
                    progress,
                });
            }}
        >
            <label>
                手动进度
                <input
                    aria-label="手动进度"
                    type="number"
                    min={trace.progress_floor}
                    max={100}
                    value={progress}
                    onChange={(event) =>
                        setProgress(Number(event.target.value))
                    }
                    disabled={busy}
                />
            </label>
            <span>%</span>
            <button type="submit" disabled={busy}>
                更新进度
            </button>
        </form>
    );
}
