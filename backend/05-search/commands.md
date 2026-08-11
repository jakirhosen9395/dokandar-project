```bash
git clone https://gitlab.com/learningdevopstools/backend/05-search.git
cd 05-search
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_search_service:latest .
docker build -t dokandar_search_service:dev .

docker rm -f dokandar_search_service_dev

docker run -d \
  --name dokandar_search_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10005:8080 \
  --restart=on-failure:3 \
  dokandar_search_service:dev

docker ps -a
docker logs dokandar_search_service_dev
```
