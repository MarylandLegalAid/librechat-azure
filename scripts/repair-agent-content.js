/*
 * Reapply agent content that a restore cannot reproduce.
 *
 * ⚠️  Do not run this file directly. Run scripts/repair-agent-content.sh, which
 * supplies the content file, chooses dry-run or apply, and writes the audit trail.
 *
 *     scripts/repair-agent-content.sh --dry-run     # default; changes nothing
 *     scripts/repair-agent-content.sh --apply
 *
 * Run it AFTER scripts/migrate-agent-models.sh. The two are independent — one
 * fixes models, this fixes instructions and tools — but running the model
 * migration second would be the more surprising order for a reader of the
 * runbook, and there is no reason to invite the question.
 *
 * mongosh rather than Node for the same reason as the model migration: mongosh
 * is already in the mongodb container, so this needs nothing installed at the
 * moment it runs, and that moment is inside a cutover window.
 *
 * All decision-making lives in lib/agent-content-repair.js, which has no database
 * in it and is unit-tested. This file is only the parts that need one.
 *
 * Inputs, injected by the wrapper via --eval before this file is loaded:
 *   globalThis.AGENT_CONTENT_RAW   the parsed contents of agent-content.json
 *   globalThis.APPLY               true to write; anything else is a dry run
 */

/* globals db, load, print, quit, globalThis */

'use strict';

load('/scripts/lib/agent-content-repair.js');

const { planContentRepair, summarize, validateContent } = globalThis.AgentContentRepair;

const APPLY = globalThis.APPLY === true;
const MODE = APPLY ? 'APPLY' : 'DRY RUN';

print('');
print('==========================================================================');
print(`  Agent content repair — ${MODE}`);
print('==========================================================================');
print('');

const doc = globalThis.AGENT_CONTENT_RAW;
if (!doc) {
  print('ERROR: no content file was supplied. Run scripts/repair-agent-content.sh.');
  quit(2);
}

const problems = validateContent(doc);
if (problems.length) {
  print('ERROR: agent-content.json is not usable:');
  problems.forEach((problem) => print(`  - ${problem}`));
  quit(2);
}

const deadTools = doc.deadTools || [];
const byId = {};
doc.agents.forEach((entry) => {
  byId[entry.id] = entry;
});

print(`Recorded agents : ${doc.agents.length}`);
print(`Dead tools      : ${deadTools.length ? deadTools.join(', ') : '(none)'}`);
print('');

/* --- Plan ---------------------------------------------------------------- */
const agents = db.agents.find({}).toArray();
print(`Agents found    : ${agents.length}`);

/*
 * A recorded agent that is not in the database is not fatal — the agent may have
 * been deleted deliberately — but it is always worth saying out loud, because the
 * other explanation is that the id is wrong and the repair silently did nothing.
 */
const liveIds = {};
agents.forEach((agent) => {
  liveIds[agent.id || String(agent._id)] = true;
});
const missing = doc.agents.filter((entry) => !liveIds[entry.id]);
if (missing.length) {
  print('');
  print('  ⚠️  recorded but NOT PRESENT in this database:');
  missing.forEach((entry) => print(`      ${entry.id}  ${entry.name || ''}`));
  print('      Either the agent was deleted, or the id in agent-content.json is wrong.');
}
print('');

const plans = agents.map((agent) =>
  planContentRepair(agent, {
    content: byId[agent.id || String(agent._id)] || null,
    deadTools,
  }),
);

/* --- Report -------------------------------------------------------------- */
print('--------------------------------------------------------------------------');
print('  Proposed changes');
print('--------------------------------------------------------------------------');

const changed = plans.filter((plan) => !plan.skipped);
if (!changed.length) {
  print('  (none — every agent already matches the recorded content)');
} else {
  changed.forEach((plan) => {
    plan.changes.forEach((change) => {
      print(`  ${plan.agentId} | ${plan.name} | ${change.field} | ${change.from} -> ${change.to}`);
    });
  });
}
print('');

const summary = summarize(plans);
print('--------------------------------------------------------------------------');
print('  Summary');
print('--------------------------------------------------------------------------');
print(`  Agents total     : ${summary.agentsTotal}`);
print(`  Agents to change : ${summary.agentsChanged}`);
print(`  Agents unchanged : ${summary.agentsSkipped}`);
print(`  Field writes     : ${summary.fieldsChanged}`);
print('');

/* --- Apply --------------------------------------------------------------- */
let written = 0;

if (APPLY) {
  print('--------------------------------------------------------------------------');
  print('  Applying');
  print('--------------------------------------------------------------------------');

  changed.forEach((plan) => {
    const agent = agents.filter((candidate) => {
      const id = candidate.id || (candidate._id ? String(candidate._id) : null);
      return id === plan.agentId;
    })[0];

    const result = db.agents.updateOne({ _id: agent._id }, { $set: plan.set });
    written += result.modifiedCount;
    print(`  ${plan.agentId} | ${plan.name} | ${Object.keys(plan.set).length} field(s) written`);
  });

  print('');
  print(`  ${written} agent document(s) modified.`);
  print('');

  /* --- Verify, in the same run -------------------------------------------- */
  print('--------------------------------------------------------------------------');
  print('  Verification');
  print('--------------------------------------------------------------------------');

  let ok = true;

  doc.agents.forEach((entry) => {
    if (!liveIds[entry.id]) {
      return;
    }
    const fresh = db.agents.findOne({ id: entry.id });
    if (typeof entry.instructions === 'string' && fresh.instructions !== entry.instructions) {
      print(`  ✗ ${entry.name}: instructions do not match the recorded copy`);
      ok = false;
    }
  });
  if (ok) {
    print('  ✓ every recorded agent matches its recorded instructions');
  }

  const deadLeft = deadTools.filter(
    (tool) =>
      db.agents.countDocuments({ tools: tool }) > 0 ||
      db.agents.countDocuments({ 'versions.tools': tool }) > 0,
  );
  if (deadLeft.length) {
    print(`  ✗ dead tools still referenced somewhere: ${deadLeft.join(', ')}`);
    ok = false;
  } else {
    print('  ✓ no agent or snapshot references a dead tool');
  }
  print('');

  if (!ok) {
    print('  The repair did not fully succeed. Do not close the window.');
  }
} else {
  print('--------------------------------------------------------------------------');
  print('  Nothing was changed. This was a dry run.');
  print('');
  print('      scripts/repair-agent-content.sh --apply');
  print('--------------------------------------------------------------------------');
  print('');
}

print('===CHANGELOG-JSON-BEGIN===');
print(
  JSON.stringify({
    timestamp: new Date().toISOString(),
    mode: MODE,
    applied: APPLY,
    documentsModified: written,
    deadTools,
    recordedAgents: doc.agents.map((entry) => ({
      id: entry.id,
      name: entry.name,
      present: Boolean(liveIds[entry.id]),
      instructionsLength: (entry.instructions || '').length,
      toolCount: (entry.tools || []).length,
    })),
    summary,
    plans: plans.map((plan) => ({
      agentId: plan.agentId,
      name: plan.name,
      skipped: plan.skipped,
      changes: plan.changes,
    })),
  }),
);
print('===CHANGELOG-JSON-END===');
