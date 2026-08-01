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
- Read documents attached to a matter — **native-digital PDFs only**. A scanned
  document has no text layer to read, and OCR is deliberately not enabled here. See
  [OCR for scanned documents](#ocr-for-scanned-documents).
- Search contacts, users and organizations
- "My tasks", "my calendar", "my matters" for the signed-in user, when you supply the
  saved-report URLs that back them

Everything is **read-only**. Nothing it does can change data in LegalServer. That is a
property of the server, not a configuration choice, and it is the reason this is
comfortable to switch on.

## Turning it on

```bash
V=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)
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

The server supports OCR. **This deployment leaves it off**, so the document tools work
on native-digital PDFs — a scan has no text layer and returns nothing useful, which is
expected behaviour rather than a bug to report.

That is a judgement rather than a limitation, so here is the whole of it; you may weigh
it differently. Two independent reasons, either enough on its own:

**A cloud vision model is a confidentiality problem.** Every supported provider works
by sending page images somewhere else. A scanned document is whatever the client
walked in with — an ID, a medical record, a court paper someone else's lawyer sent —
so it is a broader and less predictable disclosure than a prompt a caseworker chose
to type. That is a different question from "do we have an agreement with this vendor",
and it is not answered by having one.

**Local OCR does not fit the machine.** Tesseract or PaddleOCR would keep the pages on
your own hardware and answer the paragraph above, but the VM this blueprint provisions
is `Standard_D4s_v5` — four vCPUs shared by the app, MongoDB, Meilisearch, pgvector and
the RAG service. It is sized for chat, not for page rasterisation. A multi-page scan
would saturate the CPU everything else is sharing and would likely exceed the tool-call
timeout, which reaches the user as a tool that hangs and then fails, on the documents
most likely to matter.

### What would make it reasonable

Worth stating as a checklist, because "set the variable" is the easy part and not the
part that decides it. Any of these changes the answer:

- A vision model running **on infrastructure you control**, which removes the
  disclosure entirely rather than relocating it.
- **Dedicated compute** — a separate worker, so a scan cannot starve chat — plus an
  async path that survives the tool-call timeout instead of racing it.
- A cloud arrangement whose terms genuinely cover **client documents** rather than
  chat, entered into deliberately and written down.

If you do enable it, `scripts/check-secrets.sh` validates the provider and its
companion key, so a half-configured one fails loudly rather than on the first scanned
page. Note that `vertex_gemini` cannot work as this repository ships: it authenticates
with a service-account **file**, and `legalserver-mcp` mounts no volumes. Update your
[Compliance](../compliance.md) data-flow table and your terms of service to name the
provider.

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
