import { useState } from 'react';
import { useDraft } from './drafts';
import type { Day, Execute, Idea, Snapshot } from './types';
import { DraftHint, Empty, FormFields, Icon, Modal, compositionKeyGuard, dateLabel } from './ui';

export function Flylight({ snapshot, scope, pinned, execute, busy }: { snapshot: Snapshot; scope: string; pinned: boolean; execute: Execute; busy: boolean }) {
  const draft = useDraft(scope, 'new-idea', '0', '');
  const [selected, setSelected] = useState<string | null>(null);
  const ideas = snapshot.ideas.filter(idea => !idea.deleted_at && (!pinned || idea.pinned_at)).sort((a, b) => (pinned ? b.pinned_at! : b.created_at).localeCompare(pinned ? a.pinned_at! : a.created_at));
  const editing = snapshot.ideas.find(idea => idea.id === selected && !idea.deleted_at);
  return <>
    {!pinned && <form className="idea-composer" onKeyDownCapture={compositionKeyGuard} onCompositionStart={draft.onCompositionStart} onCompositionEnd={draft.onCompositionEnd} onSubmit={async event => {
      event.preventDefault();
      if (draft.composing.current || !draft.value.trim() || busy) return;
      if (await execute('CreateIdea', '0', { body: draft.value.trim() })) await draft.clear('');
    }}><FormFields ready={draft.ready}><label className="sr-only" htmlFor="flylight-body">记录内容</label><textarea id="flylight-body" rows={3} placeholder="留住一闪而过的念头…" value={draft.value} maxLength={20000} disabled={!draft.ready} onChange={event => draft.update(event.target.value)} /><div className="composer-bottom"><DraftHint {...draft} /><button className="primary" disabled={busy || !draft.ready || !draft.value.trim()} type="submit"><Icon name="plus" size={16} />记录</button></div></FormFields></form>}
    {ideas.length ? <ol className="idea-list">{ideas.map(idea => <li key={idea.id}><div className="idea-meta"><time dateTime={idea.created_at}>{new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: snapshot.timezone }).format(new Date(idea.created_at))}</time><div><button className={`icon-button ${idea.pinned_at ? 'selected' : ''}`} disabled={busy} aria-label={idea.pinned_at ? '取消便签' : '设为便签'} title={idea.pinned_at ? '取消便签' : '设为便签'} onClick={() => void execute(idea.pinned_at ? 'UnpinIdea' : 'PinIdea', idea.revision, { idea_id: idea.id })}><Icon name="pin" size={17} /></button><button className="text-button" onClick={() => setSelected(idea.id)}>编辑</button></div></div><p className="idea-body">{idea.body}</p></li>)}</ol> : <Empty>{pinned ? '将常用的飞光设为便签，就能在这里随时找到。' : '灵感不必完整。想到的一句话，也值得留下。'}</Empty>}
    {editing && <EditIdea idea={editing} scope={scope} execute={execute} busy={busy} close={() => setSelected(null)} />}
  </>;
}
function EditIdea({ idea, scope, execute, busy, close }: { idea: Idea; scope: string; execute: Execute; busy: boolean; close: () => void }) {
  const draft = useDraft(scope, `edit-idea:${idea.id}`, idea.revision, idea.body);
  const [deleting, setDeleting] = useState(false);
  return <Modal title="编辑记录" close={close}><form onKeyDownCapture={compositionKeyGuard} onCompositionStart={draft.onCompositionStart} onCompositionEnd={draft.onCompositionEnd} onSubmit={async event => { event.preventDefault(); if (draft.composing.current || !draft.value.trim()) return; if (await execute('EditIdea', draft.baseRevision, { idea_id: idea.id, body: draft.value.trim() })) { await draft.clear(''); close(); } }}><FormFields ready={draft.ready}><label>内容<textarea data-autofocus rows={8} maxLength={20000} value={draft.value} required onChange={event => draft.update(event.target.value)} /></label><DraftHint {...draft} /><div className="form-actions"><button type="button" className="text-button danger" onClick={() => setDeleting(true)}>删除记录</button><button type="submit" disabled={busy} className="primary">保存修改</button></div>{deleting && <div className="inline-confirm"><p>删除这条记录？它将从飞光和便签中一并移除。</p><button type="button" className="danger" onClick={async () => { if (await execute('DeleteIdea', idea.revision, { idea_id: idea.id })) { await draft.clear(''); close(); } }}>确认删除</button><button type="button" className="text-button" onClick={() => setDeleting(false)}>取消</button></div>}</FormFields></form></Modal>;
}
export function Review({ date, snapshot, scope, execute, busy }: { date: string; snapshot: Snapshot; scope: string; execute: Execute; busy: boolean }) {
  const day = snapshot.days.find(day => day.date === date);
  return <ReviewForm key={date} {...{ date, day, snapshot, scope, execute, busy }} />;
}
function ReviewForm({ date, day, snapshot, scope, execute, busy }: { date: string; day?: Day; snapshot: Snapshot; scope: string; execute: Execute; busy: boolean }) {
  const draft = useDraft(scope, `review:${date}`, day?.revision ?? '0', { summary: day?.summary ?? '', unfinished_reason: day?.unfinished_reason ?? '', tomorrow_note: day?.tomorrow_note ?? '' });
  const [saved, setSaved] = useState(false);
  const traces = snapshot.traces.filter(trace => trace.date === date && trace.status !== 'cancelledDraft');
  const done = traces.filter(trace => trace.status === 'completed').length;
  return <div className="review-content"><p className="review-context">{dateLabel(date)}，{traces.length ? `${traces.length} 条轨迹，${done} 项完成。` : '还没有任务轨迹。'}{day?.locked_at ? '这一天已经收好，仍可补写复盘。' : '用几句话，为这一天留个注脚。'}</p>
    <form onKeyDownCapture={compositionKeyGuard} onCompositionStart={draft.onCompositionStart} onCompositionEnd={draft.onCompositionEnd} onSubmit={async event => { event.preventDefault(); if (draft.composing.current) return; if (await execute('UpdateReview', draft.baseRevision, { date, ...draft.value })) { await draft.clear(draft.value); setSaved(true); } }}><FormFields ready={draft.ready && date <= snapshot.today}>
      <label>今天，想记住什么？<textarea rows={5} placeholder="做成的事、一个发现，或值得记住的片刻。" value={draft.value.summary} maxLength={20000} onChange={event => { draft.update({ ...draft.value, summary: event.target.value }); setSaved(false); }} /></label>
      <label>还有什么没完成？<textarea rows={3} placeholder="是什么挡住了进展？" value={draft.value.unfinished_reason} maxLength={20000} onChange={event => { draft.update({ ...draft.value, unfinished_reason: event.target.value }); setSaved(false); }} /></label>
      <label>留给明天的话<textarea rows={3} placeholder="明天，先从哪里开始？" value={draft.value.tomorrow_note} maxLength={20000} onChange={event => { draft.update({ ...draft.value, tomorrow_note: event.target.value }); setSaved(false); }} /></label>
      <DraftHint {...draft} /><div className="form-actions"><span className="success-text" role="status">{saved ? '复盘已保存到实例。' : ''}</span><button className="primary" disabled={busy} type="submit">{busy ? '正在保存…' : '保存复盘'}</button></div>
    </FormFields></form>
  </div>;
}
