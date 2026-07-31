/*
 * Rename the product's versioned wordmark, MLAGPT 4 -> MLAGPT 4.1.
 *
 * No database in here on purpose — this file is pure string and object work so
 * it can be unit-tested without one. scripts/rename-brand.js is the half that
 * needs mongosh.
 *
 * WHAT IT MATCHES, AND WHY IT IS NARROW
 *
 * Only the VERSIONED wordmark. The user agreement says "MLAGPT" perhaps a dozen
 * times with no version attached, and those are talking about the product in
 * general rather than a release. Renaming them would be wrong, so the pattern
 * requires a version number to be present.
 *
 * Casing is normalized to MLAGPT, John's call on 2026-07-31. Both spellings are
 * live today: APP_TITLE reads `mlaGPT 4` while everything else reads `MLAGPT 4`,
 * and the Entra app registration is `mlaGPT`. After this runs there is one
 * spelling.
 *
 * IDEMPOTENCE IS THE WHOLE GAME
 *
 * This runs after a restore, in a cutover window, possibly twice because
 * somebody was not sure whether it had run. A second pass must be a no-op, so
 * the pattern refuses to match a version that already carries a minor part:
 * `MLAGPT 4.1` does not become `MLAGPT 4.1.1`. That is what the (?!\.\d)
 * lookahead is for, and there is a test that asserts exactly this.
 */

'use strict';

/*
 * \bMLA\s?GPT   — matches both `MLAGPT` and the `mlaGPT`/`MLA GPT` spellings
 * \s+4\b        — a bare major version, so `MLAGPT 40` is left alone
 * (?!\.\d)      — but not one that already has a minor part
 */
const VERSIONED_WORDMARK = /\bMLA\s?GPT\s+4\b(?!\.\d)/gi;

const REPLACEMENT = 'MLAGPT 4.1';

/* The agent fields that are the live, user-facing record.
 *
 * versions[] is deliberately absent. John's call on 2026-07-31: the snapshots
 * stay as they were written. The consequence is real and worth knowing — if
 * somebody restores an older version of one of these agents from the UI, the
 * old name comes back with it — but a version snapshot is a record of what
 * something was, and this rename is not fixing a fault. Contrast
 * agent-content-repair.js, which does rewrite snapshots, because a dangling
 * tool name there is a broken pointer rather than a record.
 */
const LIVE_FIELDS = ['name', 'description', 'instructions'];

function renameString(value) {
  if (typeof value !== 'string') {
    return value;
  }
  return value.replace(VERSIONED_WORDMARK, REPLACEMENT);
}

function hasOldBrand(value) {
  if (typeof value !== 'string') {
    return false;
  }
  /* .test() on a /g regex is stateful via lastIndex; build a fresh one. */
  return new RegExp(VERSIONED_WORDMARK.source, 'i').test(value);
}

/*
 * Produce the change plan for one agent. Returns { skipped: true } when nothing
 * would change, so a caller can count untouched agents without re-deriving it.
 */
function planAgentRename(agent) {
  const agentId = agent.id || (agent._id ? String(agent._id) : null);
  const plan = {
    agentId,
    name: agent.name || '(unnamed)',
    changes: [],
    set: {},
    skipped: true,
  };

  LIVE_FIELDS.forEach((field) => {
    const before = agent[field];
    if (typeof before !== 'string' || !hasOldBrand(before)) {
      return;
    }
    const after = renameString(before);
    if (after === before) {
      return;
    }
    plan.set[field] = after;
    plan.changes.push({
      field,
      from: excerpt(before),
      to: excerpt(after),
    });
  });

  plan.skipped = plan.changes.length === 0;
  return plan;
}

/*
 * Instructions run to thousands of characters and the interesting part is the
 * wordmark, so the report shows the neighbourhood rather than the whole field.
 * A full before/after belongs in the audit trail, not on somebody's terminal
 * mid-cutover.
 */
function excerpt(value, radius) {
  const width = typeof radius === 'number' ? radius : 24;
  const match = new RegExp(
    `.{0,${width}}(?:MLA\\s?GPT\\s+4(?:\\.1)?).{0,${width}}`,
    'i',
  ).exec(value);
  if (!match) {
    return value.length > width * 2 ? `${value.slice(0, width * 2)}…` : value;
  }
  const found = match[0];
  const prefix = value.startsWith(found) ? '' : '…';
  const suffix = value.endsWith(found) ? '' : '…';
  return `${prefix}${found}${suffix}`;
}

function summarize(plans) {
  const changed = plans.filter((plan) => !plan.skipped);
  return {
    agentsTotal: plans.length,
    agentsChanged: changed.length,
    agentsSkipped: plans.length - changed.length,
    fieldsChanged: changed.reduce((total, plan) => total + Object.keys(plan.set).length, 0),
  };
}

const api = {
  planAgentRename,
  renameString,
  hasOldBrand,
  summarize,
  excerpt,
  LIVE_FIELDS,
  REPLACEMENT,
};

/* mongosh has no module system; Node does. Support both without branching. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
}
if (typeof globalThis !== 'undefined') {
  globalThis.BrandRename = api;
}
