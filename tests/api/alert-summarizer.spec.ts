import { test, expect } from '@playwright/test';

const BASE_URL = process.env.ALERT_SUMMARIZER_URL ?? 'http://alert-summarizer.homelab.local';

const firingAlert = (alertname: string, severity = 'warning') => ({
  status: 'firing' as const,
  labels: { alertname, severity, namespace: 'default' },
  annotations: {
    summary: `[Playwright テスト] ${alertname}`,
    description: 'Playwright API テストから送信されたアラートです。',
  },
  startsAt: new Date().toISOString(),
  fingerprint: `test-${Date.now()}`,
});

const webhookPayload = (alerts: ReturnType<typeof firingAlert>[]) => ({
  version: '4',
  status: 'firing',
  receiver: 'alert-summarizer',
  groupLabels: { alertname: alerts[0]?.labels.alertname ?? '' },
  commonLabels: {},
  commonAnnotations: {},
  externalURL: 'http://alertmanager.test',
  alerts,
});

test.describe('alert-summarizer', () => {
  test('GET /health → status: ok', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/health`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.status).toBe('ok');
  });

  test('POST /webhook (warning) → accepted', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/webhook`, {
      data: webhookPayload([firingAlert('TestAlertWarning', 'warning')]),
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.status).toBe('accepted');
    expect(body.alert_count).toBe(1);
  });

  test('POST /webhook (critical) → accepted', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/webhook`, {
      data: webhookPayload([firingAlert('TestAlertCritical', 'critical')]),
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.status).toBe('accepted');
  });

  test('POST /webhook (複数アラート) → alert_count が正しい', async ({ request }) => {
    const alerts = [
      firingAlert('Alert1', 'warning'),
      firingAlert('Alert2', 'critical'),
      firingAlert('Alert3', 'warning'),
    ];
    const resp = await request.post(`${BASE_URL}/webhook`, {
      data: webhookPayload(alerts),
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.alert_count).toBe(3);
  });

  test('POST /webhook (resolved のみ) → スキップされる', async ({ request }) => {
    const payload = {
      ...webhookPayload([]),
      status: 'resolved',
      alerts: [
        {
          status: 'resolved',
          labels: { alertname: 'TestAlert' },
          annotations: {},
          startsAt: new Date().toISOString(),
          endsAt: new Date().toISOString(),
          fingerprint: 'test-resolved',
        },
      ],
    };
    const resp = await request.post(`${BASE_URL}/webhook`, { data: payload });
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.status).toMatch(/no firing alerts/);
  });

  test('POST /webhook (不正な JSON) → 422', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/webhook`, {
      data: 'not-json',
      headers: { 'Content-Type': 'application/json' },
    });
    expect(resp.status()).toBe(422);
  });
});
