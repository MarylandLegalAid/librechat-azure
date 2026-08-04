# Compliance

**Read this before you spend money.** For most organizations this is the hardest part
of the whole exercise, it is not a technical problem, and it is much worse to discover
halfway through a deployment than at the start.

!!! warning "Not legal advice"
    This page describes how the system is built and which questions that raises. It
    is not legal advice, and reading it creates no relationship of any kind between
    your organization and Maryland Legal Aid. Your obligations depend on your
    jurisdiction, your funders, your clients and your own policies. Ask your own
    counsel.

## Where your data actually goes

Being concrete about this is more useful than any general statement.

| Data | Where it lives | Who else can see it |
|---|---|---|
| Conversations, users, agents | MongoDB on your VM | Nobody. It never leaves your subscription. |
| Uploaded files | The data disk on your VM | Nobody. |
| Search index | Meilisearch on your VM | Nobody. |
| Document embeddings | pgvector on your VM | Nobody. |
| Backups | Your Azure storage and Recovery Services vault | Nobody. |
| **Prompts and responses** | **Sent to your AI provider** | **Anthropic or OpenAI** |
| **Web search queries** | **Sent to your search provider** | **Serper, Firecrawl, or Jina** |
| **Speech-to-text audio** | **Sent to OpenAI** | **OpenAI** |
| **Generated images** | **Prompt sent to OpenAI** | **OpenAI** |
| **OCR page images** | **Off by default. Maryland Legal Aid enables it — page images sent to OpenAI** | **OpenAI, if you turn it on** |

The rows in bold are the ones that matter — they are every case where data can leave
your infrastructure. Everything else stays inside infrastructure you control. The last
row ships off and is a real egress path the moment you switch it on; the section below
is about what turning it on actually commits you to.

## The two agreements you probably need

### 1. With Microsoft, for Azure

Everything in the top half of that table is covered by whatever agreement you have
with Microsoft for Azure. If you handle protected health information, that means a
**Business Associate Agreement**, available under the Microsoft Product Terms for
most Azure services.

This is why the blueprint is Azure-only and why file storage is on the VM's own disk
rather than an object store: **one agreement instead of two**. Every additional
vendor is another negotiation.

### 2. With your AI provider

Prompts and responses go to Anthropic or OpenAI. What you need from them depends on
what you send.

Both offer enterprise terms including zero-data-retention arrangements and, for
qualifying customers, a BAA. **The default consumer or developer terms are usually not
sufficient** for confidential client information — check what your account is actually
on rather than what you assume.

Get this settled before you deploy. It is a procurement conversation with a lead time,
not a checkbox.

## Features that leave the boundary

Three of these are switched on in this blueprint by default. Decide about each one.

### Web search — the one that catches people

Web search sends the user's query to a third-party search provider. That provider is
almost certainly **not** covered by your agreements.

A user researching a case can paste a client's name, an address, or a case detail into
what looks like an ordinary chat. Nothing about the interface signals that this
particular message is going somewhere different.

Two things worth doing:

1. **Say so in your terms of service.** The dialogue shipped in this repository's
   `librechat.yaml` has a section on exactly this. It is worth reading as a model.
2. **Consider leaving it off.** If nobody has asked for it, the safest configuration
   is the one where the question does not arise. Unset the provider keys and the
   feature is unavailable.

### Speech to text

Audio uploads go to OpenAI. If people dictate case notes, that audio is client
information leaving your infrastructure.

Unset `STT_API_KEY` to disable it.

### OCR in the LegalServer tools

Off by default. **Maryland Legal Aid enables it** (since 2026-08-04), through OpenAI,
which is the only provider the server supports. The reasoning is worth borrowing even if
you reach a different answer.

Enabling it sends page images of client documents to a third party. That is a broader
disclosure than prompts and responses: a scanned document contains whatever the client
brought in rather than what a worker chose to type, so having an agreement with the
vendor does not by itself settle whether those documents should go there. Local OCR
avoids the disclosure but needs CPU a chat-sized VM does not have.

What made it acceptable at MLA was an agreement that covers **client documents** rather
than chat — ZDR on the OpenAI account, confirmed 2026-08-03 — plus scoping OCR to
documents an agent has decided are worth reading rather than running it matter-wide.
The server sends `store: false` on every page request and cannot be configured not to.

**Two things ZDR does not settle, and you should not assume it does:**

- `store: false` is not zero retention. It stops the page image becoming a retrievable
  stored object; abuse-monitoring retention is governed by the agreement itself.
- **OpenAI scans every image input for CSAM and retains flagged images for manual human
  review regardless of ZDR.** For a legal aid caseload — custody, abuse/neglect, CPS,
  paediatric records — this is a real carve-out affecting exactly the documents most
  likely to be scanned.

If you enable it, that row in the table above applies to you — update it, and name the
provider in your terms of service. The full picture, including how the page ceiling
works and how to roll back safely, is in
[LegalServer tools](modules/mcp-legalserver.md#ocr-for-scanned-documents).

## What the platform does to help

- **Users only see their own conversations.** There is no cross-user visibility.
- **Uploaded files and generated images need a session**, and one belonging to the user who
  owns them. Documents go through an authenticated download route. Images need
  `secureImageLinks: true` in `librechat.yaml` — **this is not LibreChat's default**, and
  without it the image directory is served to anyone holding the URL, with no session at all.
  It is set in this repository. If you are adapting this configuration, do not remove it, and
  if you are auditing a different LibreChat deployment, check for it specifically: the
  middleware that enforces it is a no-op when the key is absent, so the route *looks* guarded.
- **Stored provider API keys are encrypted at rest** with `CREDS_KEY`.
- **Nothing is published.** Agents can be shared within your organization if you
  enable the marketplace, and not outside it.
- **The admin panel is admin-gated** and on its own hostname.
- **No database GUI ships in this stack.** The previous deployment ran one, published
  on all interfaces, where the only thing between it and the internet was the absence
  of a firewall rule.
- **Every service except the web proxy binds to localhost**, so a loosened firewall
  rule does not expose a database.
- **SSH is restricted to named addresses** and can use your identity provider.
- **Secrets live in Azure Key Vault**, not in files. There is no credential on the
  machine's disk to find.

## What it does not do

Honestly, because you will be asked:

- **No audit log of who read what.** LibreChat records conversations, not access to
  them. If you need "who opened this document, and when", this is not that system.
- **No data loss prevention.** Nothing inspects what users type for client identifiers
  before it goes to a model.
- **No retention policy enforcement.** Conversations persist until deleted. If your
  records policy requires disposal after a period, that is a process you run, not a
  setting here.
- **No legal hold.** Related to the above.
- **The AI can be wrong, confidently.** That is a professional-responsibility question
  for whoever relies on the output, and it belongs in your terms of service and your
  training.

## Questions worth answering before you deploy

- [ ] Do we have a BAA or equivalent with Microsoft covering Azure?
- [ ] What terms is our AI provider account actually on? Zero data retention?
- [ ] Are we enabling web search? If so, how do users find out what that means?
- [ ] Are we enabling speech to text?
- [ ] What do our terms of service say, and has counsel seen them?
- [ ] Who administers this, and what can they see?
- [ ] What is our answer when a funder asks where client data goes?
- [ ] Do our record retention obligations apply to conversations here?
- [ ] Have we checked that an image URL, opened in a signed-out browser, is refused?
