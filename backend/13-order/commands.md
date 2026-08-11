```bash
git clone https://gitlab.com/learningdevopstools/backend/13-order.git
cd 13-order
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_order_service:latest .
docker build -t dokandar_order_service:dev .

docker rm -f dokandar_order_service_dev

docker run -d \
  --name dokandar_order_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10013:8080 \
  -p 20013:9090 \
  --restart=on-failure:3 \
  dokandar_order_service:dev

docker ps -a
docker logs dokandar_order_service_dev
```
