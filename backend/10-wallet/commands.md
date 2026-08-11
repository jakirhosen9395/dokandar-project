```bash
git clone https://gitlab.com/learningdevopstools/backend/10-wallet.git
cd 10-wallet
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_wallet_service:latest .
docker build -t dokandar_wallet_service:dev .

docker rm -f dokandar_wallet_service_dev

docker run -d \
  --name dokandar_wallet_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10010:8080 \
  -p 20010:8001 \
  --restart=on-failure:3 \
  dokandar_wallet_service:dev

docker ps -a
docker logs dokandar_wallet_service_dev
```
