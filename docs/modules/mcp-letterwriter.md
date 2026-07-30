# LetterWriter

Generates a Word document on your organization's letterhead and attaches it to the
conversation. A caseworker describes the letter; the model produces a formatted
document with the right office's branding on it.

**Repository:** [MarylandLegalAid/letterwriter-mcp](https://github.com/MarylandLegalAid/letterwriter-mcp)

## Your letterheads are data, not code

Two pieces:

| | |
|---|---|
| `letterheads.json` | A registry describing your offices — identifiers, labels, and the names you or your case system call them. |
| `.docx` template files | The actual letterhead documents, one per office. |

**Neither is committed to git.** Both live together on the data disk and are read at
runtime from `LETTERHEAD_DIR`:

```
/srv/librechat/data/letterheads/       # LETTERHEAD_DIR
├── letterheads.json
├── generic.docx
├── baltimore-city.docx
└── montgomery-county.docx
```

`.gitignore` blocks `*.docx` repository-wide and `.github/workflows/secrets.yml` fails
the build if one appears. That is not paranoia about file size — it is so that a public
fork of this blueprint can never carry another organization's letterhead.

The registry stays out of git for a weaker but real reason: it names your offices. It
is not a secret, but it is not something a fork should inherit either, and keeping it
beside the `.docx` files it describes means one directory holds everything an
organization has to supply — and Azure Backup covers all of it.

If `LETTERHEAD_DIR` has no `letterheads.json`, the image falls back to a placeholder
registry with a single blank letterhead, so the service still starts. See the
troubleshooting note at the end — that fallback is easy to mistake for working.

## Turning it on

### 1. Put your templates on the data disk

```bash
scp letterheads/*.docx vm-librechat-prod:/tmp/
az ssh vm -g rg-librechat-prod -n vm-librechat-prod
sudo mv /tmp/*.docx /srv/librechat/data/letterheads/
sudo chmod 0644 /srv/librechat/data/letterheads/*.docx
```

They are covered by Azure Backup along with everything else on that disk.

### 2. Describe them

Write `letterheads.json` **into the same directory**,
`/srv/librechat/data/letterheads/`:

```json
{
  "defaultId": "generic",
  "stopWords": ["office", "maryland legal aid"],
  "letterheads": [
    {
      "id": "generic",
      "label": "Generic",
      "file": "generic.docx",
      "aliases": ["generic", "statewide"]
    },
    {
      "id": "baltimore_city",
      "label": "Baltimore City",
      "file": "baltimore-city.docx",
      "aliases": ["baltimore city", "baltimore city office"],
      "legalserver_offices": ["Baltimore City"],
      "include_unit_name": true
    }
  ]
}
```

| Field | Means |
|---|---|
| `id` | Stable machine name; what an explicit `letterhead_id` accepts |
| `label` | Human name, shown when the model lists the letterheads |
| `file` | A **bare filename** in `LETTERHEAD_DIR`. A path is refused. |
| `aliases` | Free-text spellings that should resolve to this office |
| `legalserver_offices` | Exact office names as LegalServer spells them, so a matter lookup resolves correctly |
| `include_unit_name` | When true, a `unit_name` argument joins this office's signature block |
| `defaultId` | Which letterhead to use when nothing matches |
| `stopWords` | Words ignored when matching. **Put your organization's own name here** so "Maryland Legal Aid — Baltimore City Office" matches `baltimore city`. |

`aliases` is how a fuzzy office name from a case management system, or from a user
typing, resolves to the right letterhead. Be generous with them — a missed match
falls back to the default letterhead, which is a wrong-looking letter rather than an
error. Matching prefers the **longest** alias that fits, so `baltimore county suite 300`
wins over `baltimore county` rather than depending on the order of the file.

`include_unit_name` exists because that is a per-office convention: MLA includes the
unit in Baltimore City signature blocks and nowhere else. It was hardcoded to that one
office; now it is a flag, which is what makes the tool reusable.

### 3. Switch it on

```bash
V=$(az keyvault list -g rg-librechat-prod --query "[?starts_with(name,'kv-')].name | [0]" -o tsv)
az keyvault secret set --vault-name $V --name COMPOSE-PROFILES \
  --value "mcp-letterwriter" --output none
az keyvault secret set --vault-name $V --name ORGANIZATION-NAME \
  --value "Your Organization" --output none
```

`ORGANIZATION_NAME` is the first line of the signature block.

Then redeploy.

!!! note "It refuses to start if a template is missing"
    If `letterheads.json` names a file that is not in `LETTERHEAD_DIR`, the service
    fails at startup and tells you which file.

    That is deliberate. The alternative is failing the first time a caseworker tries
    to send a letter, which is a much worse moment to find out.

## Template placeholders

Your `.docx` files use `{placeholder}` markers where content goes:

| Placeholder | Content |
|---|---|
| `{today}` | Date, written out long |
| `{client_name}` | Recipient's full name |
| `{address1}`, `{address2}` | Address lines |
| `{honorific}`, `{client_last_name}` | Salutation |
| `{message_body}` | The letter itself |
| `{attorney}` | Author's name |
| `{signature_lines}` | Organization and office, assembled automatically |

Edit these in Word like any other document. The only requirement is that the braces
survive — Word sometimes splits a placeholder across formatting runs if you edit it
character by character, which makes it stop being recognized. If a placeholder is not
being replaced, retype it in one go.

## How the document comes back

The tool writes the `.docx` to the data disk and returns a **download URL on your own
domain**, which Caddy serves at `/letters/<token>/<filename>.docx`.

### Why not simply attach it

The MCP specification lets a tool return bytes directly, as an embedded resource with a
base64 `blob`, and `letterwriter-mcp` did exactly that in v1.0.0. **LibreChat v0.8.7 does
not read it.** Its tool-result handler has cases for text, image and resource, and the
resource case looks only at `ui://` URIs, `text`, `uri` and `mimeType`. `blob` is never
touched — `grep` it in `packages/api` and you get nothing.

The failure is quiet and misleading. The letter renders correctly, the tool call succeeds,
and the model receives a description of a file with no way to produce it. What a user sees
is a confident download link pointing at `file:///Closing%20Letter.docx`, which the browser
resolves against the current page — so it looks like a link back to the chat application.

So delivery goes back to a URL, but not back to S3. The file is written to a directory the
deployment already serves. Nothing expires, and no cloud credential is involved.

### The three settings

| Where | Setting |
|---|---|
| `compose.yaml` | `LETTER_OUTPUT_DIR: /data/letters` and `LETTER_PUBLIC_BASE_URL: https://${CHAT_DOMAIN}/letters` |
| `compose.yaml` | `${DATA_DIR}/letters` mounted **writable** into the MCP, **read-only** into Caddy |
| `Caddyfile` | `handle_path /letters/*` with `root * /srv/letters` and `file_server` |

The MCP refuses to start if only one of the two variables is set — an output directory
with no URL writes files nobody can reach, and a URL with no directory advertises files
that were never written. `validate-config.sh` checks all four couplings, including that
the Caddy path matches the advertised URL.

!!! danger "Never enable `browse` on that `file_server`"
    Directory listing would let anyone who requests `/letters/` enumerate every token and
    therefore download every letter your organization has generated. It is off by default
    and one word away from being on. `validate-config.sh` fails the build if it appears.

### What the URL protects

The URL is a **capability**: whoever holds it can fetch that letter, with no LibreChat
session required. That is the same model as the presigned S3 link it replaces, minus the
expiry. Two things make it defensible:

- The token is 24 bytes from a CSPRNG, base64url-encoded. It is not guessable.
- The letter's text is already in the conversation that produced it — the agent drafted
  it there — so the file exposes nothing that conversation does not already hold.

Links **do not expire**, deliberately. An expiring link makes a letter written three weeks
ago look like data loss, which is the specific complaint that ended the S3 version. The
directory is ordinary files on the data disk, covered by Azure Backup, and can be pruned
by age if it ever grows enough to matter. At roughly 250 KB per letter it will take a
long time.

## Checking it works

```bash
docker compose exec api curl -fsS http://letterwriter-mcp:3002/healthz
```

```json
{"ok":true,"service":"letterwriter-mcp","version":"1.1.0",
 "letterheads":{"count":13,"default":"generic",
                "registry":"/data/letterheads/letterheads.json",
                "using_bundled_registry":false}}
```

!!! warning "Check `using_bundled_registry` before anything else"
    If it is `true`, the service never found your `letterheads.json` and is running on
    the placeholder registry that ships inside the image — one blank letterhead reading
    "[ YOUR LETTERHEAD ARTWORK GOES HERE ]".

    Everything else looks perfectly healthy in that state: the container is up, the
    health check passes, letters generate. They just come out blank-headed. The usual
    cause is a `LETTERHEAD_DIR` that is empty, or a data disk that did not mount.

    `count` is the other number worth reading — if it does not match the number of
    offices you described, you are not running the registry you think you are.

Then ask for a letter and open what comes back. Check the letterhead is the right
office's — the fallback to the default is silent by design, so the only way to know
matching worked is to look.
