const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const {
  planContentRepair,
  sameTools,
  summarize,
  validateContent,
} = require('../lib/agent-content-repair.js');

const DEAD = [
  'search_case_by_number_mcp_LegalServer',
  'get_case_info_mcp_LegalServer',
  'list_case_documents_mcp_LegalServer',
];

const OPTS = { deadTools: DEAD };

function agent(overrides) {
  return Object.assign({ id: 'agent_x', name: 'Test Agent', tools: [], versions: [] }, overrides);
}

/* ------------------------------------------------------------------------- */
/* The committed data file                                                    */
/* ------------------------------------------------------------------------- */

const CONTENT = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'agent-content.json'), 'utf8'),
);

test('agent-content.json is valid', () => {
  assert.deepEqual(validateContent(CONTENT), []);
});

test('agent-content.json records both recovered agents with real content', () => {
  assert.equal(CONTENT.agents.length, 2);
  CONTENT.agents.forEach((entry) => {
    assert.ok(entry.id.startsWith('agent_'), `${entry.name} needs a real agent id`);
    assert.ok(entry.instructions.length > 1000, `${entry.name} instructions look truncated`);
    assert.ok(entry.tools.length > 0, `${entry.name} has no tools`);
  });
});

test('the recorded instructions no longer describe S3', () => {
  // LetterWriter serves letters from the data disk over Caddy. Instructions that
  // still promise a presigned Amazon S3 link make the model invent one.
  CONTENT.agents.forEach((entry) => {
    assert.doesNotMatch(entry.instructions, /presigned|Amazon S3|signedUrl/i, entry.name);
  });
});

/* ------------------------------------------------------------------------- */
/* validateContent                                                            */
/* ------------------------------------------------------------------------- */

test('an entry with no id is rejected — agents are matched by id, not name', () => {
  const problems = validateContent({ agents: [{ name: 'X', instructions: 'hi' }] });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /has no id/);
});

test('a duplicated id is rejected rather than letting the last entry win', () => {
  const problems = validateContent({
    agents: [
      { id: 'a', instructions: 'one' },
      { id: 'a', instructions: 'two' },
    ],
  });
  assert.match(problems.join(' '), /repeats id a/);
});

test('an entry that sets nothing is rejected', () => {
  const problems = validateContent({ agents: [{ id: 'a', name: 'X' }] });
  assert.match(problems.join(' '), /sets neither instructions nor tools/);
});

test('recorded tools containing a dead tool are rejected', () => {
  // It would work — the dead-tool pass strips it in the same run — but the file
  // would be describing an end state that is not the end state.
  const problems = validateContent({
    deadTools: DEAD,
    agents: [{ id: 'a', name: 'X', tools: ['context', DEAD[0]] }],
  });
  assert.match(problems.join(' '), /lists dead tool\(s\)/);
});

/* ------------------------------------------------------------------------- */
/* Content repair                                                             */
/* ------------------------------------------------------------------------- */

test('instructions and tools are set from the recorded copy', () => {
  const plan = planContentRepair(
    agent({ instructions: 'old', tools: ['context'] }),
    { ...OPTS, content: { instructions: 'new and much longer', tools: ['context', 'web_search'] } },
  );
  assert.equal(plan.skipped, false);
  assert.equal(plan.set.instructions, 'new and much longer');
  assert.deepEqual(plan.set.tools, ['context', 'web_search']);
});

test('the dry-run output reports lengths, not thousands of characters of prose', () => {
  const plan = planContentRepair(
    agent({ instructions: 'old' }),
    { ...OPTS, content: { instructions: 'x'.repeat(9000) } },
  );
  const change = plan.changes.find((c) => c.field === 'instructions');
  assert.equal(change.from, '3 chars');
  assert.equal(change.to, '9000 chars');
});

test('an agent already matching the recorded copy is skipped — idempotent', () => {
  const content = { instructions: 'same', tools: ['context'] };
  const plan = planContentRepair(agent({ instructions: 'same', tools: ['context'] }), {
    ...OPTS,
    content,
  });
  assert.equal(plan.skipped, true);
  assert.deepEqual(plan.set, {});
});

test('tool ORDER is significant — LibreChat renders them in order', () => {
  const plan = planContentRepair(agent({ tools: ['b', 'a'] }), {
    ...OPTS,
    content: { tools: ['a', 'b'] },
  });
  assert.deepEqual(plan.set.tools, ['a', 'b']);
});

test('an agent with no recorded content still gets dead tools stripped', () => {
  const plan = planContentRepair(agent({ tools: ['context', DEAD[1]] }), OPTS);
  assert.equal(plan.skipped, false);
  assert.deepEqual(plan.set.tools, ['context']);
});

/* ------------------------------------------------------------------------- */
/* Dead tools and the interaction between the two passes                      */
/* ------------------------------------------------------------------------- */

test('dead tools are stripped from every versions[] snapshot', () => {
  const plan = planContentRepair(
    agent({
      versions: [
        { tools: ['context', DEAD[0]] },
        { tools: ['context'] },
        { tools: [DEAD[1], DEAD[2]] },
      ],
    }),
    OPTS,
  );
  assert.deepEqual(plan.set['versions.0.tools'], ['context']);
  assert.ok(!('versions.1.tools' in plan.set), 'a clean snapshot is not rewritten');
  assert.deepEqual(plan.set['versions.2.tools'], []);
});

test('recorded tools are not re-polluted by the dead-tool pass', () => {
  // The bug this guards: filtering the agent's CURRENT tools while set.tools is
  // about to replace them computes a diff against a discarded value.
  const plan = planContentRepair(
    agent({ tools: [DEAD[0], DEAD[1]] }),
    { ...OPTS, content: { tools: ['context', 'matter_get_mcp_LegalServer'] } },
  );
  assert.deepEqual(plan.set.tools, ['context', 'matter_get_mcp_LegalServer']);
  assert.ok(!plan.set.tools.some((t) => DEAD.indexOf(t) !== -1));
});

test('instructions in version history are left alone', () => {
  // Dangling tool references are a broken pointer and get fixed. Instructions
  // are a record of what the author wrote, and rewriting them falsifies it.
  const plan = planContentRepair(
    agent({ versions: [{ instructions: 'what they wrote in March', tools: ['context'] }] }),
    { ...OPTS, content: { instructions: 'the new text' } },
  );
  assert.ok(!Object.keys(plan.set).some((k) => /^versions\.\d+\.instructions$/.test(k)));
});

test('a version with no tools array is skipped without error', () => {
  const plan = planContentRepair(
    agent({ versions: [{ instructions: 'x' }, null, { tools: [DEAD[0]] }] }),
    OPTS,
  );
  assert.deepEqual(plan.set['versions.2.tools'], []);
});

test('running against already-repaired data produces no changes', () => {
  const content = { instructions: 'final', tools: ['context'] };
  const repaired = agent({
    instructions: 'final',
    tools: ['context'],
    versions: [{ tools: ['context'] }],
  });
  const plan = planContentRepair(repaired, { ...OPTS, content });
  assert.equal(plan.skipped, true);
  assert.deepEqual(plan.set, {});
});

/* ------------------------------------------------------------------------- */
/* Summary                                                                    */
/* ------------------------------------------------------------------------- */

test('the summary counts agents and field writes', () => {
  const plans = [
    planContentRepair(agent({ id: 'a', tools: [DEAD[0]] }), OPTS),
    planContentRepair(agent({ id: 'b', tools: ['context'] }), OPTS),
    planContentRepair(agent({ id: 'c', versions: [{ tools: [DEAD[1]] }] }), OPTS),
  ];
  const summary = summarize(plans);
  assert.equal(summary.agentsTotal, 3);
  assert.equal(summary.agentsChanged, 2);
  assert.equal(summary.agentsSkipped, 1);
  assert.equal(summary.fieldsChanged, 2);
});

test('sameTools compares by value and order', () => {
  assert.ok(sameTools(['a', 'b'], ['a', 'b']));
  assert.ok(!sameTools(['a', 'b'], ['b', 'a']));
  assert.ok(!sameTools(['a'], ['a', 'b']));
  assert.ok(sameTools(undefined, []));
});
