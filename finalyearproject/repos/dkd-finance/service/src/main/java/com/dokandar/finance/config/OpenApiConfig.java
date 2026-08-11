package com.dokandar.finance.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI financeOpenApi() {
        return new OpenAPI().info(new Info()
            .title("DOKANDAR finance-ledger-svc")
            .description("Context #8 Finance & Settlement — R2 isolated int64-poisha double-entry " +
                "ledger, wallets, MFS accounts, escrow saga (R3). All writes require Idempotency-Key.")
            .version("v1"));
    }
}
