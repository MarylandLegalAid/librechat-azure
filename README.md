# LibreChat on Azure

A complete, private AI chat platform for your organization, running on infrastructure
you control, in a subscription you own.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMarylandLegalAid%2Flibrechat-azure%2Fmain%2Finfra%2Fmain.json)

📖 **[Documentation](https://marylandlegalaid.github.io/librechat-azure/)** ·
🚀 **[Quickstart](https://marylandlegalaid.github.io/librechat-azure/quickstart/)** ·
⚖️ **[Compliance](https://marylandlegalaid.github.io/librechat-azure/compliance/)** ·
💬 **[Support](./SUPPORT.md)**

---

## What this is

[Maryland Legal Aid](https://www.mdlab.org) runs [LibreChat](https://librechat.ai) for
its staff. This is the deployment — not a sanitized copy of it, not a template derived
from it. The same repository, deployed the same way.

That matters more than it sounds like it should. A blueprint nobody runs quietly stops
working, and you would be the one to find out. Everything here is exercised in
production every day.

It is published so that other legal-services organizations can reproduce the same
patterns — branding, a terms-of-service dialogue, custom tool servers, curated model
lists — without deriving them again.

## What you get

- **LibreChat** on your own Azure VM, behind TLS that renews itself
- **Your models** — Anthropic, OpenAI, or both, on your own API keys
- **Your branding** — name, logo, welcome message, terms of service users must accept
- **Your users only** — email and password with a domain allowlist, or your existing
  single sign-on
- **Conversation search, file chat, agents, speech-to-text, image generation**
- **Optional custom tools** so the model can reach your own systems
- **Automatic updates, backups and monitoring**, configured rather than assumed

Roughly **$150–200/month** in Azure for a few hundred users, plus model usage.
[Itemized](https://marylandlegalaid.github.io/librechat-azure/cost-model/).

## Getting started

**[Follow the Quickstart.](https://marylandlegalaid.github.io/librechat-azure/quickstart/)**
An Azure subscription and one API key gets you a working instance in about an hour,
most of it waiting.

> ⚖️ **Read the [compliance page](https://marylandlegalaid.github.io/librechat-azure/compliance/) before you spend money.**
> For most organizations the agreements you need with Microsoft and your AI provider
> are the hardest part of this, and it is much worse to discover halfway through.

## How it is put together

```
compose.yaml              the whole stack; optional services behind profiles
compose.storage.*.yml     disk (default) or S3 — selected by one variable
Caddyfile                 TLS and hostname routing, ten readable lines
librechat.yaml            application config; merged with a storage overlay at deploy
config/storage/           the two overlays, and why they exist
env.defaults              non-secret defaults, committed
.env.example              every variable, documented, no values
infra/                    Bicep: VM, network, data disk, Key Vault, backup, alerts
scripts/deploy.sh         THE deploy path — both triggers run this
scripts/                  secrets rendering, backup, restore, agent migration
docs/                     the documentation site
```

Three ideas do most of the work:

**One deploy path, two triggers.** `scripts/deploy.sh` is the only thing that ever
deploys. A systemd timer and an optional GitHub Actions pipeline both run it, unchanged,
so neither path can rot while the other is exercised. In practice everyone including
Maryland Legal Aid runs the timer — the pipeline ships unconfigured and skips itself, so
treat it as a setup path that has not been exercised.
[How deploys work](https://marylandlegalaid.github.io/librechat-azure/modules/deployment/).

**No secret in a file.** Secrets live in Azure Key Vault. The VM reads them with its
own managed identity, so there is no credential on disk anywhere. `.env` is generated
at deploy time and never committed. `gitleaks` runs over the full history on every
push.

**Data on a separate disk.** Databases, uploaded files and letterheads live on a
mounted data disk, so the OS disk can be rebuilt or the VM resized without touching
data. Azure Backup protects it.

## Contributing

Issues and pull requests are welcome. Two things worth knowing:

- **CI is not decoration.** `validate.yml` renders both storage configurations, parses
  every Compose profile combination, checks that every provider name resolves, and
  asserts the committed ARM template matches its Bicep source. Most of what can break
  here fails at *request* time rather than at startup, so those checks are the only
  thing standing between a plausible-looking change and a user finding it.
- **Never commit a secret or a `.docx`.** This repository is public and a public
  repository exposes its entire history. `.gitignore` states the intent; `secrets.yml`
  enforces it.

Run the checks locally before opening a pull request:

```bash
./scripts/validate-config.sh
node --test "scripts/test/*.test.js"
```

## Related repositories

| | |
|---|---|
| [legalserver-mcp](https://github.com/MarylandLegalAid/legalserver-mcp) | Read-only LegalServer tools. Useful on its own to any organization running LegalServer. |
| [letterwriter-mcp](https://github.com/MarylandLegalAid/letterwriter-mcp) | Letters on your organization's letterhead, returned as a document. |

## License and expectations

[MIT](./LICENSE), no warranty. Maryland Legal Aid is a legal aid organization, not a
software vendor — there is no support contract behind this and no on-call rotation.
[SUPPORT.md](./SUPPORT.md) is honest about what that means.

What you can rely on is that it works, because we depend on it working.
