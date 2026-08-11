```bash
git clone https://gitlab.com/learningdevopstools/backend/08-review.git
cd 08-review
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_review_service:latest .
docker build -t dokandar_review_service:dev .

docker rm -f dokandar_review_service_dev

docker run -d \
  --name dokandar_review_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10008:8080 \
  -p 20008:50051 \
  --restart=on-failure:3 \
  dokandar_review_service:dev

docker ps -a
docker logs dokandar_review_service_dev
```
