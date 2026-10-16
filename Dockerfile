# syntax=docker/dockerfile:1
ARG NODE_IMAGE=node:22-alpine
ARG ALPINE_MIRROR=dl-cdn.alpinelinux.org
ARG NPM_REGISTRY=https://registry.npmjs.org/
ARG APP_VERSION=unknown

FROM ${NODE_IMAGE} AS base
ARG ALPINE_MIRROR
WORKDIR /app

# Use the official Alpine mirror by default. A repository variable/build arg can
# override it for environments that require a regional mirror.
RUN if [ "$ALPINE_MIRROR" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

FROM base AS builder
ARG NPM_REGISTRY

# Copy lockfile along with package.json for deterministic, cached install
COPY package.json package-lock.json* ./

# Clean any stale locks before install to prevent cache mount deadlock/hangs.
# Uses explicit cache id and sharing=locked for safe BuildKit caching.
RUN --mount=type=cache,id=npm-cache,target=/root/.npm,sharing=locked \
    rm -rf /root/.npm/_locks 2>/dev/null || true && \
    if [ -f package-lock.json ]; then \
      npm ci --registry="${NPM_REGISTRY}" --prefer-offline --no-audit --no-fund; \
    else \
      npm install --registry="${NPM_REGISTRY}" --prefer-offline --no-audit --no-fund; \
    fi

COPY . ./
ENV NEXT_TELEMETRY_DISABLED=1

# Cache Next.js build output (.next/cache) to accelerate subsequent code builds
RUN --mount=type=cache,id=next-cache,target=/app/.next/cache,sharing=locked \
    npm run build

FROM ${NODE_IMAGE} AS runner
ARG ALPINE_MIRROR
ARG APP_VERSION
WORKDIR /app

RUN if [ "$ALPINE_MIRROR" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g" /etc/apk/repositories; \
    fi

LABEL org.opencontainers.image.title="9router" \
      org.opencontainers.image.version="${APP_VERSION}"

ENV NODE_ENV=production
ENV PORT=20128
ENV HOSTNAME=0.0.0.0
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATA_DIR=/app/data

# Chown langsung saat copy tanpa layer chown -R terpisah
COPY --chown=node:node --from=builder /app/public ./public
COPY --chown=node:node --from=builder /app/.next/static ./.next/static
COPY --chown=node:node --from=builder /app/.next/standalone ./
COPY --chown=node:node --from=builder /app/custom-server.js ./custom-server.js
COPY --chown=node:node --from=builder /app/open-sse ./open-sse
# Next file tracing can omit sibling files; MITM runs server.js as a separate process.
COPY --chown=node:node --from=builder /app/src/mitm ./src/mitm
# Standalone node_modules may omit deps only required by the MITM child process.
COPY --chown=node:node --from=builder /app/node_modules/node-forge ./node_modules/node-forge
# Ensure `next` is available at runtime in case tracing did not include it.
COPY --chown=node:node --from=builder /app/node_modules/next ./node_modules/next
# sql.js loads dist/sql-wasm.wasm by path at runtime; tracing only follows JS imports,
# so the last-resort DB driver would abort with ENOENT on the missing binary.
COPY --chown=node:node --from=builder /app/node_modules/sql.js ./node_modules/sql.js
# node-machine-id is createRequire-loaded at runtime; tracing omits it.
COPY --chown=node:node --from=builder /app/node_modules/node-machine-id ./node_modules/node-machine-id

RUN mkdir -p /app/data /app/data-home && \
  chown node:node /app/data /app/data-home && \
  ln -sf /app/data-home /root/.9router 2>/dev/null || true

# Avoid recursive chown on mounted volume at runtime so container starts immediately
RUN apk add --no-cache su-exec && \
  printf '#!/bin/sh\nchown node:node /app/data /app/data-home 2>/dev/null || true\nexec su-exec node "$@"\n' > /entrypoint.sh && \
  chmod +x /entrypoint.sh

EXPOSE 20128

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "custom-server.js"]
