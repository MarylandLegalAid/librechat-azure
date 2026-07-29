# Code interpreter

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
([ClickHouse/code-interpreter](https://github.com/ClickHouse/code-interpreter)) keeps
everything inside infrastructure you control.

If that distinction does not matter for your data, the hosted option is much less
work.

## What it costs

A `Standard_D2s_v5` — about **$70/month** — plus its disk and public IP. That size
class supports nested virtualization, which is the whole reason it is viable. Two
concurrent executions is a reasonable starting point.

Realistically this doubles the infrastructure cost of the deployment. Decide whether
you want the capability before building it.

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
V=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)

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

Out of scope for this blueprint — it is a separate deployment with its own hardening,
monitoring and operational story. The
[upstream project](https://github.com/ClickHouse/code-interpreter) is the starting
point.

What is in scope is everything above: how LibreChat reaches it, how authentication
works, and what to verify.
