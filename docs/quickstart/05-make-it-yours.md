# 5. Make it yours

You have a working instance. What is left is making it look and behave like your
organization's tool rather than a generic one.

Everything here is a change to your fork of this repository. Commit and push, and the
machine deploys it within five minutes. Nothing needs a rebuild and nothing needs SSH.

## Fork it first

If you deployed from the button, the machine is currently pulling from Maryland Legal
Aid's repository. That is fine to start, but you cannot change anything until you
point it at a copy you control.

1. Fork `MarylandLegalAid/librechat-azure` on GitHub.
2. Point the machine at your fork:

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "cd /srv/librechat/app && git remote set-url origin https://github.com/YOURORG/librechat-azure.git && git fetch origin" \
  --query "value[0].message" -o tsv
```

Pulling improvements from upstream later is a normal git merge. Keeping your changes
confined to the handful of files below makes that painless.

## The four things worth doing now

### 1. Your name and greeting

`APP_TITLE` is a key vault secret because it is per-deployment:

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret set --vault-name "$VAULT" \
  --name APP-TITLE --value "Your Organization AI" --output none
```

The greeting on a new chat is in `librechat.yaml`:

```yaml
interface:
  customWelcome: "Welcome! How can I help you today?"
```

### 2. Your terms of service

**Do this before anyone else logs in.** `librechat.yaml` currently carries Maryland
Legal Aid's user agreement, shown as a dialogue every user must accept. Shipping
another organization's terms of service to your staff is worse than shipping none.

Replace `interface.termsOfService` and `interface.privacyPolicy` with your own. The
existing `modalContent` is a reasonable starting structure — in particular the section
warning that web search sends queries to third parties, which is a real limitation
your users need to know about and will not otherwise discover.

### 3. Your logo

Drop your files into `client/public/assets/` and they replace the defaults. See
**[Your branding](../modules/branding.md)** for sizes and file names.

### 4. Your model list

`env.defaults` holds the models users can choose:

```
ANTHROPIC_MODELS=claude-opus-5,claude-sonnet-5,claude-haiku-4-5
```

!!! warning "There is no `OPENAI_MODELS`, and that is deliberate"
    OpenAI models are not listed here at all. They reach users through a separate
    endpoint declared in `librechat.yaml`, because those models reject reasoning
    combined with tools on the ordinary chat completions API. The built-in `openAI`
    endpoint was retired outright so that no second route to them can exist.

    Read **[GPT-5.6 and the Responses API](../modules/models-gpt56-responses.md)**
    before changing that line. It is the least obvious thing in this repository and
    the failure it prevents does not show up until a user tries to use a tool.

See **[Adding and retiring models](../modules/models.md)** for the general process.

## Then, when you need them

| Want | Read |
|---|---|
| Nobody manages another password | [Single sign-on](../modules/sso-oidc.md) |
| The AI can reach your own systems | [Custom tools (MCP)](../modules/mcp-servers.md) |
| The AI can run code and analyze spreadsheets | [Code interpreter](../modules/code-interpreter.md) |
| To know backups actually work | [Backup and restore](../modules/backups.md) |
| To move an existing LibreChat here | [Migrating an existing install](../modules/migrating-an-existing-install.md) |

## One last thing

Put a note in your calendar for three months from now to
[test a restore](../modules/backups.md#test-your-restore). An untested backup is not
a backup, and it takes five minutes to find out which one you have.
