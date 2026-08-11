package com.dokandar.b2b.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * dkd.* settings. marginRateBps is POLICY DATA (canon margin rate tables have no values —
 * NEEDS-INFO, P2); the dev default 1000 bps = 10% is the floor of the FR-MKT-052 forward
 * advance band. inventoryUrl/custodyUrl are the strong-local G2 reserve seam and the
 * custody OHS used to verify settlement transfers (InitiateSettlement precondition).
 */
@ConfigurationProperties(prefix = "dkd")
public record B2bProps(int marginRateBps, String inventoryUrl, String custodyUrl,
                       String custodyGrpcUrl, String inventoryGrpcUrl, String buildInfoPath) {
    public B2bProps {
        if (marginRateBps <= 0) marginRateBps = 1000;
        if (inventoryUrl == null || inventoryUrl.isBlank()) inventoryUrl = "";
        if (custodyUrl == null || custodyUrl.isBlank()) custodyUrl = "";
        // B2B-F2: dkd.custody-grpc-url ("host:port") routes the passport read over gRPC (EF-API-1).
        if (custodyGrpcUrl == null || custodyGrpcUrl.isBlank()) custodyGrpcUrl = "";
        if (inventoryGrpcUrl == null || inventoryGrpcUrl.isBlank()) inventoryGrpcUrl = "";
        if (buildInfoPath == null || buildInfoPath.isBlank()) buildInfoPath = "/app/build-info.properties";
    }
}
