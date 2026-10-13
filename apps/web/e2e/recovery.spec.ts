import { test, expect } from '@playwright/test';
import { login, MAIN_IDEA, MAIN_REVIEW, MAIN_TASK, navigation, snapshot, SUBTASK } from './helpers';

test('重启或恢复后：原有任务、飞光和复盘仍可从真实界面读取', async ({ page }) => {
  let errors = 0;
  page.on('pageerror', () => { errors++; });
  const token = await login(page);
  const state = await snapshot(page, token);
  const definition = state.definitions.find(item => item.title === MAIN_TASK);
  expect(Boolean(definition), '验收任务必须从服务端恢复').toBe(true);
  const trace = state.traces.find(item => item.chain_id === definition!.chain_id && item.status === 'completed');
  expect(Boolean(trace), '完成事实必须保留').toBe(true);
  await navigation(page, '已完成');
  await expect(page.locator('.task-open').filter({ hasText: MAIN_TASK })).toBeVisible();
  await expect(page.locator('.completed-children').filter({ hasText: SUBTASK })).toBeVisible();
  await navigation(page, '便签');
  await expect(page.locator('.idea-body').filter({ hasText: MAIN_IDEA })).toBeVisible();
  await navigation(page, '每日复盘');
  await page.getByLabel('查看日期', { exact: true }).fill(trace!.date);
  await expect(page.getByRole('textbox', { name: '今天，想记住什么？', exact: true })).toHaveValue(MAIN_REVIEW);
  expect(errors, '恢复后不得出现浏览器脚本错误').toBe(0);
});
