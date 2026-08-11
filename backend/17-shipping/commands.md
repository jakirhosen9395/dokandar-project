```bash
git clone https://gitlab.com/learningdevopstools/backend/17-shipping.git
cd 17-shipping
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_shipping_service:latest .
docker build -t dokandar_shipping_service:dev .

docker rm -f dokandar_shipping_service_dev

docker run -d \
  --name dokandar_shipping_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10017:8000 \
  -p 20017:8001 \
  --restart=on-failure:3 \
  dokandar_shipping_service:dev

docker ps -a
docker logs dokandar_shipping_service_dev
```
