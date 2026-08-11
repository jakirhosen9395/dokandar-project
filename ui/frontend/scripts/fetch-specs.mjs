// DOKANDAR frontend — build-time OpenAPI spec collection + type generation.
//
// The API Gateway does NOT expose/aggregate per-service specs (verified: /api/v1/<svc>/openapi.json
// -> 404). So this script fetches each service's /openapi.json directly from the app host's internal
// per-service ports AT BUILD TIME ONLY (server-side, on the dev/build box). Those internal URLs/ports
// are NEVER shipped to the browser — only the generated `.ts` types are committed and imported.
//
// Output:
//   generated/openapi/raw/<svc>.json   pinned spec snapshot (committed, reproducible build)
//   generated/openapi/<svc>.ts         openapi-typescript types (read-only; regenerate, don't edit)
//   generated/openapi/MANIFEST.json    svc -> { version, title, paths, source, fetchedAt }
//
// Run:  pnpm gen:api      (re-run manually when a backend API changes; review `git diff generated/`)
// Env:  SPEC_HOST (default 65.2.81.217)  — the app host serving the per-service ports.

import { writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const HOST = process.env.SPEC_HOST || '172.31.14.241'; // app-server private VPC IP (in-VPC build/runtime)

// service -> external per-service port (frontend-relevant + DEVOPS-portal completeness = all 18 + support)
const SERVICES = {
  '00-support': 10099, '01-auth': 10001, '02-profile': 10002, '03-seller': 10003,
  '04-catalog': 10004, '05-search': 10005, '06-cart': 10006, '07-coupon': 10007,
  '08-review': 10008, '09-payment': 10009, '10-wallet': 10010, '11-reporting': 10011,
  '12-media': 10012, '13-order': 10013, '14-notification': 10014, '15-api-gateway': 10015,
  '16-recommendation': 10016, '17-shipping': 10017, '18-risk-trust': 10018,
};

const RAW_DIR = 'generated/openapi/raw';
mkdirSync(RAW_DIR, { recursive: true });

const manifest = {};
let ok = 0, fail = 0;

for (const [svc, port] of Object.entries(SERVICES)) {
  const url = `http://${HOST}:${port}/openapi.json`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) { console.error(`  ✗ ${svc.padEnd(18)} HTTP ${res.status} (${url})`); fail++; continue; }
    const spec = await res.json();
    const rawPath = `${RAW_DIR}/${svc}.json`;
    writeFileSync(rawPath, JSON.stringify(spec, null, 2) + '\n');
    execSync(`pnpm exec openapi-typescript ${rawPath} -o generated/openapi/${svc}.ts`, { stdio: 'pipe' });
    manifest[svc] = {
      version: spec.info?.version ?? null,
      title: spec.info?.title ?? null,
      paths: Object.keys(spec.paths ?? {}).length,
      source: `:${port}/openapi.json`,
      fetchedAt: new Date().toISOString(),
    };
    console.log(`  ✓ ${svc.padEnd(18)} v=${manifest[svc].version}  paths=${manifest[svc].paths}`);
    ok++;
  } catch (e) {
    console.error(`  ✗ ${svc.padEnd(18)} ${String(e.message || e).slice(0, 60)}`);
    fail++;
  }
}

writeFileSync('generated/openapi/MANIFEST.json', JSON.stringify(manifest, null, 2) + '\n');
console.log(`\nOpenAPI codegen: ${ok} ok, ${fail} failed. Manifest: generated/openapi/MANIFEST.json`);
if (ok === 0) process.exit(1);
