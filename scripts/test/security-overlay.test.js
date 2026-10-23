const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, writeFileSync, rmSync, unlinkSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

const script = resolve(__dirname, '../security-overlay.sh');
const official = 'ghcr.io/librechat-ai/librechat:v0.8.8';
const patched = `ghcr.io/marylandlegalaid/librechat-node-hotfix:v0.8.8-node24.22.1-r1@sha256:${'a'.repeat(64)}`;

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'security-overlay-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const base = image => writeFileSync(join(root, 'compose.yaml'), JSON.stringify({ services: { api: { image } } }));
  const overlay = (image = patched, extra = {}) => writeFileSync(join(root, 'compose.security.yml'), JSON.stringify({
    'x-security-patch': { 'upstream-image': official },
    services: { api: { image, ...extra } },
  }));
  const run = () => spawnSync('bash', [script, root], { encoding: 'utf8' });
  base(official);
  return { root, base, overlay, run };
}

test('deployment and rollback resolve the current checkout, including removal', t => {
  const f = fixture(t);
  assert.equal(f.run().stdout, '');
  f.overlay();
  assert.equal(f.run().status, 0);
  assert.equal(f.run().stdout.trim(), join(f.root, 'compose.security.yml'));
  f.base('ghcr.io/librechat-ai/librechat:v0.8.9');
  assert.notEqual(f.run().status, 0);
  assert.match(f.run().stderr, /remove or rebuild/);
  f.base(official);
  assert.equal(f.run().status, 0);
  unlinkSync(join(f.root, 'compose.security.yml'));
  f.base('ghcr.io/librechat-ai/librechat:v0.8.9');
  assert.equal(f.run().status, 0);
  assert.equal(f.run().stdout, '');
});

test('mutable images and changes beyond the image are rejected', t => {
  const f = fixture(t);
  f.overlay('ghcr.io/example/hotfix:latest');
  assert.notEqual(f.run().status, 0);
  f.overlay(patched, { privileged: true });
  assert.notEqual(f.run().status, 0);
  writeFileSync(join(f.root, 'compose.security.yml'), 'services: [broken');
  assert.notEqual(f.run().status, 0);
});
