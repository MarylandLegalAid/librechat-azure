/*
 * The decision logic for moving conversations forward onto current models, with
 * no database and no I/O in it at all.
 *
 * Why conversations need moving at all: a conversation stores the endpoint and
 * model its NEXT turn will use. When a model is retired, every conversation
 * still pointing at it either fails when continued (if the server enforces its
 * model list) or keeps quietly running the retired model (if it does not —
 * which is how the deleted built-in `openAI` endpoint kept serving gpt-5.4 for
 * months). Moving the conversation's next-turn model to the same-tier successor
 * fixes both.
 *
 * What it never touches: messages. Each message records which model actually
 * wrote it. Rewriting that would be falsifying a record, not fixing
 * configuration — the same rule the agent migration follows for history.
 *
 * Kept pure so it can be tested against fixtures — see
 * scripts/test/conversation-migration.test.js. Loaded by
 * scripts/migrate-conversations.js under mongosh, and required directly by the
 * tests under Node.
 */

'use strict';

/*
 * Turn conversation-map.json into the shape the rest of the code uses, dropping
 * documentation keys and rejecting anything malformed. The map is:
 *
 *   targets: { <name>: { <conversation field>: <value or null>, ... } }
 *   sources: { <endpoint>: { keep: [<model>...], map: { <model>: <target name> } } }
 *   specs:   { <retired modelSpecs name>: <its successor's name> }   (optional)
 *
 * A target lists every field a moved conversation should end up with. `null`
 * means "remove this field". `endpoint` and `model` are required, because they
 * are what makes a conversation reach its new model at all.
 */
function parseConversationMap(raw) {
  if (!raw || typeof raw !== 'object') {
    throw new Error('conversation-map.json: expected an object.');
  }
  const targets = {};
  const sources = {};

  Object.keys(raw.targets || {}).forEach((name) => {
    if (name.indexOf('_') === 0) return;
    const target = raw.targets[name];
    if (!target || typeof target.endpoint !== 'string' || typeof target.model !== 'string') {
      throw new Error(`conversation-map.json: target "${name}" needs an "endpoint" and a "model".`);
    }
    targets[name] = Object.assign({}, target);
  });

  Object.keys(raw.sources || {}).forEach((endpoint) => {
    if (endpoint.indexOf('_') === 0) return;
    const source = raw.sources[endpoint] || {};
    const keep = Array.isArray(source.keep) ? source.keep.slice() : [];
    const map = {};
    Object.keys(source.map || {}).forEach((model) => {
      if (model.indexOf('_') === 0) return;
      map[model] = source.map[model];
    });
    sources[endpoint] = { keep, map };
  });

  const specs = {};
  Object.keys(raw.specs || {}).forEach((name) => {
    if (name.indexOf('_') === 0) return;
    specs[name] = raw.specs[name];
  });

  return { targets, sources, specs };
}

/*
 * Everything that can be wrong with a map without looking at any data. Returns
 * a list of problems; empty means usable.
 */
function validateConversationMap(map) {
  const problems = [];
  Object.keys(map.sources).forEach((endpoint) => {
    const source = map.sources[endpoint];
    Object.keys(source.map).forEach((model) => {
      const targetName = source.map[model];
      if (!map.targets[targetName]) {
        problems.push(`${endpoint} / ${model} maps to "${targetName}", which is not a defined target`);
      }
      if (source.keep.indexOf(model) !== -1) {
        problems.push(`${endpoint} / ${model} is both kept and mapped`);
      }
    });
  });
  /*
   * A target that lands on a source endpoint with a model that endpoint would
   * itself migrate again is a loop: the second run would move it a second time,
   * and the migration would never settle.
   */
  Object.keys(map.targets).forEach((name) => {
    const target = map.targets[name];
    const landing = map.sources[target.endpoint];
    if (landing && landing.keep.indexOf(target.model) === -1) {
      problems.push(
        `target "${name}" lands on ${target.endpoint} / ${target.model}, which that ` +
          `endpoint does not keep — the conversation would be moved again on the next run`,
      );
    }
  });
  return problems;
}

/* The marker for "this field was absent", which JSON cannot otherwise express. */
const ABSENT = { absent: true };

function snapshot(doc, fields) {
  const before = {};
  fields.forEach((field) => {
    before[field] = Object.prototype.hasOwnProperty.call(doc, field) ? doc[field] : ABSENT;
  });
  return before;
}

const sameValue = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/*
 * Decide what should happen to one conversation.
 *
 * Returns a plain description of the work so the same function drives the dry
 * run and the apply:
 *
 *   { conversationId, user, action: 'ignore' | 'keep' | 'move',
 *     from: { endpoint, model }, target, set, unset, before }
 *
 *   ignore — its endpoint is not one this map migrates (agents, for example,
 *            follow their agent and are handled by the agent migration)
 *   keep   — on a migrated endpoint, already on a model that stays
 *   move   — rewrite `set` / `unset`; `before` holds the old values for revert
 *
 * Throws on a model with no mapping on a migrated endpoint. Refusing to guess is
 * the point: a skipped conversation keeps pointing at a retired model, and the
 * failure surfaces to a user rather than to whoever ran this.
 *
 * Deliberately NOT returned: the conversation's title. Titles are user content
 * and can name clients; nothing this tool prints or keeps needs them.
 */
/*
 * Saved presets have the same fields as a conversation (endpoint, model, spec,
 * parameters), so the same planner moves them; only the key differs. Pass
 * { idField: 'presetId' } for a preset. The plan keeps the name of the key it
 * used, under `idField`, so updates and reverts address the right document.
 */
function planConversation(convo, map, options) {
  const idField = (options && options.idField) || 'conversationId';
  const conversationId = convo[idField] || (convo._id ? String(convo._id) : '(no id)');
  const user = convo.user ? String(convo.user) : null;
  const from = { endpoint: convo.endpoint, model: convo.model };
  const base = { conversationId, user, from };
  if (idField !== 'conversationId') base.idField = idField;

  const source = map.sources[convo.endpoint];
  if (!source) {
    return Object.assign(base, { action: 'ignore' });
  }
  if (source.keep.indexOf(convo.model) !== -1) {
    return Object.assign(base, { action: 'keep' });
  }

  const targetName = source.map[convo.model];
  if (!targetName) {
    throw new Error(
      `Conversation ${conversationId} is on ${convo.endpoint} / ${convo.model}, which ` +
        `conversation-map.json neither keeps nor maps. Add a row for it. Refusing to guess.`,
    );
  }

  const target = map.targets[targetName];
  const set = {};
  const unset = [];
  Object.keys(target).forEach((field) => {
    const value = target[field];
    if (value === null) {
      if (Object.prototype.hasOwnProperty.call(convo, field)) unset.push(field);
    } else if (!sameValue(convo[field], value)) {
      set[field] = value;
    }
  });

  return Object.assign(base, {
    action: 'move',
    target: targetName,
    set,
    unset,
    before: snapshot(convo, Object.keys(set).concat(unset)),
  });
}

/*
 * The update for one planned move, guarded so it applies only while the
 * conversation is still where the plan found it. A user who changed model in
 * the meantime made a newer decision than this script, and it wins.
 */
function updateFor(plan) {
  const update = {};
  if (Object.keys(plan.set).length) update.$set = plan.set;
  if (plan.unset.length) {
    update.$unset = {};
    plan.unset.forEach((field) => {
      update.$unset[field] = '';
    });
  }
  const filter = {};
  filter[plan.idField || 'conversationId'] = plan.conversationId;
  filter.endpoint = plan.from.endpoint;
  filter.model = plan.from.model;
  return { filter, update };
}

/*
 * The inverse of one applied move, from the audit trail. Guarded the same way:
 * only a conversation still exactly where the migration left it is put back.
 */
function revertFor(entry) {
  const after = Object.assign({}, entry.from, entry.set);
  const filter = {};
  filter[entry.idField || 'conversationId'] = entry.conversationId;
  ['endpoint', 'model'].forEach((field) => {
    filter[field] = after[field];
  });

  const update = {};
  Object.keys(entry.before).forEach((field) => {
    const value = entry.before[field];
    if (value && value.absent === true) {
      update.$unset = update.$unset || {};
      update.$unset[field] = '';
    } else {
      update.$set = update.$set || {};
      update.$set[field] = value;
    }
  });
  return { filter, update };
}

/*
 * Roll plans into the totals reviewed before anyone types --apply.
 * `recentSince` is a Date: conversations updated after it are counted as recent,
 * because a recently used thread is the one somebody will notice.
 */
function summarize(plans, convosById, recentSince) {
  const routes = {};
  const counts = { ignore: 0, keep: 0, move: 0 };

  plans.forEach((plan) => {
    counts[plan.action] += 1;
    if (plan.action !== 'move') return;
    const key = `${plan.from.endpoint} / ${plan.from.model} -> ${plan.target}`;
    routes[key] = routes[key] || { count: 0, recent: 0 };
    routes[key].count += 1;
    const convo = convosById ? convosById[plan.conversationId] : null;
    if (recentSince && convo && convo.updatedAt && new Date(convo.updatedAt) > recentSince) {
      routes[key].recent += 1;
    }
  });

  return { total: plans.length, counts, routes };
}

/*
 * A user's favorites: the models, specs and agents pinned in the model selector.
 * Each entry is { agentId }, { spec } or { endpoint, model }. A favorite on a
 * retired model or spec would sit in the menu pointing at something that no
 * longer exists, so it moves the way a conversation would:
 *
 *   { endpoint, model } — through `sources`, to the target's endpoint and model
 *   { spec }            — through `specs`, to the successor spec
 *   { agentId }         — never touched; the agent itself is migrated
 *
 * Moving two favorites onto the same successor would pin it twice, so the
 * second copy is dropped. An unmapped model on a migrated endpoint throws, as
 * for conversations; an unknown spec that is not being retired is left alone.
 *
 * Returns { changed, next, changes: [ { from, to } ] }; `to` is null for a
 * dropped duplicate.
 */
function planFavorites(favorites, map) {
  const next = [];
  const changes = [];
  const seen = {};
  const keyOf = (fav) => JSON.stringify(
    Object.keys(fav).sort().reduce((acc, k) => { acc[k] = fav[k]; return acc; }, {}),
  );

  (Array.isArray(favorites) ? favorites : []).forEach((fav) => {
    let moved = fav;
    if (fav && typeof fav.spec === 'string' && map.specs[fav.spec]) {
      moved = Object.assign({}, fav, { spec: map.specs[fav.spec] });
    } else if (fav && typeof fav.endpoint === 'string' && typeof fav.model === 'string') {
      const source = map.sources[fav.endpoint];
      if (source && source.keep.indexOf(fav.model) === -1) {
        const targetName = source.map[fav.model];
        if (!targetName) {
          throw new Error(
            `A favorite is on ${fav.endpoint} / ${fav.model}, which conversation-map.json ` +
              `neither keeps nor maps. Add a row for it. Refusing to guess.`,
          );
        }
        const target = map.targets[targetName];
        moved = Object.assign({}, fav, { endpoint: target.endpoint, model: target.model });
      }
    }
    const key = keyOf(moved);
    if (seen[key]) {
      changes.push({ from: fav, to: null });
      return;
    }
    seen[key] = true;
    if (moved !== fav) changes.push({ from: fav, to: moved });
    next.push(moved);
  });

  return { changed: changes.length > 0, next, changes };
}

const exported = {
  ABSENT,
  planFavorites,
  parseConversationMap,
  validateConversationMap,
  planConversation,
  updateFor,
  revertFor,
  summarize,
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = exported;
}

/* mongosh's load() has no module system; see agent-model-migration.js. */
if (typeof globalThis !== 'undefined') {
  globalThis.ConversationMigration = exported;
}
