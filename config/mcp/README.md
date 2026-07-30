# MCP overlays

One file per MCP server, and **the filename is the Compose profile name**. That single
convention is the whole mechanism:

```
COMPOSE_PROFILES=mcp-legalserver
   ↓
compose.yaml    starts the service whose profiles: ["mcp-legalserver"]
config/mcp/mcp-legalserver.yaml    is merged into librechat.runtime.yaml
```

Turn a profile on and the server both **runs** and is **declared** to LibreChat. Leave
it off and neither happens. The two cannot disagree, because one variable drives both.

## Why this directory exists

`mcpServers` used to live directly in `librechat.yaml`. That meant the servers were
declared unconditionally while the Compose profiles that actually *run* them were off by
default — so a deployment with no MCP servers spent about **60 seconds at startup trying
to reach containers that were not there**, logging connection errors the whole time.

The app does come up. But "it works, ignore the errors" is a bad first impression to ship
in a blueprint, and it trains an operator to ignore exactly the logs they should read.

## How the merge works

`scripts/deploy.sh` assembles `librechat.runtime.yaml` from the base config, one storage
overlay, and one MCP overlay per enabled profile:

```bash
yq eval-all '. as $item ireduce ({}; . *+ $item)' \
  librechat.yaml config/storage/disk.yaml config/mcp/mcp-legalserver.yaml ...
```

**Note the `+` on the merge operator.** `*` alone *replaces* arrays, so with two MCP
overlays each contributing one `mcpSettings.allowedAddresses` entry, the second would
silently discard the first and that server's every connection would be refused at
runtime. `*+` appends them. Maps merge either way, so `mcpServers` is unaffected — this
flag exists solely for `allowedAddresses`.

The consequence for anyone adding an overlay here: **an array in an overlay is added to
the base, never a replacement for it.** If you ever need to replace one, do it in
`librechat.yaml`.

A profile with no matching file in this directory is skipped, not an error — profiles
are also a general Compose feature and need not all be MCP servers.

## Adding your own

1. `config/mcp/mcp-yourtool.yaml` — an `mcpServers` entry and its
   `mcpSettings.allowedAddresses` line. Both. The allow-list entry is the one people
   forget, and it fails at request time rather than at startup.
2. A service in `compose.yaml` with `profiles: ["mcp-yourtool"]`, matching the hostname
   and port in the URL.
3. Add `mcp-yourtool` to `COMPOSE_PROFILES` and redeploy.

`scripts/validate-config.sh` then checks, for every overlay in this directory, that each
`mcpServers` URL has a matching `allowedAddresses` entry, that its host is a real service
in `compose.yaml`, and that **the service carries the profile the file is named after**.
That last check is what catches a file named for one profile wired to a service in
another — a mismatch that produces a server which is declared but never running, or
running but never declared.

See `docs/modules/mcp-servers.md` for the full walkthrough.
