# syntax=docker/dockerfile:1
#
# Self-hosted Sandpack bundlers, so previews never load code from CodeSandbox.
#
# LibreChat renders Artifacts and code-output file previews (CSV, Office, HTML,
# Markdown, SVG) inside Sandpack iframes. By default those iframes are served
# by CodeSandbox's public hosts, so the previewed content is handed to a page
# running a third party's code. This image serves both bundlers from our own
# preview domain instead (UPGRADE_PLAN Round 2, gate D19).
#
#   /srv/static   static template server: CSV/Office/HTML/Markdown/SVG/code
#                 previews and non-React Artifacts (SANDPACK_STATIC_BUNDLER_URL).
#                 Built from codesandbox/static-browser-server at a pinned
#                 commit. Contacts no external host.
#   /srv/bundler  React Artifacts (SANDPACK_BUNDLER_URL). LibreChat's build of
#                 the CodeSandbox client with telemetry removed, pinned by
#                 SHA-256. It still fetches npm packages for React previews.
#
# Both are plain static files; nginx serves them unprivileged. Caddy terminates
# TLS for the preview domain and proxies here (compose.previews.yml).

ARG NODE_IMAGE=node:20.19.5-alpine3.22@sha256:6178e78b972f79c335df281f4b7674a2d85071aae2af020ffa39f0a770265435
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.29.8-alpine3.23@sha256:0c79d56aee561a1d81c63f00eee5fb5fe29279560cdc55e91425133104c7fbe6

# --- static template server ---------------------------------------------------
FROM ${NODE_IMAGE} AS static
ARG SBS_COMMIT=ce0f22517d5033c67ded7bfcdf57af9ac405f4e9
RUN apk add --no-cache git && npm install -g pnpm@9.15.0
RUN git clone https://github.com/codesandbox/static-browser-server /src \
 && cd /src && git checkout --quiet "$SBS_COMMIT" \
 && test "$(git rev-parse HEAD)" = "$SBS_COMMIT"
WORKDIR /src
RUN pnpm install --frozen-lockfile && pnpm build \
 # Type declarations are build output nobody serves.
 && find out/preview -name '*.d.ts' -delete \
 && test -f out/preview/index.html && test -f out/preview/__csb_relay/index.html

# --- React bundler --------------------------------------------------------------
FROM ${NODE_IMAGE} AS bundler
ARG BUNDLER_URL=https://github.com/LibreChat-AI/codesandbox-client/releases/download/bundler-v12/bundler.zip
ARG BUNDLER_SHA256=e6ce913b9066a46b9255e9cd517e6413134523eb2da861bd356e4e1999a654c6
RUN apk add --no-cache unzip \
 && wget -q -O /bundler.zip "$BUNDLER_URL" \
 && echo "$BUNDLER_SHA256  /bundler.zip" | sha256sum -c - \
 && mkdir /bundler && unzip -q /bundler.zip -d /bundler \
 # Source maps are not needed to run and are a third of the size.
 && find /bundler -name '*.map' -delete \
 && test -f /bundler/index.html

# --- runtime ----------------------------------------------------------------------
FROM ${NGINX_IMAGE}
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=static /src/out/preview /srv/static
COPY --from=bundler /bundler /srv/bundler
LABEL org.opencontainers.image.source=https://github.com/MarylandLegalAid/librechat-azure \
      org.opencontainers.image.description="Self-hosted Sandpack bundlers for LibreChat previews"
EXPOSE 8080 8081
