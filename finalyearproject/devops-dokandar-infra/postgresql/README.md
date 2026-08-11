# PostgreSQL 18 — utility

The relational system-of-record for DOKANDAR (every SQL-owning service + the transactional
outbox pattern). This folder teaches you to run it, prove it works, and reach it from anywhere.

## Layout

```text
postgresql/
├── README.md                   ← this file
├── test.sh                     ← shared contract test (works against any variant)
├── .env.example                ← optional defaults for test.sh (DATABASE_URL etc.)
├── docker-single-node-setup/   ← built + tested in this pass
├── native-single-node/         ← (later)
├── native-multi-node-cluster/  ← (later)
└── docker-multi-node-cluster/  ← (later)
```

## Quick start

```bash
cd docker-single-node-setup
bash setup_env.sh     # .env created, strong password generated (chmod 600)
bash setup.sh up      # pulls postgres:18, waits healthy, prints credentials
cd ..
bash test.sh          # PASS/FAIL contract test -> test-result.txt
```

## Reaching it from OUTSIDE the machine

The container listens on `0.0.0.0:5432` on the DEDICATED server <server-ip> and security
group `launch-wizard-1` opens tcp/5432, so from **your laptop**:

```bash
# with psql installed locally (password is in docker-single-node-setup/.env on the server):
PGPASSWORD='<password>' psql -h <server-ip> -p 5432 -U dki -d dkd_identity -c 'SELECT version();'

# or without psql, via docker:
docker run --rm -e PGPASSWORD='<password>' postgres:18 \
  psql -h <server-ip> -p 5432 -U dki -d dkd_identity -c 'SELECT 1;'
```

## Testing any other server

```bash
bash test.sh "postgresql://user:pass@host:5432/postgres"
```

The test creates only throwaway `dki_pgtest_*` objects and proves zero residue afterwards.

## One container, MANY databases (the consolidation lesson)

Database-per-service means separate **databases** inside one PostgreSQL server — never a
server per service. `.env` drives it:

```bash
DKD_DATABASES=dkd_identity,dkd_catalog,dkd_custody
```

`setup.sh up` provisions each name as a database + same-named role with its own generated
password (saved as `DKD_PASSWORD_<NAME>` in `.env`). **To add another database:** append the
name to `DKD_DATABASES` and re-run `bash setup.sh up` — no new container, ever.
