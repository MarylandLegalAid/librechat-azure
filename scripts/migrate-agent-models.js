/*
 * Move every LibreChat Agent onto an approved model.
 *
 * ⚠️  Do not run this file directly. Run scripts/migrate-agent-models.sh, which
 * supplies the model map, chooses dry-run or apply, and writes the audit trail.
 *
 *     scripts/migrate-agent-models.sh --dry-run     # default; changes nothing
 *     scripts/migrate-agent-models.sh --apply
 *
 * This is a mongosh script rather than a Node program on purpose. mongosh is
 * already inside the mongodb container, so the migration needs nothing installed
 * and nothing downloaded at the moment it runs — which matters when the moment
 * it runs is inside a one-hour maintenance window on a production cutover.
 *
 * All of the decision-making lives in lib/agent-model-migration.js, which has no
 * database in it and is unit-tested. This file is only the parts that need a
 * database: read the agents, print the plan, write the updates.
 *
 * Inputs, injected by the wrapper via --eval before this file is loaded:
 *   globalThis.MODEL_MAP_RAW   the parsed contents of model-map.json
 *   globalThis.APPLY           true to write; anything else is a dry run
 */

/* globals db, load, print, quit, globalThis */

'use strict';

load('/scripts/lib/agent-model-migration.js');

const { planAgentChanges, summarize, parseModelMap, validateModelMap, APPROVED_MODELS } =
  globalThis.AgentModelMigration;

const APPLY = globalThis.APPLY === true;
const MODE = APPLY ? 'APPLY' : 'DRY RUN';

print('');
print('==========================================================================');
print(`  Agent model migration — ${MODE}`);
print('==========================================================================');
print('');

if (!globalThis.MODEL_MAP_RAW) {
  print('ERROR: no model map was supplied. Run scripts/migrate-agent-models.sh.');
  quit(2);
}

/* --- Validate the map before touching anything --------------------------- */
let map;
try {
  map = parseModelMap(globalThis.MODEL_MAP_RAW);
} catch (error) {
  print(`ERROR: ${error.message}`);
  quit(2);
}

const mapProblems = validateModelMap(map, APPROVED_MODELS);
if (mapProblems.length) {
  print('ERROR: model-map.json is inconsistent with the approved model list:');
  mapProblems.forEach((problem) => print(`  - ${problem}`));
  quit(2);
}

print(`Approved models : ${APPROVED_MODELS.join(', ')}`);
print(`Mapping entries : ${Object.keys(map).length}`);
print('');

/* --- Plan ---------------------------------------------------------------- */
const agents = db.agents.find({}).toArray();
print(`Agents found    : ${agents.length}`);
print('');

let plans;
try {
  plans = agents.map((agent) => planAgentChanges(agent, { map, approved: APPROVED_MODELS }));
} catch (error) {
  /*
   * An unmapped model stops everything, including the agents that would have
   * migrated cleanly. A partial migration is worse than none: it is harder to
   * reason about and harder to re-run.
   */
  print('');
  print('ERROR — nothing has been changed:');
  print(`  ${error.message}`);
  print('');
  quit(1);
}

/* --- Report -------------------------------------------------------------- */
print('--------------------------------------------------------------------------');
print('  Proposed changes');
print('--------------------------------------------------------------------------');

const changed = plans.filter((plan) => !plan.skipped);
const skipped = plans.filter((plan) => plan.skipped);

if (!changed.length) {
  print('  (none — every agent is already on an approved model)');
} else {
  changed.forEach((plan) => {
    plan.changes.forEach((change) => {
      print(
        `  ${plan.agentId} | ${plan.name} | ${change.field} | ` +
          `${change.from} -> ${change.to}`,
      );
    });
  });
}
print('');

/* --- Warnings ------------------------------------------------------------ */
const warned = plans.filter((plan) => plan.warnings.length);
if (warned.length) {
  print('--------------------------------------------------------------------------');
  print('  ⚠️  Needs a human decision — NOT changed by this script');
  print('--------------------------------------------------------------------------');
  warned.forEach((plan) => {
    plan.warnings.forEach((warning) => print(`  ${plan.agentId} | ${plan.name} | ${warning}`));
  });
  print('');
  print('  These agents are already on an approved model, so the rule "touch only');
  print('  agents whose model is absent from the approved list" leaves them alone.');
  print('  Their stored history still points at a retired model, which would come');
  print('  back if a user reverted to that version. Decide deliberately.');
  print('');
}

/* --- Summary, to compare against the expected distribution --------------- */
const summary = summarize(plans);

print('--------------------------------------------------------------------------');
print('  Summary');
print('--------------------------------------------------------------------------');
print(`  Agents total        : ${summary.agentsTotal}`);
print(`  Agents to change    : ${summary.agentsChanged}`);
// Spelled out because the migration plan predicts how many agents move their
// CURRENT model, and this number is larger than that whenever an agent already
// on an approved model still has retired models in its history. Without this
// line the totals look like they disagree with the plan and the reader has no
// way to see why.
if (summary.agentsHistoryOnly) {
  print(`    of which history only : ${summary.agentsHistoryOnly}  (current model already approved)`);
  print(`    moving current model  : ${summary.agentsChanged - summary.agentsHistoryOnly}`);
}
print(`  Agents unchanged    : ${summary.agentsSkipped}`);
print(`  Field writes        : ${summary.fieldsChanged}`);
print('');
Object.keys(summary.byTarget)
  .sort()
  .forEach((target) => {
    const detail = summary.byTarget[target];
    const sources = Object.keys(detail.from)
      .sort()
      .map((from) => `${from} x${detail.from[from]}`)
      .join(', ');
    print(`  -> ${target}: ${detail.count} agent(s)  (from ${sources})`);
  });
print('');
print('  Compare these totals with the expected distribution in the migration');
print('  plan before applying. If they differ, stop and find out why.');
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
  const stragglers = db.agents
    .aggregate([
      { $group: { _id: '$model', n: { $sum: 1 } } },
      { $match: { _id: { $nin: APPROVED_MODELS } } },
    ])
    .toArray();

  print('--------------------------------------------------------------------------');
  print('  Verification');
  print('--------------------------------------------------------------------------');
  if (stragglers.length) {
    print('  ✗ FAILED — these models are still in use at the top level:');
    stragglers.forEach((row) => print(`      ${row._id}: ${row.n} agent(s)`));
  } else {
    print('  ✓ every agent.model is in the approved list');
  }

  const versionStragglers = db.agents
    .aggregate([
      { $unwind: '$versions' },
      { $group: { _id: '$versions.model', n: { $sum: 1 } } },
      { $match: { _id: { $nin: APPROVED_MODELS.concat([null]) } } },
    ])
    .toArray();

  if (versionStragglers.length) {
    print('  ✗ FAILED — these models are still referenced in version history:');
    versionStragglers.forEach((row) => print(`      ${row._id}: ${row.n} version(s)`));
  } else {
    print('  ✓ every versions[].model is in the approved list');
  }
  print('');

  if (stragglers.length || versionStragglers.length) {
    print('  The migration did not fully succeed. Do not close the window.');
  }
} else {
  print('--------------------------------------------------------------------------');
  print('  Nothing was changed. This was a dry run.');
  print('');
  print('  Review every line above with the person who owns these agents, then:');
  print('      scripts/migrate-agent-models.sh --apply');
  print('--------------------------------------------------------------------------');
  print('');
}

/*
 * The audit trail. The wrapper extracts everything between these markers and
 * writes it to the data disk. mongosh cannot write files itself, which is why
 * this goes out through stdout.
 */
print('===CHANGELOG-JSON-BEGIN===');
print(
  JSON.stringify({
    timestamp: new Date().toISOString(),
    mode: MODE,
    applied: APPLY,
    documentsModified: written,
    approvedModels: APPROVED_MODELS,
    map,
    summary,
    plans: plans.map((plan) => ({
      agentId: plan.agentId,
      name: plan.name,
      skipped: plan.skipped,
      // Serialized so the audit trail can answer "which agent was that?" — the
      // summary counts history-only repairs, and without this the count is the
      // only trace of them anywhere in the log.
      historyOnly: plan.historyOnly,
      changes: plan.changes,
      warnings: plan.warnings,
    })),
  }),
);
print('===CHANGELOG-JSON-END===');
