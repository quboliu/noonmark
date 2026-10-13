import { useEffect, useId, useRef, useState } from "react";
import type { ReactNode } from "react";
import { Backup } from "./Backup";
import { DEFAULT_POEM } from "./preferences";
import type { Preferences, UpdatePreference } from "./preferences";
import type { Snapshot } from "./types";
import { Icon } from "./ui";

type Pane = "general" | "data" | "connection" | "privacy";
const panes: { id: Pane; title: string; icon: ReactNode }[] = [
    { id: "general", title: "偏好", icon: <Icon name="settings" size={18} /> },
    {
        id: "data",
        title: "数据",
        icon: (
            <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.6"
                aria-hidden="true"
            >
                <path
                    d="M7 10H4v11h16V10h-3M12 16V2m-5 5 5-5 5 5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                />
            </svg>
        ),
    },
    {
        id: "connection",
        title: "连接",
        icon: <Icon name="refresh" size={18} />,
    },
    {
        id: "privacy",
        title: "写入与隐私边界",
        icon: (
            <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.6"
                aria-hidden="true"
            >
                <path
                    d="m12 2 8 4v6c0 5-8 10-8 10S4 17 4 12V6l8-4Z"
                    strokeLinejoin="round"
                />
                <rect x="9" y="10" width="6" height="6" rx="1" />
                <path d="M10 10V8a2 2 0 0 1 4 0v2" />
            </svg>
        ),
    },
];

export interface SettingsProps {
    token: string;
    snapshot: Snapshot;
    connected: boolean;
    close: () => void;
    logout: () => void;
    preferences: Preferences;
    updatePreference: UpdatePreference;
    storageError: boolean;
}

export function Settings({
    token,
    snapshot,
    connected,
    close,
    logout,
    preferences,
    updatePreference,
    storageError,
}: SettingsProps) {
    const [pane, setPane] = useState<Pane>("general");
    const [poemDraft, setPoemDraft] = useState(preferences.poem);
    const [poemExpanded, setPoemExpanded] = useState(false);
    const composing = useRef(false);
    const dialog = useRef<HTMLDialogElement>(null);
    const firstPane = useRef<HTMLButtonElement>(null);
    const content = useRef<HTMLElement>(null);
    const id = useId();
    const selected = panes.find((item) => item.id === pane)!;

    useEffect(() => {
        const opener =
            document.activeElement instanceof HTMLElement
                ? document.activeElement
                : null;
        const window = dialog.current;
        window?.showModal();
        firstPane.current?.focus();
        return () => {
            window?.close();
            if (opener?.isConnected) opener.focus();
        };
    }, []);
    useEffect(() => {
        if (!composing.current) setPoemDraft(preferences.poem);
    }, [preferences.poem]);

    const changePane = (next: Pane) => {
        setPane(next);
        content.current?.scrollTo({ top: 0 });
    };

    return (
        <dialog
            ref={dialog}
            className="settings-window"
            aria-label="设置"
            data-theme={preferences.theme}
            onCancel={(event) => {
                event.preventDefault();
                if (!composing.current) close();
            }}
        >
            <div className="settings-layout">
                <nav className="settings-navigation" aria-label="设置分类">
                    {panes.map((item, index) => (
                        <button
                            key={item.id}
                            ref={index === 0 ? firstPane : undefined}
                            type="button"
                            aria-current={pane === item.id ? "page" : undefined}
                            aria-controls={`${id}-content`}
                            className={`settings-pane-button ${pane === item.id ? "selected" : ""}`}
                            onClick={() => changePane(item.id)}
                        >
                            {item.icon}
                            <span>{item.title}</span>
                        </button>
                    ))}
                </nav>
                <section
                    ref={content}
                    id={`${id}-content`}
                    className="settings-pane-content"
                    aria-labelledby={`${id}-title`}
                >
                    <h1 id={`${id}-title`}>{selected.title}</h1>
                    {storageError && (
                        <p className="settings-storage-warning" role="alert">
                            浏览器未能保存偏好。当前选择仍会生效，关闭页面后可能丢失。
                        </p>
                    )}
                    {pane === "general" && (
                        <div className="settings-general">
                            <p className="settings-subtitle">
                                只影响此浏览器的偏好，不改变任务事实。
                            </p>
                            <SettingsSection title="外观">
                                <div
                                    className="settings-segmented"
                                    role="group"
                                    aria-label="外观"
                                >
                                    <button
                                        type="button"
                                        aria-pressed={
                                            preferences.theme === "coolGray"
                                        }
                                        onClick={() =>
                                            updatePreference(
                                                "theme",
                                                "coolGray",
                                            )
                                        }
                                    >
                                        冷灰
                                    </button>
                                    <button
                                        type="button"
                                        aria-pressed={
                                            preferences.theme === "warmPaper"
                                        }
                                        onClick={() =>
                                            updatePreference(
                                                "theme",
                                                "warmPaper",
                                            )
                                        }
                                    >
                                        微暖纸感
                                    </button>
                                </div>
                            </SettingsSection>
                            <SettingsSection title="页面滑动方向">
                                <div
                                    className="settings-segmented"
                                    role="group"
                                    aria-label="页面滑动方向"
                                >
                                    <button
                                        type="button"
                                        aria-pressed={
                                            preferences.swipeDirection ===
                                            "book"
                                        }
                                        onClick={() =>
                                            updatePreference(
                                                "swipeDirection",
                                                "book",
                                            )
                                        }
                                    >
                                        翻书方向
                                    </button>
                                    <button
                                        type="button"
                                        aria-pressed={
                                            preferences.swipeDirection ===
                                            "reversed"
                                        }
                                        onClick={() =>
                                            updatePreference(
                                                "swipeDirection",
                                                "reversed",
                                            )
                                        }
                                    >
                                        反向
                                    </button>
                                </div>
                                <p className="settings-explanation">
                                    用于 Day Todo
                                    与日历；翻书方向为左滑到下一天或下个月。
                                </p>
                            </SettingsSection>
                            <SettingsSection title="应用内快捷键">
                                <label className="settings-checkbox">
                                    <input
                                        type="checkbox"
                                        checked={preferences.shortcutsEnabled}
                                        onChange={(event) =>
                                            updatePreference(
                                                "shortcutsEnabled",
                                                event.target.checked,
                                            )
                                        }
                                    />
                                    启用应用内快捷键
                                </label>
                                <dl className="settings-shortcuts">
                                    <div>
                                        <dt>快速记录</dt>
                                        <dd>
                                            <kbd>⌘ / Ctrl K</kbd>
                                        </dd>
                                    </div>
                                    <div>
                                        <dt>保存飞光</dt>
                                        <dd>
                                            <kbd>⌘ / Ctrl Enter</kbd>
                                        </dd>
                                    </div>
                                </dl>
                                <p className="settings-explanation">
                                    仅在当前页面生效。输入法组词期间不会提交内容。
                                </p>
                            </SettingsSection>
                            <details
                                className="settings-poem"
                                open={poemExpanded}
                                onToggle={(event) =>
                                    setPoemExpanded(event.currentTarget.open)
                                }
                            >
                                <summary>诗文</summary>
                                <div className="settings-poem-controls">
                                    <label className="settings-checkbox">
                                        <input
                                            type="checkbox"
                                            checked={preferences.poemEnabled}
                                            onChange={(event) =>
                                                updatePreference(
                                                    "poemEnabled",
                                                    event.target.checked,
                                                )
                                            }
                                        />
                                        显示诗文
                                    </label>
                                    <div className="settings-poem-label">
                                        <label htmlFor={`${id}-poem`}>
                                            诗文内容
                                        </label>
                                        <button
                                            type="button"
                                            className="settings-text-button"
                                            onClick={() => {
                                                setPoemDraft(DEFAULT_POEM);
                                                updatePreference(
                                                    "poem",
                                                    DEFAULT_POEM,
                                                );
                                            }}
                                        >
                                            恢复默认《苦昼短》
                                        </button>
                                    </div>
                                    <textarea
                                        id={`${id}-poem`}
                                        value={poemDraft}
                                        maxLength={20000}
                                        rows={5}
                                        onCompositionStart={() => {
                                            composing.current = true;
                                        }}
                                        onCompositionEnd={(event) => {
                                            composing.current = false;
                                            updatePreference(
                                                "poem",
                                                event.currentTarget.value,
                                            );
                                        }}
                                        onChange={(event) => {
                                            setPoemDraft(event.target.value);
                                            if (!composing.current)
                                                updatePreference(
                                                    "poem",
                                                    event.target.value,
                                                );
                                        }}
                                    />
                                </div>
                            </details>
                            {preferences.poemEnabled && (
                                <div
                                    className="settings-poem-display"
                                    aria-label="诗文"
                                >
                                    <p>{preferences.poem}</p>
                                </div>
                            )}
                        </div>
                    )}
                    {pane === "data" && (
                        <div className="settings-data">
                            <p className="settings-subtitle">
                                导出加密的实例备份，妥善保管恢复所需的口令。
                            </p>
                            <Backup token={token} connected={connected} />
                        </div>
                    )}
                    {pane === "connection" && (
                        <div className="settings-connection">
                            <p className="settings-subtitle">
                                一位拥有者，多设备访问同一个个人实例。
                            </p>
                            <dl className="settings-facts">
                                <div>
                                    <dt>连接状态</dt>
                                    <dd
                                        className={
                                            connected
                                                ? "settings-connected"
                                                : ""
                                        }
                                    >
                                        {connected ? "已连接" : "暂时无法连接"}
                                    </dd>
                                </div>
                                <div>
                                    <dt>实例地址</dt>
                                    <dd>{window.location.origin}</dd>
                                </div>
                                <div>
                                    <dt>日历时区</dt>
                                    <dd>{snapshot.timezone}</dd>
                                </div>
                                <div>
                                    <dt>数据位置</dt>
                                    <dd>当前连接的自部署服务</dd>
                                </div>
                            </dl>
                            <div className="settings-rule" />
                            <SettingsSection title="当前登录">
                                <p className="settings-explanation">
                                    刷新页面后需要重新登录。退出会撤销这次登录，其他设备不受影响。
                                </p>
                                <button
                                    type="button"
                                    className="settings-secondary"
                                    onClick={logout}
                                >
                                    <Icon name="logout" size={15} />
                                    退出登录
                                </button>
                            </SettingsSection>
                        </div>
                    )}
                    {pane === "privacy" && (
                        <div className="settings-privacy">
                            <p className="settings-subtitle">
                                任务事实由实例保存，浏览器只保留本机偏好与输入草稿。
                            </p>
                            <ul className="settings-boundaries">
                                <li>
                                    只有服务器确认成功，任务和飞光才算已保存。
                                </li>
                                <li>
                                    断线期间可以写草稿，恢复连接不会自动提交。
                                </li>
                                <li>
                                    输入草稿在此浏览器保留 7
                                    天，按实例和拥有者隔离；退出时可选择清除。
                                </li>
                                <li>
                                    登录凭证只保留在当前页面内存，不写入浏览器存储。
                                </li>
                            </ul>
                            <div className="settings-rule" />
                            <SettingsSection title="实例备份">
                                <p className="settings-explanation">
                                    备份使用你设置的独立口令加密。实例密码与备份口令不会写入输入草稿；请将备份文件和口令分开保管。
                                </p>
                                <button
                                    type="button"
                                    className="settings-text-button"
                                    onClick={() => changePane("data")}
                                >
                                    前往数据设置
                                </button>
                            </SettingsSection>
                        </div>
                    )}
                </section>
                <button
                    type="button"
                    className="settings-close"
                    aria-label="关闭设置"
                    onClick={close}
                >
                    <Icon name="close" size={16} />
                </button>
            </div>
        </dialog>
    );
}

function SettingsSection({
    title,
    children,
}: {
    title: string;
    children: ReactNode;
}) {
    return (
        <section className="settings-section">
            <h2>{title}</h2>
            {children}
        </section>
    );
}
