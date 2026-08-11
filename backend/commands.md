# DOKANDAR — Full Platform Deployment (all 19 backend services)

Copy these commands into a terminal one by one, top to bottom. Run everything
from this `backend/` directory. Auth is deployed **first**; every other service
verifies auth's JWTs with the public key + shared internal token that auth
generates, so those generated values are copied into `all_components_creds.txt`
before the other services render their environments.

Prerequisite: the backing infrastructure (Postgres, Mongo, Elasticsearch, Redis,
Kafka, RabbitMQ, Elastic APM, RustFS, ClickHouse, Qdrant, Neo4j, ScyllaDB, NATS,
Temporal) is already running, and its real credentials are filled into the
`### NN_Service` blocks of `all_components_creds.txt`.

Ports: each service publishes REST on host `100NN` and gRPC (if any) on `200NN`;
support publishes REST on `10099`.

---

## 1. Clone every repository

```bash
git clone https://gitlab.com/learningdevopstools/backend/00-support.git
git clone https://gitlab.com/learningdevopstools/backend/01-auth.git
git clone https://gitlab.com/learningdevopstools/backend/02-profile.git
git clone https://gitlab.com/learningdevopstools/backend/03-seller.git
git clone https://gitlab.com/learningdevopstools/backend/04-catalog.git
git clone https://gitlab.com/learningdevopstools/backend/05-search.git
git clone https://gitlab.com/learningdevopstools/backend/06-cart.git
git clone https://gitlab.com/learningdevopstools/backend/07-coupon.git
git clone https://gitlab.com/learningdevopstools/backend/08-review.git
git clone https://gitlab.com/learningdevopstools/backend/09-payment.git
git clone https://gitlab.com/learningdevopstools/backend/10-wallet.git
git clone https://gitlab.com/learningdevopstools/backend/11-reporting.git
git clone https://gitlab.com/learningdevopstools/backend/12-media.git
git clone https://gitlab.com/learningdevopstools/backend/13-order.git
git clone https://gitlab.com/learningdevopstools/backend/14-notification.git
git clone https://gitlab.com/learningdevopstools/backend/15-api-gateway.git
git clone https://gitlab.com/learningdevopstools/backend/16-recommendation.git
git clone https://gitlab.com/learningdevopstools/backend/17-shipping.git
git clone https://gitlab.com/learningdevopstools/backend/18-risk-trust.git
```

## 2. Switch every repository to the `source-code` branch

```bash
git -C 00-support switch source-code
git -C 01-auth switch source-code
git -C 02-profile switch source-code
git -C 03-seller switch source-code
git -C 04-catalog switch source-code
git -C 05-search switch source-code
git -C 06-cart switch source-code
git -C 07-coupon switch source-code
git -C 08-review switch source-code
git -C 09-payment switch source-code
git -C 10-wallet switch source-code
git -C 11-reporting switch source-code
git -C 12-media switch source-code
git -C 13-order switch source-code
git -C 14-notification switch source-code
git -C 15-api-gateway switch source-code
git -C 16-recommendation switch source-code
git -C 17-shipping switch source-code
git -C 18-risk-trust switch source-code
```

## 3. Prepare tenant data (cloud snapshot served by /data)

```bash
( cd 00-support && ./data/cloud/collect.sh )
( cd 01-auth && ./data/cloud/collect.sh )
( cd 02-profile && ./data/cloud/collect.sh )
( cd 03-seller && ./data/cloud/collect.sh )
( cd 04-catalog && ./data/cloud/collect.sh )
( cd 05-search && ./data/cloud/collect.sh )
( cd 06-cart && ./data/cloud/collect.sh )
( cd 07-coupon && ./data/cloud/collect.sh )
( cd 08-review && ./data/cloud/collect.sh )
( cd 09-payment && ./data/cloud/collect.sh )
( cd 10-wallet && ./data/cloud/collect.sh )
( cd 11-reporting && ./data/cloud/collect.sh )
( cd 12-media && ./data/cloud/collect.sh )
( cd 13-order && ./data/cloud/collect.sh )
( cd 14-notification && ./data/cloud/collect.sh )
( cd 15-api-gateway && ./data/cloud/collect.sh )
( cd 16-recommendation && ./data/cloud/collect.sh )
( cd 17-shipping && ./data/cloud/collect.sh )
( cd 18-risk-trust && ./data/cloud/collect.sh )
```

## 4. Generate the Auth service environment

```bash
cp all_components_creds.txt 01-auth/env/components-creds.txt
( cd 01-auth && ./env/init-env.sh .env.dev )
```

## 5. Start only the Auth service

```bash
( cd 01-auth && docker build --no-cache -t dokandar_auth_service:latest . )
( cd 01-auth && docker build -t dokandar_auth_service:dev . )
docker rm -f dokandar_auth_service_dev || true
( cd 01-auth && docker run -d --name dokandar_auth_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10001:8000 -p 20001:8001 --restart=on-failure:3 dokandar_auth_service:dev )
```

## 6. Obtain the generated JWT public key and service token

```bash
grep '^JWT_PUBLIC_KEY_B64=' 01-auth/env/.env.dev
grep '^INTERNAL_SERVICE_TOKEN=' 01-auth/env/.env.dev
```

## 7. Copy those two values into `all_components_creds.txt`

Open the file and paste the two values into the `### Auth_Identity` block —
`auth_service_public_key` = the `JWT_PUBLIC_KEY_B64` value, and
`internal_service_token` = the `INTERNAL_SERVICE_TOKEN` value:

```bash
nano all_components_creds.txt
```

## 8. Copy `all_components_creds.txt` into every repository

```bash
cp all_components_creds.txt 00-support/env/components-creds.txt
cp all_components_creds.txt 02-profile/env/components-creds.txt
cp all_components_creds.txt 03-seller/env/components-creds.txt
cp all_components_creds.txt 04-catalog/env/components-creds.txt
cp all_components_creds.txt 05-search/env/components-creds.txt
cp all_components_creds.txt 06-cart/env/components-creds.txt
cp all_components_creds.txt 07-coupon/env/components-creds.txt
cp all_components_creds.txt 08-review/env/components-creds.txt
cp all_components_creds.txt 09-payment/env/components-creds.txt
cp all_components_creds.txt 10-wallet/env/components-creds.txt
cp all_components_creds.txt 11-reporting/env/components-creds.txt
cp all_components_creds.txt 12-media/env/components-creds.txt
cp all_components_creds.txt 13-order/env/components-creds.txt
cp all_components_creds.txt 14-notification/env/components-creds.txt
cp all_components_creds.txt 15-api-gateway/env/components-creds.txt
cp all_components_creds.txt 16-recommendation/env/components-creds.txt
cp all_components_creds.txt 17-shipping/env/components-creds.txt
cp all_components_creds.txt 18-risk-trust/env/components-creds.txt
```

## 9. Generate each service's `.env.dev`

```bash
( cd 00-support && ./env/init-env.sh .env.dev )
( cd 02-profile && ./env/init-env.sh .env.dev )
( cd 03-seller && ./env/init-env.sh .env.dev )
( cd 04-catalog && ./env/init-env.sh .env.dev )
( cd 05-search && ./env/init-env.sh .env.dev )
( cd 06-cart && ./env/init-env.sh .env.dev )
( cd 07-coupon && ./env/init-env.sh .env.dev )
( cd 08-review && ./env/init-env.sh .env.dev )
( cd 09-payment && ./env/init-env.sh .env.dev )
( cd 10-wallet && ./env/init-env.sh .env.dev )
( cd 11-reporting && ./env/init-env.sh .env.dev )
( cd 12-media && ./env/init-env.sh .env.dev )
( cd 13-order && ./env/init-env.sh .env.dev )
( cd 14-notification && ./env/init-env.sh .env.dev )
( cd 15-api-gateway && ./env/init-env.sh .env.dev )
( cd 16-recommendation && ./env/init-env.sh .env.dev )
( cd 17-shipping && ./env/init-env.sh .env.dev )
( cd 18-risk-trust && ./env/init-env.sh .env.dev )
```

## 10. Build every Docker image

```bash
( cd 00-support && docker build --no-cache -t dokandar_support_service:latest . && docker build -t dokandar_support_service:dev . )
( cd 02-profile && docker build --no-cache -t dokandar_profile_service:latest . && docker build -t dokandar_profile_service:dev . )
( cd 03-seller && docker build --no-cache -t dokandar_seller_service:latest . && docker build -t dokandar_seller_service:dev . )
( cd 04-catalog && docker build --no-cache -t dokandar_catalog_service:latest . && docker build -t dokandar_catalog_service:dev . )
( cd 05-search && docker build --no-cache -t dokandar_search_service:latest . && docker build -t dokandar_search_service:dev . )
( cd 06-cart && docker build --no-cache -t dokandar_cart_service:latest . && docker build -t dokandar_cart_service:dev . )
( cd 07-coupon && docker build --no-cache -t dokandar_coupon_service:latest . && docker build -t dokandar_coupon_service:dev . )
( cd 08-review && docker build --no-cache -t dokandar_review_service:latest . && docker build -t dokandar_review_service:dev . )
( cd 09-payment && docker build --no-cache -t dokandar_payment_service:latest . && docker build -t dokandar_payment_service:dev . )
( cd 10-wallet && docker build --no-cache -t dokandar_wallet_service:latest . && docker build -t dokandar_wallet_service:dev . )
( cd 11-reporting && docker build --no-cache -t dokandar_reporting_service:latest . && docker build -t dokandar_reporting_service:dev . )
( cd 12-media && docker build --no-cache -t dokandar_media_service:latest . && docker build -t dokandar_media_service:dev . )
( cd 13-order && docker build --no-cache -t dokandar_order_service:latest . && docker build -t dokandar_order_service:dev . )
( cd 14-notification && docker build --no-cache -t dokandar_notification_service:latest . && docker build -t dokandar_notification_service:dev . )
( cd 15-api-gateway && docker build --no-cache -t dokandar_api_gateway_service:latest . && docker build -t dokandar_api_gateway_service:dev . )
( cd 16-recommendation && docker build --no-cache -t dokandar_recommendation_service:latest . && docker build -t dokandar_recommendation_service:dev . )
( cd 17-shipping && docker build --no-cache -t dokandar_shipping_service:latest . && docker build -t dokandar_shipping_service:dev . )
( cd 18-risk-trust && docker build --no-cache -t dokandar_risk_trust_service:latest . && docker build -t dokandar_risk_trust_service:dev . )
```

## 11. Deploy every service

```bash
docker rm -f dokandar_support_service_dev || true
( cd 00-support && docker run -d --name dokandar_support_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10099:8000 --restart=on-failure:3 dokandar_support_service:dev )

docker rm -f dokandar_profile_service_dev || true
( cd 02-profile && docker run -d --name dokandar_profile_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10002:8000 -p 20002:8001 --restart=on-failure:3 dokandar_profile_service:dev )

docker rm -f dokandar_seller_service_dev || true
( cd 03-seller && docker run -d --name dokandar_seller_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10003:8000 --restart=on-failure:3 dokandar_seller_service:dev )

docker rm -f dokandar_catalog_service_dev || true
( cd 04-catalog && docker run -d --name dokandar_catalog_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10004:8080 -p 20004:9090 --restart=on-failure:3 dokandar_catalog_service:dev )

docker rm -f dokandar_search_service_dev || true
( cd 05-search && docker run -d --name dokandar_search_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10005:8080 --restart=on-failure:3 dokandar_search_service:dev )

docker rm -f dokandar_cart_service_dev || true
( cd 06-cart && docker run -d --name dokandar_cart_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10006:3000 --restart=on-failure:3 dokandar_cart_service:dev )

docker rm -f dokandar_coupon_service_dev || true
( cd 07-coupon && docker run -d --name dokandar_coupon_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10007:8080 -p 20007:9090 --restart=on-failure:3 dokandar_coupon_service:dev )

docker rm -f dokandar_review_service_dev || true
( cd 08-review && docker run -d --name dokandar_review_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10008:8080 -p 20008:50051 --restart=on-failure:3 dokandar_review_service:dev )

docker rm -f dokandar_payment_service_dev || true
( cd 09-payment && docker run -d --name dokandar_payment_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10009:4000 --restart=on-failure:3 dokandar_payment_service:dev )

docker rm -f dokandar_wallet_service_dev || true
( cd 10-wallet && docker run -d --name dokandar_wallet_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10010:8080 -p 20010:8001 --restart=on-failure:3 dokandar_wallet_service:dev )

docker rm -f dokandar_reporting_service_dev || true
( cd 11-reporting && docker run -d --name dokandar_reporting_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10011:8080 --restart=on-failure:3 dokandar_reporting_service:dev )

docker rm -f dokandar_media_service_dev || true
( cd 12-media && docker run -d --name dokandar_media_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10012:8080 -p 20012:50051 --restart=on-failure:3 dokandar_media_service:dev )

docker rm -f dokandar_order_service_dev || true
( cd 13-order && docker run -d --name dokandar_order_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10013:8080 -p 20013:9090 --restart=on-failure:3 dokandar_order_service:dev )

docker rm -f dokandar_notification_service_dev || true
( cd 14-notification && docker run -d --name dokandar_notification_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10014:3000 --restart=on-failure:3 dokandar_notification_service:dev )

docker rm -f dokandar_api_gateway_service_dev || true
( cd 15-api-gateway && docker run -d --name dokandar_api_gateway_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10015:8080 --restart=on-failure:3 dokandar_api_gateway_service:dev )

docker rm -f dokandar_recommendation_service_dev || true
( cd 16-recommendation && docker run -d --name dokandar_recommendation_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10016:8000 -p 20016:50051 --restart=on-failure:3 dokandar_recommendation_service:dev )

docker rm -f dokandar_shipping_service_dev || true
( cd 17-shipping && docker run -d --name dokandar_shipping_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10017:8000 -p 20017:8001 --restart=on-failure:3 dokandar_shipping_service:dev )

docker rm -f dokandar_risk_trust_service_dev || true
( cd 18-risk-trust && docker run -d --name dokandar_risk_trust_service_dev --env-file env/.env.dev -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 10018:8000 -p 20018:50051 --restart=on-failure:3 dokandar_risk_trust_service:dev )
```

## 12. Verify every service is healthy

```bash
docker ps -a --filter name=dokandar --format '{{.Names}}\t{{.Status}}'
curl -s http://127.0.0.1:10099/ready
curl -s http://127.0.0.1:10001/ready
curl -s http://127.0.0.1:10002/ready
curl -s http://127.0.0.1:10003/ready
curl -s http://127.0.0.1:10004/ready
curl -s http://127.0.0.1:10005/ready
curl -s http://127.0.0.1:10006/ready
curl -s http://127.0.0.1:10007/ready
curl -s http://127.0.0.1:10008/ready
curl -s http://127.0.0.1:10009/ready
curl -s http://127.0.0.1:10010/ready
curl -s http://127.0.0.1:10011/ready
curl -s http://127.0.0.1:10012/ready
curl -s http://127.0.0.1:10013/ready
curl -s http://127.0.0.1:10014/ready
curl -s http://127.0.0.1:10015/ready
curl -s http://127.0.0.1:10016/ready
curl -s http://127.0.0.1:10017/ready
curl -s http://127.0.0.1:10018/ready
```

## 13. Verify service-to-service communication (JWT + gRPC)

```bash
AUTH_URL=http://127.0.0.1:10001 ./01-auth/test.sh
docker logs dokandar_api_gateway_service_dev
nc -z 127.0.0.1 20001
nc -z 127.0.0.1 20002
nc -z 127.0.0.1 20004
nc -z 127.0.0.1 20007
nc -z 127.0.0.1 20008
nc -z 127.0.0.1 20010
nc -z 127.0.0.1 20012
nc -z 127.0.0.1 20013
nc -z 127.0.0.1 20016
nc -z 127.0.0.1 20017
nc -z 127.0.0.1 20018
```

## 14. Commit and Push Changes

```bash
cd 01-auth && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 02-profile && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 03-seller && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 04-catalog && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 05-search && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 06-cart && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 07-coupon && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 08-review && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 09-payment && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 10-wallet && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 11-reporting && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 12-media && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 13-order && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 14-notification && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 15-api-gateway && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 16-recommendation && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 17-shipping && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 18-risk-trust && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
cd 00-support && git add . && git commit -m "modified" && git push -uf  source-code && cd ..
```

---


### Notes

- Each repository also ships its own `commands.md` with the identical
  single-service workflow (clone → env → collect → build → run → verify).
- `./env/init-env.sh` supports `.env.dev`, `.env.stage`, `.env.prod` and
  `TENANT=cloud|local`. Everything derives from `all_components_creds.txt`; no
  manual editing of the rendered `.env.*` files is required.
