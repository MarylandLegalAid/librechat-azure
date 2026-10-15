/*
 * HEAD the S3 object behind each file record, the way LibreChat would read it.
 *
 * ⚠️  Do not run this file directly. scripts/remove-dead-agent-files.sh runs it
 * inside a one-off container of the LibreChat image, which has the AWS SDK and
 * the deployment's AWS_* settings:
 *
 *     docker compose run --rm --no-deps -T -v "$PWD/scripts:/scripts:ro" \
 *       api node /scripts/head-s3-objects.js < candidates.json
 *
 * Input (stdin): [{ file_id, filepath, storageKey }]
 * Output: one JSON array between markers, [{ file_id, status, httpStatus,
 * detail }], where status is 'present', 'missing' (404) or 'error'.
 *
 * Bucket and region are AWS_BUCKET_NAME and AWS_REGION, exactly what the app
 * reads with, so "missing" means "the app's read would fail". Keys and file
 * names never appear in the output: they can carry a document's name.
 */

'use strict';

const lib =
  globalThis.DeadAgentFileCleanup || require('/scripts/lib/dead-agent-file-cleanup.js');

const TIMEOUT_MS = 15000;

function emit(results) {
  console.log('===HEADS-JSON-BEGIN===');
  console.log(JSON.stringify(results));
  console.log('===HEADS-JSON-END===');
}

async function main() {
  const input = JSON.parse(require('fs').readFileSync(0, 'utf8') || '[]');
  const bucket = process.env.AWS_BUCKET_NAME;
  const region = process.env.AWS_REGION;

  if (!bucket || !region) {
    emit(
      input.map((c) => ({
        file_id: c.file_id,
        status: 'error',
        httpStatus: null,
        detail: 'AWS_BUCKET_NAME or AWS_REGION is not set in this deployment',
      })),
    );
    return;
  }

  // Resolve the SDK from the app, not from /scripts: Node looks for modules
  // next to the requiring file, and /scripts has no node_modules.
  const appRequire = require('module').createRequire('/app/package.json');
  const { S3Client, HeadObjectCommand } = appRequire('@aws-sdk/client-s3');
  const s3 = new S3Client({ region });
  const results = [];

  for (const candidate of input) {
    const key = lib.s3KeyFor(candidate, bucket);
    if (!key) {
      results.push({ file_id: candidate.file_id, status: 'error', httpStatus: null, detail: 'cannot derive an S3 key from the record' });
      continue;
    }
    try {
      const out = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }), {
        abortSignal: AbortSignal.timeout(TIMEOUT_MS),
      });
      const httpStatus = (out.$metadata && out.$metadata.httpStatusCode) || 200;
      results.push({ file_id: candidate.file_id, status: lib.classifyHead(httpStatus), httpStatus, detail: null });
    } catch (err) {
      const httpStatus = (err && err.$metadata && err.$metadata.httpStatusCode) || null;
      results.push({
        file_id: candidate.file_id,
        status: lib.classifyHead(httpStatus),
        httpStatus,
        detail: httpStatus === 404 ? null : `${(err && err.name) || 'Error'}${httpStatus ? ` (HTTP ${httpStatus})` : ''}`,
      });
    }
  }
  emit(results);
}

main().catch((err) => {
  console.error(`head-s3-objects: ${(err && err.name) || 'Error'}: ${(err && err.message) || err}`);
  process.exit(1);
});
