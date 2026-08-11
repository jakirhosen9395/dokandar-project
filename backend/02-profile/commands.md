```bash
git clone https://gitlab.com/learningdevopstools/backend/02-profile.git
cd 02-profile
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_profile_service:latest .
docker build -t dokandar_profile_service:dev .

docker rm -f dokandar_profile_service_dev

docker run -d \
  --name dokandar_profile_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10002:8000 \
  -p 20002:8001 \
  --restart=on-failure:3 \
  dokandar_profile_service:dev

docker ps -a
docker logs dokandar_profile_service_dev
```
