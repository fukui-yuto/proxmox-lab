import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  timeout: 30_000,
  retries: 1,
  reporter: [['html', { open: 'never' }], ['list']],
  use: {
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    ignoreHTTPSErrors: true,
  },
  projects: [
    {
      name: 'ui',
      testMatch: 'e2e/**/*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
      },
    },
    {
      name: 'api',
      testMatch: 'api/**/*.spec.ts',
    },
  ],
});
