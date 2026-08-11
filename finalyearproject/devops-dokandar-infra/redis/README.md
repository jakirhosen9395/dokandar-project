# Redis 8 — utility

DOKANDAR's cache + fraud feature store. Password auth is ON (unlike many tutorials) because
the port is world-reachable in this learning setup.

## Quick start
```bash
cd docker-single-node-setup
bash setup_env.sh    # generates REDIS_PASSWORD into .env (chmod 600)
bash setup.sh up     # starts redis:8, waits for an authenticated PONG
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
Port tcp/6379 is open on the dedicated server <server-ip>. From your laptop:
```bash
redis-cli -h <server-ip> -p 6379 -a '<password from .env>' ping     # → PONG
```
test.sh also proves a WRONG password is rejected.
