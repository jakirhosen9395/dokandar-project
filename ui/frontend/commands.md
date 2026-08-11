# DOKANDAR Frontend — Deployment (commands.md)

Copy these commands into a terminal one by one, top to bottom, on the frontend
host. The frontend is the edge: browser → Next.js BFF → **API Gateway** (backend
private VPC IP `:10015`) → 18 services. The **only** value you must set for a new
deployment is `GATEWAY_URL` (the gateway's private IP) + a `SESSION_COOKIE_SECRET`.

Prerequisite: Docker is installed, and the backend (API gateway) is running and
reachable from this host on its private VPC IP, port `10015`.

Ports: the container serves the app on host `3000`.

---

## 1. Clone the repository + switch to `source-code`

```bash
git clone https://gitlab.com/learningdevopstools/ui/frontend.git
cd frontend
git switch source-code
```

## 2. Create the runtime environment file

`generated/` (typed API clients) is committed, so no codegen runs at build time.
Only server-side vars are needed at runtime. `GATEWAY_URL` / `SPEC_HOST` point at
the **backend gateway's private VPC IP** (here `172.31.43.165` — replace with your
gateway host). Over plain HTTP keep `APP_ENV=dev` (the session cookie is then
non-Secure); for HTTPS production set `APP_ENV=prod`.

```bash
cp .env.example .env.local
```

```bash
cat > .env.local <<EOF
GATEWAY_URL=http://172.31.43.165:10015
SPEC_HOST=172.31.43.165
SESSION_COOKIE_SECRET=$(openssl rand -hex 32)
APP_ENV=dev
NEXT_PUBLIC_ENV=dev
NEXT_PUBLIC_DEFAULT_LOCALE=en
NEXT_PUBLIC_RUM_SERVER_URL=
NEXT_PUBLIC_RUM_SERVICE_NAME=dokandar-web
EOF
```

## 3. Build the Docker image (standalone, non-root)

```bash
docker build -t dokandar-frontend \
  --build-arg CODE_VERSION="$(cat CODE_VERSION 2>/dev/null || echo 0.1.0)" \
  --build-arg BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
  .
```

## 4. Run the container

```bash
docker rm -f dokandar_frontend_dev
docker run -d --name dokandar_frontend_dev -p 3000:3000 \
  --env-file .env.local --restart unless-stopped dokandar-frontend
```

## 5. Verify

```bash
docker ps --filter name=dokandar_frontend_dev
docker logs dokandar_frontend_dev
curl -s http://127.0.0.1:3000/health
curl -s http://127.0.0.1:3000/ready
curl -s http://127.0.0.1:3000/data
curl -s -o /dev/null -w 'home=%{http_code}\n'   http://127.0.0.1:3000/
curl -s -o /dev/null -w 'search=%{http_code}\n' http://127.0.0.1:3000/search
curl -s -o /dev/null -w 'login=%{http_code}\n'  http://127.0.0.1:3000/login
```

`/ready` must report `"status":"ready"` with `gateway.ok=true` and
`openapi_manifest.services=19`. `/health` is 200 whenever the process is up.

---

### Notes
- `SESSION_COOKIE_SECRET` encrypts the httpOnly session cookie — set a long random
  value and keep it stable (changing it invalidates all sessions). `.env.local` is
  gitignored; never commit it.
- `NEXT_PUBLIC_*` are inlined at **build** time; server-only vars (`GATEWAY_URL`,
  `SPEC_HOST`, `SESSION_COOKIE_SECRET`) are read at **runtime** from `--env-file`.
- The BFF is the only path to the backend: browser calls `/api/gw/*` and
  `/api/auth/*`; the container talks to the gateway server-side.
- For HTTPS production, terminate TLS in front of `:3000` and set `APP_ENV=prod`
  so the session cookie is issued `Secure`.
