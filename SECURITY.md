# Security policy

## Reporting a vulnerability

**Please do not open a public issue.** A public issue describing a vulnerability tells
everyone running this blueprint about it at the same moment it tells us, including the
people who have not patched yet.

Use GitHub's private vulnerability reporting instead:

**[Report a vulnerability →](https://github.com/MarylandLegalAid/librechat-azure/security/advisories/new)**

That opens a private conversation visible only to the maintainers. You can attach
details and proof-of-concept code to it safely.

## What is in scope

This repository is a **deployment blueprint**. In scope:

- Anything in `infra/` that provisions a resource less securely than it should
- Anything in `scripts/` that could expose a secret, or that runs untrusted input
- Compose or Caddy configuration that exposes a service it should not
- Defaults in `librechat.yaml` or `env.defaults` that are unsafe for the audience this
  is written for
- Documentation that instructs a reader to do something insecure

**Out of scope**, because we did not write them and cannot fix them:

- LibreChat itself → [LibreChat security policy](https://github.com/danny-avila/LibreChat/security)
- MongoDB, Meilisearch, pgvector, Caddy, Docker, Azure
- Your own deployment's configuration

If you are unsure which side of that line something falls on, report it here and we
will route it.

## If you find a secret in this repository

Report it privately, the same way, and treat it as urgent. Do **not** open an issue —
that would advertise it.

Nothing should ever get this far: `.gitignore` blocks the categories, `gitleaks` scans
the full history on every push and monthly, and GitHub push protection refuses commits
containing recognized credentials. If something slipped through all of that, we want to
know immediately so it can be rotated before it is cleaned from history — in that
order, because rewriting history does not un-publish an object that has already been
fetched.

## What to expect

We aim to acknowledge a report within a week. This is a legal aid organization
maintaining a blueprint it depends on, not a vendor with a security team, and
[SUPPORT.md](./SUPPORT.md) is honest about what that means.

For anything affecting a running deployment's confidentiality, say so plainly in the
report and we will prioritize accordingly.

## Supported versions

`main` only. This is a deployment blueprint that its own maintainers run continuously;
there are no release branches and no backports. Fixes land on `main`, and every
deployment following the blueprint picks them up on its next deploy.
