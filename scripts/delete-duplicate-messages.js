/*
 * Delete the unfinished placeholder copy of each duplicated assistant message.
 *
 * ⚠️  Do not run this file directly. Run scripts/delete-duplicate-messages.sh,
 * which chooses dry-run or apply and writes the audit trail.
 *
 *     scripts/delete-duplicate-messages.sh             # dry run; changes nothing
 *     scripts/delete-duplicate-messages.sh --apply
 *
 * The rule, and why, is in lib/duplicate-message-cleanup.js, which has no
 * database in it and is unit-tested. This file is only the parts that need one.
 *
 * Inputs, injected by the wrapper via --eval before this file is loaded:
 *   globalThis.APPLY   true to delete; anything else is a dry run
 */

/* globals db, load, print, quit, globalThis */

'use strict';

load('/scripts/lib/duplicate-message-cleanup.js');

const { planGroup, describe, summarize } = globalThis.DuplicateMessageCleanup;

const APPLY = globalThis.APPLY === true;
const MODE = APPLY ? 'APPLY' : 'DRY RUN';

print('');
print('==========================================================================');
print(`  Duplicate message cleanup — ${MODE}`);
print('==========================================================================');
print('');

/*
 * The same key v0.8.8's unique index uses. A missing tenantId and a null one
 * collide in a unique index, and they group together here too.
 */
function findGroups() {
  return db.messages
    .aggregate(
      [
        {
          $group: {
            _id: { messageId: '$messageId', user: '$user', tenantId: '$tenantId' },
            n: { $sum: 1 },
            ids: { $push: '$_id' },
          },
        },
        { $match: { n: { $gt: 1 } } },
      ],
      { allowDiskUse: true },
    )
    .toArray();
}

/* --- Plan ---------------------------------------------------------------- */
const groups = findGroups();
print(`Messages        : ${db.messages.estimatedDocumentCount()}`);
print(`Duplicate keys  : ${groups.length}`);
print('');

const plans = groups.map((group) =>
  planGroup(group._id, db.messages.find({ _id: { $in: group.ids } }).toArray()),
);

/* --- Report -------------------------------------------------------------- */
print('--------------------------------------------------------------------------');
print('  Proposed deletions (unfinished copy; the finished copy is kept)');
print('--------------------------------------------------------------------------');
if (!plans.length) {
  print('  (none — no messageId appears more than once)');
}
plans
  .filter((plan) => !plan.unresolved)
  .forEach((plan) => {
    plan.remove.forEach((doc) => {
      const d = describe(doc);
      print(`  ${d.conversationId} | ${d.messageId} | created ${d.createdAt} | text ${d.textLength} chars, ${d.contentParts} parts`);
    });
  });

const unresolved = plans.filter((plan) => plan.unresolved);
if (unresolved.length) {
  print('');
  print('  ⚠️  UNRESOLVED — left untouched, and the tenant-index migration will fail on them:');
  unresolved.forEach((plan) => print(`      ${plan.key.messageId} (user ${plan.key.user}): ${plan.unresolved}`));
}
print('');

const summary = summarize(plans);
print('--------------------------------------------------------------------------');
print('  Summary');
print('--------------------------------------------------------------------------');
print(`  Duplicate keys   : ${summary.groups}`);
print(`  Copies to delete : ${summary.toRemove}`);
print(`  Unresolved keys  : ${summary.unresolved}`);
print('');

/* --- Apply --------------------------------------------------------------- */
let deleted = 0;
let remaining = null;

if (APPLY) {
  print('--------------------------------------------------------------------------');
  print('  Applying');
  print('--------------------------------------------------------------------------');

  plans.forEach((plan) => {
    plan.remove.forEach((doc) => {
      // Re-check the flag in the filter: a copy that was finished since the
      // plan was made is no longer a placeholder, and must not be deleted.
      deleted += db.messages.deleteOne({ _id: doc._id, unfinished: true }).deletedCount;
    });
  });
  print(`  ${deleted} message document(s) deleted.`);
  print('');

  /* --- Verify, in the same run -------------------------------------------- */
  print('--------------------------------------------------------------------------');
  print('  Verification');
  print('--------------------------------------------------------------------------');
  remaining = findGroups().length;
  if (remaining === 0) {
    print('  ✓ every { messageId, user, tenantId } is unique');
  } else {
    print(`  ✗ ${remaining} duplicate key(s) remain. The tenant-index migration will fail.`);
  }
  print('');
} else {
  print('--------------------------------------------------------------------------');
  print('  Nothing was changed. This was a dry run.');
  print('');
  print('      scripts/delete-duplicate-messages.sh --apply');
  print('--------------------------------------------------------------------------');
  print('');
}

print('===CHANGELOG-JSON-BEGIN===');
print(
  JSON.stringify({
    timestamp: new Date().toISOString(),
    mode: MODE,
    applied: APPLY,
    documentsDeleted: deleted,
    duplicateKeysRemaining: remaining,
    summary,
    plans: plans.map((plan) => ({
      key: { messageId: plan.key.messageId, user: String(plan.key.user), tenantId: plan.key.tenantId || null },
      unresolved: plan.unresolved,
      keep: plan.keep ? describe(plan.keep) : null,
      remove: plan.remove.map(describe),
    })),
  }),
);
print('===CHANGELOG-JSON-END===');

if (summary.unresolved > 0 || (APPLY && remaining !== 0)) {
  quit(1);
}
