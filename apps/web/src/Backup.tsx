import { useRef, useState } from 'react';
import { APIError, errorMessage } from './api';
import { compositionKeyGuard } from './ui';

export function Backup({ token, connected }: { token: string; connected: boolean }) {
  const [password, setPassword] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const composing = useRef(false);
  return <section className="backup-section"><h2>备份与恢复</h2>
    <p>生成加密的实例备份，将它另存到安全的位置。请单独保管备份口令；恢复时需要它。</p>
    <form onKeyDownCapture={compositionKeyGuard} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onSubmit={async event => {
      event.preventDefault();
      if (busy || composing.current || !connected) return;
      setError(''); setNotice('');
      if (passphrase.length < 12) { setError('备份口令至少需要 12 个字符。'); return; }
      if (passphrase !== confirmation) { setError('两次输入的备份口令不一致。'); return; }
      setBusy(true);
      try {
        const response = await fetch('/api/v1/backups', {
          method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ password, passphrase }), credentials: 'omit', cache: 'no-store', signal: AbortSignal.timeout(120_000),
        });
        if (!response.ok) {
          const detail = await response.json().catch(() => ({}));
          throw new APIError(detail.code ?? 'BACKUP_FAILED', response.status);
        }
        if (!response.headers.get('Content-Type')?.includes('application/octet-stream')) throw new APIError('BACKUP_FAILED', 500);
        const file = await response.blob();
        const url = URL.createObjectURL(file);
        const link = document.createElement('a');
        link.href = url; link.download = `noonmark-${new Date().toISOString().slice(0, 10)}.noonmarkbackup`;
        document.body.append(link); link.click(); link.remove();
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
        setPassphrase(''); setConfirmation(''); setNotice('已生成备份包，下载已发起。请确认浏览器已保存文件。');
      } catch (cause) {
        setError(cause instanceof APIError && cause.code === 'INVALID_CREDENTIALS' ? '实例密码不正确，请重新输入。' : errorMessage(cause));
      } finally { setPassword(''); setBusy(false); }
    }}><fieldset disabled={busy}>
      <label>实例密码<input type="password" autoComplete="current-password" required value={password} maxLength={1024} onChange={event => setPassword(event.target.value)} /></label>
      <label>备份口令<input type="password" autoComplete="new-password" required minLength={12} maxLength={256} value={passphrase} onChange={event => setPassphrase(event.target.value)} /></label>
      <p className="field-hint">至少 12 个字符，不会保存在浏览器草稿中。</p>
      <label>再次输入备份口令<input type="password" autoComplete="new-password" required minLength={12} maxLength={256} value={confirmation} onChange={event => setConfirmation(event.target.value)} /></label>
      {error && <p className="backup-feedback error-text" role="alert">{error}</p>}
      {notice && <p className="backup-feedback success-text" role="status">{notice}</p>}
      <button type="submit" disabled={!connected || busy} className="primary">{busy ? '正在生成备份…' : '生成并下载备份'}</button>
    </fieldset></form>
    <p className="restore-hint">恢复由管理员在服务器通过管理命令完成。恢复前请停止实例，核对备份来源。</p>
  </section>;
}
