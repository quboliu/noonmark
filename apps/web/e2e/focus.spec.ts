import { test, expect } from '@playwright/test';
import { closeDialog, login, navigation } from './helpers';

test('FAIL-2026-10-12-06：草稿读取就绪后初次聚焦，提交失败不重新抢焦点', async ({ page }) => {
  await page.addInitScript(() => {
    let held = true;
    let callbacks: (() => void)[] = [];
    Object.defineProperty(window, '__noonmarkHoldDraftReads', { value: () => { held = true; } });
    Object.defineProperty(window, '__noonmarkReleaseDraftReads', { value: () => { held = false; const pending = callbacks; callbacks = []; pending.forEach(run => run()); } });
    const setter = Object.getOwnPropertyDescriptor(IDBRequest.prototype, 'onsuccess')?.set;
    if (!setter) throw new Error('IDB_SUCCESS_HOOK_UNAVAILABLE');
    const intercept = <T extends IDBRequest>(request: T): T => {
      Object.defineProperty(request, 'onsuccess', {
        configurable: true,
        set(listener: ((event: Event) => unknown) | null) {
          setter.call(request, (event: Event) => {
            const deliver = () => listener?.call(request, event);
            if (held) callbacks.push(deliver); else deliver();
          });
        },
      });
      return request;
    };
    const open = IDBFactory.prototype.open;
    IDBFactory.prototype.open = function (...args) {
      const request = open.apply(this, args);
      return args[0] === 'noonmark-input-drafts' ? intercept(request) : request;
    };
    const get = IDBObjectStore.prototype.get;
    IDBObjectStore.prototype.get = function (...args) {
      const request = get.apply(this, args);
      return this.transaction.db.name === 'noonmark-input-drafts' ? intercept(request) : request;
    };
  });
  await login(page);
  await page.locator('.add-task').click();
  const task = page.getByRole('dialog', { name: '添加任务', exact: true });
  const title = task.getByLabel('任务名称', { exact: true });
  await expect(title).toBeDisabled();
  await expect(title).not.toBeFocused();
  await page.evaluate(() => (window as unknown as { __noonmarkReleaseDraftReads: () => void }).__noonmarkReleaseDraftReads());
  await expect(title).toBeEnabled();
  await expect(title).toBeFocused();
  await title.fill('汉'.repeat(1000));
  await task.getByRole('textbox', { name: /^描述/ }).focus();
  await task.getByRole('button', { name: '添加任务', exact: true }).click();
  await expect(task.getByRole('alert')).toContainText('请检查输入内容');
  await expect(title).toBeEnabled();
  await expect(title, 'pending 往返不得再次执行初次聚焦').not.toBeFocused();
  await closeDialog(page);
  await navigation(page, '飞光');
  await expect(page.getByLabel('记录内容', { exact: true })).toBeEnabled();
  const content = '焦点验收记录：实际草稿读取，不伪造数据库或服务端响应。';
  await page.getByLabel('记录内容', { exact: true }).fill(content);
  await page.getByRole('button', { name: '记录', exact: true }).click();
  const note = page.locator('.idea-list > li').filter({ hasText: content });
  await expect(note).toBeVisible();
  await page.evaluate(() => (window as unknown as { __noonmarkHoldDraftReads: () => void }).__noonmarkHoldDraftReads());
  await note.getByRole('button', { name: '编辑', exact: true }).click();
  const editing = page.getByRole('dialog', { name: '编辑记录', exact: true });
  const body = editing.getByRole('textbox', { name: '内容', exact: true });
  await expect(body).toBeDisabled();
  await page.evaluate(() => (window as unknown as { __noonmarkReleaseDraftReads: () => void }).__noonmarkReleaseDraftReads());
  await expect(body).toBeEnabled();
  await expect(body).toHaveValue(content);
  await expect(body).toBeFocused();
  await closeDialog(page);
});
