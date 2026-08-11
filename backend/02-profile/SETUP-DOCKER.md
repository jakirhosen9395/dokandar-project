# Setup — Docker (`docker run`, no Compose)

Build `dokandar-profile` into a container image and run it via plain
`docker run`. The Go toolchain is **not** required on the deployment host
— Docker handles compile + run.

## 1. Install Docker

(Same install commands as the auth service.) Pick your platform:

### Debian or Ubuntu

```
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER
```

### RHEL / Fedora

```
sudo dnf install -y dnf-plugins-core git curl
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### macOS

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
+ `brew install git curl jq`.

Verify: `docker --version` should print `Docker version 28.x` or later.

## 2. Clone the repository

The service code lives on the `source-code` branch:

```
cd ~
git clone -b source-code https://gitlab.com/dokandar/backend/02-profile.git dokandar-profile
cd ~/dokandar-profile
```

## 3. Get the components-host credentials + auth's public key

### 3a. Paste the credential block

```
cp ~/dokandar-profile/env/components-creds.example.txt ~/dokandar-profile/env/components-creds.txt
nano ~/dokandar-profile/env/components-creds.txt
# paste the output of components/manage-services.sh status
```

### 3b. Grab auth's RS256 public key

Profile verifies the access token offline using auth's public key. On the
host where dokandar-auth runs:

```
ssh <auth-host>  grep '^JWT_PUBLIC_KEY_B64=' ~/dokandar-auth/env/.env.dev
```

Copy the value (everything after the `=`).

### 3c. Run `init-env.sh` with the public key in scope

```
AUTH_PUBLIC_KEY_B64='<paste-the-value-here>' ./env/init-env.sh .env.dev
```

You should see:

```
✓ wrote env/.env.dev (chmod 600, gitignored)
  target env       : APP_ENV=dev   TENANT=local
  components host  : <infra-host>
  service DB       : dokandar_profile_dev
  ...
```

If you forgot to pass `AUTH_PUBLIC_KEY_B64`, the script writes `CHANGE_ME`
into the JWT field and prints a reminder. Either re-run the script with
the env var set, or open `env/.env.dev` in an editor and paste the value
into the `JWT_PUBLIC_KEY_B64=` line.

For stage / prod, repeat with `.env.stage` / `.env.prod`.

## 4. Populate the `/data` tenant snapshot

```
chmod +x ~/dokandar-profile/data/local/collect.sh
PUBLIC_IP_LOOKUP=off ~/dokandar-profile/data/local/collect.sh
```

That writes `data/local/result.json`. (`data/cloud/collect.sh` for EC2
IMDSv2 if you'll run with `TENANT=cloud`.)

## 5. Build the image

```
cd ~/dokandar-profile
docker build --no-cache -t dokandar_profile_service:latest .
docker tag dokandar_profile_service:latest dokandar_profile_service:dev
docker images dokandar_profile_service
```

First build pulls the Go module proxy + the migrate / pgx / chi / APM
modules + builds the binary into a `distroless/static` final image
(~30 MB). Subsequent builds reuse the layer cache.

## 6. Run the container

```
cd ~/dokandar-profile
docker run -d --name dokandar_profile_service_dev \
  --env-file ~/dokandar-profile/env/.env.dev \
  -v ~/dokandar-profile/data:/app/data:ro \
  -p 8010:8010 \
  --restart=always \
  dokandar_profile_service:dev
```

Confirm:

```
docker ps --filter name=dokandar_profile_service
docker logs dokandar_profile_service_dev | head -30
```

You should see:

```
{
  "@timestamp": "...",
  "log": {"level": "INFO", "logger": "profile"},
  "message": "profile starting up",
  ...
}
{ ... "message": "ensure_db: creating database", "name": "dokandar_profile_dev" }
{ ... "message": "ensure_db: migrations at head" }
{ ... "message": "apm runtime detected", "runtime": "docker", ... }
{ ... "message": "kafka: consumer started", "topic": "dokandar.user.created", "group": "profile" }
{ ... "message": "http server listening", "addr": "0.0.0.0:8010" }
```

## 7. Verify the standard contract

```
curl -s http://127.0.0.1:8010/ready
```

Expected:

```
{
  "status": "ready",
  "identity": {
    "service_name":   "profile",
    "code_version":   "2-profile",
    "env_version":    "v1.0.0",
    "tenant":         "local",
    "env":            "dev",
    "uptime_seconds": 4
  },
  "dependencies": [
    { "name": "postgres", "reachable": true, "latency_ms": 6.2 },
    { "name": "redis",    "reachable": true, "latency_ms": 1.4 }
  ]
}
```

```
curl -s http://127.0.0.1:8010/health | jq '{status, checks: (.checks | keys), obs: (.observability | keys)}'
curl -sI http://127.0.0.1:8010/foobar | head -3      # → HTTP 404, content-length: 0
curl -sI http://127.0.0.1:8010/docs | head -1        # → HTTP 200
```

Open `http://<host>:8010/docs` in a browser — title `DOKANDAR Profile
Service`, identity row below it, green **Authorize** button top-right.

## 8. End-to-end test via Swagger UI

1. Get an access token from **auth**: `POST /api/v1/auth/login/request`
   then `POST /api/v1/auth/login/verify` with the OTP from auth's
   `docker logs`.
2. In Profile's `/docs`, click **Authorize**, paste the access token, click
   **Authorize → Close**.
3. **GET /api/v1/profile/me** — should return the profile shell that
   auth's `UserCreated` event triggered.
4. **PUT /api/v1/profile/me** with `{"name": "Updated", "gender": "male"}`
   — `200 OK` with the updated profile.
5. **POST /api/v1/profile/me/addresses** with the address body — `201`
   with the new row.

## 9. Inspect APM in Kibana

Open Kibana → **APM → Services → profile**:

- **Instances** — one row, identified by container ID prefix.
- **Dependencies** — `postgres`, `redis`, `kafka`, `mongodb` (`apm` is
  intentionally absent — labeling profile as depending on its own trace
  destination would draw a self-loop).
- **Transactions** — `GET /ready`, `GET /api/v1/profile/me`, etc.

Every transaction document carries `labels.runtime=docker` and
`labels.container_id`.

## 10. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Container restarts in a loop | `docker logs <name>` — usually a missing/wrong value in `env/.env.dev`. Re-run step 3 to regenerate the env file. |
| `/ready.dependencies` shows `postgres.reachable=false` | Wrong host/password or the components host's SG doesn't permit 5432 from this machine. |
| `GET /me` returns `profile_not_found` immediately after auth signup | The Kafka consumer may not yet have caught up. Wait a second and retry; check `docker logs` for `profile shell upserted`. |
| `POST /me/avatar` returns 501 `media_unavailable` | Expected — the Media service is not yet built. Stub will be replaced when Media lands. |
| `apm.reachable=false` on `/health` | `APM_SERVER_URL` host:port unreachable from the container. APM going down does NOT trip `/ready` — see service-contract docs. |
