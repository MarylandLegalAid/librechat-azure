# GPT-5.6 and the Responses API

**This is the least obvious thing in this repository.** It is also a worked example of
provider-specific routing, which is why it gets its own page rather than a footnote:
if you adopt a model family with its own API requirements, this is the shape of the
solution.

If you are here because you were about to tidy up the model configuration and
something told you to read this first — please do read it. The arrangement looks
redundant and is not.

## The problem

The GPT-5.6 family **rejects requests that combine reasoning with function tools on
`/v1/chat/completions`**. Those models expect the newer `/v1/responses` API when tools
are involved.

LibreChat's built-in `openAI` endpoint uses chat completions by default. So GPT-5.6
works fine through it right up until a tool is used — which is most of what an agent
does, and quite a lot of what an ordinary chat does once web search or file chat is
switched on.

The failure has three properties that make it worse than it sounds:

- **It does not fail at startup.** Configuration validation passes. The application is
  healthy. The model appears in the dropdown.
- **It does not fail on a simple message.** "Hello" works perfectly. Only a request
  that actually carries tools fails.
- **It surfaces to users, not to you.** The first you hear of it is somebody saying
  the AI stopped working.

We hit this in production. The fix below is proven; it is not theoretical.

!!! note "Upgrading LibreChat will not fix this for you"
    Confirmed against the v0.8.7 source: `useResponsesApi` is auto-enabled **only**
    when web search is on
    (`packages/api/src/endpoints/openai/llm.ts`). There is no
    model-name-based detection. Re-check when you upgrade, but do not assume.

## The fix

Three parts. They only work together, and removing any one of them silently
reintroduces the bug.

### 1. A dedicated endpoint that forces the Responses API

In `librechat.yaml`:

```yaml
endpoints:
  # No `openAI:` block. The built-in endpoint was retired on 2026-07-30 — see
  # part 2 below. Titles and the memory agent moved onto the custom endpoint.
  custom:
    - name: "OpenAI GPT-5.6 Responses"
      apiKey: "${OPENAI_API_KEY}"
      baseURL: "https://api.openai.com/v1"
      models:
        default: ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]
        fetch: false
      titleConvo: true                # MUST be true — see "Titles" below
      titleModel: "gpt-5.6-luna"
      summarize: false
      modelDisplayLabel: "OpenAI"
      addParams:
        useResponsesApi: true
```

`addParams` is applied **server-side**. A client that submits
`useResponsesApi: false` gets the Responses API anyway. That is the property that
makes this policy rather than a default.

### 2. The built-in `openAI` endpoint does not exist

`env.defaults` sets no `OPENAI_MODELS` at all, and `librechat.yaml` declares no
`endpoints.openAI`.

This used to be a weaker rule: the endpoint stayed configured with a single model,
`gpt-5.4-nano`, for chat titles and the memory agent, and GPT-5.6 was merely kept
out of `OPENAI_MODELS`. On 2026-07-30 OpenAI cut `gpt-5.6-luna` to roughly nano's
price; nano was retired, the endpoint had nothing left to do, and it was deleted.

That is stronger than excluding models from a list. **An endpoint that does not
exist cannot be bypassed to.** `validate-config.sh` asserts both halves and fails
the build if either reappears.

### Titles

`titleConvo: true` on the custom endpoint is load-bearing, and it was `false` for
one day in July 2026 with consequences worth recording.

`api/server/services/Endpoints/agents/title.js` early-returns on
`client.options.titleConvo === false` — no fallback to `titleModel`, no delegation
to another endpoint. With it false, **every conversation on every agent using this
endpoint was silently saved as "New Chat"**.

The reason it survived a smoke test: **direct chats on this endpoint titled
correctly the whole time.** The non-agent code path does not consult the flag. Only
agents were affected, so a model-by-model check passes while most agents quietly
lose their titles. `titleEndpoint` exists in `librechat-data-provider`'s types but
is not referenced by the API server, so it cannot be used to delegate titling.

### 3. The built-in endpoint is not selectable

In `librechat.yaml`:

```yaml
modelSpecs:
  addedEndpoints:
    - anthropic
    - agents          # note: no openAI
  list:
    - name: "gpt-5.6-terra"
      label: "GPT-5.6 Terra"
      softDefault: true
      preset:
        endpoint: "OpenAI GPT-5.6 Responses"
        model: "gpt-5.6-terra"
        useResponsesApi: true
```

The built-in `openAI` endpoint stays *configured* — chat-title generation and the
memory agent use it, and neither is affected by the routing problem — but it is not
*selectable*, so nobody can route around the fix through the UI.

## How agents reach these models

An agent points its `provider` directly at the custom endpoint:

```json
{ "model": "gpt-5.6-terra", "provider": "OpenAI GPT-5.6 Responses" }
```

LibreChat resolves a `provider` that is not a built-in endpoint through
`getCustomEndpointConfig` (`packages/api/src/agents/load.ts`), so the endpoint's
`addParams` applies to agent runs too.

!!! danger "The provider string must match byte for byte"
    `"OpenAI GPT-5.6 Responses"` — spaces included. A mismatch fails at **request**
    time, not at startup, so nothing warns you.

    `scripts/validate-config.sh` asserts that every provider named in
    `scripts/model-map.json` and every endpoint named in `modelSpecs.list` resolves
    to a real endpoint. It runs in CI on every pull request. That check exists
    because this is exactly the kind of mistake that is invisible until a user finds
    it.

### The alternative we rejected, and why

Setting `model_parameters.useResponsesApi: true` while keeping `provider: "openAI"`
also works. The key is recognized. We do not do it because it is **per-agent state**:
the Agent Builder UI can drop unknown parameters when an agent is saved, silently
reintroducing the bug with no error and no diff to look at.

Routing through the custom endpoint is **server-enforced policy**. A user editing
their agent cannot turn it off, because there is nothing in the agent document to
turn off.

## If you are adopting this pattern

The general shape, for any model family with its own API requirements:

1. Declare a custom endpoint whose `addParams` enforces what the family needs.
2. Keep those models out of the built-in endpoint's model list.
3. Omit the built-in endpoint from `addedEndpoints` so it cannot be selected.
4. Point agents at the custom endpoint by name.
5. Add a CI assertion that the names agree, because nothing at runtime will tell you.

Step 5 is the one people skip. Do not skip step 5.

## Verifying it works

A plain "hello" **does not test this** and will pass while the configuration is
broken. You need a conversation that actually invokes a tool:

- [ ] On each GPT-5.6 model, run a conversation that uses a tool (web search, file
      chat, or any agent tool)
- [ ] Confirm the built-in `openAI` endpoint is **not** selectable in the model
      dropdown
- [ ] Edit and save a GPT-5.6 agent through the Agent Builder UI, then run a
      tool-calling conversation on it again — this checks that the UI round-trips a
      custom `provider` without resetting it
