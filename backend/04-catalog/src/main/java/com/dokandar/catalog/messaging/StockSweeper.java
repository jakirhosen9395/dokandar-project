package com.dokandar.catalog.messaging;

import com.dokandar.catalog.observability.CatalogMetrics;
import com.dokandar.catalog.service.StockService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Releases reservations past their 15-min expiry so abandoned checkouts return stock (architecture.md §7.3). */
@Component
public class StockSweeper {

    private static final Logger LOG = LoggerFactory.getLogger(StockSweeper.class);
    private final StockService stock;
    private final CatalogMetrics metrics;

    public StockSweeper(StockService stock, CatalogMetrics metrics) { this.stock = stock; this.metrics = metrics; }

    @Scheduled(fixedDelay = 60000, initialDelay = 60000)
    public void sweep() {
        try {
            long n = stock.gcExpired();
            if (n > 0) { metrics.gc(n); LOG.info("released {} expired reservation(s)", n); }
        } catch (Exception e) {
            LOG.warn("reservation sweep failed: {}", e.getMessage());
        }
    }
}
