import { Module } from '@nestjs/common';
import { MongoService } from './mongo.service';
import { RedisService } from './redis.service';
import { OpsController } from './ops/ops.controller';
import { CartController } from './cart/cart.controller';
import { CartService } from './cart/cart.service';
import { CheckoutService } from './cart/checkout.service';

@Module({
  controllers: [OpsController, CartController],
  providers: [MongoService, RedisService, CartService, CheckoutService],
})
export class AppModule {}
