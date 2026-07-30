/*
 * The decision logic for the agent model migration, with no database and no I/O
 * in it at all.
 *
 * It lives apart from the runner for one reason: this is the part that can be
 * wrong in ways nobody notices until a user reverts an agent to an old version
 * six months from now. Keeping it pure means it can be tested exhaustively
 * against fixtures — see scripts/test/agent-model-migration.test.js — instead of
 * being tested by running it against production and looking at the output.
 *
 * Loaded by scripts/migrate-agent-models.js under mongosh, and required
 * directly by the tests under Node.
 */

'use strict';

/*
 * Every model a user is allowed to select. An agent already pointing at one of
 * these is finished, whatever else is true about it.
 */
const APPROVED_MODELS = [
  'claude-opus-5',
  'claude-sonnet-5',
  'claude-haiku-4-5',
  'gpt-5.6-sol',
  'gpt-5.6-terra',
  'gpt-5.6-luna',
];

/*
 * Decide what should happen to one agent.
 *
 * Returns a plain description of the work rather than doing it, so the same
 * function drives both the dry run and the apply. There is no second code path
 * that only executes when writes are enabled — the dry run exercises exactly the
 * logic that --apply will use.
 *
 *   {
 *     agentId, name,
 *     skipped: bool,          // already on an approved model
 *     changes: [ { field, from, to } ],
 *     warnings: [ string ],
 *     set: { <mongo field path>: value }
 *   }
 *
 * Throws on a model with no mapping. Silently skipping an unmapped model is the
 * one behaviour that must never happen: it leaves an agent pointing at a model
 * that no longer exists, and the failure surfaces to a user rather than to us.
 */
function planAgentChanges(agent, options) {
  const opts = options || {};
  const approved = opts.approved || APPROVED_MODELS;
  const map = opts.map || {};

  const agentId = agent.id || (agent._id ? String(agent._id) : '(no id)');
  const name = agent.name || '(unnamed)';
  const changes = [];
  const warnings = [];
  const set = {};

  const isApproved = (model) => approved.indexOf(model) !== -1;

  const lookup = (model, where) => {
    const entry = map[model];
    if (!entry) {
      throw new Error(
        `Agent ${agentId} (${name}) uses model "${model}" at ${where}, which is ` +
          `neither approved nor present in model-map.json. Add a mapping for it ` +
          `— or decide it should keep that model and add it to the approved list. ` +
          `Refusing to guess.`,
      );
    }
    return entry;
  };

  /*
   * The gate on the AGENT ITSELF is its top-level model, and only that. An agent
   * already on an approved model keeps that model and its provider.
   *
   * Its HISTORY is a separate question, and is handled below regardless. An
   * agent can sit on an approved model while its snapshots do not: "Referral
   * Bot" on production carried 22 versions referencing gpt-5-mini, gpt-5.4 and
   * gpt-5.4-mini. Leaving those alone would fail the verification query, which
   * §11.3 requires to come back empty for versions[].model as well, and would
   * leave a revert one click away from a model that no longer exists — with one
   * snapshot pointing gpt-5.4 at openAI, which cannot serve it.
   *
   * 2026-07-30: gpt-5.4-nano was removed from the approved list when the
   * built-in `openAI` endpoint was deleted, so the five agents that sat on it
   * are now migration targets like any other. Nothing in this function needed to
   * change for that — the approved list is the whole gate, which is the point of
   * keeping the decision data-driven.
   */
  const topLevelUnchanged = isApproved(agent.model);

  /* --- The agent itself --------------------------------------------------- */
  if (!topLevelUnchanged) {
    const target = lookup(agent.model, 'model');

    changes.push({ field: 'model', from: agent.model, to: target.model });
    set.model = target.model;

    if (agent.provider !== target.provider) {
      changes.push({ field: 'provider', from: agent.provider, to: target.provider });
      set.provider = target.provider;
    }
  }

  /* --- Every version snapshot --------------------------------------------- */
  /*
   * LibreChat keeps prior versions of an agent and lets a user revert to one.
   * An untouched snapshot resurfaces a retired model — and now a retired
   * provider — the instant somebody does that. The sample agent inspected on
   * production carried 46 versions, so this is the bulk of the write volume, not
   * an edge case.
   *
   * Each version is mapped by ITS OWN model, not the agent's current one. A
   * version that predates the current model had a different one, and rewriting
   * every snapshot to the agent's newest target would silently rewrite history
   * rather than repair it.
   */
  (agent.versions || []).forEach((version, index) => {
    if (!version || !version.model || isApproved(version.model)) {
      return;
    }

    const versionTarget = lookup(version.model, `versions[${index}].model`);

    changes.push({
      field: `versions[${index}].model`,
      from: version.model,
      to: versionTarget.model,
    });
    set[`versions.${index}.model`] = versionTarget.model;

    if (version.provider !== versionTarget.provider) {
      changes.push({
        field: `versions[${index}].provider`,
        from: version.provider,
        to: versionTarget.provider,
      });
      set[`versions.${index}.provider`] = versionTarget.provider;
    }
  });

  /*
   * `skipped` means nothing at all was planned — not merely that the top-level
   * model was already fine. An agent whose history alone needed repair is a
   * changed agent, and counting it as skipped would hide exactly the work this
   * pass exists to do.
   */
  return {
    agentId,
    name,
    skipped: changes.length === 0,
    historyOnly: topLevelUnchanged && changes.length > 0,
    changes,
    warnings,
    set,
  };
}

/*
 * Roll a set of plans into the summary that gets compared against the expected
 * distribution before anyone types --apply.
 */
function summarize(plans) {
  const byTarget = {};
  let agentsChanged = 0;
  let agentsSkipped = 0;
  let agentsHistoryOnly = 0;
  let fieldsChanged = 0;

  plans.forEach((plan) => {
    if (plan.skipped) {
      agentsSkipped += 1;
      return;
    }
    agentsChanged += 1;
    // Reported separately so the headline can be compared against the migration
    // plan's expected count without the two silently disagreeing: the plan
    // predicts agents whose CURRENT model moves, and a history-only repair is
    // not one of those.
    if (plan.historyOnly) agentsHistoryOnly += 1;
    fieldsChanged += plan.changes.length;

    const modelChange = plan.changes.filter((c) => c.field === 'model')[0];
    if (modelChange) {
      const key = modelChange.to;
      byTarget[key] = byTarget[key] || { count: 0, from: {} };
      byTarget[key].count += 1;
      byTarget[key].from[modelChange.from] = (byTarget[key].from[modelChange.from] || 0) + 1;
    }
  });

  return {
    agentsTotal: plans.length,
    agentsChanged,
    agentsSkipped,
    agentsHistoryOnly,
    fieldsChanged,
    byTarget,
  };
}

/*
 * Strip the documentation keys out of model-map.json so the rest of the code
 * never has to think about them.
 */
function parseModelMap(raw) {
  const map = {};
  Object.keys(raw).forEach((key) => {
    if (key.indexOf('_') === 0) {
      return;
    }
    const entry = raw[key];
    if (!entry || typeof entry.model !== 'string' || typeof entry.provider !== 'string') {
      throw new Error(
        `model-map.json: entry "${key}" must have both a "model" and a "provider" string.`,
      );
    }
    map[key] = { model: entry.model, provider: entry.provider };
  });
  return map;
}

/*
 * A mapping whose target is not itself approved would move an agent from one
 * retired model to another, and the verification query would still fail. Catch
 * that when the map is loaded rather than after the writes.
 */
function validateModelMap(map, approved) {
  const list = approved || APPROVED_MODELS;
  const problems = [];
  Object.keys(map).forEach((from) => {
    if (list.indexOf(map[from].model) === -1) {
      problems.push(`"${from}" maps to "${map[from].model}", which is not in the approved list`);
    }
    if (list.indexOf(from) !== -1) {
      problems.push(`"${from}" is in the approved list and must not also be a migration source`);
    }
  });
  return problems;
}

const exported = {
  APPROVED_MODELS,
  planAgentChanges,
  summarize,
  parseModelMap,
  validateModelMap,
};

/* Node (the tests) uses module.exports. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = exported;
}

/*
 * mongosh's load() has no module system, and `const` declarations inside a
 * loaded file do not reliably reach the calling scope. Hanging the exports off
 * globalThis under one name is what makes the runner able to see them.
 */
if (typeof globalThis !== 'undefined') {
  globalThis.AgentModelMigration = exported;
}
