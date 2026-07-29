# Going public

This repository was born **private** and is flipped **public** after the production
cutover. Same repository, same history throughout — which is exactly why no secret was
ever committed to it, even while nobody outside could read it.

Three capabilities are unavailable on a private repository under a Free organization
plan and become available, free, the moment it is public. They are listed here because
each one is a gap in enforcement or delivery while the repository is private, and it
would be easy to flip the repository and never notice they were still off.

## Before flipping

- [ ] **Review the full history, not just the tip.** Making a repository public exposes
      every object in it. A secret committed and removed the next day is still readable
      by anyone who knows to look.

      ```bash
      gitleaks git --redact --verbose --exit-code 1 .
      git log --stat --all | grep -iE '\.env$|\.pem$|\.docx?$|parameters\.json$'
      ```

- [ ] **Confirm no production identifiers survived.** Subscription IDs, tenant IDs,
      resource IDs, and the addresses of production hosts must not be here.

      ```bash
      for pat in <subscription-id> <tenant-id> <prod-ip>; do
        git grep -l "$pat" $(git rev-list --all) 2>/dev/null | head
      done
      ```

      `.github/workflows/secrets.yml` enforces the IP half of this on every push, and
      blocks the internal planning documents by name. The identifiers themselves are
      deliberately not listed in the workflow — writing them into a file in this
      repository in order to check for them would commit them.

- [ ] **Confirm no letterhead `.docx` is present, in any commit.**

## At the flip

- [ ] Make the repository public.

- [ ] **Enable secret scanning and push protection.** Not available while private on
      this plan, so until now `gitleaks` in CI has been the only mechanical
      enforcement. Push protection is better than CI: it refuses the push rather than
      reporting the leak afterwards.

      ```bash
      gh api -X PATCH repos/OWNER/REPO \
        -f 'security_and_analysis[secret_scanning][status]=enabled' \
        -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
      ```

- [ ] **Enable GitHub Pages and turn on publishing.** The docs have been building on
      every push all along; only publishing was gated.

      ```bash
      gh api -X POST repos/OWNER/REPO/pages -f build_type=workflow
      gh variable set PAGES_ENABLED --body true
      ```

- [ ] **Retire the deploy key.** While the repository was private, the VM cloned it
      using a read-only deploy key. A public repository needs no credential at all, and
      that is the whole point — a grantee's machine clones with nothing configured.

      1. On the VM, change `REPO_URL` in `/etc/librechat-deploy.conf` back to the
         `https://` form.
      2. Delete the vault secret:
         ```bash
         az keyvault secret delete --vault-name kv-librechat-prod --name BOOTSTRAP-GIT-DEPLOY-KEY
         ```
      3. Delete the deploy key on GitHub (Settings → Deploy keys).
      4. Remove `/root/.ssh/id_ed25519` from the VM.
      5. Force a deploy and confirm it still pulls.

- [ ] **Verify the Deploy to Azure button.** It reads `infra/main.json` from the raw
      URL on `main`, so it cannot work until the repository is public. Click it and
      confirm the portal renders the parameter form.

      CI already asserts `main.json` matches `main.bicep`, so the button deploys what
      the Bicep source says — but nothing has ever checked that the *link* resolves.

## After

- [ ] Add a `SECURITY.md` with a private reporting address, since anyone can now file
      an issue and a public issue is the wrong place for a vulnerability.
- [ ] Turn on branch protection for `main` if the plan allows it.
- [ ] Have someone outside the project follow the Quickstart on a clean subscription,
      and fix whatever stops them. This is the only real test of the documentation, and
      reading it yourself is not a substitute.
