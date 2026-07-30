# 2. Add your secrets

About ten minutes.

Your API keys and other secrets live in **Azure Key Vault**, never in a file. The
virtual machine reads them at deploy time using its own identity, so there is no
password, key file, or service principal anywhere on the machine for anyone to find.

## The one thing that trips everyone up

**Azure Key Vault secret names cannot contain underscores.** The convention is that a
dash in a secret name becomes an underscore in the application:

| Key Vault secret name | becomes the variable |
|---|---|
| `OPENID-CLIENT-SECRET` | `OPENID_CLIENT_SECRET` |
| `ANTHROPIC-API-KEY` | `ANTHROPIC_API_KEY` |
| `CREDS-KEY` | `CREDS_KEY` |

Store `ANTHROPIC-API-KEY`. `ANTHROPIC_API_KEY` will be rejected by Azure outright,
which is the good outcome. A name with a *typo* is accepted silently and simply never
becomes the variable you wanted, and the application starts up missing it.

## Give yourself permission

Creating the vault does not give you access to its contents — that is a separate role
assignment, and it is deliberate.

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)
SUBSCRIPTION=$(az account show --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee "$ME" \
  --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/rg-librechat-prod/providers/Microsoft.KeyVault/vaults/$VAULT"
```

Role assignments take a minute or two to take effect. If the next command says you
lack permission, wait and try again.

## Seed the vault

Paste this whole block. It generates the values that should be random and prompts you
for the ones only you know.

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

set() { az keyvault secret set --vault-name "$VAULT" --name "$1" --value "$2" --output none && echo "  set $1"; }

# --- Generated. You never need to see or keep these. ---
set CREDS-KEY                  "$(openssl rand -hex 32)"
set CREDS-IV                   "$(openssl rand -hex 16)"
set JWT-SECRET                 "$(openssl rand -hex 32)"
set JWT-REFRESH-SECRET         "$(openssl rand -hex 32)"
set MEILI-MASTER-KEY           "$(openssl rand -hex 32)"
set POSTGRES-PASSWORD          "$(openssl rand -hex 32)"
set ADMIN-PANEL-SESSION-SECRET "$(openssl rand -hex 32)"

# --- Yours. Change these to your real values. ---
set CHAT-DOMAIN       "chat.yourorg.org"
set ADMIN-DOMAIN      "chat-admin.yourorg.org"
set DOMAIN-CLIENT     "https://chat.yourorg.org"
set DOMAIN-SERVER     "https://chat.yourorg.org"
set ADMIN-PANEL-URL   "https://chat-admin.yourorg.org"
set ACME-EMAIL        "it@yourorg.org"
set APP-TITLE         "Your Organization AI"

# --- At least one of these. ---
set ANTHROPIC-API-KEY "sk-ant-..."
# set OPENAI-API-KEY  "sk-..."

# --- Where nightly database dumps go. Use the name Azure generated for you. ---
set BACKUP-STORAGE-ACCOUNT "$(az storage account list -g rg-librechat-prod --query '[0].name' -o tsv)"
```

!!! danger "Migrating an existing LibreChat?"
    **Do not generate `CREDS-KEY` and `CREDS-IV`.** Copy them verbatim from your old
    installation, before anything else.

    Those two values encrypt every API key your users have saved. New values do not
    produce an error and do not lose any data you can see — they make every stored
    key permanently undecryptable, and you find out when users report that their keys
    stopped working. There is no recovery.

    Stop here and read
    **[Migrating an existing install](../modules/migrating-an-existing-install.md)** first.

## Check it

```bash
VAULT=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret list --vault-name "$VAULT" --query "[].name" -o tsv | sort
```

You should see the names above. Values are not printed, which is the point.

## What else can go in here

[`.env.example`](https://github.com/MarylandLegalAid/librechat-azure/blob/main/.env.example)
in the repository is the complete catalogue of every variable, what it does, and
whether it belongs here or in `env.defaults`. You do not need any of the optional
ones yet.

Anything you put in the vault overrides the repository's default of the same name.
That is how a deployment customizes itself without editing files that would then
conflict every time you pull an update.

---

Next: **[Point your domain at it](03-dns.md)**
