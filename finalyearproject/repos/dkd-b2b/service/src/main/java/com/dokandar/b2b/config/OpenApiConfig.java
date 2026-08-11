package com.dokandar.b2b.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI b2bOpenApi() {
        return new OpenAPI().info(new Info()
            .title("DOKANDAR b2b-trade-svc")
            .description("Context #7 B2B Trade & Commodity Exchange — TradeOrder margining and " +
                "Saga 4 settlement over the event spine. All writes require Idempotency-Key.")
            .version("v1"));
    }
}
