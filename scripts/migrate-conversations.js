/*
 * Move conversations on retired models onto their successors.
 *
 * ⚠️  Do not run this file directly. Run scripts/migrate-conversations.sh, which
 * supplies the map, chooses the mode, and keeps the audit trail.
 *
 * mongosh, not Node, for the same reason as migrate-agent-models.js: it is
 * already inside the mongodb container, so nothing is installed at run time.
 * All decisions live in lib/conversation-migration.js, which is unit-tested;
 * this file only reads, prints and writes.
 *
 * Inputs, injected by the wrapper via --eval before this file is loaded:
 *   globalThis.CONVERSATION_MAP_RAW   conversation-map.json (plan and apply)
 *   globalThis.APPLY                  true to write; anything else is a dry run
 *   globalThis.REVERT_FILE            path inside the container of an apply
 *                                     audit trail to undo (revert mode)
 */

/* globals db, load, print, quit, globalThis, require */

'use strict';

load('/scripts/lib/conversation-migration.js');

const {
  parseConversationMap,
  validateConversationMap,
  planConversation,
  updateFor,
  revertFor,
  summarize,
} = globalThis.ConversationMigration;

const APPLY = globalThis.APPLY === true;
const REVERT_FILE = globalThis.REVERT_FILE || null;
const MODE = REVERT_FILE ? (APPLY ? 'REVERT' : 'REVERT DRY RUN') : APPLY ? 'APPLY' : 'DRY RUN';
const BATCH = 500;
const RECENT_DAYS = 30;

const rule = () =>
  print('--------------------------------------------------------------------------');

print('');
print('==========================================================================');
print(`  Conversation migration — ${MODE}`);
print('==========================================================================');
print('');

/* The audit trail goes out through stdout; the wrapper writes it to disk. */
function emitAudit(record) {
  print('===CHANGELOG-JSON-BEGIN===');
  print(JSON.stringify(record));
  print('===CHANGELOG-JSON-END===');
}

function bulkApply(ops) {
  let matched = 0;
  let modified = 0;
  for (let i = 0; i < ops.length; i += BATCH) {
    const batch = ops.slice(i, i + BATCH).map((op) => ({
      updateOne: { filter: op.filter, update: op.update },
    }));
    const result = db.conversations.bulkWrite(batch, { ordered: false });
    matched += result.matchedCount;
    modified += result.modifiedCount;
  }
  return { matched, modified };
}

/* ========================================================================= */
/* Revert                                                                    */
/* ========================================================================= */
if (REVERT_FILE) {
  const fs = require('fs');
  const audit = JSON.parse(fs.readFileSync(REVERT_FILE, 'utf8'));
  if (audit.mode !== 'APPLY' || !Array.isArray(audit.moves)) {
    print('ERROR: that file is not the audit trail of an --apply run. Nothing changed.');
    quit(2);
  }
  const ops = audit.moves.map(revertFor);
  print(`Audit trail     : ${audit.timestamp}, ${audit.moves.length} conversation(s) moved`);
  print('Each is put back only if it is still exactly where that run left it.');
  print('');

  let result = { matched: 0, modified: 0 };
  if (APPLY) {
    result = bulkApply(ops);
    print(`  ${result.modified} conversation(s) restored.`);
    print(`  ${ops.length - result.matched} skipped: changed since (a user picked another model).`);
  } else {
    const stillThere = ops.filter((op) => db.conversations.countDocuments(op.filter) > 0).length;
    print(`  ${stillThere} of ${ops.length} would be restored; the rest changed since.`);
    print('  Nothing was changed. Run with --apply to restore.');
  }
  print('');
  emitAudit({
    timestamp: new Date().toISOString(),
    mode: MODE,
    revertOf: audit.timestamp,
    matched: result.matched,
    modified: result.modified,
  });
  quit(0);
}

/* ========================================================================= */
/* Plan                                                                      */
/* ========================================================================= */
if (!globalThis.CONVERSATION_MAP_RAW) {
  print('ERROR: no map was supplied. Run scripts/migrate-conversations.sh.');
  quit(2);
}

let map;
try {
  map = parseConversationMap(globalThis.CONVERSATION_MAP_RAW);
} catch (error) {
  print(`ERROR: ${error.message}`);
  quit(2);
}
const problems = validateConversationMap(map);
if (problems.length) {
  print('ERROR: conversation-map.json is inconsistent:');
  problems.forEach((problem) => print(`  - ${problem}`));
  quit(2);
}

const endpoints = Object.keys(map.sources);
print(`Endpoints migrated : ${endpoints.join(', ')}`);
print('');

/*
 * Only the fields the plan needs. Titles and message lists stay in the
 * database: titles are user content, and nothing here needs them.
 */
const fields = { conversationId: 1, user: 1, endpoint: 1, model: 1, updatedAt: 1 };
Object.keys(map.targets).forEach((name) => {
  Object.keys(map.targets[name]).forEach((field) => {
    fields[field] = 1;
  });
});
const convos = db.conversations.find({ endpoint: { $in: endpoints } }, fields).toArray();
const byId = {};
convos.forEach((convo) => {
  byId[convo.conversationId] = convo;
});
print(`Conversations read : ${convos.length}`);

let plans;
try {
  plans = convos.map((convo) => planConversation(convo, map));
} catch (error) {
  print('');
  print('ERROR — nothing has been changed:');
  print(`  ${error.message}`);
  print('');
  quit(1);
}

const recentSince = new Date(Date.now() - RECENT_DAYS * 86400000);
const summary = summarize(plans, byId, recentSince);
const moves = plans.filter((plan) => plan.action === 'move');

rule();
print('  Proposed moves (next-turn model only; messages are never touched)');
rule();
const routes = Object.keys(summary.routes).sort();
if (!routes.length) {
  print('  (none — every conversation is on a model that stays)');
}
routes.forEach((route) => {
  const r = summary.routes[route];
  print(`  ${route}: ${r.count}  (${r.recent} used in the last ${RECENT_DAYS} days)`);
});
print('');
print(`  Conversations to move : ${summary.counts.move}`);
print(`  Already on a kept model: ${summary.counts.keep}`);
print('');

/* ========================================================================= */
/* Apply                                                                     */
/* ========================================================================= */
let result = { matched: 0, modified: 0 };
if (APPLY) {
  rule();
  print('  Applying');
  rule();
  result = bulkApply(moves.map(updateFor));
  print(`  ${result.modified} conversation(s) moved.`);
  if (result.matched < moves.length) {
    print(`  ${moves.length - result.matched} skipped: changed between reading and writing.`);
  }
  print('');

  /* Verify in the same run: nothing left on a migrated endpoint and model. */
  rule();
  print('  Verification');
  rule();
  let stragglers = 0;
  endpoints.forEach((endpoint) => {
    const mapped = Object.keys(map.sources[endpoint].map);
    const n = db.conversations.countDocuments({ endpoint, model: { $in: mapped } });
    stragglers += n;
    print(`  ${n === 0 ? '✓' : '✗'} ${endpoint}: ${n} conversation(s) still on a mapped model`);
  });
  print('');
  if (stragglers) {
    print('  Some conversations did not move. Re-run the dry run to see where they are.');
    print('');
  }
} else {
  rule();
  print('  Nothing was changed. This was a dry run.');
  print('  Compare the totals with what you expect, then:');
  print('      scripts/migrate-conversations.sh --apply');
  rule();
  print('');
}

emitAudit({
  timestamp: new Date().toISOString(),
  mode: MODE,
  applied: APPLY,
  matched: result.matched,
  modified: result.modified,
  map: globalThis.CONVERSATION_MAP_RAW,
  summary,
  // Everything --revert needs, and no titles.
  moves: moves.map((plan) => ({
    conversationId: plan.conversationId,
    user: plan.user,
    from: plan.from,
    target: plan.target,
    set: plan.set,
    unset: plan.unset,
    before: plan.before,
  })),
});
