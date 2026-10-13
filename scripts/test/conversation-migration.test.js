/*
 * Tests for the conversation migration logic.
 *
 *     node --test scripts/test/
 *
 * No database and no mocks: the logic under test is pure. Fixtures are plain
 * objects shaped like the conversation documents found in production on
 * 2026-10-13.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const {
  ABSENT,
  parseConversationMap,
  validateConversationMap,
  planConversation,
  updateFor,
  revertFor,
  summarize,
} = require('../lib/conversation-migration.js');

const RAW_MAP = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'conversation-map.json'), 'utf8'),
);
const MAP = parseConversationMap(RAW_MAP);

const CUSTOM = 'OpenAI GPT-5.6 Responses';

/* What an old built-in openAI conversation looks like in production. */
const oldOpenAI = (overrides) =>
  Object.assign(
    {
      conversationId: 'c-1',
      user: 'u-1',
      endpoint: 'openAI',
      model: 'gpt-5.4',
      maxContextTokens: 360000,
      title: 'Smith eviction — client intake',
    },
    overrides,
  );

/* ------------------------------------------------------------------------- */
/* The committed map                                                         */
/* ------------------------------------------------------------------------- */

test('conversation-map.json parses and is internally consistent', () => {
  assert.deepStrictEqual(validateConversationMap(MAP), []);
  assert.ok(Object.keys(MAP.sources).length > 0);
  assert.ok(!Object.prototype.hasOwnProperty.call(MAP, '_comment'));
});

test('every OpenAI model found on the old endpoint in production has a destination', () => {
  // The distribution observed on 2026-10-13. A model missing here would stop the
  // production run, which is the right outcome, but it is cheaper to find out now.
  ['gpt-5.2', 'gpt-5.4', 'gpt-5.5', 'gpt-4.1', 'gpt-5-mini', 'gpt-5.1', 'gpt-5.4-mini', 'gpt-5-nano']
    .forEach((model) => {
      assert.ok(MAP.sources.openAI.map[model], `no destination for ${model}`);
    });
});

test('cheaper old OpenAI models go to Luna, the larger ones to Sol (M15)', () => {
  assert.strictEqual(MAP.sources.openAI.map['gpt-5.5'], 'gpt-5.6-sol');
  assert.strictEqual(MAP.sources.openAI.map['gpt-5.4'], 'gpt-5.6-sol');
  assert.strictEqual(MAP.sources.openAI.map['gpt-5.2'], 'gpt-5.6-luna');
  assert.strictEqual(MAP.sources.openAI.map['gpt-4.1'], 'gpt-5.6-luna');
});

test('custom-endpoint targets look like conversations the UI creates there', () => {
  ['gpt-5.6-sol', 'gpt-5.6-luna'].forEach((name) => {
    const target = MAP.targets[name];
    assert.strictEqual(target.endpoint, CUSTOM);
    assert.strictEqual(target.endpointType, 'custom');
    assert.strictEqual(target.spec, target.model, 'spec must match the modelSpecs entry');
    assert.strictEqual(target.useResponsesApi, true);
    assert.strictEqual(target.maxContextTokens, 380000);
  });
});

/* ------------------------------------------------------------------------- */
/* Map validation                                                            */
/* ------------------------------------------------------------------------- */

test('a map pointing at an undefined target is rejected', () => {
  const map = parseConversationMap({
    targets: {},
    sources: { openAI: { keep: [], map: { 'gpt-5.4': 'nowhere' } } },
  });
  assert.match(validateConversationMap(map)[0], /not a defined target/);
});

test('a model both kept and mapped is rejected', () => {
  const map = parseConversationMap({
    targets: { t: { endpoint: 'anthropic', model: 'claude-opus-4-8' } },
    sources: { anthropic: { keep: ['claude-opus-4-8', 'x'], map: { x: 't' } } },
  });
  assert.ok(validateConversationMap(map).some((p) => /both kept and mapped/.test(p)));
});

test('a target that its own endpoint would move again is rejected as a loop', () => {
  const map = parseConversationMap({
    targets: { t: { endpoint: 'anthropic', model: 'claude-opus-5' } },
    sources: { anthropic: { keep: [], map: { 'claude-opus-4-5': 't' } } },
  });
  assert.ok(validateConversationMap(map).some((p) => /moved again/.test(p)));
});

test('a target without endpoint or model does not parse', () => {
  assert.throws(
    () => parseConversationMap({ targets: { t: { model: 'x' } }, sources: {} }),
    /needs an "endpoint" and a "model"/,
  );
});

/* ------------------------------------------------------------------------- */
/* Planning                                                                  */
/* ------------------------------------------------------------------------- */

test('an old openAI conversation moves to the custom endpoint with the full field set', () => {
  const plan = planConversation(oldOpenAI(), MAP);
  assert.strictEqual(plan.action, 'move');
  assert.strictEqual(plan.target, 'gpt-5.6-sol');
  assert.deepStrictEqual(plan.set, {
    endpoint: CUSTOM,
    endpointType: 'custom',
    model: 'gpt-5.6-sol',
    spec: 'gpt-5.6-sol',
    useResponsesApi: true,
    maxContextTokens: 380000,
  });
  assert.deepStrictEqual(plan.unset, []);
});

test('the oversized gpt-4.1 context limit is brought down to the target model', () => {
  // 166 production conversations carry 942,818 — beyond what Luna accepts.
  const plan = planConversation(oldOpenAI({ model: 'gpt-4.1', maxContextTokens: 942818 }), MAP);
  assert.strictEqual(plan.set.maxContextTokens, 380000);
  assert.strictEqual(plan.before.maxContextTokens, 942818);
});

test('before-values record absent fields distinctly, so a revert removes them', () => {
  // 802 production gpt-5.2 conversations have no maxContextTokens at all.
  const convo = oldOpenAI();
  delete convo.maxContextTokens;
  const plan = planConversation(convo, MAP);
  assert.deepStrictEqual(plan.before.spec, ABSENT);
  assert.deepStrictEqual(plan.before.maxContextTokens, ABSENT);
  assert.strictEqual(plan.before.model, 'gpt-5.4');
});

test('the plan never carries the title', () => {
  const plan = planConversation(oldOpenAI(), MAP);
  assert.ok(!JSON.stringify(plan).includes('Smith'));
});

test('a conversation on a kept model is left alone', () => {
  const plan = planConversation({ conversationId: 'c', endpoint: 'anthropic', model: 'claude-opus-4-8' }, MAP);
  assert.strictEqual(plan.action, 'keep');
});

test('a retired Claude model moves to its successor and only model changes', () => {
  const plan = planConversation({ conversationId: 'c', endpoint: 'anthropic', model: 'claude-opus-5' }, MAP);
  assert.strictEqual(plan.action, 'move');
  assert.deepStrictEqual(plan.set, { model: 'claude-opus-4-8' });
});

test('agents conversations and unknown endpoints are ignored', () => {
  assert.strictEqual(planConversation({ endpoint: 'agents', model: 'gpt-5.4' }, MAP).action, 'ignore');
  assert.strictEqual(planConversation({ endpoint: CUSTOM, model: 'gpt-5.6-luna' }, MAP).action, 'ignore');
  assert.strictEqual(planConversation({ endpoint: null, model: null }, MAP).action, 'ignore');
});

test('an unmapped model on a migrated endpoint stops the run', () => {
  assert.throws(
    () => planConversation({ conversationId: 'c', endpoint: 'openAI', model: 'o1-pro' }, MAP),
    /Refusing to guess/,
  );
});

test('a second run after an apply finds nothing to move', () => {
  const plan = planConversation(oldOpenAI(), MAP);
  const moved = Object.assign(oldOpenAI(), plan.set);
  plan.unset.forEach((field) => delete moved[field]);
  // A moved conversation is on the custom endpoint, which the map does not migrate.
  assert.strictEqual(planConversation(moved, MAP).action, 'ignore');
  const claude = { conversationId: 'c', endpoint: 'anthropic', model: 'claude-opus-5' };
  const movedClaude = Object.assign(claude, planConversation(claude, MAP).set);
  assert.strictEqual(planConversation(movedClaude, MAP).action, 'keep');
});

test('null in a target removes the field, and only if present', () => {
  const map = parseConversationMap({
    targets: { t: { endpoint: 'openAI', model: 'gpt-6-luna', endpointType: null, spec: null } },
    sources: { [CUSTOM]: { keep: [], map: { 'gpt-5.6-luna': 't' } }, openAI: { keep: ['gpt-6-luna'], map: {} } },
  });
  const plan = planConversation(
    { conversationId: 'c', endpoint: CUSTOM, endpointType: 'custom', model: 'gpt-5.6-luna' },
    map,
  );
  assert.deepStrictEqual(plan.unset, ['endpointType']);
  assert.deepStrictEqual(plan.before.endpointType, 'custom');
});

/* ------------------------------------------------------------------------- */
/* Writes and reverts                                                        */
/* ------------------------------------------------------------------------- */

test('an update applies only while the conversation is where the plan found it', () => {
  const { filter, update } = updateFor(planConversation(oldOpenAI(), MAP));
  assert.deepStrictEqual(filter, { conversationId: 'c-1', endpoint: 'openAI', model: 'gpt-5.4' });
  assert.ok(update.$set);
  assert.ok(!update.$unset);
});

test('a revert restores old values, removes added fields, and is guarded by the new location', () => {
  const convo = oldOpenAI();
  delete convo.maxContextTokens;
  const plan = planConversation(convo, MAP);
  const entry = JSON.parse(JSON.stringify(plan)); // as read back from the audit file
  const { filter, update } = revertFor(entry);
  assert.deepStrictEqual(filter, { conversationId: 'c-1', endpoint: CUSTOM, model: 'gpt-5.6-sol' });
  assert.strictEqual(update.$set.endpoint, 'openAI');
  assert.strictEqual(update.$set.model, 'gpt-5.4');
  assert.deepStrictEqual(Object.keys(update.$unset).sort(), [
    'endpointType',
    'maxContextTokens',
    'spec',
    'useResponsesApi',
  ]);
});

test('summarize counts moves per route and recent use', () => {
  const now = new Date('2026-10-13T00:00:00Z');
  const convos = [
    oldOpenAI({ conversationId: 'a', updatedAt: new Date('2026-10-10T00:00:00Z') }),
    oldOpenAI({ conversationId: 'b', updatedAt: new Date('2026-01-01T00:00:00Z') }),
    { conversationId: 'c', endpoint: 'anthropic', model: 'claude-opus-4-8' },
  ];
  const byId = {};
  convos.forEach((c) => (byId[c.conversationId] = c));
  const s = summarize(convos.map((c) => planConversation(c, MAP)), byId, new Date(now - 30 * 86400000));
  assert.deepStrictEqual(s.counts, { ignore: 0, keep: 1, move: 2 });
  assert.deepStrictEqual(s.routes['openAI / gpt-5.4 -> gpt-5.6-sol'], { count: 2, recent: 1 });
});
