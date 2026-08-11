# Apicurio Schema Registry (in-memory) — utility

The Published-Language schema registry (event schemas live here in the DOKANDAR design).
This teaching build stores everything IN MEMORY — a restart clears it (persistent SQL/Kafka
storage belongs to the later cluster variants). No auth.

## Quick start (infra-1)
```bash
cd docker-single-node-setup && bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **Web UI (browser):** http://<server-ip>:8081/ui/
- **API:** `curl http://<server-ip>:8081/apis/registry/v2/groups/default/artifacts`
Port tcp/8081 is open (8080 on this server belongs to kafka-ui).
