/*
 * The decision logic for repairing agent CONTENT, with no database and no I/O in
 * it at all.
 *
 * Its sibling, lib/agent-model-migration.js, fixes which model an agent points
 * at. That can be derived from a rule. This cannot: the right instructions for an
 * agent are prose somebody wrote, so the only honest source is a recorded copy of
 * that prose. scripts/agent-content.json holds it.
 *
 * Two independent repairs, deliberately separable:
 *
 *   1. CONTENT — set instructions and tools on named agents. Applies only to the
 *      agents named in the data file.
 *
 *   2. DEAD TOOLS — remove tool names that no longer exist from every agent's
 *      tools[] and from every versions[] snapshot. Applies to all agents.
 *
 * Both are idempotent: a second run finds nothing to do. That is not a nicety —
 * this runs during a cutover, after a restore, possibly twice because somebody
 * lost track, and the failure mode of a non-idempotent repair at that moment is
 * unbounded.
 *
 * Loaded by scripts/repair-agent-content.js under mongosh, and required directly
 * by the tests under Node.
 */

'use strict';

/*
 * Decide what should happen to one agent.
 *
 * Returns a description of the work rather than doing it, so the same function
 * drives the dry run and the apply. There is no second code path that runs only
 * when writes are enabled.
 *
 *   {
 *     agentId, name,
 *     skipped: bool,
 *     changes: [ { field, from, to } ],
 *     set: { <mongo field path>: value }
 *   }
 */
function planContentRepair(agent, options) {
  const opts = options || {};
  const wanted = opts.content || null;
  const deadTools = opts.deadTools || [];

  const agentId = agent.id || (agent._id ? String(agent._id) : '(no id)');
  const name = agent.name || '(unnamed)';
  const changes = [];
  const set = {};

  const isDead = (tool) => deadTools.indexOf(tool) !== -1;

  /* --- 1. Recorded content ------------------------------------------------ */
  if (wanted) {
    if (typeof wanted.instructions === 'string' && agent.instructions !== wanted.instructions) {
      changes.push({
        field: 'instructions',
        // Lengths, not the text. These are thousands of characters of legal
        // correspondence guidance; printing them whole would bury every other
        // line of the dry run, which is the output a human is supposed to read.
        from: `${(agent.instructions || '').length} chars`,
        to: `${wanted.instructions.length} chars`,
      });
      set.instructions = wanted.instructions;
    }

    if (Array.isArray(wanted.tools) && !sameTools(agent.tools, wanted.tools)) {
      changes.push({
        field: 'tools',
        from: `${(agent.tools || []).length} tools`,
        to: `${wanted.tools.length} tools`,
      });
      set.tools = wanted.tools.slice();
    }
  }

  /*
   * --- 2. Dead tools ------------------------------------------------------
   *
   * Runs for every agent, including ones with recorded content — but only
   * against the tools that will actually be stored. Filtering the agent's
   * current tools when set.tools is about to replace them would compute a diff
   * against a value that is being thrown away, and could re-add a dead tool.
   */
  const effectiveTools = set.tools || agent.tools;
  if (Array.isArray(effectiveTools)) {
    const cleaned = effectiveTools.filter((tool) => !isDead(tool));
    if (cleaned.length !== effectiveTools.length) {
      const removed = effectiveTools.filter(isDead);
      changes.push({
        field: 'tools',
        from: `${effectiveTools.length} tools`,
        to: `${cleaned.length} tools (removed ${removed.join(', ')})`,
      });
      set.tools = cleaned;
    }
  }

  /*
   * Version history, for the same reason the model migration rewrites it: a
   * revert is one click away, and it must not restore a tool that no longer
   * exists. Instructions in history are left alone — those are a record of what
   * the author wrote, and rewriting them would be falsifying it rather than
   * fixing a dangling reference.
   */
  const versions = Array.isArray(agent.versions) ? agent.versions : [];
  versions.forEach((version, index) => {
    if (!version || !Array.isArray(version.tools)) {
      return;
    }
    const cleaned = version.tools.filter((tool) => !isDead(tool));
    if (cleaned.length !== version.tools.length) {
      const removed = version.tools.filter(isDead);
      changes.push({
        field: `versions[${index}].tools`,
        from: `${version.tools.length} tools`,
        to: `${cleaned.length} tools (removed ${removed.join(', ')})`,
      });
      set[`versions.${index}.tools`] = cleaned;
    }
  });

  return {
    agentId,
    name,
    skipped: changes.length === 0,
    changes,
    set,
  };
}

/* Order matters to LibreChat's UI, so a reordering is a real change. */
function sameTools(a, b) {
  const left = Array.isArray(a) ? a : [];
  const right = Array.isArray(b) ? b : [];
  if (left.length !== right.length) {
    return false;
  }
  return left.every((tool, index) => tool === right[index]);
}

/*
 * Refuse to run against a data file that cannot be right, rather than half
 * applying it. Every check here corresponds to a way the file has actually been
 * got wrong or plausibly could be.
 */
function validateContent(doc) {
  const problems = [];

  if (!doc || typeof doc !== 'object') {
    return ['agent-content.json did not parse to an object'];
  }

  const deadTools = doc.deadTools;
  if (deadTools !== undefined && !Array.isArray(deadTools)) {
    problems.push('deadTools must be an array when present');
  }

  const agents = doc.agents;
  if (!Array.isArray(agents)) {
    problems.push('agents must be an array');
    return problems;
  }

  const seen = {};
  agents.forEach((agent, index) => {
    const where = `agents[${index}]`;
    if (!agent || typeof agent !== 'object') {
      problems.push(`${where} is not an object`);
      return;
    }
    if (!agent.id) {
      problems.push(`${where} has no id — an agent is matched by id, not by name`);
    } else if (seen[agent.id]) {
      problems.push(`${where} repeats id ${agent.id}; the later entry would silently win`);
    } else {
      seen[agent.id] = true;
    }
    if (agent.instructions === undefined && agent.tools === undefined) {
      problems.push(`${where} (${agent.name || 'unnamed'}) sets neither instructions nor tools`);
    }
    if (agent.instructions !== undefined && typeof agent.instructions !== 'string') {
      problems.push(`${where} instructions must be a string`);
    }
    if (agent.tools !== undefined && !Array.isArray(agent.tools)) {
      problems.push(`${where} tools must be an array`);
    }
    /*
     * A recorded tool list that still contains a dead tool would be reinstated
     * and then stripped in the same run — which works, but means the file is
     * lying about the intended end state, and the next person to read it is
     * misled.
     */
    if (Array.isArray(agent.tools) && Array.isArray(deadTools)) {
      const dead = agent.tools.filter((tool) => deadTools.indexOf(tool) !== -1);
      if (dead.length) {
        problems.push(`${where} (${agent.name || 'unnamed'}) lists dead tool(s): ${dead.join(', ')}`);
      }
    }
  });

  return problems;
}

function summarize(plans) {
  const changed = plans.filter((plan) => !plan.skipped);
  return {
    agentsTotal: plans.length,
    agentsChanged: changed.length,
    agentsSkipped: plans.length - changed.length,
    fieldsChanged: changed.reduce((total, plan) => total + Object.keys(plan.set).length, 0),
  };
}

const api = { planContentRepair, sameTools, summarize, validateContent };

/* mongosh has no module system; Node does. Support both without branching. */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
}
if (typeof globalThis !== 'undefined') {
  globalThis.AgentContentRepair = api;
}
