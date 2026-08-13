# LibreChat on Azure

A complete, private AI chat platform for your organization, running on
infrastructure you control, in a subscription you own.

This is the deployment [Maryland Legal Aid](https://www.mdlab.org) runs for its own
staff. Not a sanitized copy of it, not a template derived from it — the same
repository, deployed the same way. That matters more than it sounds like it should:
a blueprint nobody runs quietly stops working, and you would be the one to find out.

## What you get

- **[LibreChat](https://librechat.ai)**, a mature open-source chat interface, on your
  own virtual machine
- **Your models** — Anthropic, OpenAI, or both, using your own API keys and your own
  agreements with those vendors
- **Your branding** — name, logo, welcome message, and a terms-of-service dialogue
  users must accept
- **Your users only** — email and password with a domain allowlist, or your existing
  single sign-on
- **Conversation search, file chat, agents, speech-to-text, image generation** — all
  of LibreChat's capabilities, with the ones you do not want switched off
- **Optional custom tools** so the AI can reach your own systems
- **Automatic updates, backups and monitoring**, configured rather than assumed

## What it costs

The current host is `Standard_D2s_v5` (2 vCPU / 8 GB). Roughly **$120–140 per month**
in Azure for a few hundred users, plus whatever your model provider charges for usage.
[Real numbers, itemized](cost-model.md).

## Where to start

<div class="grid cards" markdown>

- :material-rocket-launch: **[Quickstart](quickstart/index.md)**

    Start here. An Azure subscription and one API key gets you a working, branded,
    private instance. About an hour, most of it waiting.

- :material-puzzle: **[Modules](modules/index.md)**

    One page per optional capability. Read these when you want something the
    Quickstart did not give you — single sign-on, custom tools, a code interpreter.

- :material-scale-balance: **[Compliance](compliance.md)**

    The BAA question, answered honestly. **Read this before you deploy**, not after
    — it is the largest non-technical obstacle most organizations hit, and it is
    much worse to discover halfway through.

- :material-wrench: **[Running it](maintenance.md)**

    What you actually have to do once it is live. Less than you would think, but
    not nothing.

</div>

## Being clear about what this is

This is a blueprint published in the hope that it is useful, under the
[MIT License](https://github.com/MarylandLegalAid/librechat-azure/blob/main/LICENSE),
with no warranty. Maryland Legal Aid is a legal aid organization, not a software
vendor. There is no support contract behind this and no on-call rotation. See
[SUPPORT.md](https://github.com/MarylandLegalAid/librechat-azure/blob/main/SUPPORT.md)
for what that means in practice.

What you can rely on is that it works, because we depend on it working.

!!! note "Pilot participants"
    If you are part of the funder-sponsored pilot, your support runs through the
    funder rather than through this repository. That channel is staffed; this one
    is best-effort.
