import { Logger } from "./obs/logging.js";
import { Metrics } from "./obs/metrics.js";
import { createServers } from "./http/server.js";
import { Jwt } from "./security/jwt.js";
import type { Config } from "./config.js";
import { PgDb } from "./persistence/pg.js";
import { migrate } from "./persistence/migrate.js";
import { OrderStore, MIGRATIONS } from "./store/orders.js";
import { OutboxStore, InboxStore, IdemStore } from "./store/spine.js";
import { EventFactory } from "./app/events.js";
import { IdemCommands } from "./app/idem.js";
import { OrderService } from "./app/orders.js";
import { InventoryClient, CatalogClient } from "./clients/rest.js";
import { KafkaSpine } from "./messaging/kafka.js";
import { OutboxRelay } from "./kafka/relay.js";
import { SpineDispatcher, CONSUMED_TOPICS } from "./kafka/listener.js";
import { buildRouter } from "./http/routes.js";
import { loadBuildInfo } from "./buildinfo.js";
import { CONTRACT_VERSION } from "@dokandar/platform-sdk";

// App is the dependency-injection container: it constructs and owns the service's adapters.
export class App {
  private servers?: { http: import("node:http").Server; metrics: import("node:http").Server };
  private db?: PgDb;
  private spine?: KafkaSpine;
  private relay?: OutboxRelay;
  private ready = false;
  readonly jwt: Jwt;

  constructor(private readonly cfg: Config, private readonly log: Logger) {
    this.jwt = new Jwt(cfg.jwtIssuer);
  }

  async start(): Promise<void> {
    const metrics = new Metrics();
    await migrate(this.cfg.dbDsn, MIGRATIONS, (m) => this.log.info(m));
    this.db = new PgDb(this.cfg.dbDsn);
    await this.db.ping();

    const store = new OrderStore(this.db);
    const outbox = new OutboxStore(this.db);
    const inbox = new InboxStore();
    const idem = new IdemCommands(this.db, new IdemStore(this.db));
    const events = new EventFactory(outbox);
    const orders = new OrderService(this.db, store, events,
      new InventoryClient(this.cfg.inventoryUrl), new CatalogClient(this.cfg.catalogUrl), this.log);

    this.spine = new KafkaSpine(this.cfg.kafkaBrokers, this.cfg.serviceName);
    await this.spine.connectProducer();
    this.relay = new OutboxRelay(outbox, this.spine, this.log);
    this.relay.start();
    const dispatcher = new SpineDispatcher(this.db, inbox, orders, metrics, this.log);
    await this.spine.subscribe("b2c-order-svc", CONSUMED_TOPICS,
      (rec) => dispatcher.handle(rec),
      (msg, fields) => this.log.info(msg, fields));

    const buildInfo = loadBuildInfo(this.cfg.buildInfoPath, CONTRACT_VERSION);
    const router = buildRouter(this.db, orders, store, idem);
    this.servers = createServers(this.cfg.httpPort, this.cfg.metricsPort, this.log, metrics,
      () => this.ready, this.cfg.serviceName, router, buildInfo);
    this.ready = true;
    this.log.info("started", { service: this.cfg.serviceName, port: this.cfg.httpPort });
  }

  async stop(): Promise<void> {
    this.ready = false;
    this.relay?.stop();
    await this.spine?.close();
    await new Promise<void>((resolve) => this.servers?.http.close(() => resolve()));
    await new Promise<void>((resolve) => this.servers?.metrics.close(() => resolve()));
    await this.db?.close();
  }
}
