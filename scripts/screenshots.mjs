// screenshots.mjs - catture delle UI della demo (GitLab, ArgoCD, Kargo) con Playwright.
// Uso: node scripts/screenshots.mjs <target> [...]
// Target: gitlab-branches gitlab-commits argocd-apps argocd-tree argocd-dev-events
//         argocd-drift drift-live kargo-chain kargo-freight
// Env:   GITLAB_URL ARGOCD_URL KARGO_URL GITLAB_PASSWORD ARGOCD_PASSWORD KARGO_PASSWORD OUT
// Prerequisiti: port-forward attivi e `npm i playwright` piu' `npx playwright install chromium`.

import { chromium } from "playwright";
import { mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";

const OUT = process.env.OUT || "./shots";
const GITLAB = process.env.GITLAB_URL || "http://localhost:18080";
const ARGOCD = process.env.ARGOCD_URL || "https://localhost:18443";
const KARGO = process.env.KARGO_URL || "https://localhost:18081";
const GITLAB_PW = process.env.GITLAB_PASSWORD || "Gk3B00tstr4p2025xZ";
const ARGOCD_PW = process.env.ARGOCD_PASSWORD || "";
const KARGO_PW = process.env.KARGO_PASSWORD || "Karg0D3m02025xZ";

mkdirSync(OUT, { recursive: true });

const targets = process.argv.slice(2);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// GitLab 18 apre un modal "Welcome to the redesigned GitLab UI" sopra ogni pagina al
// primo accesso di root: va chiuso prima di ogni scatto o copre tutto.
async function dismissModals(page) {
  for (const sel of ['button:has-text("Get started")', 'button[aria-label="Close"]', '[data-testid="close-icon"]']) {
    const el = page.locator(sel).first();
    try {
      if (await el.count() && await el.isVisible()) {
        await el.click({ timeout: 3000 });
        await wait(800);
      }
    } catch {}
  }
}

async function shot(page, name) {
  await dismissModals(page);
  await wait(1500);
  const path = `${OUT}/${name}.png`;
  await page.screenshot({ path, fullPage: false });
  console.log(`OK   ${name} -> ${path}`);
}

async function loginGitlab(page) {
  await page.goto(`${GITLAB}/users/sign_in`, { waitUntil: "domcontentloaded", timeout: 90000 });
  if (await page.locator("#user_login").count()) {
    await page.fill("#user_login", "root");
    await page.fill("#user_password", GITLAB_PW);
    await page.click('input[type="submit"], button[type="submit"]');
    await page.waitForLoadState("domcontentloaded");
    await wait(3000);
  }
}

async function loginArgocd(page) {
  await page.goto(`${ARGOCD}/login`, { waitUntil: "domcontentloaded", timeout: 90000 });
  await wait(2500);
  const user = page.locator('input[name="username"], input[placeholder="Username"]').first();
  if (await user.count()) {
    await user.fill("admin");
    await page.locator('input[type="password"]').first().fill(ARGOCD_PW);
    await page.locator('button:has-text("SIGN IN"), button[type="submit"]').first().click();
    await wait(6000);
  }
}

async function loginKargo(page) {
  await page.goto(`${KARGO}/login`, { waitUntil: "domcontentloaded", timeout: 90000 });
  await wait(3000);
  // Kargo mostra i metodi di login disponibili: con admin abilitato c'e' il form username/password
  const pw = page.locator('input[type="password"]').first();
  if (await pw.count()) {
    const user = page.locator('input[type="text"], input[id*="user" i]').first();
    if (await user.count()) await user.fill("admin");
    await pw.fill(KARGO_PW);
    await page.locator('button[type="submit"], button:has-text("Login"), button:has-text("Log in")').first().click();
    await wait(6000);
  }
}

const jobs = {
  // Lo scale parte con la pagina ArgoCD gia' aperta: il self-heal chiude la finestra
  // OutOfSync in pochi secondi e un login a freddo arriverebbe tardi.
  "drift-live": async (page) => {
    await loginArgocd(page);
    await page.goto(`${ARGOCD}/applications/argocd/kargo-demo-dev`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(6000);
    await shot(page, "drift-1-before");
    execFileSync("kubectl", ["scale", "deployment", "kargo-demo", "-n", "kargo-demo-dev", "--replicas=4"], { stdio: "inherit" });
    for (const [i, ms] of [1200, 1500, 2000, 3000].entries()) {
      await wait(ms);
      await shot(page, `drift-2-outofsync-${i + 1}`);
    }
    await wait(25000);
    await page.reload({ waitUntil: "domcontentloaded" });
    await wait(6000);
    await shot(page, "drift-3-healed");
  },

  "argocd-dev-events": async (page) => {
    await loginArgocd(page);
    const node = encodeURIComponent("apps/Deployment/kargo-demo-dev/kargo-demo");
    await page.goto(`${ARGOCD}/applications/argocd/kargo-demo-dev?node=${node}&tab=events`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(7000);
    await shot(page, "drift-4-argocd-events");
  },

  "gitlab-branches": async (page) => {
    await loginGitlab(page);
    await page.goto(`${GITLAB}/root/kargo-demo/-/branches`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await shot(page, "gitlab-branches");
  },
  "gitlab-commits": async (page) => {
    await loginGitlab(page);
    await page.goto(`${GITLAB}/root/kargo-demo/-/commits/stage/prod`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await shot(page, "gitlab-commits-stage-prod");
  },
  "argocd-apps": async (page) => {
    await loginArgocd(page);
    await page.goto(`${ARGOCD}/applications`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(5000);
    await shot(page, "argocd-applications");
  },
  "argocd-tree": async (page) => {
    await loginArgocd(page);
    await page.goto(`${ARGOCD}/applications/argocd/apps?view=tree`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(6000);
    await shot(page, "argocd-app-of-apps-tree");
  },
  "argocd-drift": async (page) => {
    await loginArgocd(page);
    await page.goto(`${ARGOCD}/applications/argocd/kargo-demo-dev`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(5000);
    await shot(page, `argocd-dev-${process.env.SHOT_TAG || "state"}`);
  },
  "kargo-chain": async (page) => {
    await loginKargo(page);
    await page.goto(`${KARGO}/project/kargo-demo`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(7000);
    await shot(page, "kargo-pipeline");
  },
  "kargo-freight": async (page) => {
    await loginKargo(page);
    await page.goto(`${KARGO}/project/kargo-demo/freight`, { waitUntil: "domcontentloaded", timeout: 90000 });
    await wait(6000);
    await shot(page, "kargo-freight");
  },
};

const browser = await chromium.launch();
const ctx = await browser.newContext({
  ignoreHTTPSErrors: true,
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
});

for (const t of targets) {
  const job = jobs[t];
  if (!job) {
    console.log(`SKIP ${t}: target sconosciuto`);
    continue;
  }
  const page = await ctx.newPage();
  try {
    await job(page);
  } catch (err) {
    console.log(`FAIL ${t}: ${err.message.split("\n")[0]}`);
    try {
      await page.screenshot({ path: `${OUT}/_fail-${t}.png` });
    } catch {}
  }
  await page.close();
}

await browser.close();
