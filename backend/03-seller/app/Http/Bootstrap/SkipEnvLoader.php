<?php

namespace App\Http\Bootstrap;

use Illuminate\Contracts\Foundation\Application;

/**
 * No-op replacement for Laravel's default LoadEnvironmentVariables
 * bootstrapper. Bound in bootstrap/app.php.
 *
 * Config is injected exclusively via process env (docker --env-file at
 * runtime). There is no /app/.env file inside the image — the host-side
 * env/.env.<env> drives the injection and never enters the container's
 * filesystem.
 *
 * The default LoadEnvironmentVariables calls phpdotenv's safeLoad(),
 * which does a `@file_get_contents('/app/.env')`. With no .env present,
 * PHP emits an E_WARNING that the Elastic APM PHP agent captures as a
 * full APM error document — observed at ~1,500 spurious errors/hr per
 * replica. The agent's error hook runs at the zend layer and observes
 * the warning before PHP's @ suppression applies, so the suppression
 * doesn't help.
 *
 * Skipping the bootstrapper avoids the read entirely. `env()` keeps
 * working because Laravel's Env::get() reads from $_ENV / $_SERVER via
 * its default adapters, and PHP populates both from environ on CLI
 * (variables_order = EGPCS).
 */
class SkipEnvLoader
{
    public function bootstrap(Application $app): void
    {
        // intentional no-op
    }
}
