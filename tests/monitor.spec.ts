import { test, expect } from '@playwright/test';

// A read-only visitor journey: discover monitoring and inspect the Playwright offer.
// It never registers an account, sends a message, or changes production data.
test('a visitor can discover Playwright monitoring', async ({ page }) => {
  await test.step('open the monitoring product page', async () => {
    const response = await page.goto('/monitoring');
    expect(response?.status(), 'monitoring page HTTP status').toBe(200);
    await expect(page).toHaveTitle(/Monitoring.*Testable/i);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  await test.step('follow the Playwright monitoring setup path', async () => {
    await page.getByRole('link', { name: /^Explore Playwright monitoring/ }).click();
    await expect(page).toHaveURL(/\/playwright-monitoring\/?$/);
    await expect(page).toHaveTitle(/Playwright.*Monitoring/i);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await expect(page.getByRole('link', { name: /Start monitoring free/i }).first())
      .toHaveAttribute('href', /^https:\/\/m\.testable\.io\/register(?:[?#].*)?$/);
  });
});
