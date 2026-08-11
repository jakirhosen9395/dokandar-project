# Setup — Native (Go toolchain, no Docker)

Run `dokandar-profile` directly on a host with a Go 1.23 toolchain.
**Most operators use Docker — see [SETUP-DOCKER.md](./SETUP-DOCKER.md).**
This guide is for hacking on the service locally.

## 1. Install Go 1.23 + dev tooling

### Debian / Ubuntu

```
sudo apt-get update
sudo apt-get install -y golang-1.23 git curl jq make
```

### RHEL / Fedora

```
sudo dnf install -y golang git curl jq make
```

### macOS

```
brew install go git curl jq make
```

Verify: `go version` should print `go version go1.23.x ...`.

## 2. Clone the repository

```
cd ~
git clone -b source-code https://gitlab.com/dokandar/backend/02-profile.git dokandar-profile
cd ~/dokandar-profile
```

## 3. Resolve modules and build

```
go mod tidy
go build -o bin/profile ./cmd/profile
```

## 4. Get the components creds + auth's public key

Same as the Docker setup — see
[SETUP-DOCKER.md §3](./SETUP-DOCKER.md). Run:

```
AUTH_PUBLIC_KEY_B64='<paste>' ./env/init-env.sh .env.dev
```

## 5. Populate the `/data` snapshot

```
chmod +x ~/dokandar-profile/data/local/collect.sh
PUBLIC_IP_LOOKUP=off ~/dokandar-profile/data/local/collect.sh
```

## 6. Run the binary

`APP_ENV` and `TENANT` are baked into `env/.env.dev`; load the file into
the shell, then run:

```
set -a
. ~/dokandar-profile/env/.env.dev
set +a
./bin/profile
```

You should see the same startup logs as the Docker variant. Press
`Ctrl-C` to shut down gracefully.

## 7. Verify the standard contract

Same curl commands as
[SETUP-DOCKER.md §7](./SETUP-DOCKER.md#7-verify-the-standard-contract).

## 8. Smoke-test the business APIs via Swagger UI

Same flow as
[SETUP-DOCKER.md §8](./SETUP-DOCKER.md#8-end-to-end-test-via-swagger-ui).

## 9. Troubleshooting

Same table as
[SETUP-DOCKER.md §10](./SETUP-DOCKER.md#10-troubleshooting), plus:

| Symptom | Likely cause |
|---|---|
| `go mod tidy` errors on `go.elastic.co/apm/v2` | The APM module path changed across versions. Use `go.elastic.co/apm/v2` at v2.6.2; do NOT pin `go.elastic.co/apm`. |
