# Redis — docker single node variant

```bash
bash setup_env.sh    # create .env + generate password
bash setup.sh up     # start + wait healthy + print credentials (incl. PUBLIC url)
bash setup.sh down   # stop (data kept)   |   purge = delete data too
cd .. && bash test.sh
```

Public reach: `<server-ip>:6379` (SG tcp/6379 open, password required — printed by
`setup.sh up`). From your laptop:

```bash
redis-cli -h <server-ip> -p 6379 -a '<password>' ping    # → PONG
```
