# document-svc — DOKANDAR platform #31 (PLAT-02). Multi-stage Go build; distroless non-root runtime.
ARG GIT_SHA=unknown
ARG VERSION=0.1.0

FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download || true
COPY . .
ARG GIT_SHA
RUN CGO_ENABLED=0 go build -buildvcs=false -ldflags "-s -w" -o /server .

FROM gcr.io/distroless/static:nonroot
ARG GIT_SHA
ARG VERSION
ENV DKD_GIT_SHA=$GIT_SHA DKD_VERSION=$VERSION
LABEL org.opencontainers.image.title="document-svc" \
      org.opencontainers.image.description="DOKANDAR platform #31 — evidence/media object store with signed <=5min URLs (PLAT-02)"
COPY --from=build /server /server
EXPOSE 8080 9090
USER nonroot:nonroot
ENTRYPOINT ["/server"]
