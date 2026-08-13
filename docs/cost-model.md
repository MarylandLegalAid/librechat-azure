# What it costs

Real numbers, from the live deployment. Its application host is currently
`Standard_D2s_v5` (2 vCPU / 8 GB). Azure pricing changes and varies by region, so
treat these as accurate to within about 20% rather than as a quote.

## Infrastructure

For a few hundred users, in `eastus2`, pay-as-you-go:

| Resource | Spec | Approx. per month |
|---|---|---|
| Virtual machine | `Standard_D2s_v5`, 2 vCPU / 8 GB | $70 |
| OS disk | Premium SSD, 30 GB | $5 |
| Data disk | Premium SSD, 128 GB | $19 |
| Public IP | Standard, static | $4 |
| Azure Backup | Daily, 30-day retention | $10–20 |
| Backup storage | Nightly dumps, cool tier | $1 |
| Key Vault | A few dozen secrets | $1 |
| Monitoring | Alerts + one availability test | $2 |
| Bandwidth | Egress | $5–15 |
| | **Total** | **≈ $120–140** |

### Making it cheaper

The current deployment already uses the 2-vCPU/8-GB size. The remaining savings come
from:

| Change | Saves | Costs you |
|---|---|---|
| 1-year reserved instance | ~35% of VM | A one-year commitment |
| 3-year reserved instance | ~55% of VM | A three-year commitment |
| Standard SSD data disk | ~$10/mo | Slower database. Probably noticeable. |
| Turn off Azure Backup | ~$15/mo | **Do not.** It is the only thing that restores uploaded files. |

A small pilot on the current `Standard_D2s_v5` with a reserved instance lands around
**$100/month**.

!!! tip "Non-profit and grant credits"
    Microsoft offers substantial Azure credits to eligible non-profits, and
    grant-funded subscriptions are common in this sector. That can cover the whole
    infrastructure bill. Worth checking before budgeting anything.

## AI provider usage

Usually **larger than the infrastructure**, and much harder to predict — it depends on
what people do, not on how many they are.

A rough starting point, from observed use at a legal services organization where staff
use it several times a week for drafting and summarization:

| Users | Typical monthly spend |
|---|---|
| 50 | $50–200 |
| 200 | $200–800 |
| 400 | $400–1,500 |

The range is wide because a handful of heavy users of a frontier model on long
documents can exceed everyone else combined.

### Controlling it

- **Curate the model list.** The single biggest lever. Users pick from what you offer.
  Offering a mid-tier model as the default and a frontier model for those who need it
  costs a fraction of making the frontier model the default.
- **Use a cheap model for chat titles and memory.** Both run on every conversation.
  `titleModel` and `memory.agent.model` should be the cheapest thing that works.
- **Set spending limits at the provider.** Both Anthropic and OpenAI support them. Do
  this on day one — an agent in a loop is a real way to spend real money.
- **Watch the first month closely.** Actual usage rarely matches the estimate in
  either direction.

## Optional extras

| | Approx. per month |
|---|---|
| [Code interpreter](modules/code-interpreter.md) VM (`Standard_D2s_v5` + disk + IP) | $85 |
| Web search (Serper, Firecrawl, Jina) | $0–50, usage-based |
| Speech to text | Usage-based, small |

The code interpreter adds roughly $85/month to the infrastructure bill. Decide whether
you want the capability before building it.

## What is free

- LibreChat itself, and this blueprint
- TLS certificates (Let's Encrypt)
- Container images
- GitHub Actions, on public repositories

## A realistic first-year budget

A 200-user deployment, no code interpreter, no reserved instance:

| | |
|---|---|
| Infrastructure | $1,440–1,680 |
| AI usage | $3,000–9,000 |
| **Total** | **$4,440–10,680** |

Plus staff time. Budget a week for the initial deployment including the compliance
conversation, and a few hours a month afterwards — mostly reviewing upgrade pull
requests.

## Watching your spend

```bash
az consumption usage list \
  --start-date 2026-08-01 --end-date 2026-08-31 \
  --query "[?contains(instanceName, 'librechat')].{name:instanceName, cost:pretaxCost}" \
  --output table
```

Set a budget alert on the resource group while you are at it. Putting the deployment
in its own resource group — which the Quickstart tells you to do — is what makes both
of these one line.
