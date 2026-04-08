import { test, expect } from '@playwright/test';

const BASE_URL = process.env.ARGO_WORKFLOWS_URL ?? 'http://argo-workflows.homelab.local';

test.describe('Argo Workflows', () => {
  test('UI が開く', async ({ page }) => {
    await page.goto(BASE_URL, { timeout: 20_000 });
    await expect(page).toHaveTitle(/Argo Workflows/i, { timeout: 15_000 });
  });

  test('WorkflowTemplate 一覧ページが開く', async ({ page }) => {
    await page.goto(`${BASE_URL}/workflow-templates`, { timeout: 20_000 });
    await expect(page.getByRole('heading')).toBeVisible({ timeout: 15_000 });
  });

  test('remediate-oomkilled WorkflowTemplate が存在する', async ({ page }) => {
    await page.goto(`${BASE_URL}/workflow-templates/aiops`, { timeout: 20_000 });
    await expect(page.getByText('remediate-oomkilled')).toBeVisible({ timeout: 15_000 });
  });

  test('analyze-crashloop WorkflowTemplate が存在する', async ({ page }) => {
    await page.goto(`${BASE_URL}/workflow-templates/aiops`, { timeout: 20_000 });
    await expect(page.getByText('analyze-crashloop')).toBeVisible({ timeout: 15_000 });
  });
});
