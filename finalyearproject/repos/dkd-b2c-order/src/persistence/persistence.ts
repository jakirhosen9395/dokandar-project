// DB abstraction + tx helper + repository base + migrations. The concrete driver (pg) is wired at
// the integration point. No business repositories.
export interface Tx { exec(sql: string, args?: unknown[]): Promise<void>; }
export interface Db {
  ping(): Promise<void>;
  withTx<T>(fn: (tx: Tx) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
export interface Migrator { apply(): Promise<void>; }

export abstract class RepositoryBase {
  constructor(protected readonly db: Db) {}
  protected inTx<T>(fn: (tx: Tx) => Promise<T>): Promise<T> { return this.db.withTx(fn); }
}
