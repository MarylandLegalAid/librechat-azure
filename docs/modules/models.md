# Adding and retiring models

Most of this is a one-line change. The exception is retiring a model that agents point
at, which needs a migration.

## Adding a model

`env.defaults`:

```
ANTHROPIC_MODELS=claude-opus-5,claude-sonnet-5,claude-haiku-4-5
```

There is no `OPENAI_MODELS`. The built-in `openAI` endpoint was retired on
2026-07-30, so OpenAI models are listed on the custom endpoint in
`librechat.yaml` instead — see
[GPT-5.6 and the Responses API](models-gpt56-responses.md).

Add the identifier, commit, push. It appears in every user's dropdown within five
minutes.

Two things to check first:

1. **The identifier exists in your provider account.** A model absent from your
   account fails at request time, where users see it, not at startup where you would.
2. **Whether the model needs special routing.** Read
   [GPT-5.6 and the Responses API](models-gpt56-responses.md) — that page describes a
   real family of models that break in a specific way on the default endpoint, and
   the pattern for handling any model with its own API requirements.

!!! warning "Do not reintroduce `OPENAI_MODELS`"
    Setting it resurrects the built-in `openAI` endpoint, which does not force the
    Responses API — reintroducing a bug that only appears when a tool is used. OpenAI
    models belong on the custom endpoint in `librechat.yaml`. `validate-config.sh`
    fails the build if `OPENAI_MODELS` reappears. Read the page above first.

## Retiring a model

1. **Find out who is using it.** Removing a model that an agent depends on breaks
   that agent for its author with no warning.

    ```bash
    docker compose exec mongodb mongosh LibreChat --quiet --eval '
      db.agents.aggregate([
        { $group: { _id: { model: "$model", provider: "$provider" }, n: { $sum: 1 } } },
        { $sort: { n: -1 } }
      ]).forEach(printjson)'
    ```

2. **Give notice** if it is in active use.
3. **Migrate the agents** — below.
4. **Then** remove it from the model list.

Conversations and messages keep the model string they were created with. Do not
migrate those. They record which model actually produced each response; rewriting them
would be falsifying a record, not fixing a configuration.

## Migrating agents off a dropped model

### 1. Edit the mapping table

`scripts/model-map.json`:

```json
{
  "gpt-5.2": { "model": "gpt-5.6-terra", "provider": "OpenAI GPT-5.6 Responses" },
  "gpt-4.1": { "model": "gpt-5.6-luna",  "provider": "OpenAI GPT-5.6 Responses" }
}
```

Each row carries **both** the target model and the target provider. Spelling the
provider out per row rather than deriving it in code is what lets a human audit the
dry-run output without reading the script. It is also necessary: a model that moves to
a different endpoint changes provider as well as model.

!!! danger "The provider string must match byte for byte"
    It has to equal a built-in endpoint name or an `endpoints.custom[].name` in
    `librechat.yaml` exactly, spaces included. A mismatch fails at request time, not
    at startup.

    CI asserts this on every pull request. Let it.

**Mapping rule:** each retired model maps to its **same-tier** successor. Never map
down to save money and never map up to be generous — either is a change the agent's
author did not ask for and did not consent to.

### 2. Dry run

```bash
scripts/migrate-agent-models.sh --dry-run
```

Prints every proposed change as `agentId | name | field | old → new`, plus a summary
by target model. It changes nothing.

**Read it, and compare the totals against what you expect.** If they differ,
something is wrong with the script or your understanding of the data. Find out which
before applying.

### 3. Apply

```bash
scripts/migrate-agent-models.sh --apply
```

It asks for confirmation, writes the changes, runs the verification queries itself,
and saves a JSON audit trail to the data disk.

## What the migration touches, and why

| | |
|---|---|
| `agent.model` and `agent.provider` | The obvious part. |
| The same two fields in **every** `versions[]` entry | The part people miss. |

LibreChat keeps prior versions of an agent and lets a user revert to one. An untouched
snapshot brings a retired model back the instant somebody does. One agent on Maryland
Legal Aid's production carried **46 versions**, so this is the bulk of the write
volume, not an edge case.

Each version is mapped by **its own** model, not the agent's current one. Reverting to
an old version should give you that version's successor.

## Rules the script follows

- **Only agents whose current model is not approved are touched.** An agent already on
  an approved model is left completely alone, provider included.
- **An unmapped model stops everything.** Nothing is written, including for agents
  that would have migrated cleanly. A partial migration is harder to reason about and
  harder to re-run than none.
- **It is idempotent.** A second run reports zero changes.
- **It warns without acting** when a skipped agent has a retired model buried in its
  history. That case is left for a person, because the rule says leave those agents
  alone and the consequence of a revert says otherwise. Decide deliberately.

## Verify

The migration runs these itself, but they are worth knowing:

```javascript
// no agent on an unapproved model
db.agents.aggregate([
  { $group: { _id: "$model", n: { $sum: 1 } } },
  { $match: { _id: { $nin: [
      "claude-opus-5","claude-sonnet-5","claude-haiku-4-5",
      "gpt-5.6-sol","gpt-5.6-terra","gpt-5.6-luna" ] } } }
])

// and none hiding in version history
db.agents.aggregate([
  { $unwind: "$versions" },
  { $group: { _id: "$versions.model", n: { $sum: 1 } } },
  { $match: { _id: { $nin: [ /* the same list */ ] } } }
])
```

Both must return empty.

## Specialist models

These are not chat models and are not part of a model refresh.

| Setting | Where | Note |
|---|---|---|
| `EMBEDDINGS_MODEL` | `env.defaults` | ⚠️ **Frozen.** See below. |
| `speech.stt.openai.model` | `librechat.yaml` | Speech to text. |
| `IMAGE_GEN_OAI_MODEL` | `env.defaults` | Image generation. |
| `endpoints.openAI.titleModel` | `librechat.yaml` | Chat titles. Cheapest, fastest. |
| `memory.agent.model` | `librechat.yaml` | Personalization. Also cheap and fast. |

!!! danger "Never change `EMBEDDINGS_MODEL` casually"
    It invalidates every vector already stored. File chat does not error — it returns
    confident nonsense — until every document in the system has been re-uploaded.

    Changing it is a project with a re-embedding step, not a line edit.

The title and memory models are worth revisiting whenever a cheaper-and-comparable
model ships. That is exactly the swap the cheap tiers exist for. Both run on the
built-in `openAI` endpoint, which is one of the two reasons that endpoint stays
configured even though it is not user-selectable.
