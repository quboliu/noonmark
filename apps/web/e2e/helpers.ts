import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import type { Snapshot } from '../src/types';

export const MAIN_TASK = '网页验收：为这一天留下完整轨迹';
export const SUBTASK = '完成一个可以验证的小步骤';
export const MAIN_IDEA = '一次闪念也值得留下，这是来自真实浏览器的记录。';
export const MAIN_REVIEW = '今天走通了从计划到轨迹的完整路径。';
export const DRAFT_IDEA = '只在此浏览器保存的输入，刷新后仍由我决定是否提交。';
export const OFFLINE_IDEA = '断线时记下的想法，重新连线也不会自动提交。';

export async function login(page: Page): Promise<string> {
  await page.goto('/');
  await expect(page.getByLabel('实例密码', { exact: true })).toBeVisible();
  await page.getByLabel('实例密码', { exact: true }).fill(process.env.NOONMARK_E2E_PASSWORD!);
  const response = page.waitForResponse(response => new URL(response.url()).pathname === '/api/v1/auth/login' && response.request().method() === 'POST');
  await page.getByRole('button', { name: '进入晷迹', exact: true }).click();
  const result = await response;
  expect(result.status(), '登录必须通过真实服务').toBe(200);
  const body = await result.json() as { token: string };
  expect(typeof body.token === 'string' && body.token.length > 20, '服务端必须签发会话').toBe(true);
  await expect(page.getByRole('heading', { name: 'Day Todo', exact: true })).toBeVisible();
  return body.token;
}
export async function api<T>(page: Page, token: string, path: string, body?: unknown): Promise<T> {
  const result = await page.evaluate(async input => {
    try {
      const response = await fetch(input.path, {
        method: input.body === undefined ? 'GET' : 'POST',
        headers: { Authorization: `Bearer ${input.token}`, ...(input.body === undefined ? {} : { 'Content-Type': 'application/json' }) },
        body: input.body === undefined ? undefined : JSON.stringify(input.body), credentials: 'omit', cache: 'no-store',
      });
      return { status: response.status, data: await response.json() };
    } catch { return { status: 0, data: null }; }
  }, { path, token, body });
  expect(result.status, '真实 API 请求必须成功').toBe(200);
  return result.data as T;
}
export const snapshot = (page: Page, token: string) => api<Snapshot>(page, token, '/api/v1/snapshot');
export async function navigation(page: Page, name: string) {
  if (name === '每日复盘') { await navigation(page, 'Day Todo'); await page.getByRole('button', { name: '每日复盘', exact: true }).click(); return; }
  const mobile = page.getByRole('button', { name: '打开导航', exact: true });
  if (await mobile.isVisible()) await mobile.click();
  await page.locator('.sidebar').getByRole('button', { name, exact: true }).click();
}
export async function closeDialog(page: Page) {
  await page.getByRole('dialog').getByRole('button', { name: '关闭', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
}
export async function credentialsAbsentFromStorage(page: Page, tokens: string[]): Promise<void> {
  const clean = await page.evaluate(async secrets => {
    const values = [...Object.values(localStorage), ...Object.values(sessionStorage)];
    const drafts = await new Promise<unknown[]>((resolve, reject) => {
      const opening = indexedDB.open('noonmark-input-drafts', 1);
      opening.onsuccess = () => {
        const db = opening.result;
        if (!db.objectStoreNames.contains('drafts')) { db.close(); resolve([]); return; }
        const query = db.transaction('drafts').objectStore('drafts').getAll();
        query.onsuccess = () => { db.close(); resolve(query.result); };
        query.onerror = () => { db.close(); reject(new Error('DRAFT_INSPECTION_FAILED')); };
      };
      opening.onerror = () => reject(new Error('DRAFT_INSPECTION_FAILED'));
    });
    const serialized = JSON.stringify([...values, ...drafts]);
    return secrets.every(secret => !serialized.includes(secret));
  }, [...tokens, process.env.NOONMARK_E2E_PASSWORD!, process.env.NOONMARK_E2E_BACKUP_PASSPHRASE!]);
  expect(clean, '浏览器持久存储不得保存会话或密码').toBe(true);
}
export async function waitForDraft(page: Page, content: string) {
  await expect.poll(() => page.evaluate(async value => {
    return new Promise<boolean>((resolve, reject) => {
      const opening = indexedDB.open('noonmark-input-drafts', 1);
      opening.onsuccess = () => {
        const db = opening.result;
        const query = db.transaction('drafts').objectStore('drafts').getAll();
        query.onsuccess = () => { db.close(); resolve(query.result.some(record => record.value === value)); };
        query.onerror = () => { db.close(); reject(new Error('DRAFT_INSPECTION_FAILED')); };
      };
      opening.onerror = () => reject(new Error('DRAFT_INSPECTION_FAILED'));
    });
  }, content), { message: '草稿必须实际提交到 IndexedDB' }).toBe(true);
}
