# Apache Kafka 4.3 (KRaft) + kafka-ui — utility

DOKANDAR's event spine (the 59-topic Published Language). KRaft mode = no ZooKeeper.
Ships with the Provectus **kafka-ui** so you can watch topics and messages in a browser.

## Quick start
```bash
cd docker-single-node-setup
bash setup.sh up        # generates the cluster id + advertised host, starts broker + UI
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **kafka-ui (browser):** http://<server-ip>:8080
- **broker (clients):** bootstrap `<server-ip>:9092` (the broker advertises this exact
  address, so external producers/consumers reconnect correctly).

```bash
bash test.sh <server-ip>:9092     # runs the full produce/consume test against the public port
```
