package com.dokandar.review.data

import com.dokandar.review.Config
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import java.sql.Connection

// HikariCP pool. JDBC is blocking — callers run Db ops on Dispatchers.IO (the §16.1 coroutine trap).
object Db {
    lateinit var ds: HikariDataSource
    fun init() {
        val cfg = HikariConfig().apply {
            jdbcUrl = Config.pgUrl(); username = Config.pgUser; password = Config.pgPassword
            maximumPoolSize = 10; minimumIdle = 1; connectionTimeout = 10000
            connectionInitSql = "SET statement_timeout='5000ms'"
            poolName = "review-pg"
        }
        ds = HikariDataSource(cfg)
    }
    fun <T> tx(block: (Connection) -> T): T {
        ds.connection.use { c ->
            c.autoCommit = false
            try { val r = block(c); c.commit(); return r }
            catch (e: Exception) { try { c.rollback() } catch (_: Exception) {}; throw e }
            finally { c.autoCommit = true }
        }
    }
    fun <T> conn(block: (Connection) -> T): T = ds.connection.use { block(it) }
    fun ping() { ds.connection.use { it.createStatement().execute("SELECT 1") } }
}
