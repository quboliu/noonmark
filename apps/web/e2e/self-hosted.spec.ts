import { test, expect } from '@playwright/test';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { api, closeDialog, credentialsAbsentFromStorage, DRAFT_IDEA, login, MAIN_IDEA, MAIN_REVIEW, MAIN_TASK, navigation, OFFLINE_IDEA, snapshot, SUBTASK, waitForDraft } from './helpers';

test('个人实例：真实浏览器命令、草稿、多设备及备份闭环', async ({ page, context, browser }) => {
  const reportRoot = join(process.env.NOONMARK_RUN_ROOT!, 'reports');
  await mkdir(join(reportRoot, 'screenshots'), { recursive: true });
  await mkdir(join(reportRoot, 'e2e-downloads'), { recursive: true });
  let pageErrors = 0;
  let commands = 0;
  let successfulCommands = 0;
  page.on('pageerror', () => { pageErrors++; });
  page.on('request', request => { if (new URL(request.url()).pathname === '/api/v1/commands' && request.method() === 'POST') commands++; });
  page.on('response', response => { if (new URL(response.url()).pathname === '/api/v1/commands' && response.status() === 200) successfulCommands++; });
  await test.step('FAIL-2026-10-12-01：认证字段别名必须在真实服务被拒绝', async () => {
    await page.goto('/');
    const results = await page.evaluate(async password => {
      const wrong = `invalid-${crypto.randomUUID()}`;
      const bodies = [
        JSON.stringify({ password: wrong, Password: password }),
        '{"password":' + JSON.stringify(wrong) + ',"pa\\u017fsword":' + JSON.stringify(password) + '}',
      ];
      const outcomes: { status: number; code: string; tokenReturned: boolean }[] = [];
      for (const body of bodies) {
        const response = await fetch('/api/v1/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body, credentials: 'omit' });
        const data = await response.json();
        outcomes.push({ status: response.status, code: typeof data.code === 'string' ? data.code : 'MISSING_TYPED_ERROR', tokenReturned: typeof data.token === 'string' });
      }
      return outcomes;
    }, process.env.NOONMARK_E2E_PASSWORD!);
    expect(results).toEqual([
      { status: 400, code: 'INVALID_REQUEST', tokenReturned: false },
      { status: 400, code: 'INVALID_REQUEST', tokenReturned: false },
    ]);
  });
  let token = await login(page);
  const initial = await snapshot(page, token);
  const secondContext = await browser.newContext({ baseURL: process.env.NOONMARK_E2E_URL, ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 } });
  const second = await secondContext.newPage();
  let secondErrors = 0;
  second.on('pageerror', () => { secondErrors++; });
  const secondToken = await login(second);
  try {
    await test.step('中文组合输入不会提前提交，任务由实例保存', async () => {
      await page.keyboard.press('Control+k');
      const dialog = page.getByRole('dialog', { name: '添加任务', exact: true });
      const title = dialog.getByLabel('任务名称', { exact: true });
      await expect(title).toBeEnabled();
      await expect(title, '真实速记浮窗打开后，标题应取得焦点').toBeFocused();
      await title.dispatchEvent('compositionstart', { data: '网' });
      await title.fill(MAIN_TASK);
      const before = commands;
      await title.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 229, isComposing: true });
      await dialog.locator('form').dispatchEvent('submit');
      await expect(dialog).toBeVisible();
      expect(commands, '组合输入期间不得发送领域命令').toBe(before);
      await title.dispatchEvent('compositionend', { data: MAIN_TASK });
      await dialog.getByRole('textbox', { name: /^描述/ }).fill('这份验收资料通过真实领域命令创建。');
      await dialog.getByLabel('安排日期', { exact: true }).fill(initial.today);
      await dialog.getByRole('button', { name: '添加任务', exact: true }).click();
      await expect(dialog).toHaveCount(0);
      await expect(page.locator('.task-title').filter({ hasText: MAIN_TASK })).toBeVisible();
      await expect(second.locator('.task-title').filter({ hasText: MAIN_TASK })).toBeVisible();
    });
    await test.step('子任务前置条件、完成轨迹及另一台设备更新', async () => {
      await page.locator('.task-open').filter({ hasText: MAIN_TASK }).click();
      const dialog = page.getByRole('dialog', { name: '任务详情', exact: true });
      await expect(dialog.getByLabel('子任务名称', { exact: true })).toBeEnabled();
      await dialog.getByLabel('子任务名称', { exact: true }).fill(SUBTASK);
      await dialog.getByLabel('子任务难度', { exact: true }).selectOption('medium');
      await dialog.getByRole('button', { name: '添加子任务', exact: true }).click();
      await expect(dialog.locator('.subtask-line').filter({ hasText: SUBTASK })).toBeVisible();
      await dialog.getByRole('button', { name: '标为完成', exact: true }).click();
      await expect(dialog.getByRole('alert')).toContainText('还有未完成的子任务');
      await dialog.getByRole('button', { name: `完成子任务：${SUBTASK}`, exact: true }).click();
      await expect(dialog.getByRole('button', { name: `撤销子任务完成：${SUBTASK}`, exact: true })).toBeVisible();
      await dialog.getByRole('button', { name: '标为完成', exact: true }).click();
      await expect(dialog.getByRole('button', { name: '撤销今日完成', exact: true })).toBeVisible();
      await closeDialog(page);
      await expect(second.locator('.task-row').filter({ hasText: MAIN_TASK })).toHaveClass(/is-complete/);
      const state = await snapshot(page, token);
      const definition = state.definitions.find(item => item.title === MAIN_TASK)!;
      const trace = state.traces.find(item => item.chain_id === definition.chain_id)!;
      expect(trace.status).toBe('completed');
      expect(state.subtasks.filter(item => item.trace_id === trace.id && item.status === 'completed')).toHaveLength(1);
      await navigation(page, '已完成');
      await expect(page.locator('.completed-children').filter({ hasText: SUBTASK })).toBeVisible();
    });
    await test.step('飞光记录、便签投影与每日复盘', async () => {
      await navigation(page, '飞光');
      await expect(page.getByLabel('记录内容', { exact: true })).toBeEnabled();
      await page.getByLabel('记录内容', { exact: true }).fill(MAIN_IDEA);
      await page.getByRole('button', { name: '发布', exact: true }).click();
      const record = page.locator('.idea-list > li').filter({ hasText: MAIN_IDEA });
      await expect(record).toBeVisible();
      await record.getByRole('button', { name: '记录操作', exact: true }).click();
      await record.getByRole('button', { name: '加入 Sticky Note', exact: true }).click();
      await record.getByRole('button', { name: '记录操作', exact: true }).click();
      await expect(record.getByRole('button', { name: '从 Sticky Note 移除', exact: true })).toBeVisible();
      await navigation(page, 'Sticky Note');
      await expect(page.locator('.idea-body').filter({ hasText: MAIN_IDEA })).toBeVisible();
      await navigation(page, '每日复盘');
      await expect(page.getByRole('textbox', { name: '今日总结', exact: true })).toBeEnabled();
      await page.getByRole('textbox', { name: '今日总结', exact: true }).fill(MAIN_REVIEW);
      await page.getByRole('textbox', { name: '未完成原因', exact: true }).fill('留待下一步完成商业发行门禁。');
      await page.getByRole('textbox', { name: '明日注意事项', exact: true }).fill('从已有证据继续。');
      await page.getByRole('button', { name: '保存复盘', exact: true }).click();
      await expect(page.getByText('✓ 复盘已保存', { exact: true })).toBeVisible();
      expect((await snapshot(page, token)).days.find(day => day.date === initial.today)?.summary).toBe(MAIN_REVIEW);
    });
    await test.step('草稿实际落盘，刷新重新认证后恢复，凭证不落盘', async () => {
      await navigation(page, '飞光');
      await page.getByLabel('记录内容', { exact: true }).fill(DRAFT_IDEA);
      await waitForDraft(page, DRAFT_IDEA);
      await credentialsAbsentFromStorage(page, [token, secondToken]);
      await page.reload();
      token = await login(page);
      await navigation(page, '飞光');
      await expect(page.getByLabel('记录内容', { exact: true })).toHaveValue(DRAFT_IDEA);
      expect((await snapshot(page, token)).ideas.filter(idea => idea.body === DRAFT_IDEA)).toHaveLength(0);
    });
    await test.step('断线草稿不自动写入，明确提交才产生事实', async () => {
      const before = commands;
      await context.setOffline(true);
      await expect(page.getByText('暂时无法连接实例。可继续写草稿，恢复连接后再提交。', { exact: true })).toBeVisible();
      const composer = page.getByLabel('记录内容', { exact: true });
      await expect(composer).toBeEnabled();
      await composer.fill(OFFLINE_IDEA);
      await waitForDraft(page, OFFLINE_IDEA);
      await expect(page.getByRole('button', { name: '发布', exact: true })).toBeDisabled();
      expect(commands).toBe(before);
      await context.setOffline(false);
      await expect(page.locator('.instance-note').getByText('已连接', { exact: true })).toBeVisible();
      await expect(page.getByRole('button', { name: '发布', exact: true })).toBeEnabled();
      expect((await snapshot(page, token)).ideas.filter(idea => idea.body === OFFLINE_IDEA)).toHaveLength(0);
      expect(commands, '重新连接不得自动发送命令').toBe(before);
      await page.getByRole('button', { name: '发布', exact: true }).click();
      await expect(page.locator('.idea-body').filter({ hasText: OFFLINE_IDEA })).toBeVisible();
      expect((await snapshot(page, token)).ideas.filter(idea => idea.body === OFFLINE_IDEA)).toHaveLength(1);
    });
    await test.step('服务端已提交但确认丢失：查询原回执，不重复创建', async () => {
      await navigation(page, '飞光');
      const content = '确认响应丢失时，这条记录仍然只由服务端创建一次。';
      await page.getByLabel('记录内容', { exact: true }).fill(content);
      const before = commands;
      let committedStatus = 0;
      await page.route('**/api/v1/commands', async route => {
        try {
          const response = await route.fetch({ timeout: 30_000 });
          committedStatus = response.status();
          await route.abort('failed');
        } catch {
          committedStatus = 0;
          await route.abort('failed').catch(() => {});
        }
      }, { times: 1 });
      await page.getByRole('button', { name: '发布', exact: true }).click();
      await expect(page.getByText('有一次操作结果待确认', { exact: true })).toBeVisible();
      expect(committedStatus, '丢弃响应前必须已走完真实提交').toBe(200);
      await expect(page.getByRole('button', { name: '发布', exact: true })).toBeDisabled();
      expect(commands, '确认丢失后不得生成新命令自动重试').toBe(before + 1);
      await page.getByRole('button', { name: '核对结果', exact: true }).click();
      await expect(page.getByText('有一次操作结果待确认', { exact: true })).toHaveCount(0);
      await expect(page.getByText('已确认：这次操作已保存。请核对最新内容。', { exact: true })).toBeVisible();
      expect((await snapshot(page, token)).ideas.filter(idea => idea.body === content)).toHaveLength(1);
      expect(commands, '回执确认只查询结果，不再次发送命令').toBe(before + 1);
    });
    await test.step('真实长列表的桌面与移动布局、导航和唯一 DOM 身份', async () => {
      let state = await snapshot(page, token);
      for (let index = 1; index <= 38; index++) {
        await api(page, token, '/api/v1/commands', {
          instance_id: state.instance_id, instance_epoch: state.instance_epoch, dataset_id: state.dataset_id,
          command_id: crypto.randomUUID(), schema_version: 1, type: 'CreateTask', expected_revision: '0',
          payload: { title: `长列表验收 ${String(index).padStart(2, '0')} · 让每一步都有记录`, date: state.today },
        });
      }
      await navigation(page, 'Day Todo');
      await expect(page.locator('.task-row')).toHaveCount(39);
      await page.screenshot({ path: join(reportRoot, 'screenshots', 'day-desktop-top.png') });
      await page.evaluate(() => document.querySelector('.main-content')!.scrollTo(0, document.querySelector('.main-content')!.scrollHeight));
      await expect(page.locator('.sidebar')).toBeInViewport();
      await page.screenshot({ path: join(reportRoot, 'screenshots', 'day-desktop-bottom.png') });
      const uniqueIDs = await page.evaluate(() => { const ids = [...document.querySelectorAll('[id]')].map(element => element.id); return new Set(ids).size === ids.length; });
      expect(uniqueIDs).toBe(true);
      await page.setViewportSize({ width: 390, height: 844 });
      await expect(page.locator('.sidebar'), '移动侧栏收起后才采集页面证据').not.toBeInViewport();
      await expect(page.getByRole('heading', { name: 'Day Todo', exact: true })).toBeVisible();
      await page.evaluate(() => document.querySelector('.main-content')!.scrollTo(0, 0));
      await page.screenshot({ path: join(reportRoot, 'screenshots', 'day-mobile-top.png') });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), '移动页面不得横向溢出').toBe(true);
      await page.evaluate(() => document.querySelector('.main-content')!.scrollTo(0, document.querySelector('.main-content')!.scrollHeight));
      await page.screenshot({ path: join(reportRoot, 'screenshots', 'day-mobile-bottom.png') });
      await page.evaluate(() => document.querySelector('.main-content')!.scrollTo(0, 0));
      await navigation(page, 'Sticky Note');
      await expect(page.locator('.idea-body').filter({ hasText: MAIN_IDEA })).toBeVisible();
      await page.setViewportSize({ width: 1440, height: 1000 });
      state = await snapshot(page, token);
      expect(state.chains.length - initial.chains.length).toBe(39);
    });
    await test.step('最后下载真实加密备份，检查本机没有持久凭证', async () => {
      await navigation(page, '设置');
      await page.getByRole('dialog', { name: '设置', exact: true }).getByRole('button', { name: '数据', exact: true }).click();
      await page.getByLabel('实例密码', { exact: true }).fill(process.env.NOONMARK_E2E_PASSWORD!);
      await page.getByLabel('备份口令', { exact: true }).fill(process.env.NOONMARK_E2E_BACKUP_PASSPHRASE!);
      await page.getByLabel('再次输入备份口令', { exact: true }).fill(process.env.NOONMARK_E2E_BACKUP_PASSPHRASE!);
      const downloadPromise = page.waitForEvent('download', { timeout: 130_000 });
      await page.getByRole('button', { name: '生成并下载备份', exact: true }).click();
      const download = await downloadPromise;
      const output = join(reportRoot, 'e2e-downloads', 'instance.noonmarkbackup');
      await download.saveAs(output);
      expect(await download.failure(), '下载必须真正完成').toBeNull();
      const content = await readFile(output);
      expect(content.subarray(0, 22).toString().startsWith('age-encryption.org/v1'), '备份必须是加密包').toBe(true);
      await expect(page.getByText('已生成备份包，下载已发起。请确认浏览器已保存文件。', { exact: true })).toBeVisible();
      await expect(page.getByLabel('实例密码', { exact: true })).toHaveValue('');
      await expect(page.getByLabel('备份口令', { exact: true })).toHaveValue('');
      await credentialsAbsentFromStorage(page, [token, secondToken]);
      await page.screenshot({ path: join(reportRoot, 'screenshots', 'settings-backup.png') });
    });
    expect(pageErrors, '主浏览器不得出现脚本错误').toBe(0);
    expect(secondErrors, '第二浏览器不得出现脚本错误').toBe(0);
    await writeFile(join(reportRoot, 'browser-evidence.json'), JSON.stringify({ verdict: 'PASS', command_requests: commands, committed_responses: successfulCommands, page_errors: pageErrors + secondErrors, checked_viewports: 2, offline_auto_commands: 0, credential_persistence: false, encrypted_backup_downloaded: true }) + '\n');
  } finally { await context.setOffline(false); await secondContext.close(); }
});
