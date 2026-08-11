```bash
git clone https://gitlab.com/learningdevopstools/backend/04-catalog.git
cd 04-catalog
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_catalog_service:latest .
docker build -t dokandar_catalog_service:dev .

docker rm -f dokandar_catalog_service_dev

docker run -d \
  --name dokandar_catalog_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10004:8080 \
  -p 20004:9090 \
  --restart=on-failure:3 \
  dokandar_catalog_service:dev

docker ps -a
docker logs dokandar_catalog_service_dev
```
