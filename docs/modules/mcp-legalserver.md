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
- Read documents attached to a matter, including **scanned documents via OCR**, which
  this deployment now enables. See [OCR for scanned documents](#ocr-for-scanned-documents)
  for what that sends where, and why it is scoped rather than matter-wide.
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

The server supports OCR through **OpenAI only**, and **this deployment now enables it**
(`DOCUMENT_OCR_PROVIDER=openai`, enabled 2026-08-04 with `legalserver-mcp` v3.1.0).
Scanned pages are rasterised to PNG with `pdftoppm` in memory — nothing is written to
disk — and sent one page at a time to a vision model.

This section used to explain why it was off. That judgement has been made rather than
reversed, so here is what actually changed and what did not.

**The confidentiality question was answered, not dropped.** A scanned document is
whatever the client walked in with — an ID, a medical record, a court paper someone
else's lawyer sent — so it is a broader and less predictable disclosure than a prompt a
caseworker chose to type. What makes it acceptable here is the third item on the
checklist this section used to carry: a cloud arrangement whose terms genuinely cover
**client documents** rather than chat. MLA holds ZDR on the OpenAI account (confirmed
2026-08-03). That is also why `openrouter` and `vertex_gemini` were **removed from the
server entirely** rather than merely discouraged — page images have to stay with the one
vendor the agreement covers. Both values now fail at container boot.

**Local OCR still does not fit the machine**, and that has not changed. Tesseract or
PaddleOCR would keep the pages on your own hardware, but the VM this blueprint
provisions is `Standard_D4s_v5` — four vCPUs shared by the app, MongoDB, Meilisearch,
pgvector and the RAG service. A multi-page scan would saturate the CPU everything else
is sharing and would likely exceed the tool-call timeout.

### The carve-out ZDR does not close

**`store: false` is not zero retention.** The server hardcodes it on every page request
and no environment variable can turn it off, but it only stops the page image becoming a
retrievable stored object. Abuse-monitoring retention is governed by the ZDR agreement
on the account.

**ZDR does not cover the CSAM scan.** OpenAI scans every image input for CSAM and
retains flagged images for manual human review regardless of ZDR. On a legal aid
document mix — custody, abuse/neglect, CPS, paediatric records — that is a real
carve-out, not a theoretical one. It is the main reason OCR is scoped to documents an
agent has decided are worth reading, rather than run across a whole matter.

### How it is scoped

- **OCR is decided per page**, not per document, so a typed motion with scanned exhibits
  costs a few vision calls rather than one per page of the whole filing.
- **`matter_search_document_text` does not OCR by default.** It searches what is readable
  and reports what it skipped in `meta.documents_requiring_ocr`. The calling agent
  decides what is worth reading, so that decision lands in the transcript where a
  caseworker can audit and override it.
- **`DOCUMENT_OCR_MAX_PAGES` is a per-document ceiling, set to 25 here.** A document
  needing more OCR pages than that is refused outright with `document_too_large` rather
  than partially transcribed. It is **not** a cap on matter-wide spend: an agent supplies
  `ocr_page_budget` per search, which defaults to this value but is not clamped to it. If
  you want to bound what a matter-wide search costs, change the agent's instructions —
  that is the lever that governs the total.

**Prompt injection is not mitigated in code.** OCR text is transcribed verbatim into the
agent's context, including from documents filed by opposing parties. Treat it as
untrusted input.

`scripts/check-secrets.sh` validates the provider, its key, and the page ceiling, so a
half-configured one fails there rather than on the first scanned page. Update your
[Compliance](../compliance.md) data-flow table and your terms of service to name OpenAI
as a recipient of client document images.

### Turning it off, and rolling back

Set `DOCUMENT-OCR-PROVIDER` to `none` in Key Vault and run `scripts/deploy.sh --force`.

**Order matters if you are also rolling the image back.** The `v3.0.0` image rejects
`DOCUMENT_OCR_PROVIDER=openai` at boot, so repinning the image while the variable still
says `openai` gives you a container that will not start, while you are already
mid-incident. **Set the variable to `none` first, then repin.**

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
