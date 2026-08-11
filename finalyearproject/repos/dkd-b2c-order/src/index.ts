import { load, validate } from "./config.js";
import { Logger } from "./obs/logging.js";
import { App } from "./app.js";

const log = new Logger();
const cfg = load();
validate(cfg);                          // startup validation
const app = new App(cfg, log);
app.start().catch((e) => {
  log.error("startup failed", { err: String(e) });
  process.exit(1);
});

async function shutdown(): Promise<void> { // graceful shutdown
  log.info("shutting down");
  await app.stop();
  process.exit(0);
}
process.on("SIGINT", () => { shutdown().catch((e) => { log.error("shutdown error", { err: String(e) }); process.exit(1); }); });
process.on("SIGTERM", () => { shutdown().catch((e) => { log.error("shutdown error", { err: String(e) }); process.exit(1); }); });
