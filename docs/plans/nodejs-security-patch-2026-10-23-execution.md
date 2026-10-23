# October 2026 Node security patch execution

Status: artifacts published and staging verified; production activation pending.

The [plan](nodejs-security-patch-2026-10-23.md) is implemented through an image-only
Compose override. The official LibreChat image reference remains in `compose.yaml`
for Renovate. Remove `compose.security.yml` when upgrading to a verified patched
official image; deployment and CI reject an override for a different release.

| Component | Before | Candidate |
|---|---|---|
| LibreChat | v0.8.8, Node 24.16.0, Alpine 3.24.2 | Same application source and lockfile, Node 24.22.1 on Alpine 3.24 |
| LegalServer MCP | v3.1.0, Node 20.20.2 | v3.1.1, Node 22.23.4, same application behavior |
| LetterWriter MCP | v1.1.0, Node 20.20.2 | v1.1.1, Node 22.23.4, same application behavior |
| Admin panel | Bun 1.3.11 | Unchanged: its `node` command is a symlink to Bun, which reports a Node compatibility version |

No Node executable was found in the running code interpreter service containers.
A real Python execution and generated-file download passed through the patched
LibreChat application and the existing interpreter deployment.

LibreChat's source commit is `e8f3be08623663d4ad7f7241e693c94469b63bb0`.
The Node base is
`node:24.22.1-alpine3.24@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53`.
The published LibreChat hotfix digest is
`sha256:e2f0bdeabf61e8e485aaea7e696e1042e980b25b552ffa07440410db01727dc0`.
The deployment pins all three candidate images by digest. Anonymous pulls were
verified on both production and staging before activation.

Build evidence, including the runtime versions and dependency scan, is attached to
the [LibreChat build](https://github.com/MarylandLegalAid/librechat-azure/actions/runs/39988924596).
The [LegalServer release](https://github.com/MarylandLegalAid/legalserver-mcp/actions/runs/39989157024)
and [LetterWriter release](https://github.com/MarylandLegalAid/letterwriter-mcp/actions/runs/39989154955)
also passed their CI gates. Local verification passed 125 deployment-script tests,
246 LegalServer tests with one existing skip, and 46 LetterWriter tests, plus
LegalServer's MCP transport smoke check. Both storage modes and all MCP profile
combinations rendered with and without the active override, selecting the expected
API image.

Staging used an isolated restore of the fresh paired MongoDB and vector backups
from `2026-10-23T16-42-31Z`, plus copied uploads, images, skills, and letterheads.
Schedules were disabled in the restored database. The restore verified 169,183
MongoDB documents, 31,091 embeddings, and 7,727 indexed conversations against 7,726
eligible restored conversations; the synthetic test added a conversation during
verification. Existing uploaded-PDF download, old-document embedding retrieval,
conversation search, password login, admin-panel login, agent/file/conversation
API responses, streamed chat, a synthetic upload read by the model, MCP handshake
and tool listing, DOCX generation, real Python execution, generated-file download,
Brotli decompression, and native image processing were exercised.

The initial staging replacement took 17 seconds to readiness. The rollback
rehearsal took 15 seconds to return to the original image and 16 seconds to return
to the patched image, using the same restored database. Production rollback should
revert the activation commit, keeping the earlier deployment-support commit.
Restoring the old image also restores the vulnerable runtime; it is a recovery
measure while correcting the patch, not a completed fix.

A fresh paired database backup completed successfully, and the incremental
data-disk snapshot `librechat-node-hotfix-20261023` reached `Succeeded` before the
cutover. Database schema and embedding model changes are outside this patch.

The image scan is **not clean**: it reports four critical and fourteen high
advisories in npm dependencies from the unchanged LibreChat lockfile. These are
separate from the Node runtime update and need a separate dependency review.
The critical findings are DOMPurify `GHSA-cg2g-xh64-v4q7`, Handlebars
`CVE-2026-106445` and `CVE-2026-106446`, and proxy-addr `CVE-2026-90711`.
Fixed package versions reported by the scan are DOMPurify 3.4.17, Handlebars
4.7.10, and proxy-addr 2.0.8. High findings include the MCP SDK and npm-installed
Undici; updating Node's bundled Undici does not update a separate npm dependency.
The full scan is retained in the build artifact. This rollout fixes the requested
Node runtime release; it does not establish absence of other vulnerabilities.

The OpenID login redirect can be checked without user credentials. Completing an
interactive organizational SSO callback still requires a real user session; the
staging smoke account exercises password login instead.
