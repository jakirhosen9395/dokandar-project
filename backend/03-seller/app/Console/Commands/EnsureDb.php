<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;

/**
 * Idempotent CREATE DATABASE on the components Postgres. Laravel's
 * `migrate` requires the DB to already exist — this command runs FIRST
 * in the container entrypoint. Connects to the bootstrap `postgres`
 * DB via a separate PDO and checks pg_database.
 */
class EnsureDb extends Command
{
    protected $signature = 'shop:ensure-db';
    protected $description = 'CREATE DATABASE dokandar_shop_<env> if it does not exist.';

    public function handle(): int
    {
        $host = env('DB_HOST');
        $port = env('DB_PORT', '5432');
        $user = env('DB_USERNAME');
        $pass = env('DB_PASSWORD');
        $target = env('DB_DATABASE');
        if (empty($host) || empty($user) || empty($target)) {
            $this->error('DB_HOST / DB_USERNAME / DB_DATABASE must be set');
            return self::FAILURE;
        }
        try {
            $pdo = new \PDO(
                "pgsql:host={$host};port={$port};dbname=postgres",
                $user, $pass,
                [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]
            );
        } catch (\Throwable $e) {
            $this->error("admin connect failed: ".$e->getMessage());
            return self::FAILURE;
        }
        $stmt = $pdo->prepare('SELECT 1 FROM pg_database WHERE datname = :n');
        $stmt->execute([':n' => $target]);
        if ($stmt->fetchColumn()) {
            $this->info("ensure_db: database '{$target}' already exists");
            return self::SUCCESS;
        }
        // CREATE DATABASE cannot run inside a TX; PDO autocommits standalone.
        $pdo->exec('CREATE DATABASE "'.str_replace('"', '', $target).'"');
        $this->info("ensure_db: created database '{$target}'");
        return self::SUCCESS;
    }
}
