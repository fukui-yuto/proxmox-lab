import { test, expect } from '@playwright/test';

const BASE_URL = process.env.KIBANA_URL ?? 'http://kibana.homelab.local';

test.describe('Kibana', () => {
  test('トップページが開く', async ({ page }) => {
    await page.goto(BASE_URL, { waitUntil: 'networkidle', timeout: 30_000 });
    await expect(page).toHaveTitle(/Kibana/i, { timeout: 20_000 });
  });

  test('Discover ページが開く', async ({ page }) => {
    await page.goto(`${BASE_URL}/app/discover`, { timeout: 30_000 });
    // Kibana の Discover ページが読み込まれるまで待つ
    await expect(page.getByRole('heading', { name: /discover/i }))
      .toBeVisible({ timeout: 20_000 });
  });

  test('fluent-bit インデックスが存在する', async ({ page }) => {
    await page.goto(`${BASE_URL}/app/discover`, { timeout: 30_000 });
    // データビューセレクターに fluent-bit が表示される
    await expect(page.getByText(/fluent-bit/i)).toBeVisible({ timeout: 20_000 });
  });
});
