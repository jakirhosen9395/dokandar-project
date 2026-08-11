import { Injectable, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';
import { config } from './config';

@Injectable()
export class RedisService implements OnModuleInit {
  public client!: Redis;
  onModuleInit(): void {
    this.client = new Redis({
      host: config.redisHost, port: config.redisPort,
      password: config.redisPassword || undefined, db: config.redisDb,
      maxRetriesPerRequest: 2, enableReadyCheck: true,
    });
    this.client.on('error', () => {});
  }
  async acquireLock(userId: string): Promise<string | null> {
    const token = Math.random().toString(36).slice(2) + Date.now();
    const ok = await this.client.set(`cart:lock:${userId}`, token, 'EX', config.checkoutLockTtlSeconds, 'NX');
    return ok ? token : null;
  }
  async releaseLock(userId: string, token: string): Promise<void> {
    const lua = "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end";
    try { await this.client.eval(lua, 1, `cart:lock:${userId}`, token); } catch {}
  }
}
