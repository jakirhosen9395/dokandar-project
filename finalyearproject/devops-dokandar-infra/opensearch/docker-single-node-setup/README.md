# OpenSearch — docker single node variant (security OFF, learning mode)

```bash
bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```
Public reach: http://<server-ip>:9201 (no auth — learning config). `_cluster/health` and
`_search` work from any browser/curl.
