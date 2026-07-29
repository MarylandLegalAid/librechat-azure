# Your branding

Making it look like your organization's tool. Four things, none of which needs a
rebuild.

## Name and greeting

`APP_TITLE` is per-deployment, so it lives in the key vault:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

az keyvault secret set --vault-name "$VAULT" \
  --name APP-TITLE --value "Your Organization AI" --output none
```

It appears in the browser tab, the header, and the login page.

The greeting on a new chat is in `librechat.yaml`:

```yaml
interface:
  customWelcome: "Welcome! How can I help you today?"
```

## Logo and favicons

Put your files in `client/public/assets/` and commit:

| File | Size | Where it shows |
|---|---|---|
| `logo.svg` | vector | Header and login page |
| `favicon-32x32.png` | 32×32 | Browser tab |
| `favicon-16x16.png` | 16×16 | Browser tab, small |
| `apple-touch-icon-180x180.png` | 180×180 | Saved to a phone home screen |

SVG for the logo if you have one — it stays sharp on every display. A PNG at roughly
512px wide works if not.

## Terms of service

The most important item on this page, and the one most likely to be skipped.

`librechat.yaml` can show a dialogue that users must accept before they can use the
application:

```yaml
interface:
  termsOfService:
    externalUrl: "https://yourorg.org/ai-terms"
    openNewTab: true
    modalAcceptance: true
    modalTitle: "Your Organization AI — User Agreement"
    modalContent: |
      By using this platform you agree to the terms below.

      ## 1. Purpose
      ...
  privacyPolicy:
    externalUrl: "https://yourorg.org/privacy"
    openNewTab: true
```

!!! danger "Replace what ships here before anyone logs in"
    This repository carries Maryland Legal Aid's user agreement, because Maryland
    Legal Aid runs this repository. Shipping another organization's terms of service
    to your staff is worse than shipping none — it looks authoritative and is not
    yours.

`modalContent` takes Markdown, so headings and lists work.

### What is worth saying in it

The existing content is a reasonable structure to work from. The sections that carry
real weight:

- **What the tool is for**, and that it does not replace professional judgment.
- **Which features are safe for confidential information and which are not.** In
  particular, **web search sends queries to third parties** and is outside whatever
  confidentiality boundary the rest of the platform sits in. Users will not discover
  that on their own, and it is exactly the kind of thing that goes wrong quietly.
- **That output needs checking.** Say it plainly.
- **What is logged**, and for what purpose.
- **If you run a code interpreter**, what happens to uploaded files and how long they
  are kept.

Write it for the person who will read it once, quickly, and then act on their
recollection of it a month later.

## The model dropdown

Users see the models in `ANTHROPIC_MODELS` and `OPENAI_MODELS`, plus any pinned
entries in `modelSpecs.list`. `modelSpecs` lets you give a model a friendly label:

```yaml
modelSpecs:
  list:
    - name: "claude-sonnet-5"
      label: "General purpose"
      softDefault: true
      preset:
        endpoint: "anthropic"
        model: "claude-sonnet-5"
```

`softDefault` pre-selects a model for a user's **first-ever** chat, then gets out of
the way — LibreChat remembers what each user last chose after that. `default: true`,
by contrast, re-selects it on every new chat regardless of preference, which people
find annoying quite quickly.

!!! warning
    If you add any `modelSpecs.list` entry, `interface.modelSelect` and
    `interface.parameters` are silently disabled unless they are explicitly set to
    `true`. They are pinned to `true` in this repository's `librechat.yaml` for
    exactly that reason. Leave them.

## What changes when

| Change | Takes effect |
|---|---|
| Key vault secret | Next `deploy.sh --force` |
| Anything committed to the repository | Within five minutes, automatically |

Nothing here needs SSH or a container rebuild.
