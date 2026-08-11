# Elastic APM stack — docker single node variant

```bash
bash setup_env.sh && bash setup.sh up   # prints Kibana URL + elastic password + APM token
cd .. && bash test.sh
```

Public reach: Kibana http://<server-ip>:5601 (login `elastic`) · ES :9200 · APM :8200.
RAM: ES heap 512m/limit 1500m, Kibana 1g, APM 300m — sized for the shared 8GB host.
