// B2C-09: dependency-free Prometheus-text registry — counters + RED duration histograms.
export class Metrics {
  private counters = new Map<string, number>();
  // RED histogram: cumulative bucket counts keyed by metric name (seconds).
  private static readonly BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];
  private histCounts = new Map<string, number[]>();
  private histSum = new Map<string, number>();
  private histCount = new Map<string, number>();

  inc(name: string): void { this.counters.set(name, (this.counters.get(name) ?? 0) + 1); }

  // observe a request duration (seconds) into a Prometheus histogram (RED — Duration).
  observe(name: string, seconds: number): void {
    let counts = this.histCounts.get(name);
    if (!counts) { counts = Metrics.BUCKETS.map(() => 0); this.histCounts.set(name, counts); }
    Metrics.BUCKETS.forEach((b, i) => { if (seconds <= b) counts[i] = (counts[i] ?? 0) + 1; });
    this.histSum.set(name, (this.histSum.get(name) ?? 0) + seconds);
    this.histCount.set(name, (this.histCount.get(name) ?? 0) + 1);
  }

  expose(): string {
    let out = "";
    for (const [name, v] of this.counters) out += `${name} ${v}\n`;
    for (const [name, counts] of this.histCounts) {
      const total = this.histCount.get(name) ?? 0;
      out += `# TYPE ${name} histogram\n`;
      Metrics.BUCKETS.forEach((b, i) => { out += `${name}_bucket{le="${b}"} ${counts[i] ?? 0}\n`; });
      out += `${name}_bucket{le="+Inf"} ${total}\n`;
      out += `${name}_sum ${this.histSum.get(name) ?? 0}\n`;
      out += `${name}_count ${total}\n`;
    }
    return out;
  }
}
