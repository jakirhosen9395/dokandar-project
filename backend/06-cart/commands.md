```bash
git clone https://gitlab.com/learningdevopstools/backend/06-cart.git
cd 06-cart
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_cart_service:latest .
docker build -t dokandar_cart_service:dev .

docker rm -f dokandar_cart_service_dev

docker run -d \
  --name dokandar_cart_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10006:3000 \
  --restart=on-failure:3 \
  dokandar_cart_service:dev

docker ps -a
docker logs dokandar_cart_service_dev
```
