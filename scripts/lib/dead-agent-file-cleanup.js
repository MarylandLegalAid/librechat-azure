/*
 * The decision logic for removing dead S3 files from agents, with no database
 * and no network in it at all.
 *
 * Why it is needed: v0.8.8 records which vector namespace holds each agent
 * file (`files.metadata.embeddedEntities`). A file embedded before v0.8.8 has
 * no such record, so on the agent's first file search v0.8.8 reads the
 * original from storage and embeds it again. If that read fails, the whole
 * tool call aborts ("Failed to provision N file(s) for search"), on every
 * turn. On v0.8.7 the same agent still searches its old vectors.
 *
 * Production on 2026-10-15: one agent ("Public Records Request Assistant -
 * WEB SEARCH") has 17 knowledge files with `source: s3`, and every one of them
 * is 404 in the bucket. They were uploaded under an earlier deployment and the
 * objects are gone. Decision (John, 2026-10-15): remove them from the agent.
 *
 * The rule:
 *
 *   - a file is DEAD when its `files` record says `source: 's3'` AND a HEAD of
 *     the object v0.8.8 would read returns 404. Both, every time: never a
 *     hard-coded list, and never "404" from anything but S3 itself;
 *   - any other HEAD outcome (403, a timeout, no credentials) is not an
 *     answer. The caller stops before changing anything;
 *   - dead ids are removed from every `tool_resources.<resource>.file_ids` of
 *     the agent AND of every `versions[]` snapshot. v0.8.8's "restore this
 *     version" copies a snapshot's tool_resources back verbatim, so a snapshot
 *     left alone would bring the dead ids straight back.
 *
 * What it does not touch: the `files` records themselves (other things, such
 * as old messages, may point at them), the vectors, and agents' `updatedAt`.
 *
 * Every change records the array before and after, so a revert can put it
 * back exactly, and only where nothing has changed it since.
 *
 * Loaded by scripts/remove-dead-agent-files.js under mongosh and by
 * scripts/head-s3-objects.js under Node, and required directly by the tests.
 */

'use strict';

/*
 * The S3 key v0.8.8 reads for a file record, mirroring upstream's
 * resolveStoredS3Key / extractKeyFromS3Url (packages/api/src/storage/s3/
 * crud.ts, v0.8.8) for AWS-hosted URLs. Returns null when it cannot be sure;
 * the caller treats that as "no answer", never as dead.
 */
function s3KeyFor(file, bucketName) {
  if (!file) {
    return null;
  }
  if (typeof file.storageKey === 'string' && file.storageKey) {
    return file.storageKey;
  }
  const ref = file.filepath;
  if (typeof ref !== 'string' || !ref) {
    return null;
  }
  if (!/^https?:\/\//.test(ref)) {
    return ref.startsWith('/') ? ref.substring(1) : ref;
  }

  let url;
  try {
    url = new URL(ref);
  } catch (e) {
    return null;
  }
  const host = url.hostname;
  const pathname = url.pathname.substring(1);
  if (!/(^|\.)amazonaws\.com$/.test(host)) {
    return null;
  }

  const pathStyle =
    host === 's3.amazonaws.com' ||
    /^s3[-.][a-z0-9-]+\.amazonaws\.com$/.test(host) ||
    (bucketName && pathname.startsWith(`${bucketName}/`));
  const raw = pathStyle ? pathname.substring(pathname.indexOf('/') + 1) : pathname;
  if (pathStyle && pathname.indexOf('/') < 1) {
    return null;
  }
  let key;
  try {
    key = decodeURIComponent(raw);
  } catch (e) {
    key = raw;
  }
  return key || null;
}

/*
 * One HEAD outcome → 'present' | 'missing' | 'error'. Only a 404 from S3 is
 * 'missing'. A 403 can mean "missing, but you may not list the bucket", which
 * is exactly the case that must not be guessed at.
 */
function classifyHead(httpStatus) {
  if (httpStatus === 200) {
    return 'present';
  }
  if (httpStatus === 404) {
    return 'missing';
  }
  return 'error';
}

/*
 * Every file_ids array on an agent, as { path, ids }. `path` is the dotted
 * Mongo path, so the same string addresses the array in an update and in a
 * revert. Version paths use the array index; versions are only ever appended,
 * so an index keeps meaning the same snapshot.
 */
function fileIdArrays(agent) {
  const arrays = [];
  const collect = (prefix, toolResources) => {
    if (!toolResources || typeof toolResources !== 'object') {
      return;
    }
    Object.keys(toolResources)
      .sort()
      .forEach((resource) => {
        const ids = toolResources[resource] && toolResources[resource].file_ids;
        if (Array.isArray(ids)) {
          arrays.push({ path: `${prefix}tool_resources.${resource}.file_ids`, ids });
        }
      });
  };
  collect('', agent.tool_resources);
  (Array.isArray(agent.versions) ? agent.versions : []).forEach((version, i) => {
    collect(`versions.${i}.`, version && version.tool_resources);
  });
  return arrays;
}

/* Every distinct file id an agent references, current or in any version. */
function referencedFileIds(agent) {
  const ids = new Set();
  fileIdArrays(agent).forEach(({ ids: list }) => list.forEach((id) => ids.add(id)));
  return Array.from(ids);
}

/*
 * What should change on one agent, given the set of dead file ids:
 *
 *   { agentId, changes: [{ path, before, after, removed }] }
 *
 * Arrays with no dead id are not listed. Order and duplicates of the ids that
 * stay are kept as they were.
 */
function planAgent(agent, deadIds) {
  const dead = deadIds instanceof Set ? deadIds : new Set(deadIds);
  const changes = [];
  fileIdArrays(agent).forEach(({ path, ids }) => {
    const after = ids.filter((id) => !dead.has(id));
    if (after.length !== ids.length) {
      changes.push({
        path,
        before: ids.slice(),
        after,
        removed: ids.filter((id) => dead.has(id)),
      });
    }
  });
  return { agentId: agent.id, changes };
}

/* Read a dotted path such as "versions.3.tool_resources.file_search.file_ids". */
function getPath(doc, path) {
  return path.split('.').reduce((value, part) => (value == null ? undefined : value[part]), doc);
}

function sameArray(a, b) {
  return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => x === b[i]);
}

/*
 * How to undo one agent's recorded changes. A path is restored only if it
 * still holds exactly what the apply left there; anything else has been
 * edited since, and is reported rather than overwritten.
 *
 *   { set: { path: before }, skipped: [{ path, reason }] }
 */
function planRevert(agent, entry) {
  const set = {};
  const skipped = [];
  entry.changes.forEach((change) => {
    const current = getPath(agent, change.path);
    if (sameArray(current, change.before)) {
      skipped.push({ path: change.path, reason: 'already restored' });
    } else if (sameArray(current, change.after)) {
      set[change.path] = change.before;
    } else {
      skipped.push({ path: change.path, reason: 'changed since the apply' });
    }
  });
  return { set, skipped };
}

/*
 * The HEAD results this run will act on, checked against the candidates:
 * every candidate must have exactly one recorded answer.
 *
 *   { dead: [file_id], present: [file_id], errors: [{ file_id, detail }] }
 */
function resolveHeads(candidateIds, heads) {
  const byId = new Map();
  (heads || []).forEach((head) => byId.set(head.file_id, head));
  const result = { dead: [], present: [], errors: [] };
  candidateIds.forEach((fileId) => {
    const head = byId.get(fileId);
    if (!head) {
      result.errors.push({ file_id: fileId, detail: 'no HEAD result recorded' });
    } else if (head.status === 'missing' && head.httpStatus === 404) {
      result.dead.push(fileId);
    } else if (head.status === 'present') {
      result.present.push(fileId);
    } else {
      result.errors.push({ file_id: fileId, detail: head.detail || `HTTP ${head.httpStatus}` });
    }
  });
  return result;
}

function summarize(plans) {
  const withChanges = plans.filter((plan) => plan.changes.length);
  return {
    agentsChanged: withChanges.length,
    arraysChanged: withChanges.reduce((n, plan) => n + plan.changes.length, 0),
    idsRemoved: withChanges.reduce(
      (n, plan) => n + plan.changes.reduce((m, change) => m + change.removed.length, 0),
      0,
    ),
  };
}

const api = {
  s3KeyFor,
  classifyHead,
  fileIdArrays,
  referencedFileIds,
  planAgent,
  planRevert,
  resolveHeads,
  summarize,
  getPath,
};

/* mongosh has no module system; Node does. Support both without branching. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
}
if (typeof globalThis !== 'undefined') {
  globalThis.DeadAgentFileCleanup = api;
}
