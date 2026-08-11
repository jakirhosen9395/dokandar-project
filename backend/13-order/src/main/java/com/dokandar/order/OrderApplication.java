package com.dokandar.order;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * DOKANDAR 13-order — Temporal-orchestrated checkout-saga orchestrator + order /
 * sub-order lifecycle (system of record for order state; the choreography apex).
 */
@SpringBootApplication
@EnableScheduling
@ConfigurationPropertiesScan
public class OrderApplication {
    public static void main(String[] args) {
        SpringApplication.run(OrderApplication.class, args);
    }
}
