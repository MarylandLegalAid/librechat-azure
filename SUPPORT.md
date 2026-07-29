# Support

This repository is published as a **blueprint**, not as a product. Being honest
about what that means is more useful to you than an implied promise nobody can keep.

## What this is

Maryland Legal Aid runs its own LibreChat deployment from this exact repository.
That is deliberate: a blueprint nobody runs rots quietly, and you would be the one
to discover it. When something here is broken, it is usually broken for us too.

## What we can and cannot do

| | |
|---|---|
| **Bug reports** | Please open an issue. We read them. We fix the ones that also affect our own deployment quickly, and the rest on a best-effort basis. |
| **Questions about this blueprint** | Open a discussion or an issue. Best effort, no response-time commitment. |
| **Questions about LibreChat itself** | Please take those upstream — [LibreChat docs](https://www.librechat.ai/docs), [LibreChat Discord](https://discord.librechat.ai). We did not write LibreChat and cannot support it. |
| **Questions about Azure** | Microsoft support, or your Azure reseller. We cannot see your subscription and cannot debug it for you. |
| **Your production incident** | We cannot help. There is no on-call rotation behind this repository. |
| **Security issues** | Do **not** open a public issue. See [Reporting a security issue](#reporting-a-security-issue). |

## Pilot participants

If you are a grantee organization participating in the funder-sponsored pilot,
your support runs **through the funder**, out of band from this repository — that
channel is staffed and this one is not. Use it. Filing here instead will be slower
and will not reach the people assigned to help you.

Issues that turn out to be blueprint bugs are welcome here in addition, because a
fix helps everyone who comes after you.

## Before you file

Two things resolve a large share of reports on their own:

1. **`docs/troubleshooting.md`** — the failures we have actually hit, with their causes.
2. **`scripts/deploy.sh` output.** Run it with `--force` and read the log. It reports
   what it pulled, what it started, and why a health check failed. Paste that output
   into your issue; a report without it is usually unactionable.

Please also say which LibreChat image tag you are on (`docker compose images api`)
and whether you have modified `librechat.yaml`.

## Reporting a security issue

Email the address in the repository's GitHub security policy rather than opening an
issue. If you believe a **secret has been committed to this repository**, treat that
as urgent and report it the same way — a public issue would advertise it.

## No warranty

This software is provided under the [MIT License](./LICENSE), without warranty of
any kind. You are responsible for your own deployment, your own data, and your own
compliance obligations. `docs/compliance.md` is written to help you reason about
the last of those; it is not legal advice and does not create a relationship of any
kind between your organization and Maryland Legal Aid.
