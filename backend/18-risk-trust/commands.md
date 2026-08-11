```bash
git clone https://gitlab.com/learningdevopstools/backend/18-risk-trust.git
cd 18-risk-trust
git switch source-code

cp env/components-creds.example.txt env/components-creds.txt
vi env/components-creds.txt
./env/init-env.sh .env.dev

./data/cloud/collect.sh

docker build --no-cache -t dokandar_risk_trust_service:latest .
docker build -t dokandar_risk_trust_service:dev .

docker rm -f dokandar_risk_trust_service_dev

docker run -d \
  --name dokandar_risk_trust_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10018:8000 \
  -p 20018:50051 \
  --restart=on-failure:3 \
  dokandar_risk_trust_service:dev

docker ps -a
docker logs dokandar_risk_trust_service_dev
```
