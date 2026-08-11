# RabbitMQ — docker single node variant

```bash
bash setup_env.sh && bash setup.sh up    # credentials + PUBLIC urls printed
cd .. && bash test.sh
```

Public reach: web UI http://<server-ip>:15672 · AMQP <server-ip>:5672
(SG tcp/5672 + 15672 open; log in with the generated credentials).
