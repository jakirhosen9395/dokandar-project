# RustFS — S3-compatible object storage utility

DOKANDAR's object store (documents, KYC media, POD photos — MinIO-class, Rust).

## Quick start (infra-2)
```bash
cd docker-single-node-setup && bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **Console (browser):** http://<server-ip>:9001/rustfs/console/index.html — log in with the access/secret keys from `.env`.
- **S3 API:** endpoint `http://<server-ip>:9000`
```bash
docker run --rm --network host -e MC_HOST_rfs=http://dki:<secret>@<server-ip>:9000 minio/mc ls rfs/
```
Ports tcp/9000 + 9001 are open.
