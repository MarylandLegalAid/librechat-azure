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

The registry is configuration you commit. **The `.docx` files are never committed to
git.** They live on the data disk and are read at runtime:

```
/srv/librechat/data/letterheads/
├── generic.docx
├── baltimore-city.docx
└── montgomery-county.docx
```

`.gitignore` blocks `*.docx` repository-wide and CI fails the build if one appears.
That is not paranoia about file size — it is so that a public fork of this blueprint
can never carry another organization's letterhead.

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

`letterheads.json` in your fork:

```json
[
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
    "aliases": ["baltimore city", "baltimore city office"]
  }
]
```

`aliases` is how a fuzzy office name from a case management system, or from a user
typing, resolves to the right letterhead. Be generous with them — a missed match
falls back to the generic letterhead, which is a wrong-looking letter rather than an
error.

### 3. Switch it on

```bash
V=$(az keyvault list -g rg-librechat-prod --query "[0].name" -o tsv)
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

Then ask for a letter and open what comes back. Check the letterhead is the right
office's — the fallback to generic is silent by design, so the only way to know
matching worked is to look.
