/*
 * Rename MLAGPT 4 -> MLAGPT 4.1 on the agents that carry it.
 *
 * ⚠️  Do not run this file directly. Run scripts/rename-brand.sh, which chooses
 * dry-run or apply and writes the audit trail.
 *
 *     scripts/rename-brand.sh --dry-run     # default; changes nothing
 *     scripts/rename-brand.sh --apply
 *
 * ⚠️  THIS IS A POST-RESTORE FIXUP. A Mongo restore brings back the old names,
 * because the agents live in the database and not in this repository. Run it
 * after every restore, alongside migrate-agent-models.sh and
 * repair-agent-content.sh. Skipping it leaves two agents in the picker still
 * advertising the previous release.
 *
 * The other three places the wordmark lives are NOT here, because they are not
 * in the database and do not need a restore to fix:
 *   - librechat.yaml            modalTitle, customWelcome   (git, deployed)
 *   - Key Vault APP-TITLE       the browser tab and header
 *   - Key Vault CUSTOM-FOOTER   the footer disclaimer
 *
 * mongosh rather than Node for the same reason as its two siblings: mongosh is
 * already in the mongodb container, so this needs nothing installed at the
 * moment it runs, and that moment is inside a cutover window.
 *
 * All decision-making lives in lib/brand-rename.js, which has no database in it
 * and is unit-tested. This file is only the parts that need one.
 *
 * Inputs, injected by the wrapper via --eval before this file is loaded:
 *   globalThis.APPLY   true to write; anything else is a dry run
 */

/* globals db, load, print, quit, globalThis */

'use strict';

load('/scripts/lib/brand-rename.js');

const { planAgentRename, summarize, hasOldBrand, REPLACEMENT } = globalThis.BrandRename;

const APPLY = globalThis.APPLY === true;
const MODE = APPLY ? 'APPLY' : 'DRY RUN';

print('');
print('==========================================================================');
print(`  Brand rename — MLAGPT 4 -> ${REPLACEMENT} — ${MODE}`);
print('==========================================================================');
print('');

/* --- Plan ---------------------------------------------------------------- */
const agents = db.agents.find({}).toArray();
print(`Agents found    : ${agents.length}`);

const plans = agents.map(planAgentRename);
const changed = plans.filter((plan) => !plan.skipped);

print('');
print('--------------------------------------------------------------------------');
print('  Proposed changes');
print('--------------------------------------------------------------------------');

if (!changed.length) {
  print('  (none — no agent carries the previous wordmark)');
} else {
  changed.forEach((plan) => {
    plan.changes.forEach((change) => {
      print(`  ${plan.agentId} | ${change.field}`);
      print(`      from: ${change.from}`);
      print(`      to  : ${change.to}`);
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

/*
 * Version snapshots are deliberately left alone, but silence about them would
 * be its own kind of error — somebody restoring an old version later deserves
 * to have been told. Count them and say so.
 */
let snapshotsLeft = 0;
agents.forEach((agent) => {
  (agent.versions || []).forEach((version) => {
    if (['name', 'description', 'instructions'].some((f) => hasOldBrand(version[f]))) {
      snapshotsLeft += 1;
    }
  });
});
if (snapshotsLeft) {
  print(`  Note: ${snapshotsLeft} version snapshot(s) keep the old name, by decision.`);
  print('        Restoring one of those versions from the UI brings it back.');
  print('');
}

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
    print(`  ${plan.agentId} | ${Object.keys(plan.set).length} field(s) written`);
  });

  print('');
  print(`  ${written} agent document(s) modified.`);
  print('');

  /* --- Verify, in the same run -------------------------------------------- */
  print('--------------------------------------------------------------------------');
  print('  Verification');
  print('--------------------------------------------------------------------------');

  let ok = true;

  const stragglers = db.agents
    .find({})
    .toArray()
    .filter((agent) =>
      ['name', 'description', 'instructions'].some((f) => hasOldBrand(agent[f])),
    );

  if (stragglers.length) {
    print(`  ✗ ${stragglers.length} agent(s) still carry the old wordmark:`);
    stragglers.forEach((agent) => print(`      ${agent.id || agent._id} | ${agent.name}`));
    ok = false;
  } else {
    print('  ✓ no agent carries the old wordmark in a live field');
  }

  /* Re-planning against fresh documents must produce nothing. That is the
   * property the cutover actually depends on, so assert it rather than assume
   * it: this script may well be run twice. */
  const rerun = summarize(db.agents.find({}).toArray().map(planAgentRename));
  if (rerun.agentsChanged !== 0) {
    print(`  ✗ a second pass would still change ${rerun.agentsChanged} agent(s) — not idempotent`);
    ok = false;
  } else {
    print('  ✓ a second run would change nothing');
  }
  print('');

  if (!ok) {
    print('  The rename did not fully succeed. Do not close the window.');
  }
} else {
  print('--------------------------------------------------------------------------');
  print('  Nothing was changed. This was a dry run.');
  print('');
  print('      scripts/rename-brand.sh --apply');
  print('--------------------------------------------------------------------------');
  print('');
}

print('===CHANGELOG-JSON-BEGIN===');
print(
  JSON.stringify({
    timestamp: new Date().toISOString(),
    mode: MODE,
    applied: APPLY,
    replacement: REPLACEMENT,
    documentsModified: written,
    snapshotsLeftByDecision: snapshotsLeft,
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
