package com.dokandar.review.data

import com.dokandar.review.Config
import com.dokandar.review.observability.Log
import java.io.File
import java.sql.DriverManager
import java.sql.SQLException

// Self-bootstrap: validate db name → create-if-missing (catch 42P04) → apply migrations — before bind.
object DbBootstrap {
    fun ensure() {
        require(Config.pgDb.matches(Regex("^[A-Za-z_][A-Za-z0-9_]*$"))) { "refusing unsafe db name: ${Config.pgDb}" }
        DriverManager.getConnection(Config.pgUrl("postgres"), Config.pgUser, Config.pgPassword).use { admin ->
            val rs = admin.prepareStatement("SELECT 1 FROM pg_database WHERE datname=?").apply { setString(1, Config.pgDb) }.executeQuery()
            if (!rs.next()) {
                try { admin.createStatement().execute("CREATE DATABASE \"${Config.pgDb}\""); Log.info("review.boot", "created database ${Config.pgDb}") }
                catch (e: SQLException) { if (e.sqlState != "42P04") throw e }
            }
        }
        DriverManager.getConnection(Config.pgUrl(), Config.pgUser, Config.pgPassword).use { c ->
            val dir = listOf("migrations", "/app/migrations").map { File(it) }.firstOrNull { it.isDirectory }
                ?: throw IllegalStateException("migrations dir not found")
            (dir.listFiles { f -> f.name.endsWith(".sql") } ?: emptyArray()).sortedBy { it.name }.forEach { f ->
                c.createStatement().execute(f.readText())
            }
            Log.info("review.boot", "migrations applied; schema ready")
        }
    }
}
