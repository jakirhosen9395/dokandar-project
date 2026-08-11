```bash
git clone https://gitlab.com/learningdevopstools/backend/16-recommendation.git
cd 16-recommendation
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_recommendation_service:latest .
docker build -t dokandar_recommendation_service:dev .

docker rm -f dokandar_recommendation_service_dev

docker run -d \
  --name dokandar_recommendation_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10016:8000 \
  -p 20016:50051 \
  --restart=on-failure:3 \
  dokandar_recommendation_service:dev

docker ps -a
docker logs dokandar_recommendation_service_dev
```
