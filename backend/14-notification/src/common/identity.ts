// The shared identity block prepended to /ready, /health, /data, /docs and the
// canonical boot timestamp. server.ts and ops/ops.routes BOTH import these so the
// uptime + identity are computed from one source (the contract: service_name,
// code_version, env_version, tenant, env, uptime_seconds — identical everywhere).
import { config } from '../config';

// Process boot epoch (ms). Captured once at module load.
export const BOOT = Date.now();

export interface Identity {
  service_name: string;
  code_version: string;
  env_version: string;
  tenant: string;
  env: string;
  uptime_seconds: number;
}

export function identity(): Identity {
  return {
    service_name: config.serviceName,
    code_version: config.codeVersion,
    env_version: config.envVersion,
    tenant: config.tenant,
    env: config.appEnv,
    uptime_seconds: Math.floor((Date.now() - BOOT) / 1000),
  };
}
