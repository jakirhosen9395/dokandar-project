# Kafka — docker single node variant (KRaft + kafka-ui)

```bash
bash setup.sh up      # fills cluster-id + advertised host, starts broker + UI, prints URLs
cd .. && bash test.sh
```

Public reach: kafka-ui http://<server-ip>:8080 · broker bootstrap <server-ip>:9092
(SG tcp/8080 + 9092 open). The advertised host is this machine's public IP so external
clients work.
