const assert = require('node:assert/strict');
const { test } = require('node:test');

const { planGroup, describe, summarize } = require('../lib/duplicate-message-cleanup.js');

const KEY = { messageId: 'm1', user: 'u1', tenantId: undefined };

function msg(overrides) {
  return Object.assign(
    {
      _id: 'id-' + Math.random().toString(36).slice(2),
      messageId: 'm1',
      conversationId: 'c1',
      user: 'u1',
      isCreatedByUser: false,
      createdAt: new Date('2026-09-21T14:45:31.405Z'),
      text: '',
      content: [{ type: 'text', text: 'hello' }],
    },
    overrides,
  );
}

/* ------------------------------------------------------------------------- */
/* planGroup                                                                  */
/* ------------------------------------------------------------------------- */

test('the observed pair: keep the finished copy, delete the placeholder', () => {
  const finished = msg({ _id: 'fin', unfinished: false, tokenCount: 14, model: 'claude-sonnet-5' });
  const placeholder = msg({ _id: 'unf', unfinished: true, text: 'half a reply' });
  const plan = planGroup(KEY, [placeholder, finished]);
  assert.equal(plan.unresolved, null);
  assert.equal(plan.keep._id, 'fin');
  assert.deepEqual(plan.remove.map((d) => d._id), ['unf']);
});

test('a finished copy with no unfinished field at all counts as finished', () => {
  const plan = planGroup(KEY, [msg({ _id: 'a' }), msg({ _id: 'b', unfinished: true })]);
  assert.equal(plan.keep._id, 'a');
  assert.deepEqual(plan.remove.map((d) => d._id), ['b']);
});

test('several placeholders beside one finished copy are all removed', () => {
  const plan = planGroup(KEY, [
    msg({ _id: 'u1', unfinished: true }),
    msg({ _id: 'f', unfinished: false }),
    msg({ _id: 'u2', unfinished: true }),
  ]);
  assert.equal(plan.keep._id, 'f');
  assert.deepEqual(plan.remove.map((d) => d._id).sort(), ['u1', 'u2']);
});

test('two finished copies are unresolved and nothing is removed', () => {
  const plan = planGroup(KEY, [msg({ _id: 'a', unfinished: false }), msg({ _id: 'b' })]);
  assert.match(plan.unresolved, /2 finished copies/);
  assert.equal(plan.keep, null);
  assert.deepEqual(plan.remove, []);
});

test('only placeholders is unresolved: never delete the last copy of a reply', () => {
  const plan = planGroup(KEY, [msg({ unfinished: true }), msg({ unfinished: true })]);
  assert.match(plan.unresolved, /no finished copy/);
  assert.deepEqual(plan.remove, []);
});

test('a single document is not a duplicate', () => {
  const only = msg({ unfinished: true });
  const plan = planGroup(KEY, [only]);
  assert.equal(plan.unresolved, null);
  assert.deepEqual(plan.remove, []);
});

test('placeholder is chosen by the flag, not by which copy holds more text', () => {
  // In 25 of the 34 production pairs the placeholder holds MORE text, because
  // the finished copy keeps its reply in content[] and leaves text empty.
  const plan = planGroup(KEY, [
    msg({ _id: 'fin', unfinished: false, text: '' }),
    msg({ _id: 'unf', unfinished: true, text: 'x'.repeat(10000) }),
  ]);
  assert.deepEqual(plan.remove.map((d) => d._id), ['unf']);
});

/* ------------------------------------------------------------------------- */
/* describe                                                                   */
/* ------------------------------------------------------------------------- */

test('the audit record carries sizes, never the message itself', () => {
  const d = describe(msg({ text: 'client name and facts', content: [{ type: 'text', text: 'secret' }], tokenCount: 7 }));
  const json = JSON.stringify(d);
  assert.doesNotMatch(json, /client name|secret/);
  assert.equal(d.textLength, 'client name and facts'.length);
  assert.equal(d.contentParts, 1);
  assert.equal(d.tokenCount, 7);
  assert.equal(d.createdAt, '2026-09-21T14:45:31.405Z');
});

test('describe copes with missing fields', () => {
  const d = describe({ messageId: 'm' });
  assert.equal(d._id, null);
  assert.equal(d.textLength, 0);
  assert.equal(d.contentParts, 0);
  assert.equal(d.unfinished, false);
});

/* ------------------------------------------------------------------------- */
/* summarize                                                                  */
/* ------------------------------------------------------------------------- */

test('summarize counts keys, deletions and unresolved keys', () => {
  const plans = [
    planGroup(KEY, [msg({ unfinished: false }), msg({ unfinished: true })]),
    planGroup(KEY, [msg({ unfinished: true }), msg({ unfinished: true })]),
  ];
  assert.deepEqual(summarize(plans), { groups: 2, toRemove: 1, unresolved: 1 });
});

test('an empty plan is a clean database', () => {
  assert.deepEqual(summarize([]), { groups: 0, toRemove: 0, unresolved: 0 });
});
