/*
 * The decision logic for removing duplicate assistant messages, with no
 * database and no I/O in it at all.
 *
 * Why duplicates exist: LibreChat saves an assistant reply twice while it
 * streams, once as an `unfinished: true` placeholder and once as the finished
 * reply, and v0.8.7 sometimes INSERTS the second save instead of updating the
 * first. The messages collection has no unique index in v0.8.7, so nothing
 * stops it. Production had 34 such pairs on 2026-10-15, spread from March to
 * September, and they keep appearing.
 *
 * Why it matters now: v0.8.8's tenant-index migration builds a unique index on
 * { messageId, user, tenantId }. One duplicate fails it with E11000, and the
 * upgrade cannot proceed until every pair is resolved.
 *
 * What users see today: both copies, as two "versions" of the same reply. The
 * finished copy sorts last and is shown by default; the arrow back shows the
 * placeholder, often half-streamed. Follow-up turns hang off the finished
 * copy. Removing the placeholder therefore removes only the stray "1 / 2"
 * switcher. (Verified on staging, 2026-10-15.)
 *
 * The rule, for each { messageId, user, tenantId } with more than one document:
 *
 *   - exactly one copy is finished (unfinished is not true) → delete every
 *     unfinished copy, keep the finished one;
 *   - anything else (no finished copy, or two finished copies) → UNRESOLVED.
 *     Nothing in that group is touched; the caller reports it and fails,
 *     because the migration will fail on it too and a human has to decide.
 *
 * Idempotent: once applied, there are no groups left, so a second run plans
 * nothing.
 *
 * Loaded by scripts/delete-duplicate-messages.js under mongosh, and required
 * directly by the tests under Node.
 */

'use strict';

/*
 * Decide what should happen to one group of documents that share a key.
 *
 *   { key, keep: doc|null, remove: [doc], unresolved: reason|null }
 */
function planGroup(key, docs) {
  const finished = docs.filter((doc) => doc.unfinished !== true);
  const unfinished = docs.filter((doc) => doc.unfinished === true);

  if (docs.length < 2) {
    return { key, keep: docs[0] || null, remove: [], unresolved: null };
  }
  if (finished.length === 1) {
    return { key, keep: finished[0], remove: unfinished, unresolved: null };
  }
  return {
    key,
    keep: null,
    remove: [],
    unresolved:
      finished.length === 0
        ? `no finished copy among ${docs.length}`
        : `${finished.length} finished copies among ${docs.length}`,
  };
}

/*
 * What the audit trail records about one document: enough to find it in a
 * backup and to see why it was chosen, and no message content. These are
 * client conversations.
 */
function describe(doc) {
  const content = Array.isArray(doc.content) ? doc.content : [];
  return {
    _id: doc._id === undefined ? null : String(doc._id),
    messageId: doc.messageId,
    conversationId: doc.conversationId,
    user: doc.user === undefined ? null : String(doc.user),
    unfinished: doc.unfinished === true,
    createdAt: doc.createdAt instanceof Date ? doc.createdAt.toISOString() : doc.createdAt || null,
    textLength: typeof doc.text === 'string' ? doc.text.length : 0,
    contentParts: content.length,
    tokenCount: doc.tokenCount || 0,
  };
}

function summarize(plans) {
  return {
    groups: plans.length,
    toRemove: plans.reduce((n, plan) => n + plan.remove.length, 0),
    unresolved: plans.filter((plan) => plan.unresolved).length,
  };
}

const api = { planGroup, describe, summarize };

/* mongosh has no module system; Node does. Support both without branching. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
}
if (typeof globalThis !== 'undefined') {
  globalThis.DuplicateMessageCleanup = api;
}
