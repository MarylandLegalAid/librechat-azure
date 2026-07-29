# Custom tools (MCP)

MCP is the protocol LibreChat uses to let a model call your tools — look up a case,
generate a document, query a system only you have. It is the difference between a
chat assistant and one that knows about your work.

This is optional. Nothing in a basic instance needs it.

## How they work here

Each MCP server is **its own public repository publishing its own container image**.
This deployment consumes pinned tags, one Compose service per server, each behind a
profile.

```yaml
legalserver-mcp:
  image: ghcr.io/marylandlegalaid/legalserver-mcp:v3.0.0
  profiles: ["mcp-legalserver"]
```

Why separate repositories rather than a folder in this one: an MCP server that talks
to a case management system is useful to organizations that have that system and have
never heard of LibreChat. Bundling it here would hide it from them.

## Turning one on

```bash
az keyvault secret set --vault-name kv-librechat-prod \
  --name COMPOSE-PROFILES --value "mcp-legalserver,mcp-letterwriter" --output none
```

Set whatever configuration that server needs, then redeploy. The available ones:

| Profile | What it does |
|---|---|
| `mcp-legalserver` | [Read-only LegalServer matter, document and discovery tools](mcp-legalserver.md) |
| `mcp-letterwriter` | [Letters on your own letterhead](mcp-letterwriter.md) |

## The trust boundary

Neither server publishes a port. They are reachable only from other containers on the
Compose network, and **that is the trust boundary**.

Both images support an optional shared-secret header that no-ops when unset. It is
deliberately left unset here. That is stated explicitly, in `librechat.yaml` and
again here, so the assumption is visible rather than accidental — if you ever move an
MCP server onto a different host, this is the paragraph that should stop you.

## ⚠️ The SSRF allow list

This will bite you if you add your own server and do not know about it.

LibreChat v0.8.7 blocks SSRF targets — including private and internal hostnames — for
MCP server URLs by default. **A Docker Compose service name is an internal hostname.**
Without an explicit exemption, every connection attempt fails with
`Domain ... is not allowed`.

```yaml
mcpSettings:
  allowedAddresses:
    - "legalserver-mcp:3001"
    - "letterwriter-mcp:3002"

mcpServers:
  LegalServer:
    type: streamable-http
    url: http://legalserver-mcp:3001/legalserver/mcp
```

Use `allowedAddresses` — host and port, no scheme. **Not** `allowedDomains`, which
switches the field into a strict whitelist mode that blocks every public destination
you did not also list.

`scripts/validate-config.sh` checks that every `mcpServers` URL has a matching
`allowedAddresses` entry and a matching Compose service. It runs in CI.

## Writing your own

An MCP server is a small HTTP service. The two in this blueprint are each a few
hundred lines of Node.

### 1. Start from an existing one

[`legalserver-mcp`](https://github.com/MarylandLegalAid/legalserver-mcp) is the more
complete example. The parts you need:

- A `/healthz` endpoint returning JSON — Compose's health check uses it.
- A streamable-HTTP MCP route, mounted statelessly.
- Tool definitions with a JSON Schema for their inputs. The schema is what the model
  reads to decide whether and how to call your tool, so its `description` fields are
  functional text, not documentation.

### 2. Publish an image

A release workflow on tag, publishing to `ghcr.io/yourorg/yourtool:vX.Y.Z`.

### 3. Add it here

```yaml
# compose.yaml
yourtool-mcp:
  image: ghcr.io/yourorg/yourtool-mcp:v1.0.0
  container_name: yourtool-mcp
  profiles: ["mcp-yourtool"]
  restart: unless-stopped
  env_file: .env
  environment:
    MCP_HTTP_HOST: 0.0.0.0
    MCP_HTTP_PORT: "3003"
    MCP_ALLOWED_HOSTS: yourtool-mcp,localhost,127.0.0.1
```

```yaml
# librechat.yaml
mcpSettings:
  allowedAddresses:
    - "yourtool-mcp:3003"        # do not forget this

mcpServers:
  YourTool:
    type: streamable-http
    url: http://yourtool-mcp:3003/yourtool/mcp
    description: "What this does, written for a model to read"
    chatMenu: true
```

Then add `mcp-yourtool` to `COMPOSE_PROFILES`, and add the new variables to
`.env.example` so the next person knows they exist.

### Things worth knowing

- **`MCP_ALLOWED_HOSTS`** — the MCP SDK's Express host check rejects requests whose
  `Host` header is not listed. The Compose service name is what LibreChat sends.
- **`{{LIBRECHAT_USER_EMAIL}}`** in a header value forwards the signed-in user's
  email, so a tool can scope results to the person asking:

    ```yaml
    headers:
      X-Your-User-Email: "{{LIBRECHAT_USER_EMAIL}}"
    ```

- **Tools should be read-only unless you have thought hard about it.** A model calling
  a tool that writes to your case management system is a different risk conversation
  from one that reads.
- **Return binary content directly** when a tool produces a file. LibreChat attaches
  it to the conversation, which works in every storage mode and avoids inventing a
  link that expires.
