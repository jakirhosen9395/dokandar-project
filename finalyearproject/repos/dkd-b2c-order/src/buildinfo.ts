// Fleet provenance convention: /version returns {version, gitSha, buildTime} from the
// build-info.json baked into the image (single-SHA rule: OCI revision == /version gitSha == HEAD).
import { readFileSync } from "node:fs";

export interface BuildInfo {
  service: string;
  version: string;
  gitSha: string;
  buildTime: string;
  contractVersion: string;
}

export function loadBuildInfo(path: string, contractVersion: string): BuildInfo {
  let raw: Partial<BuildInfo> = {};
  try {
    raw = JSON.parse(readFileSync(path, "utf8")) as Partial<BuildInfo>;
  } catch {
    // local dev without a baked build-info file
  }
  return {
    service: "b2c-order-svc",
    version: raw.version ?? "0.0.0-dev",
    gitSha: raw.gitSha ?? "unknown",
    buildTime: raw.buildTime ?? "unknown",
    contractVersion,
  };
}
