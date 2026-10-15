/*
 * Tests for the dead agent file cleanup logic.
 *
 *     node --test scripts/test/
 *
 * No database, no network, no mocks. Fixtures are shaped like the agent and
 * file records found in production on 2026-10-15.
 */

'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  s3KeyFor,
  classifyHead,
  fileIdArrays,
  referencedFileIds,
  planAgent,
  planRevert,
  resolveHeads,
  summarize,
  getPath,
} = require('../lib/dead-agent-file-cleanup.js');

function agent(overrides) {
  return Object.assign(
    {
      id: 'agent_test',
      name: 'Test agent',
      tool_resources: {
        file_search: { file_ids: ['dead1', 'live1', 'dead2'] },
        execute_code: { file_ids: [] },
      },
      versions: [
        { tool_resources: {} },
        { tool_resources: { file_search: { file_ids: ['dead1'] } } },
        { tool_resources: { file_search: { file_ids: ['dead1', 'live1', 'dead2'] } } },
      ],
    },
    overrides,
  );
}

/* ------------------------------------------------------------------------- */
/* s3KeyFor: the same key v0.8.8 reads                                        */
/* ------------------------------------------------------------------------- */

test('a virtual-hosted URL (the production shape) gives the decoded path', () => {
  const file = { filepath: 'https://bucket-a.s3.us-east-1.amazonaws.com/uploads/u1/abc__My%20File.pdf' };
  assert.equal(s3KeyFor(file, 'bucket-a'), 'uploads/u1/abc__My File.pdf');
});

test('a path-style URL drops the bucket segment', () => {
  assert.equal(s3KeyFor({ filepath: 'https://s3.us-east-1.amazonaws.com/bucket-a/uploads/u1/x.pdf' }, 'bucket-a'), 'uploads/u1/x.pdf');
  assert.equal(s3KeyFor({ filepath: 'https://s3.amazonaws.com/bucket-a/uploads/x.pdf' }, 'bucket-a'), 'uploads/x.pdf');
});

test('storageKey wins over the URL, as in resolveStoredS3Key', () => {
  assert.equal(s3KeyFor({ storageKey: 'k/1', filepath: 'https://b.s3.amazonaws.com/other' }, 'b'), 'k/1');
});

test('a bare key loses its leading slash', () => {
  assert.equal(s3KeyFor({ filepath: '/uploads/u1/x.pdf' }, 'b'), 'uploads/u1/x.pdf');
});

test('anything not hosted on AWS gives no key rather than a guess', () => {
  assert.equal(s3KeyFor({ filepath: 'https://example.com/uploads/x.pdf' }, 'b'), null);
  assert.equal(s3KeyFor({ filepath: 'https://s3.amazonaws.com/bucket-only' }, 'b'), null);
  assert.equal(s3KeyFor({ filepath: '' }, 'b'), null);
  assert.equal(s3KeyFor({}, 'b'), null);
  assert.equal(s3KeyFor(null, 'b'), null);
});

/* ------------------------------------------------------------------------- */
/* classifyHead / resolveHeads: only a 404 is dead                            */
/* ------------------------------------------------------------------------- */

test('only 404 is missing; 403 and no status are errors', () => {
  assert.equal(classifyHead(200), 'present');
  assert.equal(classifyHead(404), 'missing');
  assert.equal(classifyHead(403), 'error');
  assert.equal(classifyHead(null), 'error');
  assert.equal(classifyHead(301), 'error');
});

test('resolveHeads splits dead, present and unanswered', () => {
  const out = resolveHeads(
    ['a', 'b', 'c', 'd'],
    [
      { file_id: 'a', status: 'missing', httpStatus: 404 },
      { file_id: 'b', status: 'present', httpStatus: 200 },
      { file_id: 'c', status: 'error', httpStatus: 403, detail: 'Forbidden (HTTP 403)' },
    ],
  );
  assert.deepEqual(out.dead, ['a']);
  assert.deepEqual(out.present, ['b']);
  assert.deepEqual(out.errors, [
    { file_id: 'c', detail: 'Forbidden (HTTP 403)' },
    { file_id: 'd', detail: 'no HEAD result recorded' },
  ]);
});

test('a "missing" label without a 404 is not trusted', () => {
  const out = resolveHeads(['a'], [{ file_id: 'a', status: 'missing', httpStatus: 403 }]);
  assert.deepEqual(out.dead, []);
  assert.equal(out.errors.length, 1);
});

/* ------------------------------------------------------------------------- */
/* fileIdArrays / referencedFileIds                                           */
/* ------------------------------------------------------------------------- */

test('every file_ids array is found, current and in versions, with Mongo paths', () => {
  const paths = fileIdArrays(agent()).map((a) => a.path);
  assert.deepEqual(paths, [
    'tool_resources.execute_code.file_ids',
    'tool_resources.file_search.file_ids',
    'versions.1.tool_resources.file_search.file_ids',
    'versions.2.tool_resources.file_search.file_ids',
  ]);
});

test('any resource counts, not only file_search', () => {
  const a = agent({ tool_resources: { context: { file_ids: ['x'] }, ocr: { file_ids: ['y'] } }, versions: [] });
  assert.deepEqual(referencedFileIds(a).sort(), ['x', 'y']);
});

test('an agent with no tool_resources or versions references nothing', () => {
  assert.deepEqual(referencedFileIds({ id: 'a' }), []);
  assert.deepEqual(referencedFileIds({ id: 'a', tool_resources: null, versions: [null] }), []);
});

/* ------------------------------------------------------------------------- */
/* planAgent                                                                  */
/* ------------------------------------------------------------------------- */

test('dead ids go from the agent and from every snapshot; live ids stay in order', () => {
  const plan = planAgent(agent(), new Set(['dead1', 'dead2']));
  assert.equal(plan.agentId, 'agent_test');
  assert.deepEqual(
    plan.changes.map((c) => [c.path, c.after, c.removed]),
    [
      ['tool_resources.file_search.file_ids', ['live1'], ['dead1', 'dead2']],
      ['versions.1.tool_resources.file_search.file_ids', [], ['dead1']],
      ['versions.2.tool_resources.file_search.file_ids', ['live1'], ['dead1', 'dead2']],
    ],
  );
  assert.deepEqual(plan.changes[0].before, ['dead1', 'live1', 'dead2']);
});

test('the plan does not mutate the agent', () => {
  const a = agent();
  planAgent(a, ['dead1']);
  assert.deepEqual(a.tool_resources.file_search.file_ids, ['dead1', 'live1', 'dead2']);
});

test('no dead ids → no changes (idempotent after an apply)', () => {
  assert.deepEqual(planAgent(agent(), new Set()).changes, []);
  const cleaned = agent();
  planAgent(cleaned, ['dead1', 'dead2']).changes.forEach((c) => {
    const parts = c.path.split('.');
    const arr = parts.slice(0, -1).reduce((v, p) => v[p], cleaned);
    arr.file_ids = c.after;
  });
  assert.deepEqual(planAgent(cleaned, ['dead1', 'dead2']).changes, []);
});

test('summarize counts agents, arrays and ids', () => {
  const plans = [planAgent(agent(), ['dead1', 'dead2']), planAgent(agent({ id: 'other' }), [])];
  assert.deepEqual(summarize(plans), { agentsChanged: 1, arraysChanged: 3, idsRemoved: 5 });
});

/* ------------------------------------------------------------------------- */
/* planRevert                                                                 */
/* ------------------------------------------------------------------------- */

function applied(a, plan) {
  const copy = JSON.parse(JSON.stringify(a));
  plan.changes.forEach((c) => {
    const parts = c.path.split('.');
    parts.slice(0, -1).reduce((v, p) => v[p], copy).file_ids = c.after;
  });
  return copy;
}

test('revert restores every array the apply left untouched since', () => {
  const plan = planAgent(agent(), ['dead1', 'dead2']);
  const after = applied(agent(), plan);
  const { set, skipped } = planRevert(after, plan);
  assert.deepEqual(skipped, []);
  assert.deepEqual(set['tool_resources.file_search.file_ids'], ['dead1', 'live1', 'dead2']);
  assert.deepEqual(set['versions.1.tool_resources.file_search.file_ids'], ['dead1']);
  assert.equal(Object.keys(set).length, 3);
});

test('revert leaves an array edited since the apply, and says so', () => {
  const plan = planAgent(agent(), ['dead1', 'dead2']);
  const after = applied(agent(), plan);
  after.tool_resources.file_search.file_ids = ['live1', 'new-upload'];
  const { set, skipped } = planRevert(after, plan);
  assert.equal(set['tool_resources.file_search.file_ids'], undefined);
  assert.deepEqual(skipped, [{ path: 'tool_resources.file_search.file_ids', reason: 'changed since the apply' }]);
});

test('a second revert finds everything already restored', () => {
  const plan = planAgent(agent(), ['dead1', 'dead2']);
  const { set, skipped } = planRevert(agent(), plan);
  assert.deepEqual(set, {});
  assert.equal(skipped.length, 3);
  assert.ok(skipped.every((s) => s.reason === 'already restored'));
});

test('getPath reads dotted paths through arrays', () => {
  assert.deepEqual(getPath(agent(), 'versions.1.tool_resources.file_search.file_ids'), ['dead1']);
  assert.equal(getPath(agent(), 'versions.9.tool_resources'), undefined);
});
