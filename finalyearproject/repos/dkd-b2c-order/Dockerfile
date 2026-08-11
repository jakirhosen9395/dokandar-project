# syntax=docker/dockerfile:1
# b2c-order-svc — Context #6 B2C Marketplace. Single-source provenance:
# GIT_SHA/VERSION/BUILD_TIME arrive once as build-args -> build-info.json + OCI labels.
ARG GIT_SHA=unknown
ARG VERSION=0.0.0-dev
ARG BUILD_TIME=unknown

FROM node:22-bookworm-slim AS build
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
WORKDIR /src
COPY package.json ./
COPY sdk/ sdk/
RUN npm install --no-audit --no-fund
COPY tsconfig.json ./
COPY src/ src/
COPY test/ test/
RUN npm run build
RUN printf '{"version":"%s","gitSha":"%s","buildTime":"%s"}\n' "$VERSION" "$GIT_SHA" "$BUILD_TIME" > /src/build-info.json

FROM node:22-bookworm-slim
ARG GIT_SHA
ARG VERSION
ARG BUILD_TIME
LABEL org.opencontainers.image.title="b2c-order-svc" \
      org.opencontainers.image.description="DOKANDAR Context #6 B2C Marketplace — single-seller orders, order saga, Conformist to Finance" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://gitlab.com/final-year-project3354127/dkd-b2c-order"
WORKDIR /app
COPY --from=build /src/node_modules node_modules
COPY --from=build /src/sdk sdk
COPY --from=build /src/dist dist
COPY --from=build /src/package.json ./
COPY --from=build /src/build-info.json ./
ENV DKD_BUILD_INFO_PATH=/app/build-info.json
EXPOSE 8080 9090
# B2C-14: container liveness via Node (the slim image has no curl); k8s probes cover in-cluster.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:8080/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"
USER node
CMD ["node", "dist/src/index.js"]
