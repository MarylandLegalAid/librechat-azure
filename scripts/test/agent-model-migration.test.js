/*
 * Tests for the agent model migration logic.
 *
 *     node --test scripts/test/
 *
 * No database and no mocks — the logic under test is pure, which is why it was
 * separated from the runner in the first place. Everything here is a plain
 * object shaped like an agent document.
 *
 * The fixtures deliberately mirror the real production distribution (24 agents),
 * so the expected totals in these tests and the expected totals in the migration
 * plan are the same numbers. If a change makes the dry run report something
 * different, one of these tests should have failed first.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const {
  APPROVED_MODELS,
  planAgentChanges,
  summarize,
  parseModelMap,
  validateModelMap,
} = require('../lib/agent-model-migration.js');

const RAW_MAP = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'model-map.json'), 'utf8'),
);
const MAP = parseModelMap(RAW_MAP);

const OPTS = { map: MAP, approved: APPROVED_MODELS };

const agent = (overrides) =>
  Object.assign({ id: 'agent_x', name: 'Test Agent', provider: 'openAI', versions: [] }, overrides);

/* ------------------------------------------------------------------------- */
/* The committed mapping table                                               */
/* ------------------------------------------------------------------------- */

test('model-map.json parses and drops the documentation keys', () => {
  assert.ok(!Object.prototype.hasOwnProperty.call(MAP, '_comment'));

  // Derived from the file rather than hardcoded. The count is not the point —
  // dropping keys that start with an underscore, and keeping every real row, is.
  // A literal here fails every time a legitimate mapping is added, which trains
  // whoever is adding one to edit the number until the test goes green.
  const expected = Object.keys(RAW_MAP).filter((k) => !k.startsWith('_'));
  assert.deepStrictEqual(Object.keys(MAP).sort(), expected.sort());
  assert.ok(expected.length > 0, 'the mapping table must not be empty');
});

test('every mapping target is itself an approved model', () => {
  assert.deepStrictEqual(validateModelMap(MAP, APPROVED_MODELS), []);
});

test('validateModelMap rejects a target that is not approved', () => {
  const bad = { 'gpt-old': { model: 'gpt-also-retired', provider: 'openAI' } };
  const problems = validateModelMap(bad, APPROVED_MODELS);
  assert.strictEqual(problems.length, 1);
  assert.match(problems[0], /not in the approved list/);
});

test('validateModelMap rejects an approved model used as a migration source', () => {
  const bad = { 'claude-haiku-4-5': { model: 'gpt-5.6-luna', provider: 'openAI' } };
  const problems = validateModelMap(bad, APPROVED_MODELS);
  assert.strictEqual(problems.length, 1);
  assert.match(problems[0], /must not also be a migration source/);
});

test('parseModelMap rejects an entry missing its provider', () => {
  assert.throws(
    () => parseModelMap({ 'gpt-old': { model: 'gpt-5.6-luna' } }),
    /must have both a "model" and a "provider"/,
  );
});

/* ------------------------------------------------------------------------- */
/* The gate: only agents on a non-approved model are touched                 */
/* ------------------------------------------------------------------------- */

test('an agent already on an approved model is left completely alone', () => {
  const plan = planAgentChanges(
    agent({ model: 'claude-haiku-4-5', provider: 'anthropic' }),
    OPTS,
  );
  assert.strictEqual(plan.skipped, true);
  assert.deepStrictEqual(plan.changes, []);
  assert.deepStrictEqual(plan.set, {});
});

test('retiring gpt-5.4-nano turns its five agents into ordinary migration targets', () => {
  // Until 2026-07-30 this was the opposite test: nano was approved, so these
  // agents had to be LEFT on the built-in openAI endpoint. Retiring nano deleted
  // that endpoint, and the only thing that had to change to move them was the
  // approved list — no code, which is the point of keeping the gate data-driven.
  const plan = planAgentChanges(
    agent({ model: 'gpt-5.4-nano', provider: 'openAI', versions: [{ model: 'gpt-5.4-nano', provider: 'openAI' }] }),
    OPTS,
  );
  assert.strictEqual(plan.skipped, false);
  assert.strictEqual(plan.set.model, 'gpt-5.6-luna');
  assert.strictEqual(plan.set.provider, 'OpenAI GPT-5.6 Responses');
  // History moves too, or a revert puts the agent back on a retired model served
  // by an endpoint that no longer exists.
  assert.strictEqual(plan.set['versions.0.model'], 'gpt-5.6-luna');
  assert.strictEqual(plan.set['versions.0.provider'], 'OpenAI GPT-5.6 Responses');
  assert.deepStrictEqual(plan.warnings, []);
});

test('an approved-model agent still has its history repaired, top level untouched', () => {
  // "Referral Bot" on production: sitting on an approved model with 22 snapshots
  // on retired ones. Leaving those would fail §11.3's verification query, which
  // must come back empty for versions[].model too, and would leave a revert one
  // click away from a model that no longer exists.
  const plan = planAgentChanges(
    agent({
      model: 'claude-haiku-4-5',
      provider: 'anthropic',
      versions: [{ model: 'gpt-5.2', provider: 'openAI' }, { model: 'claude-haiku-4-5' }],
    }),
    OPTS,
  );

  assert.strictEqual(plan.skipped, false);
  assert.strictEqual(plan.historyOnly, true);

  // The agent's own model and provider are NOT touched — that is what keeps an
  // approved model on the endpoint that actually serves it.
  assert.ok(!('model' in plan.set), 'top-level model must not be rewritten');
  assert.ok(!('provider' in plan.set), 'top-level provider must not be rewritten');
  assert.ok(!plan.changes.some((c) => c.field === 'model' || c.field === 'provider'));

  // The stale snapshot is repaired, and the approved one is left alone.
  assert.strictEqual(plan.set['versions.0.model'], 'gpt-5.6-terra');
  assert.strictEqual(plan.set['versions.0.provider'], 'OpenAI GPT-5.6 Responses');
  assert.ok(!('versions.1.model' in plan.set), 'an approved snapshot is not rewritten');
});

test('an approved-model agent with clean history is skipped entirely', () => {
  const plan = planAgentChanges(
    agent({
      model: 'claude-haiku-4-5',
      provider: 'anthropic',
      versions: [{ model: 'claude-haiku-4-5', provider: 'anthropic' }],
    }),
    OPTS,
  );
  assert.strictEqual(plan.skipped, true);
  assert.strictEqual(plan.historyOnly, false);
  assert.deepStrictEqual(plan.set, {});
});

/* ------------------------------------------------------------------------- */
/* Rewriting model and provider together                                     */
/* ------------------------------------------------------------------------- */

test('a GPT-5.6 target rewrites both model and provider', () => {
  const plan = planAgentChanges(agent({ model: 'gpt-5.2', provider: 'openAI' }), OPTS);

  assert.strictEqual(plan.skipped, false);
  assert.strictEqual(plan.set.model, 'gpt-5.6-terra');
  assert.strictEqual(plan.set.provider, 'OpenAI GPT-5.6 Responses');
});

test('the provider string matches the custom endpoint name byte for byte', () => {
  // A mismatch here fails at request time, not at startup, so no test that only
  // checks "a provider was set" would catch it.
  const plan = planAgentChanges(agent({ model: 'gpt-4.1', provider: 'openAI' }), OPTS);
  assert.strictEqual(plan.set.provider, 'OpenAI GPT-5.6 Responses');
});

test('an Opus 5 agent changes model but keeps its Anthropic provider', () => {
  const plan = planAgentChanges(
    agent({ model: 'claude-opus-5', provider: 'anthropic' }),
    OPTS,
  );
  assert.strictEqual(plan.set.model, 'claude-opus-4-8');
  assert.ok(!Object.prototype.hasOwnProperty.call(plan.set, 'provider'));
  assert.strictEqual(plan.changes.length, 1);
});

/* ------------------------------------------------------------------------- */
/* Version history                                                           */
/* ------------------------------------------------------------------------- */

test('every version entry is rewritten, not just the current model', () => {
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.2',
      provider: 'openAI',
      versions: [
        { model: 'gpt-4.1', provider: 'openAI' },
        { model: 'gpt-5.2', provider: 'openAI' },
      ],
    }),
    OPTS,
  );

  assert.strictEqual(plan.set['versions.0.model'], 'gpt-5.6-luna');
  assert.strictEqual(plan.set['versions.0.provider'], 'OpenAI GPT-5.6 Responses');
  assert.strictEqual(plan.set['versions.1.model'], 'gpt-5.6-terra');
  assert.strictEqual(plan.set['versions.1.provider'], 'OpenAI GPT-5.6 Responses');
});

test('each version is mapped by its own model, not the agent current one', () => {
  // Reverting to an old version must give you that version's successor, not the
  // successor of whatever the agent happens to point at today.
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.2', // -> terra
      provider: 'openAI',
      versions: [{ model: 'gpt-5.4-mini', provider: 'openAI' }], // -> luna, not terra
    }),
    OPTS,
  );
  assert.strictEqual(plan.set.model, 'gpt-5.6-terra');
  assert.strictEqual(plan.set['versions.0.model'], 'gpt-5.6-luna');
});

test('version entries already on an approved model are not rewritten', () => {
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.2',
      provider: 'openAI',
      versions: [{ model: 'gpt-5.6-luna', provider: 'OpenAI GPT-5.6 Responses' }],
    }),
    OPTS,
  );
  assert.ok(!Object.prototype.hasOwnProperty.call(plan.set, 'versions.0.model'));
});

test('a version entry with no model at all is skipped without error', () => {
  const plan = planAgentChanges(
    agent({ model: 'gpt-5.2', provider: 'openAI', versions: [{ instructions: 'hello' }, null] }),
    OPTS,
  );
  assert.strictEqual(plan.set.model, 'gpt-5.6-terra');
});

test('a 46-version agent produces writes for every version', () => {
  // The real sample agent on production carried 46 versions. This is the bulk
  // of the write volume, not an edge case.
  const versions = [];
  for (let i = 0; i < 46; i += 1) {
    versions.push({ model: 'gpt-4.1', provider: 'openAI' });
  }
  const plan = planAgentChanges(agent({ model: 'gpt-4.1', provider: 'openAI', versions }), OPTS);

  // 2 top-level fields + 46 versions x 2 fields
  assert.strictEqual(plan.changes.length, 2 + 46 * 2);
  assert.strictEqual(plan.set['versions.45.model'], 'gpt-5.6-luna');
});

/* ------------------------------------------------------------------------- */
/* Idempotency                                                               */
/* ------------------------------------------------------------------------- */

test('running against already-migrated data produces no changes', () => {
  const before = agent({
    model: 'gpt-5.2',
    provider: 'openAI',
    versions: [{ model: 'gpt-4.1', provider: 'openAI' }],
  });

  const first = planAgentChanges(before, OPTS);

  // Apply the plan the way the runner's $set would.
  const after = JSON.parse(JSON.stringify(before));
  after.model = first.set.model;
  after.provider = first.set.provider;
  after.versions[0].model = first.set['versions.0.model'];
  after.versions[0].provider = first.set['versions.0.provider'];

  const second = planAgentChanges(after, OPTS);
  assert.strictEqual(second.skipped, true);
  assert.deepStrictEqual(second.changes, []);
  assert.deepStrictEqual(second.warnings, []);
});

/* ------------------------------------------------------------------------- */
/* Unmapped models stop everything                                           */
/* ------------------------------------------------------------------------- */

test('an unmapped top-level model throws rather than being skipped', () => {
  assert.throws(
    () => planAgentChanges(agent({ model: 'gpt-3.5-turbo', provider: 'openAI' }), OPTS),
    /neither approved nor present in model-map\.json/,
  );
});

test('an unmapped model inside version history also throws', () => {
  assert.throws(
    () =>
      planAgentChanges(
        agent({
          model: 'gpt-5.2',
          provider: 'openAI',
          versions: [{ model: 'text-davinci-003', provider: 'openAI' }],
        }),
        OPTS,
      ),
    /versions\[0\]\.model/,
  );
});

test('the error names the agent so it can be found', () => {
  assert.throws(
    () =>
      planAgentChanges(
        agent({ id: 'agent_abc123', name: 'Intake Helper', model: 'llama-2' }),
        OPTS,
      ),
    /agent_abc123 \(Intake Helper\)/,
  );
});

/* ------------------------------------------------------------------------- */
/* The whole production fleet                                                */
/* ------------------------------------------------------------------------- */

test('the production distribution produces exactly the expected plan', () => {
  // 24 agents, matching the counts recorded during recon on 2026-07-29.
  const fleet = [];
  const push = (n, model, provider) => {
    for (let i = 0; i < n; i += 1) {
      fleet.push(agent({ id: `${model}-${i}`, model, provider }));
    }
  };

  push(5, 'gpt-5.4-nano', 'openAI');
  push(5, 'gpt-5.4-mini', 'openAI');
  push(4, 'gpt-5.2', 'openAI');
  push(3, 'gpt-4.1', 'openAI');
  push(2, 'claude-opus-4-7', 'anthropic');
  push(1, 'gpt-5.5', 'openAI');
  push(1, 'gpt-5.4', 'openAI');
  push(1, 'gpt-5-mini', 'openAI');
  push(1, 'claude-opus-4-5', 'anthropic');
  push(1, 'claude-haiku-4-5', 'anthropic');

  assert.strictEqual(fleet.length, 24);

  // "Referral Bot": 22 snapshots on retired models. Until nano was retired it was
  // the fleet's only history-only case — on an approved model with a broken past.
  // Retiring nano moved its top-level model too, so it is now an ordinary change
  // and the fleet has no history-only agents left. Kept in the fixture because it
  // is the agent with the most version history in production, and because that
  // history is where the volume of writes actually comes from.
  fleet[0].name = 'Referral Bot';
  fleet[0].versions = [
    ...Array.from({ length: 17 }, () => ({ model: 'gpt-5-mini', provider: 'openAI' })),
    ...Array.from({ length: 4 }, () => ({ model: 'gpt-5.4', provider: 'openAI' })),
    { model: 'gpt-5.4-mini', provider: 'openAI' },
  ];

  const plans = fleet.map((a) => planAgentChanges(a, OPTS));
  const summary = summarize(plans);

  assert.strictEqual(summary.agentsTotal, 24);
  // Every agent moves its current model except the single claude-haiku-4-5 one.
  // Retiring gpt-5.4-nano took this from 19/5/1 to 23/1/0: the five nano agents
  // became ordinary targets, and Referral Bot — previously the lone history-only
  // case — now moves its top-level model like everything else.
  assert.strictEqual(summary.agentsChanged, 23);
  assert.strictEqual(summary.agentsSkipped, 1);
  assert.strictEqual(summary.agentsHistoryOnly, 0);

  // 14 = 5 nano + 5 gpt-5.4-mini + 3 gpt-4.1 + 1 gpt-5-mini
  assert.strictEqual(summary.byTarget['gpt-5.6-luna'].count, 14);
  assert.strictEqual(summary.byTarget['gpt-5.6-terra'].count, 6);
  assert.strictEqual(summary.byTarget['claude-opus-4-8'].count, 3);
  assert.ok(!summary.byTarget['gpt-5.6-sol'], 'gpt-5.6-sol is approved but is not a target');

  // 20 agents move onto the custom endpoint (14 luna + 6 terra); the 3 Anthropic
  // agents change model only; 1 is untouched.
  const providerChanges = plans.filter((plan) =>
    plan.changes.some((c) => c.field === 'provider'),
  );
  assert.strictEqual(providerChanges.length, 20);
});
