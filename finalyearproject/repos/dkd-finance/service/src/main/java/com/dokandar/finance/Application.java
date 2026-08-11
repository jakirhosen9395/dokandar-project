package com.dokandar.finance;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * finance-ledger-svc — DOKANDAR Context #8 (Finance & Settlement).
 * R2: physically isolated finance core. Integer poisha only. Double-entry ledger,
 * escrow with compensating-reversal sagas (R3), exactly-once via outbox+inbox+idempotency keys.
 */
@SpringBootApplication
@EnableScheduling
@ConfigurationPropertiesScan
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
