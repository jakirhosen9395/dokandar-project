from __future__ import annotations
from prometheus_client import Counter, Gauge, Histogram

SERVICE_VAL = "11-reporting"

reporting_kpi_queries_total = Counter("reporting_kpi_queries_total", "KPI queries served.", ("service","kpi"))
reporting_kpi_query_duration_ms = Histogram("reporting_kpi_query_duration_ms", "KPI query wall-time.", ("service","kpi"), buckets=(5,10,25,50,100,250,500,1000))
reporting_facts_upserted_total = Counter("reporting_facts_upserted_total", "Fact upserts.", ("service","topic"))
reporting_projection_lag = Gauge("reporting_projection_lag", "Consumer lag.", ("service","topic"))
reporting_export_rows_total = Counter("reporting_export_rows_total", "Regulatory export rows.", ("service","export"))
