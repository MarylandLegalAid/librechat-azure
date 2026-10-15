/*
 * Remove dead S3 knowledge files from agents (and from their version history).
 *
 * ⚠️  Do not run this file directly. Run scripts/remove-dead-agent-files.sh,
 * which collects the candidates, HEADs them in S3, chooses dry-run or apply,
 * and writes the audit trail.
 *
 * The rule, and why, is in lib/dead-agent-file-cleanup.js, which has no
 * database in it and is unit-tested. This file is only the parts that need one.
 *
 * Inputs, injected by the wrapper via --eval before this file is loaded:
 *   globalThis.MODE          'candidates' | 'plan' | 'revert'
 *   globalThis.APPLY         true to write; anything else is a dry run
 *   globalThis.HEADS_FILE    (plan) path in the container of the HEAD results
 *   globalThis.HEADS_SOURCE  (plan) where they came from, for the record
 *   globalThis.REVERT_FILE   (revert) path in the container of an apply trail
 */

/* globals db, load, print, quit, globalThis, require */

'use strict';

load('/scripts/lib/dead-agent-file-cleanup.js');

const { referencedFileIds, planAgent, planRevert, resolveHeads, summarize } =
  globalThis.DeadAgentFileCleanup;

const APPLY = globalThis.APPLY === true;
const RUN = globalThis.MODE;

function rule(title) {
  print('--------------------------------------------------------------------------');
  if (title) {
    print(`  ${title}`);
    print('--------------------------------------------------------------------------');
  }
}

/* Agents that reference at least one S3 file, and those files' records. */
function findCandidates() {
  const agents = db.agents.find({}, { id: 1, name: 1, author: 1, tool_resources: 1, versions: 1, updatedAt: 1 }).toArray();
  const referenced = new Set();
  agents.forEach((agent) => referencedFileIds(agent).forEach((id) => referenced.add(id)));
  const files = db.files
    .find(
      { file_id: { $in: Array.from(referenced) }, source: 's3' },
      { file_id: 1, filepath: 1, storageKey: 1, bytes: 1, type: 1, createdAt: 1, user: 1 },
    )
    .toArray();
  const s3Ids = new Set(files.map((f) => f.file_id));
  return {
    agents: agents.filter((agent) => referencedFileIds(agent).some((id) => s3Ids.has(id))),
    files,
  };
}

/* --- candidates: the list the S3 check needs. Read-only. ------------------ */
if (RUN === 'candidates') {
  const { files } = findCandidates();
  print('===CANDIDATES-JSON-BEGIN===');
  print(JSON.stringify(files.map((f) => ({ file_id: f.file_id, filepath: f.filepath, storageKey: f.storageKey || null }))));
  print('===CANDIDATES-JSON-END===');
  quit(0);
}

const fs = require('fs');

/* --- revert --------------------------------------------------------------- */
if (RUN === 'revert') {
  const MODE = APPLY ? 'REVERT' : 'REVERT DRY RUN';
  const audit = JSON.parse(fs.readFileSync(globalThis.REVERT_FILE, 'utf8'));
  print('');
  print('==========================================================================');
  print(`  Dead agent file cleanup — ${MODE}`);
  print('==========================================================================');
  print('');
  if (audit.mode !== 'APPLY') {
    print(`  ✗ that audit trail is from a ${audit.mode} run; only an APPLY run can be reverted.`);
    quit(2);
  }
  print(`  Undoing the run of ${audit.timestamp}`);
  print('');

  const results = audit.plans.map((entry) => {
    const agent = db.agents.findOne({ id: entry.agentId });
    if (!agent) {
      return { agentId: entry.agentId, restored: 0, skipped: entry.changes.map((c) => ({ path: c.path, reason: 'agent no longer exists' })) };
    }
    const { set, skipped } = planRevert(agent, entry);
    const paths = Object.keys(set);
    if (APPLY && paths.length) {
      const res = db.agents.updateOne({ _id: agent._id, updatedAt: agent.updatedAt }, { $set: set });
      if (res.modifiedCount !== 1) {
        return { agentId: entry.agentId, restored: 0, skipped: paths.map((path) => ({ path, reason: 'agent changed during the revert' })).concat(skipped) };
      }
    }
    return { agentId: entry.agentId, restored: paths.length, skipped };
  });

  results.forEach((r) => {
    print(`  ${r.agentId}: ${r.restored} array(s) ${APPLY ? 'restored' : 'to restore'}`);
    r.skipped.forEach((s) => print(`      skipped ${s.path}: ${s.reason}`));
  });
  print('');

  print('===CHANGELOG-JSON-BEGIN===');
  print(JSON.stringify({ timestamp: new Date().toISOString(), mode: MODE, applied: APPLY, revertOf: audit.timestamp, results }));
  print('===CHANGELOG-JSON-END===');
  quit(results.some((r) => r.skipped.some((s) => s.reason !== 'already restored')) ? 1 : 0);
}

/* --- plan (dry run or apply) ---------------------------------------------- */
if (RUN !== 'plan') {
  print(`unknown MODE: ${RUN}`);
  quit(2);
}

const MODE = APPLY ? 'APPLY' : 'DRY RUN';
const headsRecord = JSON.parse(fs.readFileSync(globalThis.HEADS_FILE, 'utf8'));
const heads = Array.isArray(headsRecord) ? headsRecord : headsRecord.heads;

print('');
print('==========================================================================');
print(`  Dead agent file cleanup — ${MODE}`);
print('==========================================================================');
print('');

const { agents, files } = findCandidates();
const fileById = new Map(files.map((f) => [f.file_id, f]));
const verdict = resolveHeads(files.map((f) => f.file_id), heads);

print(`Agents referencing S3 files : ${agents.length}`);
print(`S3 files they reference     : ${files.length}`);
print(`HEAD results from           : ${globalThis.HEADS_SOURCE}`);
print(`  present (200)             : ${verdict.present.length}`);
print(`  missing (404)             : ${verdict.dead.length}`);
print(`  no answer                 : ${verdict.errors.length}`);
print('');

if (verdict.errors.length) {
  rule('⚠️  STOPPED: some S3 checks gave no answer. Nothing was changed.');
  verdict.errors.forEach((e) => print(`  ${e.file_id}: ${e.detail}`));
  print('');
  print('===CHANGELOG-JSON-BEGIN===');
  print(JSON.stringify({ timestamp: new Date().toISOString(), mode: MODE, applied: false, stopped: 'S3 checks without an answer', headsSource: globalThis.HEADS_SOURCE, heads, errors: verdict.errors }));
  print('===CHANGELOG-JSON-END===');
  quit(1);
}

const dead = new Set(verdict.dead);
const plans = agents.map((agent) => planAgent(agent, dead)).filter((plan) => plan.changes.length);
const agentById = new Map(agents.map((a) => [a.id, a]));

rule('Files to remove (source: s3, HEAD 404)');
if (!verdict.dead.length) {
  print('  (none)');
}
verdict.dead.forEach((id) => {
  const f = fileById.get(id);
  const created = f.createdAt instanceof Date ? f.createdAt.toISOString().slice(0, 10) : '?';
  print(`  ${id} | ${f.type || '?'} | ${f.bytes || 0} bytes | uploaded ${created}`);
});
print('');

rule('Agents to change');
if (!plans.length) {
  print('  (none)');
}
plans.forEach((plan) => {
  const agent = agentById.get(plan.agentId);
  const current = plan.changes.filter((c) => !c.path.startsWith('versions.'));
  const versions = plan.changes.length - current.length;
  print(`  ${plan.agentId} "${agent.name}"`);
  current.forEach((c) => print(`      ${c.path}: ${c.before.length} → ${c.after.length} file(s)`));
  print(`      versions[]: ${versions} of ${(agent.versions || []).length} snapshot(s) also lose dead ids`);
});
print('');

const summary = summarize(plans);
rule('Summary');
print(`  Agents changed   : ${summary.agentsChanged}`);
print(`  Arrays changed   : ${summary.arraysChanged} (current tool_resources and version snapshots)`);
print(`  Ids removed      : ${summary.idsRemoved} references to ${verdict.dead.length} distinct file(s)`);
print('');

let modified = 0;
let remaining = null;

if (APPLY) {
  rule('Applying');
  plans.forEach((plan) => {
    const agent = agentById.get(plan.agentId);
    const set = {};
    plan.changes.forEach((c) => {
      set[c.path] = c.after;
    });
    // updatedAt in the filter: an agent edited since it was read is left alone
    // (mongosh writes do not touch updatedAt, so this only catches app edits).
    const res = db.agents.updateOne({ _id: agent._id, updatedAt: agent.updatedAt }, { $set: set });
    if (res.modifiedCount === 1) {
      modified += 1;
    } else {
      print(`  ✗ ${plan.agentId} changed while this ran; left alone`);
    }
  });
  print(`  ${modified} of ${plans.length} agent(s) updated.`);
  print('');

  rule('Verification');
  remaining = 0;
  db.agents.find({}, { id: 1, tool_resources: 1, versions: 1 }).forEach((agent) => {
    remaining += referencedFileIds(agent).filter((id) => dead.has(id)).length;
  });
  if (remaining === 0) {
    print('  ✓ no agent or version snapshot references a dead S3 file');
  } else {
    print(`  ✗ ${remaining} dead reference(s) remain.`);
  }
  print('');
} else {
  rule();
  print('  Nothing was changed. This was a dry run.');
  print('');
  print('      scripts/remove-dead-agent-files.sh --apply');
  rule();
  print('');
}

print('===CHANGELOG-JSON-BEGIN===');
print(
  JSON.stringify({
    timestamp: new Date().toISOString(),
    mode: MODE,
    applied: APPLY,
    agentsModified: modified,
    deadReferencesRemaining: remaining,
    headsSource: globalThis.HEADS_SOURCE,
    heads,
    summary,
    plans: plans.map((plan) => ({
      agentId: plan.agentId,
      name: agentById.get(plan.agentId).name,
      changes: plan.changes,
    })),
  }),
);
print('===CHANGELOG-JSON-END===');

if (APPLY && (modified !== plans.length || remaining !== 0)) {
  quit(1);
}
