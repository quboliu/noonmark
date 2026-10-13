import { defineConfig } from '@playwright/test';
import { isAbsolute, join } from 'node:path';

const runRoot = process.env.NOONMARK_RUN_ROOT;
const baseURL = process.env.NOONMARK_E2E_URL;
const stage = process.env.NOONMARK_E2E_STAGE ?? 'browser';
if (!['browser', 'restart', 'restored', 'demo', 'focus'].includes(stage)) throw new Error('E2E_INVALID_STAGE');
if (!runRoot || !isAbsolute(runRoot) || !baseURL) {
  throw new Error('E2E_REQUIRES_EXTERNAL_RUN_AND_INSTANCE');
}
if (!process.env.NOONMARK_E2E_PASSWORD || !process.env.NOONMARK_E2E_BACKUP_PASSPHRASE) {
  throw new Error('E2E_REQUIRES_SYNTHETIC_CREDENTIALS');
}
export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 240_000,
  expect: { timeout: 15_000 },
  outputDir: join(runRoot, 'reports', 'playwright-results', stage),
  reporter: [['line'], ['json', { outputFile: join(runRoot, 'reports', `playwright-${stage}.json`) }]],
  use: {
    baseURL,
    ignoreHTTPSErrors: true,
    acceptDownloads: true,
    viewport: { width: 1440, height: 1000 },
    locale: 'zh-CN',
    trace: 'off',
    video: 'off',
    screenshot: 'off',
    actionTimeout: 15_000,
    launchOptions: process.env.NOONMARK_CHROMIUM_EXECUTABLE ? { executablePath: process.env.NOONMARK_CHROMIUM_EXECUTABLE } : {},
  },
});
