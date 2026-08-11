package com.dokandar.b2b;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * b2b-trade-svc — DOKANDAR Context #7 (B2B Trade & Commodity Exchange).
 * TradeOrder aggregate + local margin domain service; Saga 4 settlement via the event
 * spine (Finance is reached ONLY through events — R2/ADR-004); integer poisha only;
 * exactly-once via outbox+inbox+idempotency keys. ADR-009: Separate Ways from B2C.
 */
@SpringBootApplication
@EnableScheduling
@ConfigurationPropertiesScan
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
