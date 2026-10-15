# Adding and retiring models

Most of this is a one-line change. The exception is retiring a model that agents point
at, which needs a migration.

## Adding a model

`env.defaults`:

```
ANTHROPIC_MODELS=claude-opus-5-5,claude-sonnet-5-5,claude-haiku-5-5
OPENAI_MODELS=gpt-6-luna,gpt-6.1-sol
```

Both are allowlists: the server refuses any model that is not listed, including in
requests the menu would never produce.

Add the identifier, commit, push. It appears in every user's dropdown within five
minutes.

Two things to check first:

1. **The identifier exists in your provider account.** A model absent from your
   account fails at request time, where users see it, not at startup where you would.
2. **Whether the model needs special routing.** Read
   [GPT-5.6 and the Responses API](models-gpt56-responses.md) — that page describes a
   real family of models that break in a specific way on the default endpoint, and
   the pattern for handling any model with its own API requirements.

!!! warning "`OPENAI_MODELS` holds GPT-6 models only, and is never empty"
    OpenAI models with tools need the Responses API. LibreChat v0.8.8 sends a model
    there by itself only when it is GPT-6 (`gpt-6…-astra`, `-sol` or `-luna`); any
    other OpenAI model goes to Chat Completions, where GPT-5.6, for one, fails as soon
    as a tool is used. `validate-config.sh` fails the build on a non-GPT-6 entry.

    Empty is worse. With `OPENAI_API_KEY` set, an unset or empty `OPENAI_MODELS`
    allows OpenAI's whole catalog, including models priced far above anything you
    chose. The build fails on that too.

    One case the routing doesn't cover: a conversation, preset or agent that stores
    `useResponsesApi: false` keeps Chat Completions. The migrations below clear it.

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
4. **Move the conversations forward** — [below](#moving-conversations-forward).
5. **Then** remove it from the model list.

!!! danger "Removing a model from the list does not stop old conversations using it"
    A conversation stores the endpoint and model its **next** turn will use. Remove
    the model from the list and one of two things happens to every thread still
    pointing at it:

    - **The server enforces that endpoint's list:** the thread fails with an error
      the next time somebody continues it.
    - **It doesn't:** the thread keeps quietly running the retired model.

    Maryland Legal Aid had both. Threads on retired Claude models failed. Threads on
    the deleted built-in `openAI` endpoint kept running GPT-5.4 and GPT-5.5 for ten
    weeks: 883 replies to 38 people. That endpoint's allowlist had become OpenAI's
    entire catalog, because `OPENAI_MODELS` was unset while `OPENAI_API_KEY` was
    still set.

    Check what the server actually accepts with `GET /api/models` as an ordinary
    user, not by looking at the menu.

**Messages are a different matter.** Each one records which model actually wrote it.
Never migrate those; rewriting them would be falsifying a record, not fixing a
configuration. Moving a conversation changes only the model its next turn uses.

## Migrating agents off a dropped model

### 1. Edit the mapping table

`scripts/model-map.json`:

```json
{
  "gpt-5.6-sol":     { "model": "gpt-6.1-sol",     "provider": "openAI" },
  "claude-opus-4-8": { "model": "claude-opus-5-5", "provider": "anthropic" }
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
      "claude-opus-5-5","claude-sonnet-5-5","claude-haiku-5-5",
      "gpt-6.1-sol","gpt-6-luna" ] } } }
])

// and none hiding in version history
db.agents.aggregate([
  { $unwind: "$versions" },
  { $group: { _id: "$versions.model", n: { $sum: 1 } } },
  { $match: { _id: { $nin: [ /* the same list */ ] } } }
])
```

Both must return empty.

## Moving conversations forward

`scripts/conversation-map.json` says, per endpoint, which models stay and where the
others go. Each target lists every field a moved conversation should end up with,
so it looks like a conversation the UI would have created on that model:

```json
"targets": {
  "gpt-6-luna": {
    "endpoint": "openAI", "endpointType": null,
    "model": "gpt-6-luna", "spec": "quick",
    "useResponsesApi": true, "maxContextTokens": 250000
  }
},
"sources": {
  "openAI": { "keep": ["gpt-6-luna", "gpt-6.1-sol"], "map": { "gpt-4.1": "gpt-6-luna" } }
}
```

Copy the target fields from a healthy conversation already on that model; don't
guess them. `maxContextTokens` especially: old conversations carry their old model's
limit, and Maryland Legal Aid's `gpt-4.1` threads carried 942,818 tokens, far more
than their successor accepts. `null` removes a field.

```bash
scripts/migrate-conversations.sh            # dry run: totals per route, and recent use
scripts/migrate-conversations.sh --apply    # asks for confirmation, writes, verifies
```

How the script behaves:

- **It never touches messages or `updatedAt`**, so nobody's sidebar reorders.
- **It prints no conversation titles.** They are user content and can name clients.
- **An unmapped model stops everything**, as with agents.
- **Each update applies only while the conversation is still where the dry run found
  it.** A user who changed model in between made the newer decision.
- **Saved presets and favorites move in the same run.** A preset has the same fields as
  a conversation, so the same targets apply. A favorite `{ endpoint, model }` follows the
  same table, and a favorite `{ spec }` follows the map's `specs` (retired spec → its
  successor). Favorites that land on the same successor are kept once. Agent favorites
  are never touched.
- **Endpoints not listed are never touched.** `agents` conversations follow their
  agent.

Every `--apply` keeps an audit trail on the data disk holding each changed field's old
value. `--revert <file> --apply` puts back every conversation still exactly where that
run left it.

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
model ships. That is exactly the swap the cheap tiers exist for. Both must be
models their endpoint lists, or they stop without an error; `validate-config.sh`
checks it.
