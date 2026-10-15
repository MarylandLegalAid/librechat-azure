/*
 * Move conversations, saved presets and favorites on retired models onto their
 * successors.
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

/* globals db, load, print, quit, globalThis, require, ObjectId */

'use strict';

load('/scripts/lib/conversation-migration.js');

const {
  parseConversationMap,
  validateConversationMap,
  planConversation,
  planFavorites,
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

function bulkApply(ops, collection) {
  let matched = 0;
  let modified = 0;
  for (let i = 0; i < ops.length; i += BATCH) {
    const batch = ops.slice(i, i + BATCH).map((op) => ({
      updateOne: { filter: op.filter, update: op.update },
    }));
    const result = db[collection || 'conversations'].bulkWrite(batch, { ordered: false });
    matched += result.matchedCount;
    modified += result.modifiedCount;
  }
  return { matched, modified };
}

/*
 * Favorites are a whole array per user. Each write applies only while the array
 * is exactly what was read, so a user who changed their pins in between wins,
 * and a revert puts the old array back only over the one this run wrote.
 */
const favoriteOp = (userId, expected, replacement) => ({
  filter: { _id: userId, favorites: expected },
  update: { $set: { favorites: replacement } },
});
const describeFavorite = (fav) =>
  fav.spec ? `spec ${fav.spec}` : `${fav.endpoint} / ${fav.model}`;

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
  const presetOps = (audit.presetMoves || []).map(revertFor);
  const favoriteOps = (audit.favoriteMoves || []).map((f) =>
    favoriteOp(ObjectId(f.user), f.next, f.before));
  print(`Audit trail     : ${audit.timestamp}, ${audit.moves.length} conversation(s), ` +
    `${presetOps.length} preset(s), ${favoriteOps.length} user(s)' favorites moved`);
  print('Each is put back only if it is still exactly where that run left it.');
  print('');

  let result = { matched: 0, modified: 0 };
  const groups = [['conversations', ops], ['presets', presetOps], ['users', favoriteOps]];
  groups.forEach(([collection, group]) => {
    if (!group.length) return;
    if (APPLY) {
      const r = bulkApply(group, collection);
      result.matched += r.matched;
      result.modified += r.modified;
      print(`  ${collection}: ${r.modified} restored, ${group.length - r.matched} skipped (changed since).`);
    } else {
      const stillThere = group.filter((op) => db[collection].countDocuments(op.filter) > 0).length;
      print(`  ${collection}: ${stillThere} of ${group.length} would be restored; the rest changed since.`);
    }
  });
  if (!APPLY) print('  Nothing was changed. Run with --apply to restore.');
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

/* --- Saved presets: the same fields as a conversation, keyed by presetId --- */
const presetFields = Object.assign({ presetId: 1 }, fields);
delete presetFields.conversationId;
const presets = db.presets.find({ endpoint: { $in: endpoints } }, presetFields).toArray();
let presetPlans;
try {
  presetPlans = presets.map((preset) => planConversation(preset, map, { idField: 'presetId' }));
} catch (error) {
  print('');
  print('ERROR (presets) — nothing has been changed:');
  print(`  ${error.message}`);
  print('');
  quit(1);
}
const presetSummary = summarize(presetPlans);
const presetMoves = presetPlans.filter((plan) => plan.action === 'move');
rule();
print('  Saved presets');
rule();
Object.keys(presetSummary.routes).sort().forEach((route) => {
  print(`  ${route}: ${presetSummary.routes[route].count}`);
});
print(`  Presets to move: ${presetMoves.length} of ${presets.length} on migrated endpoints`);
print('');

/* --- Favorites pinned in the model selector ------------------------------ */
const favoriteUsers = db.users.find({ 'favorites.0': { $exists: true } }, { favorites: 1 }).toArray();
const favoriteMoves = [];
try {
  favoriteUsers.forEach((user) => {
    const plan = planFavorites(user.favorites, map);
    if (plan.changed) {
      favoriteMoves.push({ user: String(user._id), before: user.favorites, next: plan.next, changes: plan.changes });
    }
  });
} catch (error) {
  print('');
  print('ERROR (favorites) — nothing has been changed:');
  print(`  ${error.message}`);
  print('');
  quit(1);
}
rule();
print('  Favorites (agent favorites are never touched)');
rule();
const favoriteRoutes = {};
favoriteMoves.forEach((move) => move.changes.forEach((change) => {
  const key = `${describeFavorite(change.from)} -> ${change.to ? describeFavorite(change.to) : '(duplicate, dropped)'}`;
  favoriteRoutes[key] = (favoriteRoutes[key] || 0) + 1;
}));
Object.keys(favoriteRoutes).sort().forEach((key) => print(`  ${key}: ${favoriteRoutes[key]}`));
print(`  Users whose favorites change: ${favoriteMoves.length} of ${favoriteUsers.length}`);
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
  const presetResult = bulkApply(presetMoves.map(updateFor), 'presets');
  print(`  ${presetResult.modified} preset(s) moved.`);
  if (presetResult.matched < presetMoves.length) {
    print(`  ${presetMoves.length - presetResult.matched} preset(s) skipped: changed between reading and writing.`);
  }
  const favoriteResult = bulkApply(
    favoriteMoves.map((f) => favoriteOp(ObjectId(f.user), f.before, f.next)), 'users');
  print(`  ${favoriteResult.modified} user(s)' favorites updated.`);
  if (favoriteResult.matched < favoriteMoves.length) {
    print(`  ${favoriteMoves.length - favoriteResult.matched} skipped: favorites changed between reading and writing.`);
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
    const p = db.presets.countDocuments({ endpoint, model: { $in: mapped } });
    stragglers += p;
    print(`  ${p === 0 ? '✓' : '✗'} ${endpoint}: ${p} preset(s) still on a mapped model`);
    const f = db.users.countDocuments({ favorites: { $elemMatch: { endpoint, model: { $in: mapped } } } });
    stragglers += f;
    print(`  ${f === 0 ? '✓' : '✗'} ${endpoint}: ${f} user(s) with a favorite on a mapped model`);
  });
  const retiredSpecs = Object.keys(map.specs);
  if (retiredSpecs.length) {
    const fs2 = db.users.countDocuments({ favorites: { $elemMatch: { spec: { $in: retiredSpecs } } } });
    stragglers += fs2;
    print(`  ${fs2 === 0 ? '✓' : '✗'} ${fs2} user(s) with a favorite on a retired spec`);
  }
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
  presetMoves: presetMoves.map((plan) => ({
    conversationId: plan.conversationId,
    idField: plan.idField,
    user: plan.user,
    from: plan.from,
    target: plan.target,
    set: plan.set,
    unset: plan.unset,
    before: plan.before,
  })),
  favoriteMoves: favoriteMoves.map((f) => ({ user: f.user, before: f.before, next: f.next })),
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
