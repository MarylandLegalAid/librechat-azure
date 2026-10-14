# Code interpreter

!!! note "Optional"
    Everything on this page is an add-on. The chat deployment works without it; set
    `interface.runCode: false` in `librechat.yaml` if you do not build it.

Lets the model write and run code — analyze a spreadsheet, produce a chart, reshape a
dataset — and return the results and any files it produced.

This is the one component that **cannot run in this Compose stack**. It needs its own
machine.

## Why a second machine

Each execution boots a micro virtual machine for isolation, which requires `/dev/kvm`.
No shared container platform exposes that to tenants, and running it as an ordinary
container alongside everything else would mean generated code sharing a kernel with
your database.

So it is a second Azure VM, reachable at its own hostname, with only Caddy exposed.

## Why self-host it at all

LibreChat offers a hosted code interpreter API. Using it would mean client files and
generated code executing on a third party's infrastructure — the same confidentiality
problem your terms of service probably warn about for web search.

Self-hosting the open-source engine behind it
([LibreChat-AI/code-interpreter](https://github.com/LibreChat-AI/code-interpreter))
keeps everything inside infrastructure you control.

If that distinction does not matter for your data, the hosted option is much less
work.

## What it costs

A `Standard_D2s_v5` — about **$70/month** for compute, or roughly **$85/month** with
its disk and public IP. That size class supports nested virtualization, which is the
whole reason it is viable. Two concurrent executions is a reasonable starting point.
The health log workspace adds cents: one short line a minute.

The interpreter adds roughly $85/month to the infrastructure bill. Decide whether you
want the capability before building it.

## How authentication works

There is **no shared API key**, and users never enter one.

LibreChat mints a **short-lived per-user EdDSA token** for every execution
(`CODEAPI_AUTH_PROVIDER=librechat-jwt`, supported since v0.8.7). LibreChat holds the
private key; the interpreter machine holds only the matching public JWKS.

That means an execution is attributable to a person, a leaked token is useless within
minutes, and there is no long-lived credential to rotate.

!!! warning "A key mismatch is the most likely failure, and it is opaque"
    Every field except the private key must mirror the interpreter machine's own
    configuration **exactly**: issuer, audience, tenant, and key id.

    A mismatch produces a 401 at execution time with no indication of which field is
    wrong. **Exercise this on staging, well before you need it.**

## Wiring it up

Once the interpreter machine is running:

```bash
V=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

az keyvault secret set --vault-name $V --name LIBRECHAT-CODE-BASEURL \
  --value "https://code.yourorg.org/v1" --output none
az keyvault secret set --vault-name $V --name CODEAPI-AUTH-PROVIDER   --value "librechat-jwt" --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-ALGORITHM   --value "EdDSA"     --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-ISSUER      --value "librechat" --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-AUDIENCE    --value "codeapi"   --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-KID         --value "<your key id>" --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-TTL-SECONDS --value "300"       --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-MINT-CACHE-SECONDS --value "30" --output none
az keyvault secret set --vault-name $V --name CODEAPI-JWT-SINGLE-TENANT-ID   --value "<your tenant id>" --output none

# The Ed25519 PRIVATE key as ONE LINE of compact JSON. The interpreter machine
# holds only the public half. render-env.sh refuses a multi-line value, because
# a .env file cannot represent one.
az keyvault secret set --vault-name $V --name CODEAPI-JWT-PRIVATE-JWK-JSON \
  --value "$(cat private-jwk.json | jq -c .)" --output none
```

Then in `librechat.yaml`:

```yaml
interface:
  runCode: true
```

This repository ships `runCode: true`. **Set it to `false` if you are not running an
interpreter** — otherwise users get a "Run Code" button that fails.

## Checking it works

### First, before opening the app at all

The likeliest thing to be wrong is a **key mismatch**: LibreChat holding a private key
whose public half is not the one the interpreter trusts. It fails only when a user
clicks Run Code, and it fails as an opaque authentication error.

You do not need to run anything to rule that out. Compare the two halves directly —
the private key stays in a variable and is never printed:

```bash
V=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)

PRIV="$(az keyvault secret show --vault-name "$V" -n CODEAPI-JWT-PRIVATE-JWK-JSON --query value -o tsv)" \
python3 - <<'PY'
import base64, json, os, urllib.request
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

priv = json.loads(os.environ['PRIV'])
b64d = lambda s: base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
b64e = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()

derived = b64e(Ed25519PrivateKey.from_private_bytes(b64d(priv['d'])).public_key()
               .public_bytes(encoding=serialization.Encoding.Raw,
                             format=serialization.PublicFormat.Raw))

# Your interpreter's published JWKS. Adjust the path if yours differs.
url = os.environ.get('JWKS_URL', 'https://code.example.org/v1/.well-known/jwks.json')
with urllib.request.urlopen(url, timeout=20) as r:
    keys = json.load(r).get('keys', [])

trusted = next((k for k in keys if k.get('kid') == priv['kid']), None)
if trusted is None:
    raise SystemExit(f"FAIL: the interpreter trusts no key with kid {priv['kid']}")
print("OK: key pair confirmed" if trusted['x'] == derived == priv['x']
      else "FAIL: the private key does not pair with the trusted public key")
PY
```

If the interpreter does not publish a JWKS endpoint, compare against whatever secret
holds its public set instead — the assertion is the same: the `x` in the trusted public
key, the `x` in the private JWK, and the `x` derived from the private `d` must all be
identical, for a `kid` the interpreter actually lists.

### Then, in the app

- [ ] Ask for a chart from a small dataset. You should get an image back.
- [ ] Upload a CSV and ask for a summary. Confirm the file reaches the sandbox.
- [ ] Ask it to fetch a URL. It should **fail** — the sandbox has no internet access,
      and confirming that is confirming the isolation.
- [ ] Check the interpreter machine's logs and see the execution attributed to your
      user.

The third one is the interesting test. Run it.

## Say so in your terms of service

Users are uploading client files into something that executes code. Tell them what
happens to them: where execution occurs, that the sandbox has no internet access, how
long workspaces and session files are retained, and that they remain responsible for
reviewing what comes back.

The terms of service in this repository's `librechat.yaml` has a section covering
this. It is worth reading as a model even if your wording differs.

## Building the interpreter machine

The machine is defined in this repository and deploys the same way the chat VM does:
a Bicep template, a first-boot script that prepares the host and stops, secrets in Key
Vault rendered into `.env` at deploy time, and a five-minute deploy timer.

| Where | What |
|---|---|
| `infra/codeinterpreter/main.bicep` | VM, firewall (443 and admin SSH only), key vault, health monitoring and alerts |
| `infra/codeinterpreter/cloud-init.yaml` | First boot: Docker, Azure CLI, a checkout of this repository, the deploy timer |
| `codeinterpreter/compose.yaml` | The stack: upstream's published images pinned by digest, plus Caddy, Redis and Garage |
| `codeinterpreter/env.defaults` | Every non-secret setting, including the limits your terms of service promise |
| `scripts/codeinterpreter-seed-secrets.sh` | Generates the machine's secrets into its vault, from your workstation |
| `scripts/codeinterpreter-deploy.sh` | The only thing that starts the stack; rolls back on a failed health check |

### 1. Create the machine

Put it in its own resource group, so retiring it later is one delete:

```bash
az group create --name rg-codeinterpreter-prod --location eastus2
az deployment group create \
  --resource-group rg-codeinterpreter-prod \
  --template-file infra/codeinterpreter/main.bicep \
  --parameters adminSshPublicKey="$(cat ~/.ssh/librechat.pub)" \
               adminSourceAddressPrefixes='["203.0.113.4/32"]' \
               actionGroupId="<the chat deployment's action group resource ID>" \
               dnsLabel=codeinterpreter-<something-unique>
```

`actionGroupId` sends this machine's alerts to the same people as the chat VM's. Leave
it out and pass `alertEmail` instead to create a separate group. `dnsLabel` gives the
machine an Azure hostname (`<label>.<region>.cloudapp.azure.com`) so you can test it
before your own hostname points at it.

The template outputs the vault name. Give yourself **Key Vault Secrets Officer** on that
vault for the next step.

### 2. Seed its secrets

```bash
scripts/codeinterpreter-seed-secrets.sh \
  --vault <interpreter vault> \
  --chat-vault <the chat VM's vault> \
  --domain <the hostname this machine will answer on> \
  --acme-email <address for certificate notices>
```

It generates every secret the stack needs and writes them straight to the vault without
printing them. It also derives the public JWT key from the chat VM's
`CODEAPI-JWT-PRIVATE-JWK-JSON`, so the two halves of the key pair cannot disagree. It
refuses if that private key's own `x` does not match its `d`.

It is safe to re-run: existing secrets are left alone unless you name them with
`--rotate`.

### 3. Deploy

Point the hostname's DNS A record at the machine first (or use the `dnsLabel` hostname).
Port 80 is closed on this machine, so the certificate is issued over port 443 alone.

```bash
az ssh vm -g rg-codeinterpreter-prod -n vm-codeinterpreter-prod
sudo /srv/codeinterpreter/app/scripts/codeinterpreter-deploy.sh --force
```

The first deploy pulls the sandbox image, which is large: allow about five minutes.
After that the timer checks for new commits every five minutes.

Then set `LIBRECHAT-CODE-BASEURL` on the chat VM (see [Wiring it up](#wiring-it-up)) and
run [the checks](#checking-it-works).

## Moving a hostname to a rebuilt machine

When a new interpreter machine replaces an old one under the same hostname,
LibreChat needs no change at all: `LIBRECHAT-CODE-BASEURL` stays the same.

1. **A day ahead,** lower the hostname's DNS TTL to five minutes.
2. **On the new machine,** build it and run the [checks](#checking-it-works) against
   its `dnsLabel` hostname first.
3. Set the new vault's `CODE-DOMAIN` to the real hostname. Leave the old machine
   running: it is your rollback.
4. Change the hostname's A record to the new machine's address.
5. Wait for `scripts/check-dns.sh <hostname> <new address>` to say GO. Do not skip
   this; see the rate-limit warning in
   [migrating an existing install](migrating-an-existing-install.md).
6. `sudo /srv/codeinterpreter/app/scripts/codeinterpreter-deploy.sh --force` on the new
   machine. Caddy obtains a certificate for the real hostname.
7. Run the checks again, from the app.
8. Stop-deallocate the old machine the next day, and keep it for two weeks.

**Rollback** is pointing the A record back while the old machine still runs.
Nothing a user cares about is lost either way. Session files are disposable, and
LibreChat keeps its own copy of every uploaded and generated file. When a file it
expects is missing from the interpreter, it uploads it again.

## What differs from upstream's compose file

`codeinterpreter/compose.yaml` is a separate file, not an overlay on upstream's
`docker-compose.yaml`, because upstream's is written for a laptop:

- it hard-codes development passwords and a default execution-manifest signing key;
- it turns the bring-your-own-machine bridge **on**;
- it pulls MinIO, which can no longer be pulled (below).

An overlay has to remember to override every one of those, and the one it forgets is
silently insecure. In this file nothing is inherited, every secret is required, the
bridge stays at its disabled default, and Caddy refuses `/v1/bridge` and `/metrics` as
a second line.

### Garage instead of MinIO

The file server keeps session files in an S3-compatible store. Upstream uses MinIO,
whose community images stopped being published in late 2025; every registry copy is
now private, so a clean host cannot start upstream's stack at all
([#252](https://github.com/LibreChat-AI/code-interpreter/issues/252),
[#327](https://github.com/LibreChat-AI/code-interpreter/issues/327)).

This module uses [Garage](https://garagehq.deuxfleurs.fr/), which is maintained, AGPL
like MinIO, publishes official images, and supports everything the file server does.
An hourly `rclone` job deletes files older than 24 hours. Garage's own lifecycle rules
run once a day, which would let a file live for up to 48 hours, and your terms of
service probably say 24.

## Upgrading the interpreter

Upstream publishes images tagged only `sha-<commit>` and a moving `main`. There are no
version tags and no `latest`, so neither Renovate nor `docker compose pull` will tell
you about a release.

1. Find the release's commit: `git rev-list -n1 v<version>` in a clone of upstream.
2. Find that commit's `sha-` images. A commit that changed no image inputs has none;
   use the nearest earlier commit that does.
3. Resolve each image to a digest, for example
   `docker buildx imagetools inspect ghcr.io/librechat-ai/code-interpreter-api:sha-<commit>`,
   and replace the six digests in `codeinterpreter/compose.yaml`.
4. Diff upstream's `docker-compose.yaml` between the two tags, and carry over any new
   variable that matters. Leave out anything that turns on a feature you do not use.
5. **Run a real execution before trusting it.** Health checks are not enough.
   v1.10.4 passed every one and failed every execution, because its sandbox could not
   find a native module inside the micro-VM
   ([#320](https://github.com/LibreChat-AI/code-interpreter/issues/320),
   [#329](https://github.com/LibreChat-AI/code-interpreter/issues/329)). This module
   stays on v1.10.3 until that is fixed.

## Monitoring

Once a minute, `scripts/codeinterpreter-health.sh` writes one line to syslog with
counts only and no user data:

- workers running;
- jobs waiting;
- whether file cleanup succeeded, and when it last ran;
- files past their retention;
- missing containers and restarts;
- disk use.

Azure Monitor ships that line to Log Analytics, and seven alert rules read it.

The **heartbeat** alert fires when the line stops arriving. It is the one to trust,
because every other alert goes quiet, not loud, when the line is missing. The VM also
has the usual host-metric alerts (CPU, memory, disk).

## Known limits

- **Uploads stop just short of 50 MiB.** Caddy refuses any upload request of 50 MiB,
  framing included, before the API sees it. Upstream's API restarts itself, dropping
  every execution in flight, when it has to reject an oversized file
  ([#266](https://github.com/LibreChat-AI/code-interpreter/issues/266)), and LibreChat
  allows uploads far larger than that by default. The cost is that a batch upload whose
  files together reach 50 MiB is refused as well.
- **The tenant claim is required but not pinned.** Strict tenant isolation makes every
  token carry a tenant and keys every session by it. It does not reject a token whose
  tenant differs from `CODEAPI_JWT_SINGLE_TENANT_ID`. Only the chat VM can sign tokens,
  and it always stamps its own tenant, so that check would be defence in depth that
  upstream does not offer.
- **Nothing here is backed up**, on purpose. Workspaces last an hour and session files a
  day; a rebuilt machine starting empty is correct.
