import { createContext, useContext, useEffect, useLayoutEffect, useRef } from 'react';
import type { KeyboardEvent, ReactNode } from 'react';

export const UIStatus = createContext({ error: '', pending: false });
export function FormFields({ ready, children }: { ready: boolean; children: ReactNode }) {
  const { pending } = useContext(UIStatus);
  const fields = useRef<HTMLFieldSetElement>(null);
  const focused = useRef(false);
  useLayoutEffect(() => {
    if (!ready || pending || focused.current) return;
    const target = fields.current?.querySelector<HTMLInputElement | HTMLTextAreaElement>('[data-autofocus]');
    if (!target) return;
    focused.current = true;
    target.focus();
  }, [ready, pending]);
  return <fieldset ref={fields} disabled={!ready || pending}>{children}</fieldset>;
}
export function compositionKeyGuard(event: KeyboardEvent) {
  if (event.key === 'Enter' && (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229)) event.preventDefault();
}

export type IconName = 'sun' | 'pool' | 'calendar' | 'check' | 'clock' | 'spark' | 'pin' | 'review' | 'settings' | 'plus' | 'left' | 'right' | 'close' | 'menu' | 'logout' | 'refresh' | 'arrow' | 'history';
const paths: Record<IconName, ReactNode> = {
  sun: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" /></>,
  pool: <><path d="M4 5h16v14H4zM4 13h4l2 3h4l2-3h4" /></>,
  calendar: <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M7 3v4m10-4v4M3 11h18m-13 4h2m4 0h2" /></>,
  check: <path d="m5 12 4 4L19 6" />,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  spark: <path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z" />,
  pin: <path d="m8 3 8 0-1 6 4 4v2H5v-2l4-4-1-6Zm4 12v7" />,
  review: <><path d="M5 3h14v18H5zM9 7h6m-6 5h6m-6 5h3" /></>,
  settings: <><path d="M4 7h16M4 17h16" /><circle cx="9" cy="7" r="3" /><circle cx="15" cy="17" r="3" /></>,
  plus: <path d="M12 5v14M5 12h14" />,
  left: <path d="m14 6-6 6 6 6" />,
  right: <path d="m10 6 6 6-6 6" />,
  close: <path d="m6 6 12 12M6 18 18 6" />,
  menu: <path d="M4 6h16M4 12h16M4 18h16" />,
  logout: <><path d="M10 4H4v16h6m5-14 6 6-6 6M9 12h12" /></>,
  refresh: <><path d="M20 8a8 8 0 1 0 0 8M20 3v5h-5" /></>,
  arrow: <path d="M4 12h16m-6-6 6 6-6 6" />,
  history: <><path d="M3 11a9 9 0 1 1 2 7M3 4v7h7m2-4v5l4 2" /></>,
};
export function Icon({ name, size = 19 }: { name: IconName; size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>;
}
export function Modal({ title, children, close }: { title: string; children: ReactNode; close: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const { error, pending } = useContext(UIStatus);
  useEffect(() => { dialog.current?.showModal(); }, []);
  return <dialog ref={dialog} className="modal" aria-label={title} onCancel={event => { event.preventDefault(); if (!pending) close(); }}>
    <div className="modal-heading"><h2>{title}</h2><button className="icon-button" disabled={pending} onClick={close} aria-label="关闭"><Icon name="close" /></button></div>
    {error && <p className="modal-feedback" role="alert">{error}</p>}
    {children}
  </dialog>;
}
export function DraftHint({ storageError, stale, acceptRevision }: { storageError: boolean; stale: boolean; acceptRevision?: () => void }) {
  return <div className={storageError || stale ? 'draft-hint warning-text' : 'draft-hint'}>{storageError ? '浏览器无法保存草稿，请保持页面打开，直至提交完成。' : stale ? '已恢复此浏览器的旧草稿。服务端内容已有更新，请核对后提交。' : '输入草稿仅保存在此浏览器，7 天后过期。'}{stale && acceptRevision && <button type="button" className="text-button" onClick={acceptRevision}>已核对当前内容，继续编辑</button>}</div>;
}
export function Empty({ children }: { children: ReactNode }) { return <p className="empty-state">{children}</p>; }
export function dateLabel(date: string, options: Intl.DateTimeFormatOptions = { month: 'long', day: 'numeric', weekday: 'long' }): string {
  return new Intl.DateTimeFormat('zh-CN', { ...options, timeZone: 'UTC' }).format(new Date(`${date}T12:00:00Z`));
}
export function nextDate(date: string, offset: number): string {
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + offset);
  return value.toISOString().slice(0, 10);
}
