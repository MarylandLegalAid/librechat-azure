// Clear the "already indexed" flags so LibreChat rebuilds conversation search.
//
//     docker compose exec -T mongodb mongosh LibreChat --quiet --file /scripts/reset-meili-flags.js
//
// Run by scripts/restore.sh after every restore. Safe to run at any time; the
// worst it does is make the next api start re-send everything to Meilisearch.
//
// Why it is needed: LibreChat's indexSync does not ask Meilisearch what it
// holds. It reads a `_meiliIndex` flag on each MongoDB document, and a restored
// dump carries `true` on every document, because those documents really were
// indexed, in the SOURCE machine's Meilisearch. The target then believes its
// index is complete, skips the sync, and search stays empty with nothing in any
// log.
//
// With every flag false, indexSync sees "none indexed" and forces a full sync,
// regardless of MEILI_SYNC_THRESHOLD. It only runs at api startup, so the api
// must be (re)started afterwards.
//
// Expired and temporary conversations are skipped on purpose: indexSync skips
// them too, and MongoDB's TTL deletes them shortly afterwards.

const retention = {
  $or: [
    { isTemporary: false, expiredAt: null },
    { isTemporary: false, expiredAt: { $gt: new Date() } },
    { isTemporary: null, expiredAt: null },
  ],
};

for (const name of ['messages', 'conversations']) {
  const result = db
    .getCollection(name)
    .updateMany(Object.assign({}, retention, { _meiliIndex: { $ne: false } }), {
      $set: { _meiliIndex: false },
    });
  print('  ' + name + ': flags cleared on ' + result.modifiedCount + ' document(s)');
}
