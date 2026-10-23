# Temporary Node.js security patch plan

Prepared October 23, 2026. Status: proposed; no images have been built or deployed.

Rebuild the exact LibreChat release we already run with a patched Node.js runtime,
then select that image with a temporary Compose overlay. Keep the official image
reference in `compose.yaml` so Renovate continues proposing official upgrades.

The [October 21 Node.js advisory](https://nodejs.org/en/blog/vulnerability/october-2026-security-releases)
includes CVE-2026-111497, a Brotli decoder out-of-bounds write permitting remote code
execution. Node.js rates its highest-severity issues HIGH. Fixed releases are
22.23.4, 24.22.1, and 26.12.1. Our base Compose file selects LibreChat `v0.8.8`;
its [upstream Dockerfile](https://github.com/LibreChat-AI/LibreChat/blob/v0.8.8/Dockerfile)
selects Node `24.16.0-alpine`. Target Node **24.22.1**, staying on the same major.
The [upstream release list](https://github.com/LibreChat-AI/LibreChat/releases)
still shows `v0.8.8` as the newest release when this plan was prepared.

These findings establish the configured build baseline. The running VM's image
digest and actual Node version still need verification.

1. **Record what is running and check for a simpler official fix.**

   On production, record the deployment Git SHA, storage mode, enabled profiles,
   container image IDs, registry digests, architecture, OS/Alpine versions, and
   runtime versions. For the main application, read the runtime directly:

   ```bash
   docker exec LibreChat node -p 'JSON.stringify(process.versions)'
   ```

   Inspect the currently published official image too: upstream might rebuild an
   existing tag without publishing a new application release. If an official image
   already contains the fixes, pin its verified digest and use the same staging and
   rollout checks below; a custom build is then unnecessary.

   Inventory the admin panel, enabled MCP servers, and optional code interpreter
   services for Node runtimes. Patch affected services through their respective
   image repositories; upgrading the main application does not patch them. Record
   any outstanding exposure separately. A service without Node is out of scope.

2. **Build a narrowly scoped replacement image.**

   Add a manually triggered build workflow in this repository. Fetch `v0.8.8` by
   its resolved full commit SHA and assert it matches the recorded release commit.
   Keep its application source and `package-lock.json` unchanged. Apply a checked
   patch to the Node base image reference, failing if the expected old line differs.

   Use upstream's `Dockerfile`, target `node`, matching the published `librechat`
   image. Upstream's [tag publishing workflow](https://github.com/LibreChat-AI/LibreChat/blob/v0.8.8/.github/workflows/tag-images.yml)
   also builds `Dockerfile.multi`, but that produces the separate `librechat-api`
   image. Preserve the runtime layout and startup behavior of our selected image.

   Resolve a Node 24.22.1 Alpine image matching the existing Alpine release where
   available, verify availability for the production architecture, and pin its
   digest. Build all application dependencies against the patched runtime, including
   native modules. If matching Alpine is unavailable, treat the distro change as
   an explicit compatibility change and validate it on staging.

   Build on CI rather than the production VM. Publish, after validation, under
   `ghcr.io/marylandlegalaid/librechat-node-hotfix:v0.8.8-node24.22.1-r1`, and deploy
   by immutable digest. Verify the VM can pull it; a public package fits the existing
   credential-free pull path. Record source SHA, build recipe, base-image digests,
   output digest, runtime versions, and scan results. Retain the tested artifact;
   mutable Alpine package repositories mean later rebuilds may not be byte-identical.

3. **Prepare temporary image selection without activating it.**

   Teach `scripts/deploy.sh` to append a tracked `compose.security.yml`, when
   present, after the storage overlay. Resolve it inside `bring_up_stack()` on
   every call, including after a rollback. The overlay will change only `api.image`.
   Keep the official `compose.yaml` image reference intact.

   Record the exact upstream image reference the hotfix supports in the overlay's
   metadata. Both deployment and CI must reject an overlay whose supported upstream
   reference differs from the base file. Otherwise a future Renovate upgrade could
   appear deployed while the override silently keeps running the old application.

   Extend validation to render both storage modes and all profile combinations
   with and without the overlay, check the selected image, and reject mismatches.
   Exercise rollback selection and removal of the overlay. Document how manual
   Compose commands include the extra file: explicitly naming Compose files does
   not automatically load this overlay.

   Ship this support change separately, with no active override, and confirm the
   existing application still runs. Currently `deploy.sh` re-executes when its own
   file changes and captures the new checkout as `PREVIOUS_SHA`; combining that
   script change with image activation would lose the intended rollback commit.
   A separate activation change avoids relying on rollback across that boundary.

4. **Validate the exact published artifact on staging.**

   Use an isolated restored instance and the [documented restore procedure](../modules/backups.md#test-your-restore).
   Keep staging integrations and scheduled work from acting on production systems.
   Run `scripts/validate-config.sh` and the repository's existing script tests.
   Scan the final image, verify `node --version` is `v24.22.1`, and inspect
   `process.versions`; an image tag or clean npm audit alone does not verify the fix.

   Require `/health`, login/SSO, streamed chat across configured model families,
   a tool-using conversation, conversation search, file upload, an old attachment,
   agent knowledge search, and admin-panel operations to work. Exercise enabled
   MCP tools and a real Run Code execution/file round-trip if configured. Check
   logs for native-module loading, TLS, DNS, database, and startup errors. Rehearse
   switching to the old image and back with the same database.

5. **Activate in a controlled production window.**

   Take and verify fresh paired MongoDB/pgvector backups and a recoverable data-disk
   backup. Pause the deploy timer and wait for any active deployment to finish
   before merging the activation change. Add the tested digest in
   `compose.security.yml`; this change must not also modify `deploy.sh`.

   Deploy through `scripts/deploy.sh --force`, letting it advance the checkout from
   the previous commit. Do not manually reset the checkout first: the deploy needs
   the previous SHA for rollback. Expect a short interruption while the single API
   container is recreated. Verify the running container's image ID resolves to the
   approved digest, verify Node again inside it, and repeat the smoke tests.

   A runtime-only rebuild should require no database migration. If health fails,
   the existing script can restore the previous commit/image; if behavior fails
   after health passes, revert the activation commit and force a deploy. Either
   fallback restores the vulnerable runtime, so it is a recovery action, not a
   completed security fix. Restrict access while correcting the candidate when
   necessary. Revert or fix a failed activation before restarting the timer, or
   the timer will retry it. Resume the timer after a successful deployment.

6. **Return to the next verified official image.**

   Continue checking upstream releases while Renovate tracks the official image;
   its ordinary schedule here is Monday mornings. A new LibreChat version alone
   does not prove the runtime is patched: inspect the candidate image and verify
   its Node release contains these fixes.

   Follow the [normal upgrade procedure](../modules/upgrading.md), including any
   new migration requirements. In one upgrade change, update the official image
   reference and remove `compose.security.yml`. The mismatch check makes forgetting
   this removal a visible failure. Validate on staging, deploy, verify the running
   official digest and Node version, and run the smoke tests.

   Retain the tested hotfix artifact through the rollback window. A rollback of
   that upgrade should restore the patched `v0.8.8` image and overlay, subject to
   the usual database-migration restrictions. Retire the temporary build workflow
   and unused overlay support separately after the official upgrade is stable.

Completion means every affected, enabled Node service has a verified fixed runtime,
the main application has passed production smoke tests, and the official upgrade
path remains tracked and tested. Implementing this plan requires live inventory,
registry/build access, and a staging rehearsal; those have not been performed yet.
