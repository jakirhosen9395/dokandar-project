# MongoDB 8 — utility

DOKANDAR's document read-model store (catalog/cart/fraud projections — never a
transactional writer). Root auth is ON.

## Quick start
```bash
cd docker-single-node-setup
bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
Port tcp/27017 is open on the dedicated server <server-ip>. From your laptop:
```bash
mongosh "mongodb://dki:<password>@<server-ip>:27017/?authSource=admin" --eval 'db.runCommand({ping:1})'
```
