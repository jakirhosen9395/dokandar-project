# RabbitMQ 4 — utility

DOKANDAR's intra-context queue fabric (e.g. the fraud four-eyes approval queue and the
notification dispatch queue). Ships with the Management web UI — the best way to LEARN it.

## Quick start
```bash
cd docker-single-node-setup
bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **Web UI (browser):** http://<server-ip>:15672  — log in with the user/password from `.env`.
- **AMQP (apps):** `amqp://dki:<password>@<server-ip>:5672/`

```bash
curl -u dki:<password> http://<server-ip>:15672/api/overview | head -c 200
```
