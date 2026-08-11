```bash
git clone https://gitlab.com/learningdevopstools/backend/00-support.git
cd 00-support
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_support_service:latest .
docker build -t dokandar_support_service:dev .

docker rm -f dokandar_support_service_dev

docker run -d \
  --name dokandar_support_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10099:8000 \
  --restart=on-failure:3 \
  dokandar_support_service:dev

docker ps -a
docker logs dokandar_support_service_dev
```
