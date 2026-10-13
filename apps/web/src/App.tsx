import { useCallback, useEffect, useRef, useState } from 'react';
import type { FormEvent } from 'react';
import { APIError, errorMessage, getReceipt, getSnapshot, request, submit } from './api';
import { Backup } from './Backup';
import { clearDrafts, draftScope } from './drafts';
import { Flylight, Review } from './Notes';
import { NewTask, TaskDetail, TaskList } from './Tasks';
import type { Chain, Command, Snapshot, Trace } from './types';
import { Icon, Modal, UIStatus, compositionKeyGuard, dateLabel, nextDate } from './ui';
import type { IconName } from './ui';

type View = 'day' | 'pool' | 'future' | 'completed' | 'unfinished' | 'ideas' | 'sticky' | 'review' | 'settings';
const navigation: { view: View; label: string; icon: IconName; section?: string }[] = [
  { view: 'day', label: 'Day Todo', icon: 'sun', section: '计划' },
  { view: 'pool', label: '任务池', icon: 'pool' },
  { view: 'future', label: '未来计划', icon: 'calendar' },
  { view: 'completed', label: '已完成', icon: 'check', section: '轨迹' },
  { view: 'unfinished', label: '未完成', icon: 'clock' },
  { view: 'ideas', label: '飞光', icon: 'spark', section: '札记' },
  { view: 'sticky', label: '便签', icon: 'pin' },
  { view: 'review', label: '每日复盘', icon: 'review' },
];
const descriptions: Record<View, string> = {
  day: '把想做的事，安放在今天。', pool: '还不用决定哪一天。先让想做的事有个去处。', future: '为未来留一个位置，也为变化留一点空间。',
  completed: '那些做成的事，都在这里留下了痕迹。', unfinished: '还没有走完的路，可以选择继续。', ideas: '留住一闪而过的念头。', sticky: '常用的片语，随手就能找到。',
  review: '计划会变化，走过的每一天值得被记住。', settings: '你的个人实例。数据保存在你部署的服务上。',
};
const identity = (snapshot: Snapshot) => `${snapshot.instance_id}:${snapshot.instance_epoch}:${snapshot.dataset_id}:${snapshot.owner_id}`;
function pendingKey(snapshot: Snapshot) { return `noonmark.pending:${draftScope(snapshot)}`; }

export default function App() {
  const [token, setToken] = useState<string | null>(null);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [view, setView] = useState<View>('day');
  const [date, setDate] = useState('');
  const [mobileMenu, setMobileMenu] = useState(false);
  const [newTask, setNewTask] = useState(false);
  const [selected, setSelected] = useState<{ chainID: string; traceID?: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [connected, setConnected] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [unknownChecked, setUnknownChecked] = useState(false);
  const [unknown, setUnknown] = useState<{ id: string; command?: Command } | null>(null);
  const [logoutOpen, setLogoutOpen] = useState(false);
  const [keepDrafts, setKeepDrafts] = useState(false);
  const [query, setQuery] = useState('');
  const snapshotRef = useRef(snapshot);
  const tokenRef = useRef(token);
  const inFlight = useRef(false);
  const refreshVersion = useRef(0);
  snapshotRef.current = snapshot;
  tokenRef.current = token;
  const expire = useCallback((message: string) => {
    tokenRef.current = null;
    setToken(null); setSnapshot(null); setSelected(null); setNewTask(false); setError(message);
  }, []);
  const refresh = useCallback(async (auth: string) => {
    const requestVersion = ++refreshVersion.current;
    try {
      const next = await getSnapshot(auth);
      if (tokenRef.current !== auth || requestVersion !== refreshVersion.current) return;
      if (snapshotRef.current && identity(snapshotRef.current) !== identity(next)) {
        expire('实例资料已变更，请重新登录。旧输入不会自动提交。'); return;
      }
      if (next.schema_version !== 1) { expire('此页面版本与服务器不兼容，请刷新页面。'); return; }
      const previousToday = snapshotRef.current?.today;
      snapshotRef.current = next;
      setSnapshot(next); setConnected(true);
      setDate(current => !current || current === previousToday ? next.today : current);
    } catch (cause) {
      if (tokenRef.current !== auth) return;
      if (cause instanceof APIError && cause.status === 401) expire(errorMessage(cause));
      else { setConnected(false); throw cause; }
    }
  }, [expire]);
  useEffect(() => {
    if (!token) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const controller = new AbortController();
    const updates = async () => {
      while (!stopped) {
        try {
          const response = await fetch('/api/v1/events', { headers: { Authorization: `Bearer ${token}` }, credentials: 'omit', cache: 'no-store', signal: controller.signal });
          if (response.status === 401) { expire('登录已失效，请重新登录。输入草稿会保留。'); return; }
          if (!response.ok || !response.body) throw new Error('EVENT_STREAM_UNAVAILABLE');
          const reader = response.body.getReader();
          const decoder = new TextDecoder();
          let buffer = '';
          while (!stopped) {
            const part = await reader.read();
            if (part.done) break;
            buffer += decoder.decode(part.value, { stream: true });
            if (buffer.length > 100_000) throw new Error('EVENT_TOO_LARGE');
            const lines = buffer.split('\n'); buffer = lines.pop() ?? '';
            for (const line of lines) {
              if (line.startsWith('data:')) {
                const update = JSON.parse(line.slice(5)) as { sequence?: string };
                if (update.sequence && update.sequence !== snapshotRef.current?.sequence) void refresh(token).catch(() => {});
              }
            }
          }
        } catch { /* 已由定期一致读确认连接；流消息只作刷新提示。 */ }
        if (!stopped) await new Promise<void>(resolve => { timer = setTimeout(resolve, 3000); });
      }
    };
    void updates();
    const poll = setInterval(() => { if (!document.hidden) void refresh(token).catch(() => {}); }, 5000);
    const onVisible = () => { if (!document.hidden) void refresh(token).catch(() => {}); };
    window.addEventListener('online', onVisible);
    document.addEventListener('visibilitychange', onVisible);
    return () => { stopped = true; controller.abort(); clearTimeout(timer); clearInterval(poll); window.removeEventListener('online', onVisible); document.removeEventListener('visibilitychange', onVisible); };
  }, [token, refresh, expire]);
  useEffect(() => {
    const quickEntry = (event: KeyboardEvent) => {
      if (token && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k' && !event.isComposing && !document.querySelector('dialog[open]')) {
        event.preventDefault(); setNewTask(true);
      }
    };
    window.addEventListener('keydown', quickEntry);
    return () => window.removeEventListener('keydown', quickEntry);
  }, [token]);
  const login = async (password: string) => {
    setError('');
    try {
      const session = await request<{ token: string; expires_at: number }>('/api/v1/auth/login', undefined, { password });
      tokenRef.current = session.token;
      const next = await getSnapshot(session.token);
      if (next.schema_version !== 1) throw new APIError('SCHEMA_UNSUPPORTED', 409);
      snapshotRef.current = next;
      setSnapshot(next); setToken(session.token); setConnected(true); setDate(current => current || next.today);
      try { const pending = localStorage.getItem(pendingKey(next)); setUnknown(pending ? { id: pending } : null); setUnknownChecked(false); } catch { setUnknown(null); }
      return true;
    } catch (cause) { setError(cause instanceof APIError && cause.status === 401 ? '密码不正确，请重试。' : errorMessage(cause)); return false; }
  };
  const markUnknown = (command: Command) => {
    setUnknown({ id: command.command_id, command }); setUnknownChecked(false);
    if (snapshotRef.current) { try { localStorage.setItem(pendingKey(snapshotRef.current), command.command_id); } catch { setNotice('请保持页面打开，以便核对这次提交结果。'); } }
  };
  const clearUnknown = () => {
    if (snapshotRef.current) { try { localStorage.removeItem(pendingKey(snapshotRef.current)); } catch { /* 仅影响下一次结果提示。 */ } }
    setUnknown(null); setUnknownChecked(false);
  };
  const execute = async (type: string, revision: string, payload: Record<string, unknown>) => {
    const current = snapshotRef.current;
    const auth = tokenRef.current;
    if (!current || !auth || inFlight.current || unknown || !connected) return false;
    const command: Command = { instance_id: current.instance_id, instance_epoch: current.instance_epoch, dataset_id: current.dataset_id, command_id: crypto.randomUUID(), schema_version: 1, type, expected_revision: revision, payload };
    inFlight.current = true; setBusy(true); setError(''); setNotice('');
    let committed = false;
    try {
      await submit(auth, command);
      committed = true;
      await refresh(auth);
      setNotice('已保存到实例。');
      return true;
    } catch (cause) {
      if (committed) { setNotice('服务器已保存，但暂时无法刷新。请恢复连接后重新读取。'); return true; }
      if (!(cause instanceof APIError) || cause.status >= 500) { markUnknown(command); setConnected(false); setError('请求已发出，但还不能确认是否保存。请先核对结果，避免重复创建。'); }
      else {
        setError(errorMessage(cause));
        if (cause.status === 401 || ['INSTANCE_CHANGED', 'DATASET_INACTIVE'].includes(cause.code)) expire(errorMessage(cause));
        else await refresh(auth).catch(() => {});
      }
      return false;
    } finally { inFlight.current = false; setBusy(false); }
  };
  const checkUnknown = async (retry = false) => {
    if (!unknown || !token || busy) return;
    setBusy(true); setError('');
    try {
      if (retry && unknown.command) await submit(token, unknown.command);
      else await getReceipt(token, unknown.id);
      clearUnknown(); await refresh(token); setNotice('已确认：这次操作已保存。请核对最新内容。');
    } catch (cause) {
      if (cause instanceof APIError && cause.status === 404) { await refresh(token).then(() => setUnknownChecked(true)).catch(() => {}); setError('尚未查到这次提交的结果。请核对当前内容；不要把同一操作当成新操作重复提交。'); }
      else if (cause instanceof APIError && cause.status === 401) expire(errorMessage(cause));
      else setError(errorMessage(cause));
    } finally { setBusy(false); }
  };
  const logout = async () => {
    if (!token || !snapshot) return;
    setBusy(true);
    try {
      if (!keepDrafts) await clearDrafts(draftScope(snapshot));
      await request('/api/v1/auth/logout', token, {});
      setLogoutOpen(false); setToken(null); tokenRef.current = null; setSnapshot(null); snapshotRef.current = null; setUnknown(null); setNotice(''); setError(''); setSelected(null); setNewTask(false);
    } catch (cause) { setError(errorMessage(cause)); }
    finally { setBusy(false); }
  };
  if (!token || !snapshot) return <Login login={login} error={error} />;
  const scope = draftScope(snapshot);
  const selectedDate = date || snapshot.today;
  const activeNav = [...navigation, { view: 'settings', label: '设置', icon: 'settings' as const }].find(item => item.view === view)!;
  const disabled = busy || !connected || Boolean(unknown);
  const byTitle = (chain: Chain, trace?: Trace) => !query || snapshot.definitions.find(item => item.id === (trace?.definition_id ?? chain.definition_id))?.title.toLocaleLowerCase().includes(query.toLocaleLowerCase());
  const pool = snapshot.chains.filter(chain => chain.location === 'pool' && byTitle(chain));
  const filterTraces = (traces: Trace[]) => traces.filter(trace => { const chain = snapshot.chains.find(chain => chain.id === trace.chain_id); return chain && byTitle(chain, trace); });
  const candidateTraces = filterTraces(snapshot.traces.filter(trace => trace.status !== 'cancelledDraft' && (view === 'day' ? trace.date === selectedDate : view === 'future' ? trace.date > snapshot.today && trace.status === 'pending' : view === 'completed' ? trace.status === 'completed' || snapshot.subtasks.some(item => item.trace_id === trace.id && item.status === 'completed') : view === 'unfinished' ? ['unfinished', 'abandoned'].includes(trace.status) : false))).sort((a, b) => view === 'future' ? a.date.localeCompare(b.date) || a.priority - b.priority : b.date.localeCompare(a.date) || a.priority - b.priority);
  const seenChains = new Set<string>();
  const selectedTraces = ['completed', 'unfinished'].includes(view) ? candidateTraces.filter(trace => { if (seenChains.has(trace.chain_id)) return false; seenChains.add(trace.chain_id); return true; }) : candidateTraces;
  const dayTraces = snapshot.traces.filter(trace => trace.date === selectedDate && trace.status !== 'cancelledDraft');
  const done = dayTraces.filter(trace => trace.status === 'completed').length;
  const navigate = (next: View) => { setView(next); setMobileMenu(false); setQuery(''); setNotice(''); };
  const select = (chain: Chain, trace?: Trace) => setSelected({ chainID: chain.id, traceID: trace?.id });
  return <UIStatus.Provider value={{ error, pending: busy }}><div className="app-shell">
    <a className="skip-link" href="#main-content">跳到主要内容</a>
    {mobileMenu && <button className="sidebar-scrim" aria-label="关闭导航" onClick={() => setMobileMenu(false)} />}
    <aside className={`sidebar ${mobileMenu ? 'mobile-open' : ''}`}>
      <a className="brand" href="#" onClick={event => { event.preventDefault(); navigate('day'); }}><span className="brand-mark"><Icon name="sun" size={25} /></span><span><strong>晷迹</strong><small>NOONMARK</small></span></a>
      <nav aria-label="主要导航">{navigation.map(item => <div key={item.view}>{item.section && <p className="nav-section">{item.section}</p>}<button className={`nav-item ${view === item.view ? 'active' : ''}`} aria-current={view === item.view ? 'page' : undefined} onClick={() => navigate(item.view)}><Icon name={item.icon} /><span>{item.label}</span>{item.view === 'pool' && snapshot.chains.filter(chain => chain.location === 'pool').length > 0 && <small>{snapshot.chains.filter(chain => chain.location === 'pool').length}</small>}</button></div>)}</nav>
      <div className="sidebar-bottom"><button className={`nav-item ${view === 'settings' ? 'active' : ''}`} aria-current={view === 'settings' ? 'page' : undefined} onClick={() => navigate('settings')}><Icon name="settings" /><span>设置</span></button><div className="instance-note"><span className={`connection-dot ${connected ? '' : 'offline'}`} />{connected ? '个人实例 · 已连接' : '个人实例 · 连接中断'}</div></div>
    </aside>
    <main id="main-content" className="main-content">
      <div className="mobile-top"><button className="icon-button" aria-label="打开导航" onClick={() => setMobileMenu(true)}><Icon name="menu" /></button><span>晷迹</span></div>
      <div className="page-content">
        <header className="page-heading"><div><p className="eyebrow">{view === 'day' ? dateLabel(selectedDate, { year: 'numeric', month: 'long', day: 'numeric', weekday: 'long' }) : 'NOONMARK'}</p><h1>{activeNav.label}</h1><p className="page-description">{descriptions[view]}</p></div>{['day', 'pool', 'future'].includes(view) && <button className="primary add-task" onClick={() => setNewTask(true)} disabled={Boolean(unknown)}><Icon name="plus" size={17} />添加任务</button>}</header>
        {!connected && <div className="status-banner warning" role="status"><span>暂时无法连接实例。可继续写草稿，恢复连接后再提交。</span><button onClick={() => void refresh(token).catch(() => {})} className="text-button"><Icon name="refresh" size={15} />重新连接</button></div>}
        {unknown && <div className="status-banner warning"><div><strong>有一次操作结果待确认</strong><p>先核对服务端结果，再继续修改。</p><div className="detail-actions"><button disabled={busy} onClick={() => void checkUnknown()}>核对结果</button>{unknown.command && <button disabled={busy} onClick={() => void checkUnknown(true)}>以原请求重试</button>}<button className="text-button" disabled={busy || !unknownChecked || !connected} onClick={() => { clearUnknown(); setError(''); setNotice('请先检查最新内容，再决定下一次操作。'); }}>已核对当前内容，继续使用</button></div></div></div>}
        {error && <div className="status-banner error" role="alert"><span>{error}</span><button className="icon-button" aria-label="关闭提示" onClick={() => setError('')}><Icon name="close" size={16} /></button></div>}
        <div className="save-status" role="status" aria-live="polite">{busy ? '正在与实例确认…' : notice}</div>
        {(view === 'day' || view === 'review') && <div className="date-toolbar"><div className="date-navigation"><button className="icon-button" aria-label="前一天" onClick={() => setDate(nextDate(selectedDate, -1))}><Icon name="left" size={16} /></button><label className="sr-only" htmlFor="view-date">查看日期</label><input id="view-date" type="date" value={selectedDate} max={view === 'review' ? snapshot.today : undefined} onChange={event => event.target.value && setDate(event.target.value)} /><button className="icon-button" aria-label="后一天" disabled={view === 'review' && selectedDate >= snapshot.today} onClick={() => setDate(nextDate(selectedDate, 1))}><Icon name="right" size={16} /></button><button className="text-button" onClick={() => setDate(snapshot.today)}>今天</button></div>{view === 'day' && <span className="day-count">{dayTraces.length ? `${done} / ${dayTraces.length} 已完成` : '轻一点，开始这一天'}</span>}</div>}
        {['day', 'pool', 'future', 'completed', 'unfinished'].includes(view) && <>
          <div className="list-toolbar"><h2>{view === 'day' ? selectedDate < snapshot.today ? '当天轨迹' : '这一天的安排' : activeNav.label}<span>{view === 'pool' ? pool.length : selectedTraces.length}</span></h2><label className="sr-only" htmlFor="task-search">搜索任务</label><input id="task-search" className="search-input" type="search" placeholder="搜索任务" value={query} onChange={event => setQuery(event.target.value)} /></div>
          <TaskList {...{ snapshot, execute, disabled }} historyView={view === 'completed' || view === 'unfinished'} completedChildren={view === 'completed'} chains={view === 'pool' ? pool : undefined} traces={view === 'pool' ? undefined : selectedTraces} onSelect={select} />
          {view === 'day' && selectedDate <= snapshot.today && <button className="review-link text-button" onClick={() => navigate('review')}><Icon name="review" size={16} />给这一天写几句话<Icon name="arrow" size={16} /></button>}
        </>}
        {(view === 'ideas' || view === 'sticky') && <Flylight key={view} {...{ snapshot, scope, execute }} pinned={view === 'sticky'} busy={disabled} />}
        {view === 'review' && <Review date={selectedDate} {...{ snapshot, scope, execute }} busy={disabled} />}
        {view === 'settings' && <div className="settings-content"><section><h2>个人实例</h2><dl><div><dt>数据位置</dt><dd>当前连接的自部署服务</dd></div><div><dt>访问方式</dt><dd>一位拥有者，多设备访问</dd></div><div><dt>日历时区</dt><dd>{snapshot.timezone}</dd></div><div><dt>连接状态</dt><dd>{connected ? '已连接' : '暂时无法连接'}</dd></div></dl></section><section><h2>浏览器与草稿</h2><p>提交成功的任务和飞光保存在服务端。输入草稿仅留在此浏览器，保存 7 天；恢复连接不会自动提交。</p><p>为保护个人资料，刷新页面后需要重新登录。</p></section><Backup token={token} connected={connected} /><section><h2>登录</h2><p>退出会撤销这次登录，其他设备不受影响。</p><button onClick={() => setLogoutOpen(true)}><Icon name="logout" size={17} />退出登录</button></section></div>}
        <footer className="page-footer"><span>晷迹 · 让每一天有迹可循</span><span>个人自部署版</span></footer>
      </div>
    </main>
    {newTask && <NewTask {...{ snapshot, scope, execute }} busy={disabled} date={view === 'pool' ? '' : selectedDate >= snapshot.today ? selectedDate : snapshot.today} close={() => setNewTask(false)} />}
    {selected && <TaskDetail {...{ snapshot, scope, execute, ...selected }} busy={disabled} close={() => setSelected(null)} />}
    {logoutOpen && <Modal title="退出登录" close={() => setLogoutOpen(false)}><p>退出后，需要密码才能再次访问这个实例。</p><label className="checkbox-label"><input type="checkbox" checked={keepDrafts} onChange={event => setKeepDrafts(event.target.checked)} />在此浏览器保留未提交的草稿</label><p className="field-hint">在共用设备上，请清除草稿。</p><div className="form-actions"><button className="text-button" onClick={() => setLogoutOpen(false)}>取消</button><button className="primary" disabled={busy} onClick={() => void logout()}>{keepDrafts ? '保留草稿并退出' : '清除草稿并退出'}</button></div></Modal>}
  </div></UIStatus.Provider>;
}
function Login({ login, error }: { login: (password: string) => Promise<boolean>; error: string }) {
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const composing = useRef(false);
  const onSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (busy || composing.current || !password) return;
    setBusy(true);
    if (await login(password)) setPassword('');
    setBusy(false);
  };
  return <main className="login-page"><div className="login-brand"><Icon name="sun" size={38} /><span>晷迹 <small>NOONMARK</small></span></div><div className="login-content"><p className="eyebrow">你的每一天，都有迹可循</p><h1>回到自己的节奏。</h1><p className="muted">登录你的个人实例，继续今天的安排。</p><form onKeyDownCapture={compositionKeyGuard} onSubmit={onSubmit} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }}><input className="sr-only" type="text" autoComplete="username" value="owner" readOnly aria-label="账号" /><label htmlFor="login-password">实例密码</label><input id="login-password" type="password" autoComplete="current-password" autoFocus required value={password} onChange={event => setPassword(event.target.value)} disabled={busy} />{error && <p className="login-error" role="alert">{error}</p>}<button className="primary" type="submit" disabled={busy || !password}>{busy ? '正在登录…' : '进入晷迹'}<Icon name="arrow" size={17} /></button></form><p className="login-footnote">数据保存在你部署的服务上。<br />无需官方账号。</p></div><footer>NOONMARK <span>·</span> 个人自部署版</footer></main>;
}
