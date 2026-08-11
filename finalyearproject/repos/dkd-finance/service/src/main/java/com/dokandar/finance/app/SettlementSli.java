package com.dokandar.finance.app;

import com.dokandar.finance.store.LedgerStore;
import io.micrometer.core.instrument.MeterRegistry;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * F-5: settlement-correctness SLI + auto-freeze. Continuously probes the double-entry invariant
 * (any txn whose signed legs do not sum to zero, BR-028/R3) and exposes it as a gauge; if a breach
 * is ever seen the service latches FROZEN (gauge = 1) so operators/gates can halt settlement.
 * The check is read-only — it never mutates the ledger.
 */
@Component
public class SettlementSli {
    private static final Logger log = LoggerFactory.getLogger(SettlementSli.class);

    private final LedgerStore ledger;
    private final AtomicInteger unbalanced = new AtomicInteger(0);
    private final AtomicInteger frozen = new AtomicInteger(0); // 0 = ok, 1 = latched-frozen

    public SettlementSli(LedgerStore ledger, MeterRegistry metrics) {
        this.ledger = ledger;
        // RED-adjacent settlement SLIs, scraped at /actuator/prometheus.
        metrics.gauge("finance_settlement_unbalanced_txns", unbalanced);
        metrics.gauge("finance_settlement_frozen", frozen);
    }

    @Scheduled(fixedDelay = 30_000, initialDelay = 5_000)
    public void probe() {
        try {
            List<String> bad = ledger.unbalancedTxns();
            unbalanced.set(bad.size());
            if (!bad.isEmpty()) {
                frozen.set(1); // latch — never auto-unfreeze (requires operator review, R3)
                log.error("SETTLEMENT INVARIANT BREACH — {} unbalanced txn(s), settlement FROZEN: {}",
                    bad.size(), bad.size() > 5 ? bad.subList(0, 5) + "…" : bad);
            }
        } catch (Exception e) {
            log.warn("settlement SLI probe failed: {}", e.toString());
        }
    }

    /** Downstream money-write gates may consult this to refuse new settlement while frozen. */
    public boolean isFrozen() {
        return frozen.get() == 1;
    }
}
