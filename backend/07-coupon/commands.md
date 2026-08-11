```bash
git clone https://gitlab.com/learningdevopstools/backend/07-coupon.git
cd 07-coupon
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_coupon_service:latest .
docker build -t dokandar_coupon_service:dev .

docker rm -f dokandar_coupon_service_dev

docker run -d \
  --name dokandar_coupon_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10007:8080 \
  -p 20007:9090 \
  --restart=on-failure:3 \
  dokandar_coupon_service:dev

docker ps -a
docker logs dokandar_coupon_service_dev
```
