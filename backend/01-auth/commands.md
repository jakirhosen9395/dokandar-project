```bash
git clone https://gitlab.com/learningdevopstools/backend/01-auth.git
cd 01-auth
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_auth_service:latest .
docker build -t dokandar_auth_service:dev .

docker rm -f dokandar_auth_service_dev

docker run -d \
  --name dokandar_auth_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10001:8000 \
  -p 20001:8001 \
  --restart=on-failure:3 \
  dokandar_auth_service:dev

docker ps -a
docker logs dokandar_auth_service_dev
```
