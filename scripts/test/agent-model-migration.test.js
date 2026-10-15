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

// The retired custom endpoint. Phase 3 moves every agent on it to the built-in
// openAI provider (UPGRADE_PLAN M13).
const CUSTOM = 'OpenAI GPT-5.6 Responses';

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
  const bad = { 'claude-haiku-4-5': { model: 'gpt-6-luna', provider: 'openAI' } };
  const problems = validateModelMap(bad, APPROVED_MODELS);
  assert.strictEqual(problems.length, 1);
  assert.match(problems[0], /must not also be a migration source/);
});

test('parseModelMap rejects an entry missing its provider', () => {
  assert.throws(
    () => parseModelMap({ 'gpt-old': { model: 'gpt-6-luna' } }),
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
  assert.strictEqual(plan.set.model, 'gpt-6-luna');
  // Since Phase 3 its successor is on the built-in openAI endpoint again, so
  // the provider stays as it was and is not written.
  assert.ok(!('provider' in plan.set));
  // History moves too, or a revert puts the agent back on a retired model.
  assert.strictEqual(plan.set['versions.0.model'], 'gpt-6-luna');
  assert.ok(!('versions.0.provider' in plan.set));
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
      versions: [{ model: 'gpt-5.6-terra', provider: CUSTOM }, { model: 'claude-haiku-4-5' }],
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
  assert.strictEqual(plan.set['versions.0.model'], 'gpt-6.1-sol');
  assert.strictEqual(plan.set['versions.0.provider'], 'openAI');
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

test('a GPT-5.6 agent on the retired endpoint moves model and provider', () => {
  const plan = planAgentChanges(agent({ model: 'gpt-5.6-terra', provider: CUSTOM }), OPTS);

  assert.strictEqual(plan.skipped, false);
  assert.strictEqual(plan.set.model, 'gpt-6.1-sol');
  assert.strictEqual(plan.set.provider, 'openAI');
});

test('the target provider is the built-in endpoint name, byte for byte', () => {
  // A mismatch here fails at request time, not at startup, so no test that only
  // checks "a provider was set" would catch it.
  const plan = planAgentChanges(agent({ model: 'gpt-5.6-sol', provider: CUSTOM }), OPTS);
  assert.strictEqual(plan.set.provider, 'openAI');
});

test('an old OpenAI model already on the built-in provider changes model only', () => {
  const plan = planAgentChanges(agent({ model: 'gpt-5.2', provider: 'openAI' }), OPTS);
  assert.strictEqual(plan.set.model, 'gpt-6.1-sol');
  assert.ok(!('provider' in plan.set));
});

test('an Opus 5 agent changes model but keeps its Anthropic provider', () => {
  const plan = planAgentChanges(
    agent({ model: 'claude-opus-5', provider: 'anthropic' }),
    OPTS,
  );
  assert.strictEqual(plan.set.model, 'claude-opus-5-5');
  assert.ok(!Object.prototype.hasOwnProperty.call(plan.set, 'provider'));
  assert.strictEqual(plan.changes.length, 1);
});

test('a stored useResponsesApi: false is removed, everywhere (M14)', () => {
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.6-luna',
      provider: CUSTOM,
      model_parameters: { useResponsesApi: false, temperature: 1 },
      versions: [
        { model: 'gpt-5.6-luna', provider: CUSTOM, model_parameters: { useResponsesApi: false } },
        { model: 'gpt-6-luna', provider: 'openAI', model_parameters: { useResponsesApi: true } },
      ],
    }),
    OPTS,
  );
  assert.deepStrictEqual(plan.unset, [
    'model_parameters.useResponsesApi',
    'versions.0.model_parameters.useResponsesApi',
  ]);
  assert.ok(!('model_parameters.temperature' in plan.set), 'other parameters are untouched');
});

test('an agent already on an approved model still loses useResponsesApi: false', () => {
  const plan = planAgentChanges(
    agent({ model: 'gpt-6-luna', provider: 'openAI', model_parameters: { useResponsesApi: false } }),
    OPTS,
  );
  assert.strictEqual(plan.skipped, false);
  assert.deepStrictEqual(plan.set, {});
  assert.deepStrictEqual(plan.unset, ['model_parameters.useResponsesApi']);
});

/* ------------------------------------------------------------------------- */
/* Version history                                                           */
/* ------------------------------------------------------------------------- */

test('every version entry is rewritten, not just the current model', () => {
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.6-luna',
      provider: CUSTOM,
      versions: [
        { model: 'gpt-5.6-luna', provider: CUSTOM },
        { model: 'gpt-5.6-terra', provider: CUSTOM },
      ],
    }),
    OPTS,
  );

  assert.strictEqual(plan.set['versions.0.model'], 'gpt-6-luna');
  assert.strictEqual(plan.set['versions.0.provider'], 'openAI');
  assert.strictEqual(plan.set['versions.1.model'], 'gpt-6.1-sol');
  assert.strictEqual(plan.set['versions.1.provider'], 'openAI');
});

test('each version is mapped by its own model, not the agent current one', () => {
  // Reverting to an old version must give you that version's successor, not the
  // successor of whatever the agent happens to point at today.
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.2', // -> gpt-6.1-sol
      provider: 'openAI',
      versions: [{ model: 'gpt-5.4-mini', provider: 'openAI' }], // -> gpt-6-luna, not sol
    }),
    OPTS,
  );
  assert.strictEqual(plan.set.model, 'gpt-6.1-sol');
  assert.strictEqual(plan.set['versions.0.model'], 'gpt-6-luna');
});

test('version entries already on an approved model are not rewritten', () => {
  const plan = planAgentChanges(
    agent({
      model: 'gpt-5.2',
      provider: 'openAI',
      versions: [{ model: 'gpt-6-luna', provider: 'openAI' }],
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
  assert.strictEqual(plan.set.model, 'gpt-6.1-sol');
});

test('a 46-version agent produces writes for every version', () => {
  // The real sample agent on production carried 46 versions (51 by 2026-10).
  // This is the bulk of the write volume, not an edge case.
  const versions = [];
  for (let i = 0; i < 46; i += 1) {
    versions.push({ model: 'gpt-5.6-luna', provider: CUSTOM });
  }
  const plan = planAgentChanges(agent({ model: 'gpt-5.6-luna', provider: CUSTOM, versions }), OPTS);

  // 2 top-level fields + 46 versions x 2 fields
  assert.strictEqual(plan.changes.length, 2 + 46 * 2);
  assert.strictEqual(plan.set['versions.45.model'], 'gpt-6-luna');
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
  // 35 agents, matching production on 2026-10-15 (counted on the staging copy
  // restored that morning). The 2026-07-29 fleet this test used to hold was
  // migrated onto GPT-5.6 and Opus 4.8 that summer, so the Phase 3 dry run starts
  // from here.
  const fleet = [];
  const push = (n, model, provider) => {
    for (let i = 0; i < n; i += 1) {
      fleet.push(agent({ id: `${model}-${i}`, model, provider }));
    }
  };

  push(23, 'gpt-5.6-luna', CUSTOM);
  push(5, 'gpt-5.6-terra', CUSTOM);
  push(4, 'gpt-5.6-sol', CUSTOM);
  push(3, 'claude-opus-4-8', 'anthropic');

  assert.strictEqual(fleet.length, 35);

  // History mixes providers in production: GPT-5.6 snapshots on the custom
  // endpoint, a few on the built-in one, and Claude snapshots. Each maps by its
  // own model, and only the custom-endpoint ones change provider.
  fleet[0].name = 'Mixed history';
  fleet[0].versions = [
    { model: 'gpt-5.6-luna', provider: CUSTOM },
    { model: 'gpt-5.6-luna', provider: 'openAI' },
    { model: 'claude-haiku-4-5', provider: 'anthropic' },
  ];

  const plans = fleet.map((a) => planAgentChanges(a, OPTS));
  const summary = summarize(plans);

  // Nothing in the fleet is on an approved model yet, so every agent moves.
  assert.strictEqual(summary.agentsTotal, 35);
  assert.strictEqual(summary.agentsChanged, 35);
  assert.strictEqual(summary.agentsSkipped, 0);
  assert.strictEqual(summary.agentsHistoryOnly, 0);

  assert.strictEqual(summary.byTarget['gpt-6-luna'].count, 23);
  // There is no GPT-6 terra: terra and sol both go to gpt-6.1-sol.
  assert.strictEqual(summary.byTarget['gpt-6.1-sol'].count, 9);
  assert.strictEqual(summary.byTarget['claude-opus-5-5'].count, 3);

  // The 32 GPT-5.6 agents leave the retired endpoint; the 3 Claude agents
  // change model only.
  const providerChanges = plans.filter((plan) =>
    plan.changes.some((c) => c.field === 'provider'),
  );
  assert.strictEqual(providerChanges.length, 32);

  const mixed = plans[0].set;
  assert.strictEqual(mixed['versions.0.provider'], 'openAI');
  assert.ok(!('versions.1.provider' in mixed), 'already on openAI');
  // Haiku stays on 4.5 for now (env.defaults says why), so it is approved.
  assert.ok(!('versions.2.model' in mixed), 'Haiku 4.5 is approved and stays');
});
