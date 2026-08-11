# syntax=docker/dockerfile:1
# DOKANDAR 03-seller — Laravel 13 on PHP 8.4 (bounded context: shop).
# Multi-stage: `build` compiles the PECL extensions + resolves composer deps;
# `runtime` gets only the compiled extensions, their shared libs and /app.
# §16-j's prod target (Octane/FrankenPHP) stays deferred — startup semantics
# are unchanged: docker/entrypoint.sh → migrations → php -S.

# ------------------------------------------------------------------ build ---
FROM php:8.4-cli AS build
WORKDIR /app

# Toolchain + dev headers for the PHP extensions we compile (build stage only).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git unzip pkg-config \
      libpq-dev libzip-dev libssl-dev librdkafka-dev libcurl4-openssl-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

# Core extensions. (opcache is omitted — on php:8.4-cli it's a built-in Zend
# extension and `docker-php-ext-install opcache` produces no shared module
# ["cp: cannot stat 'modules/*'"], failing the build; it isn't required.)
RUN docker-php-ext-install pdo_pgsql pgsql zip bcmath
# PECL: mongodb (in-process log sink) + rdkafka (outbox producer) + redis.
# The `docker-php-ext-enable` step can silently not-take on some PHP base
# images; bypass it by writing the conf.d file directly, then assert
# loud-and-loud that PHP actually sees all three extensions before composer runs.
RUN pecl install mongodb rdkafka redis \
 && echo "extension=mongodb.so" > /usr/local/etc/php/conf.d/30-mongodb.ini \
 && echo "extension=rdkafka.so" > /usr/local/etc/php/conf.d/30-rdkafka.ini \
 && echo "extension=redis.so"   > /usr/local/etc/php/conf.d/30-redis.ini \
 && php -m | grep -E '^mongodb$|^rdkafka$|^redis$' > /tmp/exts.txt \
 && [ "$(wc -l < /tmp/exts.txt)" = "3" ] || (echo "FATAL: required extensions not loaded by PHP; got:" && php -m && exit 1)

# grpc extension — the east-west CLIENT for Auth.LookupShopkeeper (staff-assign
# verification) + Media presign. Installed from a prebuilt ABI-matched binary via
# install-php-extensions (~1-2 min) instead of the ~15-25 min pecl compile, so
# ShopStaffController->usable() is true and staff assignment actually verifies the
# target's role via 01-auth's gRPC (rejecting non-shop_staff roles).
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN install-php-extensions grpc \
 && php -m | grep -q '^grpc$' || (echo "FATAL: grpc extension not loaded by PHP" && php -m && exit 1)

# Tighten PHP's defaults — the platform contract's bare-404 hardening
# requires unmapped paths to leak nothing. PHP's built-in dev server
# (artisan serve) otherwise auto-injects `Content-Type: text/html;
# charset=UTF-8` and `X-Powered-By: PHP/8.x` on every response. Setting
# `default_mimetype=` (empty) tells PHP not to add a default Content-Type,
# and `expose_php=Off` drops X-Powered-By.
RUN printf 'expose_php=Off\ndefault_mimetype=\ndefault_charset=\n' \
        > /usr/local/etc/php/conf.d/50-bare-404.ini

# Elastic APM PHP agent — best-effort install via the official .deb package
# from GitHub releases (the PECL route was deprecated). If the install fails
# the service still runs without APM auto-instrumentation; the build does
# not fail. Watch for "elastic_apm: enabled" in build output. The mkdir keeps
# the runtime stage's COPY of /opt/elastic valid even when the download fails.
ARG ELASTIC_APM_PHP_VERSION=1.16.0
RUN mkdir -p /opt/elastic \
 && ( set -e \
      && APM_DEB=apm-agent-php_${ELASTIC_APM_PHP_VERSION}_$(dpkg --print-architecture).deb \
      && curl -fsSL -o /tmp/$APM_DEB \
           https://github.com/elastic/apm-agent-php/releases/download/v${ELASTIC_APM_PHP_VERSION}/$APM_DEB \
      && dpkg -i /tmp/$APM_DEB \
      && rm -f /tmp/$APM_DEB \
      && php -m | grep -q '^elastic_apm$' \
      && echo "elastic_apm: enabled" \
    ) || echo "elastic_apm: .deb install failed — service will run without APM auto-instrumentation."

# Composer (from official image; build stage only — never ships in runtime).
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# composer.json first for layer caching, then the rest of the app.
# NOTE: no composer.lock is committed — resolution happens at build time.
COPY composer.json ./
# `--no-security-blocking` skips the security-advisory block that composer 2.7+
# raises on firebase/php-jwt 6.10–6.11 (advisory PKSA-y2cr-5h3j-g3ys). Fine
# for this teaching service; revisit when a clean release of php-jwt is
# published. The `--ignore-platform-req` pair belt-and-braces composer's
# platform check even though our `php -m` assertion above already proved
# mongodb + rdkafka are loaded.
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction --no-security-blocking \
    --ignore-platform-req=ext-mongodb --ignore-platform-req=ext-rdkafka
COPY . ./
RUN composer dump-autoload --optimize --no-dev \
 && chmod -R 0755 storage bootstrap/cache \
 && chmod +x /app/docker/entrypoint.sh

# grpc extension is installed above (build stage) via install-php-extensions, so
# the east-west Auth.LookupShopkeeper / Media presign clients are functional and
# staff-assignment verification is enforced (not skipped).

# ---------------------------------------------------------------- runtime ---
FROM php:8.4-cli AS runtime
WORKDIR /app

# Shared libraries the compiled extensions link against (dev headers, git,
# unzip, composer and pecl build caches all stay behind in the build stage).
# php:8.4-cli is Debian trixie → libzip5; libzip4 is the bookworm fallback
# should the base image suite ever differ.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 librdkafka1 \
 && { apt-get install -y --no-install-recommends libzip5 \
      || apt-get install -y --no-install-recommends libzip4; } \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser

# Compiled extensions + ini config (30-*.ini, 50-bare-404.ini, the
# docker-php-ext-*.ini set, and the elastic-apm ini when the .deb installed)
# + the APM agent runtime files under /opt/elastic (empty dir if it didn't).
COPY --from=build /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=build /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=build /opt/elastic/ /opt/elastic/

# Application source + vendor + CODE_VERSION (read by /ready identity).
COPY --from=build /app/ /app/
# storage/bootstrap-cache must be writable by the non-root user; then assert
# every required extension actually loads (with its shared libs) in THIS image.
RUN chown -R appuser:appuser /app/storage /app/bootstrap/cache \
 && [ "$(php -m | grep -cE '^(mongodb|rdkafka|redis|pdo_pgsql|pgsql|zip|bcmath|grpc)$')" = "8" ] \
      || (echo "FATAL: extensions failed to load in runtime image; got:" && php -m && exit 1)

USER appuser
EXPOSE 8000
# Probe /ready via PHP, respecting SERVICE_PORT. file_get_contents returns
# false on a 503/connection failure → unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD php -r '$p=getenv("SERVICE_PORT")?:"8000"; exit(@file_get_contents("http://127.0.0.1:$p/ready")!==false?0:1);' || exit 1
ENTRYPOINT ["/app/docker/entrypoint.sh"]
