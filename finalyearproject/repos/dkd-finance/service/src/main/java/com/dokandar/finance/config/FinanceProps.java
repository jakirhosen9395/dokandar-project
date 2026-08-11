package com.dokandar.finance.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * dkd.* settings. coolingOffMs defaults to 72h (BR: settlement hold cooling-off window);
 * env-configurable so E2E can prove the SETTLEMENT_HELD -> RELEASED path without waiting 72h.
 */
@ConfigurationProperties(prefix = "dkd")
public record FinanceProps(long coolingOffMs, String sysCashAccount, String buildInfoPath) {
    public FinanceProps {
        if (coolingOffMs <= 0) coolingOffMs = 259_200_000L;
        if (sysCashAccount == null || sysCashAccount.isBlank()) sysCashAccount = "SYS-CASH";
        if (buildInfoPath == null || buildInfoPath.isBlank()) buildInfoPath = "/app/build-info.properties";
    }
}
