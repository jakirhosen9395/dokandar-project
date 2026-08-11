# syntax=docker/dockerfile:1
# DOKANDAR frontend — Next.js 16 (standalone) · Node 22 LTS · pnpm · non-root · port 3000.
# Multi-stage: deps → build (uses COMMITTED generated/ — no network codegen at build) → minimal runner.

FROM node:22-alpine AS base
RUN apk add --no-cache libc6-compat && corepack enable
WORKDIR /app

# ---- deps: install with the frozen lockfile (cache-friendly) ----
FROM base AS deps
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# ---- build: compile the standalone server ----
FROM base AS build
ARG CODE_VERSION=0.1.0
ARG BUILD_TIME=unknown
ARG GIT_COMMIT=unknown
ENV CODE_VERSION=$CODE_VERSION BUILD_TIME=$BUILD_TIME GIT_COMMIT=$GIT_COMMIT NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm build

# ---- runner: minimal, non-root ----
FROM node:22-alpine AS runner
WORKDIR /app
ARG CODE_VERSION=0.1.0
ARG BUILD_TIME=unknown
ARG GIT_COMMIT=unknown
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0 \
    CODE_VERSION=$CODE_VERSION BUILD_TIME=$BUILD_TIME GIT_COMMIT=$GIT_COMMIT
RUN addgroup -g 1001 -S nodejs && adduser -u 1001 -S nextjs -G nodejs
# Next standalone output: server.js + traced node_modules + static + public
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=build --chown=nextjs:nodejs /app/public ./public
# in-repo docs for the DEVOPS documentation viewer (read server-side at runtime)
COPY --from=build --chown=nextjs:nodejs /app/FRONTEND_ARCHITECTURE.md /app/COMMAND.md /app/README.md ./
COPY --from=build --chown=nextjs:nodejs /app/docs ./docs
USER nextjs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=4s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/health',{signal:AbortSignal.timeout(3000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.js"]
