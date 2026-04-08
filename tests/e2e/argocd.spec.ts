import { test, expect, Page } from '@playwright/test';

const BASE_URL  = process.env.ARGOCD_URL      ?? 'http://argocd.homelab.local';
const PASSWORD  = process.env.ARGOCD_PASSWORD ?? 'Argocd12345';

async function login(page: Page) {
  await page.goto(`${BASE_URL}/login`);
  await page.getByPlaceholder('Username').fill('admin');
  await page.getByPlaceholder('Password').fill(PASSWORD);
  await page.getByRole('button', { name: /sign in/i }).click();
  await page.waitForURL(`${BASE_URL}/applications`, { timeout: 15_000 });
}

const HEALTHY_APPS = [
  'kyverno',
  'monitoring',
  'logging-elasticsearch',
  'logging-fluent-bit',
  'logging-kibana',
  'aiops-alerting',
  'aiops-pushgateway',
  'aiops-anomaly-detection',
  'aiops-alert-summarizer',
  'aiops-auto-remediation',
];

test.describe('ArgoCD', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('アプリ一覧が表示される', async ({ page }) => {
    await expect(page.getByText('kyverno')).toBeVisible({ timeout: 10_000 });
  });

  for (const app of HEALTHY_APPS) {
    test(`${app} が Healthy`, async ({ page }) => {
      await page.goto(`${BASE_URL}/applications/${app}`);
      const statusPanel = page.locator('.application-status-panel__item');
      await expect(statusPanel.filter({ hasText: 'Healthy' })).toBeVisible({ timeout: 20_000 });
    });
  }

  test('aiops 系アプリがすべて Synced', async ({ page }) => {
    await page.goto(`${BASE_URL}/applications?search=aiops`);
    // Synced バッジが OutOfSync より多いことを確認
    const synced = await page.getByText('Synced').count();
    expect(synced).toBeGreaterThan(0);
  });
});
