# ClickHouse 24.8 — utility

DOKANDAR's OLAP analytics store (fact/dim marts). Has a built-in browser SQL console at `/play`.

## Quick start
```bash
cd docker-single-node-setup
bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **Browser SQL console:** http://<server-ip>:8123/play  (user + password from `.env`).
- **HTTP query:**
```bash
curl 'http://<server-ip>:8123/?user=dki&password=<pw>' -d 'SELECT version()'
```
Ports tcp/8123 (HTTP) and tcp/9004 (native — 9000 belongs to RustFS on this server) are open.
