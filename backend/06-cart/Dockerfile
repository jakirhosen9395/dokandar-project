# syntax=docker/dockerfile:1
# DOKANDAR 06-cart — Node 24 / NestJS 11 + Prisma 6 (MongoDB + Redis).
FROM node:24-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY package.json ./
# no package-lock.json in this repo — npm install (not npm ci) is the only workable install
RUN npm install --no-audit --no-fund
COPY tsconfig.json nest-cli.json ./
COPY prisma ./prisma
RUN npx prisma generate
COPY src ./src
RUN npm run build && npm prune --omit=dev --no-audit --no-fund

FROM node:24-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN apt-get update && apt-get install -y --no-install-recommends curl openssl ca-certificates && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home appuser
COPY package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/prisma ./prisma
COPY CODE_VERSION ./CODE_VERSION
USER appuser
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-3000}/ready" || exit 1
ENTRYPOINT ["node", "dist/main.js"]
