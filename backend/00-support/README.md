# `00-support` — Dev/Stage Integration Simulator

Python 3.12+ · FastAPI · `aio-pika` (RabbitMQ) · `httpx`. A **single-file** dev/stage hub that:

- **OTP read-back** — stands in for the SMS carrier: consumes the same `notifications.otp.send` RabbitMQ queue
  the **`01-auth`** service publishes to, captures the codes, and lets you look them up by phone/email — so
  phone-OTP login completes in dev/stage **without a real SMS**.
- **Payment-webhook simulator** — posts correctly **HMAC-SHA256-signed** mock provider callbacks to
  `09-payment`'s webhook endpoint.

> ⚠️ **DEV/STAGE ONLY.** It exposes live OTP codes with **no authentication**, by design. It **refuses to
> start unless `APP_ENV ∈ {dev, stage}`**. Keep its port off public networks. **Never run it in production.**

- **Design doc:** [`architecture.md`](./architecture.md). · **This README:** copy-paste **native** install.
- **Verified:** deployed natively on Ubuntu 26.04 / Python 3.14 — consumes the live auth OTP queue; `/health`
  reports `rabbitmq_connected: true` and OTPs minted by auth appear in `/otp/latest`.

---

## 1. Install OS prerequisites

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip openssl curl jq ca-certificates git
```

---

## 2. Get the code

```bash
sudo mkdir -p /opt/dokandar && sudo chown -R "$USER":"$USER" /opt/dokandar
git clone -b source-code git@gitlab.com:learningdevopstools/backend/00-support.git /opt/dokandar/00-support
cd /opt/dokandar/00-support
```

---

## 3. Create the venv + install dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -r requirements.txt
```

Deps are pinned (`fastapi==0.115.6`, …) — no APM/Starlette incompatibility, no C-extension surprises.

---

## 4. Paste the infra creds → render `env/.env.dev`

```bash
cp env/env.txt.example env/env.txt
nano env/env.txt        # paste the REAL infra creds (the ### NN_Service blocks)
chmod 600 env/env.txt
./env/init-env.sh .env.dev
```

`init-env.sh` reads `env/env.txt` (or `env/components-creds.txt`) and writes `env/.env.dev` (`chmod 600`,
**gitignored**). It wires the **same `RABBITMQ_URL` the auth service uses** (to consume the OTP queue) and
points `DATABASE_URL` at the auth DB `dokandar_auth_dev` so **email→phone search** works. No migrations, no DB
of its own — the OTP buffer is in-memory.

---

## 5. Run the service (port `10000`)

### 5a. Foreground (quick test)

```bash
APP_ENV=dev SERVICE_PORT=10000 \
  set -a && . env/.env.dev && set +a && \
  uvicorn app:app --host 0.0.0.0 --port 10000
```

### 5b. systemd (persistent, recommended)

```bash
sudo tee /etc/systemd/system/dokandar-support.service >/dev/null <<UNIT
[Unit]
Description=DOKANDAR 00-support (dev/stage OTP hub + webhook sim)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/opt/dokandar/00-support
EnvironmentFile=/opt/dokandar/00-support/env/.env.dev
ExecStart=/opt/dokandar/00-support/.venv/bin/uvicorn app:app --host 0.0.0.0 --port 10000
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now dokandar-support
sudo systemctl status dokandar-support --no-pager
```

`EnvironmentFile=env/.env.dev` injects all the config (the app reads `os.environ` directly).

---

## 6. Verify

```bash
# health — rabbitmq_connected should be true
curl -s localhost:10000/health | jq

# the web UI (open in a browser): OTP read-back + the payment-webhook simulator
echo "http://<this-host-ip>:10000/"

# end-to-end OTP read-back: trigger an auth signup → the OTP flows through RabbitMQ → shows here
PHONE="01711$(printf '%06d' $((RANDOM%1000000)))"
curl -s -X POST -H 'content-type: application/json' -d "{\"phone\":\"$PHONE\"}" \
  http://<AUTH_HOST>:8000/api/v1/auth/login/request    # auth publishes notifications.otp.send
curl -s "localhost:10000/otp/latest?phone=$PHONE" | jq # the code appears here, no SMS needed
```

*(In auth's current dev config `OTP_ENABLED=false`, so the OTP is bypassed; flip auth to `OTP_ENABLED=true` to
exercise the full SMS-stand-in path through this service.)*

---

## 7. Operate

```bash
sudo journalctl -u dokandar-support -f          # live logs
sudo systemctl restart dokandar-support         # restart
```

- **`/health`** — `rabbitmq_connected`, `messages_consumed`, `buffered`, `email_search`.
- **`/otp/latest?phone=` / `?email=`**, **`/search`** — OTP lookup. **`/`** and **`/webhook`** — web UI.
- Logs to stdout (journald). Identity: `service_name = 00-support`.

---

## 8. Security notes

- `env/env.txt` and `env/.env.dev` hold **real secrets** — both **gitignored**; never commit them.
- The service **only** starts under `APP_ENV ∈ {dev, stage}` — the boot guard prevents it ever exposing OTPs
  in prod.
- Bind it to a **private** network only (it has no authentication on the OTP surface, by design).
