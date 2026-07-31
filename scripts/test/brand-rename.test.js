const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  planAgentRename,
  renameString,
  hasOldBrand,
  summarize,
} = require('../lib/brand-rename.js');

function agent(overrides) {
  return Object.assign({ id: 'agent_x', name: 'Test Agent' }, overrides);
}

/* ------------------------------------------------------------------------- */
/* The rename itself                                                          */
/* ------------------------------------------------------------------------- */

test('the uppercase wordmark is renamed', () => {
  assert.equal(renameString('MLAGPT 4 User Agreement'), 'MLAGPT 4.1 User Agreement');
});

test('the lowercase wordmark is renamed AND normalized', () => {
  assert.equal(renameString('mlaGPT 4'), 'MLAGPT 4.1');
});

test('a spaced spelling is renamed and closed up', () => {
  assert.equal(renameString('MLA GPT 4'), 'MLAGPT 4.1');
});

test('every occurrence in one string is renamed, not just the first', () => {
  assert.equal(
    renameString('MLAGPT 4 is MLAGPT 4, after all'),
    'MLAGPT 4.1 is MLAGPT 4.1, after all',
  );
});

/* ------------------------------------------------------------------------- */
/* Idempotence — this runs post-restore, possibly twice                       */
/* ------------------------------------------------------------------------- */

test('an already-renamed string is left completely alone', () => {
  assert.equal(renameString('MLAGPT 4.1 User Agreement'), 'MLAGPT 4.1 User Agreement');
});

test('running the rename twice equals running it once', () => {
  const once = renameString('Welcome to mlaGPT 4 - how can I help?');
  assert.equal(renameString(once), once);
  assert.equal(once, 'Welcome to MLAGPT 4.1 - how can I help?');
});

test('a future minor version is not touched either', () => {
  assert.equal(renameString('MLAGPT 4.2'), 'MLAGPT 4.2');
});

/* ------------------------------------------------------------------------- */
/* What must NOT be renamed                                                   */
/* ------------------------------------------------------------------------- */

test('the unversioned wordmark is left alone — the user agreement is full of it', () => {
  const tos = 'By accessing or using MLAGPT, you acknowledge that you have read';
  assert.equal(renameString(tos), tos);
  assert.equal(hasOldBrand(tos), false);
});

test('a different major version is not swept up', () => {
  assert.equal(renameString('MLAGPT 40'), 'MLAGPT 40');
  assert.equal(renameString('MLAGPT 5'), 'MLAGPT 5');
});

test('an unrelated product that merely ends in GPT is untouched', () => {
  assert.equal(renameString('ChatGPT 4'), 'ChatGPT 4');
});

/* ------------------------------------------------------------------------- */
/* Agent planning                                                             */
/* ------------------------------------------------------------------------- */

test('an agent with the old name is planned across all three live fields', () => {
  const plan = planAgentRename(
    agent({
      name: 'MLAGPT 4 Help',
      description: 'teaches you how to use MLAGPT 4',
      instructions: 'You are the MLAGPT 4 Coach.',
    }),
  );
  assert.equal(plan.skipped, false);
  assert.deepEqual(Object.keys(plan.set).sort(), ['description', 'instructions', 'name']);
  assert.equal(plan.set.name, 'MLAGPT 4.1 Help');
  assert.equal(plan.set.instructions, 'You are the MLAGPT 4.1 Coach.');
});

test('only the fields that actually contain the wordmark are written', () => {
  const plan = planAgentRename(
    agent({ name: 'MLAGPT 4 Prompt Coach', description: 'A prompting helper.' }),
  );
  assert.deepEqual(Object.keys(plan.set), ['name']);
  assert.equal(plan.changes.length, 1);
});

test('version snapshots are never included — John’s call, they are a record', () => {
  const plan = planAgentRename(
    agent({
      name: 'MLAGPT 4 Help',
      versions: [{ name: 'MLAGPT 4 Help', instructions: 'You are the MLAGPT 4 Coach.' }],
    }),
  );
  assert.deepEqual(Object.keys(plan.set), ['name']);
  assert.ok(!('versions' in plan.set));
});

test('an agent with no branding at all is skipped', () => {
  const plan = planAgentRename(agent({ name: 'LegalServer Case Summary' }));
  assert.equal(plan.skipped, true);
  assert.deepEqual(plan.set, {});
});

test('an already-renamed agent is skipped, so a second apply writes nothing', () => {
  const plan = planAgentRename(agent({ name: 'MLAGPT 4.1 Help' }));
  assert.equal(plan.skipped, true);
});

test('a missing or non-string field does not throw', () => {
  const plan = planAgentRename({ id: 'a', name: 'MLAGPT 4 Help', description: null });
  assert.equal(plan.skipped, false);
  assert.deepEqual(Object.keys(plan.set), ['name']);
});

test('an agent identified only by _id still gets an id in the plan', () => {
  const plan = planAgentRename({ _id: 'abc123', name: 'MLAGPT 4 Help' });
  assert.equal(plan.agentId, 'abc123');
});

/* ------------------------------------------------------------------------- */
/* Summary                                                                    */
/* ------------------------------------------------------------------------- */

test('the summary counts agents and field writes separately', () => {
  const plans = [
    planAgentRename(agent({ id: 'a', name: 'MLAGPT 4 Help', description: 'about MLAGPT 4' })),
    planAgentRename(agent({ id: 'b', name: 'MLAGPT 4 Prompt Coach' })),
    planAgentRename(agent({ id: 'c', name: 'Something Else' })),
  ];
  const summary = summarize(plans);
  assert.equal(summary.agentsTotal, 3);
  assert.equal(summary.agentsChanged, 2);
  assert.equal(summary.agentsSkipped, 1);
  assert.equal(summary.fieldsChanged, 3);
});

test('the production shape — 2 agents, 4 field writes', () => {
  const plans = [
    planAgentRename(
      agent({
        id: 'help',
        name: 'MLAGPT 4 Help',
        description: 'a guide that teaches you how to use MLAGPT 4, write effective prompts',
        instructions: 'You are the MLAGPT 4 Coach — a friendly, knowledgeable guide.',
      }),
    ),
    planAgentRename(agent({ id: 'coach', name: 'MLAGPT 4 Prompt Coach' })),
  ];
  const summary = summarize(plans);
  assert.equal(summary.agentsChanged, 2);
  assert.equal(summary.fieldsChanged, 4);
});
