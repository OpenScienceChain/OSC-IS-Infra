#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { chromium } = require('@playwright/test');

const [runId, outputPath] = process.argv.slice(2);
if (!/^[a-z0-9]{8,20}$/.test(runId || '') || !outputPath) {
  throw new Error('Usage: capture-argocd-evidence <run-id> <output.png>');
}

async function main() {
  const context = execFileSync('kubectl', ['config', 'current-context'], { encoding: 'utf8' }).trim();
  if (context !== `osc-usrse26-${runId}`) throw new Error('Refusing to use a different cluster');
  const password = execFileSync('kubectl', [
    '-n', 'argocd', 'get', 'secret', 'argocd-initial-admin-secret',
    '-o', 'go-template={{.data.password | base64decode}}',
  ], { encoding: 'utf8' }).trim();
  if (!password) throw new Error('Argo admin password unavailable');

  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({
      viewport: { width: 1440, height: 960 },
      deviceScaleFactor: 1,
      ignoreHTTPSErrors: true,
    });
    await page.goto('https://127.0.0.1:18980/', { waitUntil: 'domcontentloaded' });
    await page.locator('input[name="username"]').fill('admin');
    await page.locator('input[name="password"]').fill(password);
    await page.locator('button[type="submit"]').click();
    await page.waitForURL(url => !url.pathname.startsWith('/login'), { timeout: 30000 });
    await page.goto('https://127.0.0.1:18980/applications/osc-is-aws', { waitUntil: 'domcontentloaded' });
    await page.getByText('osc-is-aws', { exact: true }).first().waitFor({ timeout: 30000 });
    await page.mouse.move(1200, 115);
    await page.waitForTimeout(1500);
    await page.screenshot({ path: outputPath, fullPage: true });
    const labels = await page.locator('body').innerText();
    const metadata = {
      runId,
      capturedAt: new Date().toISOString(),
      url: '/applications/osc-is-aws',
      syncedVisible: labels.includes('Synced'),
      healthyVisible: labels.includes('Healthy'),
      screenshot: path.basename(outputPath),
    };
    fs.writeFileSync(outputPath.replace(/\.png$/i, '.json'), JSON.stringify(metadata, null, 2) + '\n');
    console.log(JSON.stringify(metadata));
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
