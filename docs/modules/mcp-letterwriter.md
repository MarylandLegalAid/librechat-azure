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

## The document comes back directly

The tool returns the `.docx` as **MCP binary content**, and LibreChat attaches it to
the conversation.

An earlier version uploaded to S3 and returned a presigned link. Returning the file
directly is better in three ways: it works identically in both storage modes, there is
no link to expire, and there is no object store credential in the tool at all.

## Checking it works

```bash
docker compose exec api curl -fsS http://letterwriter-mcp:3002/healthz
```

```json
{"ok":true,"service":"letterwriter-mcp","version":"1.0.0",
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
