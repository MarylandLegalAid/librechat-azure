# 1. Create the infrastructure

About ten minutes, most of it waiting for Azure.

This step creates everything the application runs on: a virtual machine, a network
with a firewall, a separate disk for your data, a key vault for your secrets, a
storage account for backups, and monitoring. It does **not** start the application —
that happens in step 4, once your secrets exist.

## Option A — the portal button

The simplest path, and the one to use if you do not want to install anything.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMarylandLegalAid%2Flibrechat-azure%2Fmain%2Finfra%2Fmain.json)

The portal will ask you to fill in a form. Most fields have sensible defaults. Four
need your attention:

### Resource group

Create a new one called `rg-librechat-prod`. Keeping this deployment in its own
resource group means you can delete the whole thing later with one action, and see
its cost as a single line on your bill.

### Admin SSH public key

The **public** half of an SSH key pair — a single line beginning `ssh-ed25519` or
`ssh-rsa`. Never the private half.

If you do not have one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/librechat -C librechat-admin
cat ~/.ssh/librechat.pub          # this is what you paste
```

This is a break-glass account. Day to day you will sign in with your Entra ID
identity instead, which needs no key file — see [SSH with Entra ID](../modules/entra-ssh.md).

### Admin source address prefixes

The only addresses allowed to reach SSH. Everything else is refused at the network,
before it reaches the machine.

```bash
curl -fsS https://api.ipify.org        # your current public address
```

Enter it with `/32` on the end, e.g. `203.0.113.4/32`.

!!! warning "Home internet addresses change"
    Most home broadband connections get a new address every so often, without
    warning. When yours changes you will be locked out of SSH.

    This is **recoverable and takes about a minute** — you edit the firewall rule in
    the Azure Portal, which does not require SSH. [Read how, now](../troubleshooting.md#locked-out-of-ssh),
    rather than while it is happening.

    If you have an office with a fixed address range, list that too.

### Alert email

Where monitoring alerts go, including the one that fires when the site is down.
A shared mailbox somebody reads beats an individual's address that goes quiet
during annual leave.

Then click **Review + create**, then **Create**. Azure takes five to ten minutes.

## Option B — the command line

If you would rather see exactly what is being created:

```bash
git clone https://github.com/MarylandLegalAid/librechat-azure.git
cd librechat-azure

cp infra/main.parameters.example.json infra/main.parameters.json
$EDITOR infra/main.parameters.json          # fill in the four starred values

az login
az group create --name rg-librechat-prod --location eastus2

az deployment group create \
  --resource-group rg-librechat-prod \
  --template-file infra/main.bicep \
  --parameters @infra/main.parameters.json
```

`infra/main.parameters.json` is gitignored — it names your machine and your admin
addresses, which is not information to publish.

To see what a change would do before doing it, replace `create` with `what-if`.

## When it finishes

Azure prints several outputs. Write down two of them:

| Output | What it is for |
|---|---|
| `publicIpAddress` | The address your DNS record will point at (step 3) |
| `keyVaultName` | Where your secrets go (step 2). It carries a short uniqueness suffix — key vault names must be unique across all of Azure, not just your subscription — so read it rather than guessing it. |

From the command line:

```bash
az deployment group show \
  --resource-group rg-librechat-prod \
  --name main \
  --query properties.outputs
```

## What just happened

The machine is now booting and setting itself up: installing Docker, formatting and
mounting the data disk, and cloning this repository. That takes another five minutes
or so after Azure reports success.

**The application is not running, and that is correct.** It has no secrets yet, so
starting it now would produce a misconfigured instance that then has to be repaired
rather than simply started. Step 4 starts it.

---

Next: **[Add your secrets](02-secrets.md)**
