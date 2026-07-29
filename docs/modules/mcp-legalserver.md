# LegalServer tools

Read-only access to matters, documents and directory data in
[LegalServer](https://www.legalserver.org), so staff can ask about a case in plain
language instead of switching systems.

Only useful if your organization runs LegalServer. Skip this page otherwise.

**Repository:** [MarylandLegalAid/legalserver-mcp](https://github.com/MarylandLegalAid/legalserver-mcp) —
public, and usable on its own by any organization on LegalServer whether or not they
run LibreChat.

## What it can do

- Look up matters and their details
- Read documents attached to a matter, including OCR of scanned PDFs if you configure
  a provider for it
- Search contacts, users and organizations
- "My tasks", "my calendar", "my matters" for the signed-in user, when you supply the
  saved-report URLs that back them

Everything is **read-only**. Nothing it does can change data in LegalServer. That is a
property of the server, not a configuration choice, and it is the reason this is
comfortable to switch on.

## Turning it on

```bash
V=kv-librechat-prod
az keyvault secret set --vault-name $V --name COMPOSE-PROFILES \
  --value "mcp-legalserver" --output none
az keyvault secret set --vault-name $V --name LEGALSERVER-BASE-URL \
  --value "https://yourorg.legalserver.org" --output none
az keyvault secret set --vault-name $V --name LEGALSERVER-BEARER-TOKEN \
  --value "..." --output none
```

Then redeploy. Get the bearer token from your LegalServer administrator — it is an
API key, and it should be issued to a service account with the narrowest read access
that makes the tools useful.

## Per-user results

`librechat.yaml` forwards the signed-in user's email:

```yaml
mcpServers:
  LegalServer:
    url: http://legalserver-mcp:3001/legalserver/mcp
    headers:
      X-LegalServer-User-Email: "{{LIBRECHAT_USER_EMAIL}}"
```

That is what lets "what are my tasks this week" mean the asker's tasks. The
current-user tools additionally need saved-report URLs:

```bash
az keyvault secret set --vault-name $V \
  --name LEGALSERVER-CURRENT-USER-TASKS-REPORT-URL --value "https://..." --output none
```

The full set is documented in that repository's own `.env.example`, and everything it
supports is passed straight through.

## OCR for scanned documents

Off by default. A scanned PDF with no text layer returns nothing useful until you
enable it.

Set `DOCUMENT_OCR_PROVIDER` to `openai`, `openrouter`, or `vertex_gemini`.

!!! warning "OCR sends page images to a third party"
    Whichever provider you pick, the pages of your clients' documents leave your
    infrastructure and go to that provider.

    Pick one you already have an agreement with. `openai` calls OpenAI directly
    rather than proxying through a router, which is the right choice if your
    agreement is specifically with OpenAI. Say what you chose in your terms of
    service. See [Compliance](../compliance.md).

## Checking it works

```bash
docker compose exec api curl -fsS http://legalserver-mcp:3001/healthz
```

Then in a chat: open the tools menu, confirm the LegalServer tools are listed, and ask
something that requires one.

If the tools do not appear, check the SSRF allow list first — it is the most common
cause. See [Custom tools (MCP)](mcp-servers.md#the-ssrf-allow-list).

## What Maryland Legal Aid uses it for

Two agents: a case summary agent and a closing letter drafter. The second hands its
output to [LetterWriter](mcp-letterwriter.md), which is a reasonable illustration of
how two tool servers compose — one reads the matter, the other produces the document.
