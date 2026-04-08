import { test, expect, Page } from '@playwright/test';

const BASE_URL = process.env.GRAFANA_URL ?? 'http://grafana.homelab.local';
const USER     = process.env.GRAFANA_USER     ?? 'admin';
const PASSWORD = process.env.GRAFANA_PASSWORD ?? 'changeme';

async function login(page: Page) {
  await page.goto(`${BASE_URL}/login`);
  await page.getByLabel('Email or username').fill(USER);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: /log in/i }).click();
  await page.waitForURL(`${BASE_URL}/**`, { timeout: 15_000 });
}

test.describe('Grafana', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('ログインに成功する', async ({ page }) => {
    await expect(page).not.toHaveURL(/\/login/);
  });

  test('Log Anomaly Detection ダッシュボードが存在する', async ({ page }) => {
    await page.goto(`${BASE_URL}/d/log-anomaly`);
    await expect(page.getByText('Log Anomaly Detection')).toBeVisible({ timeout: 15_000 });
  });

  test('異常フラグパネルが表示される', async ({ page }) => {
    await page.goto(`${BASE_URL}/d/log-anomaly`);
    await expect(page.getByText('Total Log Anomaly')).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText('Error Log Anomaly')).toBeVisible();
    await expect(page.getByText('Error Log Level-Shift')).toBeVisible();
  });

  test('Namespace 別エラー件数パネルが表示される', async ({ page }) => {
    await page.goto(`${BASE_URL}/d/log-anomaly`);
    await expect(page.getByText('Namespace 別エラー件数')).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText('Top エラー Pod')).toBeVisible();
  });

  test('AIOps アラートルールが設定されている', async ({ page }) => {
    await page.goto(`${BASE_URL}/alerting/list`);
    await expect(page.getByText('DiskSpaceExhaustionIn24h')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText('PodOOMKilled')).toBeVisible();
    await expect(page.getByText('PodCrashLoopBackOff')).toBeVisible();
  });
});
