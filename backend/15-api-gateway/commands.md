```bash
git clone https://gitlab.com/learningdevopstools/backend/15-api-gateway.git
cd 15-api-gateway
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_api_gateway_service:latest .
docker build -t dokandar_api_gateway_service:dev .

docker rm -f dokandar_api_gateway_service_dev

docker run -d \
  --name dokandar_api_gateway_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10015:8080 \
  --restart=on-failure:3 \
  dokandar_api_gateway_service:dev

docker ps -a
docker logs dokandar_api_gateway_service_dev
```
