# syntax=docker/dockerfile:1
# DOKANDAR 14-notification — Node 24 / Fastify 5 (MongoDB inbox + Redis + Kafka + RabbitMQ + NATS).
FROM node:24-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:24-slim AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production
COPY package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY CODE_VERSION ./CODE_VERSION
# data/ is NOT baked into the image — the tenant snapshot is bind-mounted read-only
# at runtime (-v "$(pwd)/data:/app/data:ro"), matching the fleet standard (01-auth).
# non-root runtime (node:24-slim ships uid 1000 'node'; pin a dedicated 10001 like the fleet)
RUN groupadd -g 10001 app && useradd -u 10001 -g 10001 -M -s /usr/sbin/nologin app && chown -R app:app /app
USER 10001
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=45s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SERVICE_PORT:-3000}/ready" || exit 1
ENTRYPOINT ["node", "dist/server.js"]
