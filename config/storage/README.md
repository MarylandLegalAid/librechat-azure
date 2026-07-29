# Storage overlays

Two files, one key each. This directory exists to work around a specific limitation,
and the workaround looks like over-engineering until you know why.

## Why `fileStrategy` cannot be an environment variable

Everywhere else in `librechat.yaml`, `${SOME_VAR}` interpolation works, so the obvious
design is:

```yaml
fileStrategy: "${FILE_STRATEGY}"     # does not work
```

It does not work. `fileStrategy` is parsed as a **zod enum** when the config is loaded
into `appConfig`, and LibreChat applies `${VAR}` interpolation **selectively** — not to
that key. The literal string `${FILE_STRATEGY}` reaches the enum validator, fails to
match `local | s3 | firebase | azure_blob | cloudfront`, and the app refuses to start.

So the choice has to be made *before* LibreChat reads the file. That is what the merge
in `scripts/deploy.sh` does:

```bash
yq eval-all '. as $item ireduce ({}; . * $item)' \
  librechat.yaml config/storage/${FILE_STORAGE}.yaml > librechat.runtime.yaml
```

`librechat.runtime.yaml` is what gets bind-mounted into the container. It is gitignored —
it is a build artifact, not a source file.

## The two halves

Selecting a storage mode changes two things, and they have to agree:

| | `FILE_STORAGE=disk` (default) | `FILE_STORAGE=s3` |
|---|---|---|
| Config overlay | `config/storage/disk.yaml` → `fileStrategy: local` | `config/storage/s3.yaml` → `fileStrategy: s3` |
| Compose overlay | `compose.storage.disk.yml` → bind-mounts uploads + images to the data disk | `compose.storage.s3.yml` → no bind mounts |

`deploy.sh` selects both from the single `FILE_STORAGE` variable, so they cannot drift
apart in a running deployment.

## Why both are validated in CI

Maryland Legal Aid runs `disk`. Nobody runs `s3` day to day, which means an upgrade
could break it and no one would find out until a grantee hit it in production. So
`.github/workflows/validate.yml` renders **both** merges and parses **both** Compose
overlays on every pull request.

That check is the mechanical counterpart to dogfooding: dogfooding protects the path we
run, CI protects the path we do not.

## Adding a third mode

Add `config/storage/<name>.yaml` and `compose.storage.<name>.yml`, then add `<name>` to
the matrix in `.github/workflows/validate.yml`. Nothing in `deploy.sh` needs to change —
it interpolates `FILE_STORAGE` into both filenames.

Note that `azure_blob` is deliberately **not** one of these. See
`docs/modules/storage-s3-legacy.md` for the verified reason it is not usable in v0.8.7.
