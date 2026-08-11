package com.dokandar.review.observability

// Tiny dependency-free JSON encoder for the log records + ops responses (preserves key order,
// emits literal UTF-8). Handles String/Number/Boolean/null/Map/List.
object Json {
    fun encode(v: Any?, indent: Int = 0, pretty: Boolean = false): String {
        val sb = StringBuilder(); write(sb, v, indent, pretty); return sb.toString()
    }
    private fun write(sb: StringBuilder, v: Any?, ind: Int, pretty: Boolean) {
        when (v) {
            null -> sb.append("null")
            is String -> str(sb, v)
            is Boolean, is Int, is Long, is Double, is Float -> sb.append(v.toString())
            is Number -> sb.append(v.toString())
            is Map<*, *> -> obj(sb, v, ind, pretty)
            is List<*> -> arr(sb, v, ind, pretty)
            else -> str(sb, v.toString())
        }
    }
    private fun obj(sb: StringBuilder, m: Map<*, *>, ind: Int, pretty: Boolean) {
        if (m.isEmpty()) { sb.append("{}"); return }
        sb.append("{")
        val ni = ind + 1; var first = true
        for ((k, value) in m) {
            if (!first) sb.append(","); first = false
            if (pretty) { sb.append("\n"); repeat(ni) { sb.append("  ") } }
            str(sb, k.toString()); sb.append(if (pretty) ": " else ":"); write(sb, value, ni, pretty)
        }
        if (pretty) { sb.append("\n"); repeat(ind) { sb.append("  ") } }
        sb.append("}")
    }
    private fun arr(sb: StringBuilder, l: List<*>, ind: Int, pretty: Boolean) {
        if (l.isEmpty()) { sb.append("[]"); return }
        sb.append("[")
        val ni = ind + 1; var first = true
        for (item in l) {
            if (!first) sb.append(","); first = false
            if (pretty) { sb.append("\n"); repeat(ni) { sb.append("  ") } }
            write(sb, item, ni, pretty)
        }
        if (pretty) { sb.append("\n"); repeat(ind) { sb.append("  ") } }
        sb.append("]")
    }
    private fun str(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) when (c) {
            '"' -> sb.append("\\\""); '\\' -> sb.append("\\\\"); '\n' -> sb.append("\\n")
            '\r' -> sb.append("\\r"); '\t' -> sb.append("\\t")
            else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
        }
        sb.append('"')
    }
}
