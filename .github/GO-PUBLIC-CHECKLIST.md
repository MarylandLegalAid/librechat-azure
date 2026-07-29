# Going public

**Status: done. This repository was made public on 2026-07-29.**

Kept as a record of what was checked, and because anyone forking this blueprint
privately before publishing their own copy will need the same list.

## Why it happened earlier than planned

The original plan had this repository stay private until after the production cutover,
so that a live migration would not have an audience. Three capabilities turned out to
be unavailable on a private repository under a Free organization plan, and free the
moment it is public:

| | Private | Public |
|---|---|---|
| Secret scanning + push protection | ❌ | ✅ |
| GitHub Pages, for the documentation site | ❌ | ✅ |
| Cloning with no credential at all | ❌ | ✅ |

Deploy keys — the obvious way to bridge the third — are disabled organization-wide, so
keeping the repository private meant either changing a policy that affects every
repository in the organization, or issuing a personal access token.

So the private phase was costing the two mechanical protections that matter most for a
repository that will be published, in order to avoid an audience that a brand-new,
unadvertised repository does not have. Flipped early, deliberately.

## What was verified before flipping

Making a repository public exposes **every object in its history**, not just the tip. A
secret committed and removed the next day is still readable by anyone who looks.

- [x] `gitleaks git --redact --exit-code 1 .` over the full history — no leaks
- [x] `gitleaks dir` over the working tree — no leaks
- [x] No subscription ID, tenant ID, or production host address in any commit
- [x] No `.env`, `.pem`, `.docx`, or filled-in `main.parameters.json` in any commit
- [x] Internal planning documents absent, and blocked by `.gitignore` and by
      `.github/workflows/secrets.yml`

Two of these are now enforced on every push rather than checked by hand: the workflow
fails on a forbidden file type, and on any IP address in documentation outside the
ranges RFC 5737 reserves for examples.

## What was turned on at the flip

- [x] **Secret scanning and push protection.** Better than CI: a push containing a
      recognized credential is refused, rather than reported after the fact.

      ```bash
      gh api -X PATCH repos/OWNER/REPO \
        -f 'security_and_analysis[secret_scanning][status]=enabled' \
        -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
      ```

- [x] **GitHub Pages**, and the `PAGES_ENABLED` variable the docs workflow gates on.
      The site had been building on every push all along; only publishing was gated.

      ```bash
      gh api -X POST repos/OWNER/REPO/pages -f build_type=workflow
      gh variable set PAGES_ENABLED --body true
      ```

- [x] **Private vulnerability reporting**, plus `SECURITY.md`. Anyone can file an issue
      now, and a public issue is the wrong place for a vulnerability.

- [x] **The Deploy to Azure button.** It reads `infra/main.json` from the raw URL on
      `main`, so it could not resolve while the repository was private. Confirmed
      returning HTTP 200, valid ARM, 22 resources, three required parameters.

      CI already asserts `main.json` matches `main.bicep`; nothing had ever checked
      that the *link* resolved.

- [x] **No deploy key or token was ever issued.** A public repository needs no
      credential to clone, which is the entire configuration burden of autodeploy for
      someone adopting this: none.

## Still to do

- [ ] Branch protection on `main`, once the deploy pipeline is wired up and there is
      something for a required status check to require.
- [ ] Have someone outside the project follow the Quickstart on a clean subscription,
      and fix whatever stops them. This is the only real test of the documentation.
      Reading it yourself is not a substitute and never has been.

## If you fork this privately

`librechat-bootstrap.sh` on the VM reads an optional `BOOTSTRAP-GIT-DEPLOY-KEY` secret
from Key Vault — base64-encoded, because a `.env`-style secret cannot hold a
multi-line value — and installs it before cloning. Set that secret and point `REPO_URL`
in `/etc/librechat-deploy.conf` at the `git@github.com:` form, and a private fork works
the same way.

`render-env.sh` keeps every `BOOTSTRAP-*` secret out of `.env`, so a host credential
never reaches the application's environment.

When you publish your fork, work back through this list.
