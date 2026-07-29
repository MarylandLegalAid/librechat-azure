# Quickstart

Five steps to a working, private, branded LibreChat on your own Azure subscription.

## What you need before you start

| | |
|---|---|
| **An Azure subscription** | With permission to create resources and assign roles. If you are not sure, you probably have "Owner" or you do not have enough. |
| **A domain name** | Something like `chat.yourorg.org`, and the ability to add a DNS record to it. Usually whoever manages your website. |
| **One AI provider API key** | From [Anthropic](https://console.anthropic.com) or [OpenAI](https://platform.openai.com). Either alone is fine. |
| **About an hour** | Perhaps twenty minutes of typing. The rest is Azure creating things and certificates being issued. |

You do **not** need Docker, Linux experience, or a CI/CD pipeline. You do not need to
understand Bicep, though it is all readable if you want to.

!!! warning "Read the compliance page first"
    If your organization handles confidential client information — and if you are
    reading this, it does — the question of what agreements you need with Microsoft
    and with your AI provider is the hardest part of this whole exercise, and it is
    not a technical question.

    **[Read the compliance page](../compliance.md) before you spend money.** It is
    much easier to answer before you have a running system than halfway through.

## The five steps

1. **[Create the infrastructure](01-deploy.md)** — one button, about ten minutes.
2. **[Add your secrets](02-secrets.md)** — API keys and a few generated values, into
   Azure's key vault.
3. **[Point your domain at it](03-dns.md)** — one DNS record. Certificates issue
   themselves.
4. **[First login](04-first-login.md)** — create your account, make yourself an
   administrator, and **close registration**.
5. **[Make it yours](05-make-it-yours.md)** — your name, your logo, your terms of
   service, your model list.

Do them in order. Step 4 in particular has a step that is easy to skip and important
not to.

## What you will have at the end

A virtual machine in your own subscription running the chat application, a database,
a search index, and a vector database for file chat. Traffic arrives over HTTPS with
a certificate that renews itself. The machine backs itself up nightly, updates itself
from this repository every five minutes, and emails you when something breaks.

Nothing leaves your Azure subscription except the requests you send to your AI
provider.

## If you get stuck

[When it breaks](../troubleshooting.md) covers the failures we have actually hit.
Most first-deployment problems are one of three things: a DNS record that has not
propagated, a secret whose name has an underscore where it needs a dash, or the SSH
firewall rule pointing at an address you no longer have.
