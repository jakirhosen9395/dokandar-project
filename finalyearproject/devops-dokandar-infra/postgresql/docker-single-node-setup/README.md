# PostgreSQL — docker single node variant

See ../README.md for the full guide.

```bash
bash setup_env.sh   # create .env + generate password
bash setup.sh up    # start + wait healthy + print credentials (incl. PUBLIC url)
bash setup.sh down  # stop (data kept)   |  purge = delete data too
cd .. && bash test.sh   # prove it works
```

Public reach: `<server-ip>:5432` (SG tcp/5432 open). One container serves ALL the
databases in DKD_DATABASES — see ../README.md §consolidation. Credentials summary printed
by `setup.sh up`.
