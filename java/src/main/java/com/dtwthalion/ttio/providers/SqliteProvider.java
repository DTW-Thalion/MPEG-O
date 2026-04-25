/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.providers;

import com.dtwthalion.ttio.Enums.Compression;
import com.dtwthalion.ttio.Enums.Precision;

import java.io.File;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.sql.*;
import java.util.*;

/**
 * SQLite-backed storage provider for TTI-O.
 *
 * <p>Each TTI-O file is a single {@code .tio.sqlite} SQLite database.
 * Groups and datasets are rows in relational tables; primitive dataset
 * data is stored as little-endian BLOBs; compound datasets are stored as
 * JSON arrays of row-maps.</p>
 *
 * <p>Schema version: 1<br>
 * Provider identifier: ttio.providers.sqlite</p>
 *
 * <p>Cross-language compatible: a file written by the Python SqliteProvider
 * is readable by this class, and vice versa (same schema DDL, same BLOB
 * byte order, same JSON compound encoding).</p>
 *
 * <p><b>API status:</b> Provisional (stress-test — not for production use yet).</p>
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.providers.sqlite.SqliteProvider}</li>
 * </ul>
 *
 * @since 0.6
 */
public final class SqliteProvider implements StorageProvider {

    // ── Schema DDL — byte-identical to Python sqlite.py ─────────────────

    private static final String SCHEMA_DDL =
        "CREATE TABLE IF NOT EXISTS groups (" +
        "  id          INTEGER PRIMARY KEY AUTOINCREMENT," +
        "  parent_id   INTEGER REFERENCES groups(id) ON DELETE CASCADE," +
        "  name        TEXT NOT NULL," +
        "  UNIQUE(parent_id, name)" +
        ");" +
        "CREATE TABLE IF NOT EXISTS datasets (" +
        "  id               INTEGER PRIMARY KEY AUTOINCREMENT," +
        "  group_id         INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE," +
        "  name             TEXT NOT NULL," +
        "  kind             TEXT NOT NULL CHECK(kind IN ('primitive','compound'))," +
        "  precision        TEXT," +
        "  shape_json       TEXT NOT NULL," +
        "  data             BLOB," +
        "  compound_fields  TEXT," +
        "  compound_rows    TEXT," +
        "  UNIQUE(group_id, name)" +
        ");" +
        "CREATE TABLE IF NOT EXISTS group_attributes (" +
        "  group_id    INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE," +
        "  name        TEXT NOT NULL," +
        "  value_type  TEXT NOT NULL CHECK(value_type IN ('string','int','float'))," +
        "  value       TEXT NOT NULL," +
        "  PRIMARY KEY (group_id, name)" +
        ");" +
        "CREATE TABLE IF NOT EXISTS dataset_attributes (" +
        "  dataset_id  INTEGER NOT NULL REFERENCES datasets(id) ON DELETE CASCADE," +
        "  name        TEXT NOT NULL," +
        "  value_type  TEXT NOT NULL CHECK(value_type IN ('string','int','float'))," +
        "  value       TEXT NOT NULL," +
        "  PRIMARY KEY (dataset_id, name)" +
        ");" +
        "CREATE TABLE IF NOT EXISTS meta (" +
        "  key    TEXT PRIMARY KEY," +
        "  value  TEXT NOT NULL" +
        ");" +
        "CREATE INDEX IF NOT EXISTS idx_datasets_group ON datasets(group_id);" +
        "CREATE INDEX IF NOT EXISTS idx_ga_group ON group_attributes(group_id);" +
        "CREATE INDEX IF NOT EXISTS idx_da_dataset ON dataset_attributes(dataset_id);";

    // ─────────────────────────────────────────────────────────────────────

    private Connection conn;
    private String path;
    private boolean readOnly;
    // When true, mutating ops skip their per-call conn.commit() — the
    // caller has opened an explicit batch via beginTransaction(). Flipped
    // back off by commitTransaction() / rollbackTransaction().
    private boolean batchMode;

    /** No-arg constructor for ServiceLoader. */
    public SqliteProvider() {}

    /** Commit after a mutating op unless we're inside an explicit batch. */
    void maybeCommit() throws SQLException {
        if (!batchMode) conn.commit();
    }

    // ── StorageProvider ──────────────────────────────────────────────────

    @Override
    public String providerName() { return "sqlite"; }

    @Override
    public boolean supportsUrl(String pathOrUrl) {
        if (pathOrUrl.startsWith("sqlite://")) return true;
        String lower = pathOrUrl.toLowerCase(Locale.ROOT);
        return lower.endsWith(".tio.sqlite") || lower.endsWith(".sqlite");
    }

    @Override
    public StorageProvider open(String pathOrUrl, Mode mode) {
        if (conn != null) throw new IllegalStateException("provider already open");
        String resolved = resolvePath(pathOrUrl);
        try {
            doOpen(resolved, mode);
        } catch (SQLException e) {
            throw new RuntimeException("Failed to open SQLite store: " + resolved, e);
        }
        return this;
    }

    @Override
    public StorageGroup rootGroup() {
        requireOpen();
        try {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT id FROM groups WHERE parent_id IS NULL AND name = '/'")) {
                ResultSet rs = ps.executeQuery();
                if (!rs.next()) throw new RuntimeException("root group '/' missing");
                long rootId = rs.getLong(1);
                return new SqliteGroup(this, rootId, "/", readOnly);
            }
        } catch (SQLException e) {
            throw new RuntimeException("Failed to fetch root group", e);
        }
    }

    @Override
    public boolean isOpen() { return conn != null; }

    @Override
    public Object nativeHandle() { return conn; }

    @Override
    public void close() {
        if (conn != null) {
            // Flush any batch the caller opened but never committed, so the
            // SQLite driver's close-time rollback doesn't drop their writes.
            try { conn.commit(); } catch (SQLException ignored) {}
            try { conn.close(); } catch (SQLException ignored) {}
            conn = null;
            batchMode = false;
        }
    }

    // ── Transactions (Appendix B Gap 11) ──────────────────────────────────

    /** Opens an explicit batch: subsequent mutating ops suppress their
     *  per-call commits until {@link #commitTransaction()} flushes them
     *  as a single SQLite transaction. */
    @Override
    public void beginTransaction() {
        batchMode = true;
    }

    @Override
    public void commitTransaction() {
        if (conn == null) throw new IllegalStateException("provider not open");
        try { conn.commit(); } catch (SQLException e) {
            throw new RuntimeException("commit failed: " + e.getMessage(), e);
        }
        batchMode = false;
    }

    @Override
    public void rollbackTransaction() {
        if (conn == null) throw new IllegalStateException("provider not open");
        try { conn.rollback(); } catch (SQLException e) {
            throw new RuntimeException("rollback failed: " + e.getMessage(), e);
        }
        batchMode = false;
    }

    // ── Internal open logic ──────────────────────────────────────────────

    private void doOpen(String filePath, Mode mode) throws SQLException {
        this.readOnly = (mode == Mode.READ);
        switch (mode) {
            case READ -> {
                if (!new File(filePath).exists()) {
                    throw new RuntimeException(
                        "SQLite file not found (mode=READ): " + filePath);
                }
                conn = DriverManager.getConnection("jdbc:sqlite:" + filePath);
                applyPragmas();
            }
            case READ_WRITE -> {
                if (!new File(filePath).exists()) {
                    throw new RuntimeException(
                        "SQLite file not found (mode=READ_WRITE): " + filePath);
                }
                conn = DriverManager.getConnection("jdbc:sqlite:" + filePath);
                applyPragmas();
                initDb();
            }
            case CREATE -> {
                File f = new File(filePath);
                if (f.exists()) f.delete();
                conn = DriverManager.getConnection("jdbc:sqlite:" + filePath);
                applyPragmas();
                initDb();
            }
            case APPEND -> {
                conn = DriverManager.getConnection("jdbc:sqlite:" + filePath);
                applyPragmas();
                initDb();
            }
        }
        // Switch to manual transaction mode for consistent commit/rollback semantics.
        conn.setAutoCommit(false);
        this.path = filePath;
    }

    private void applyPragmas() throws SQLException {
        // Must be called while still in auto-commit mode (journal_mode=WAL requires it).
        try (Statement st = conn.createStatement()) {
            st.execute("PRAGMA foreign_keys = ON");
            st.execute("PRAGMA journal_mode = WAL");
            st.execute("PRAGMA synchronous = NORMAL");
        }
    }

    private void initDb() throws SQLException {
        // Execute DDL statements one by one in auto-commit mode (no explicit transaction).
        try (Statement st = conn.createStatement()) {
            for (String stmt : SCHEMA_DDL.split(";")) {
                String trimmed = stmt.trim();
                if (!trimmed.isEmpty()) {
                    st.execute(trimmed);
                }
            }
        }
        // Meta inserts
        try (PreparedStatement ps = conn.prepareStatement(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")) {
            ps.setString(1, "schema_version"); ps.setString(2, "1"); ps.executeUpdate();
            ps.setString(1, "provider"); ps.setString(2, "ttio.providers.sqlite");
            ps.executeUpdate();
        }
        // Root group
        try (PreparedStatement ps = conn.prepareStatement(
                "INSERT OR IGNORE INTO groups (parent_id, name) VALUES (NULL, '/')")) {
            ps.executeUpdate();
        }
        // All DDL ran in auto-commit mode; no explicit commit needed here.
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private void requireOpen() {
        if (conn == null) throw new IllegalStateException("provider is not open");
    }

    private static String resolvePath(String pathOrUrl) {
        if (pathOrUrl.startsWith("sqlite://")) {
            return pathOrUrl.substring("sqlite://".length());
        }
        return pathOrUrl;
    }

    @Override
    public String toString() {
        return "SqliteProvider(" + (path != null ? "path=" + path : "closed") + ")";
    }

    // ── Attribute encoding (matches Python _encode_attr / _decode_attr) ──

    static String[] encodeAttr(Object value) {
        if (value instanceof Boolean b) {
            return new String[]{"int", b ? "1" : "0"};
        }
        if (value instanceof Integer i) {
            return new String[]{"int", Long.toString(i.longValue())};
        }
        if (value instanceof Long l) {
            return new String[]{"int", Long.toString(l)};
        }
        if (value instanceof Double d) {
            return new String[]{"float", Double.toString(d)};
        }
        if (value instanceof Float f) {
            return new String[]{"float", Double.toString(f.doubleValue())};
        }
        return new String[]{"string", String.valueOf(value)};
    }

    static Object decodeAttr(String valueType, String value) {
        return switch (valueType) {
            case "int" -> Long.parseLong(value);
            case "float" -> Double.parseDouble(value);
            default -> value;
        };
    }

    // ── Blob packing (little-endian, matches Python numpy dtype layout) ──

    static byte[] packPrimitive(Object data, Precision precision) {
        // Flatten to element count
        int n = arrayLength(data);
        int elemSize = precision.elementSize();
        ByteBuffer buf = ByteBuffer.allocate(n * elemSize).order(ByteOrder.LITTLE_ENDIAN);
        switch (precision) {
            case FLOAT32 -> {
                float[] arr = toFloatArray(data);
                for (float v : arr) buf.putFloat(v);
            }
            case FLOAT64 -> {
                double[] arr = toDoubleArray(data);
                for (double v : arr) buf.putDouble(v);
            }
            case INT32 -> {
                int[] arr = toIntArray(data);
                for (int v : arr) buf.putInt(v);
            }
            case UINT32 -> {
                // UINT32 — stored as 4-byte little-endian unsigned bits.
                // Java int bit-pattern == Python numpy uint32 bit-pattern.
                int[] arr = toIntArray(data);
                for (int v : arr) buf.putInt(v);
            }
            case INT64 -> {
                long[] arr = toLongArray(data);
                for (long v : arr) buf.putLong(v);
            }
            case COMPLEX128 -> {
                // Interleaved real+imag doubles. Data arrives as double[] of length 2N.
                double[] arr = toDoubleArray(data);
                for (double v : arr) buf.putDouble(v);
            }
            case UINT8 -> {
                // v0.11 M79: raw bytes — genomic base/quality channels.
                byte[] arr = toByteArray(data);
                buf.put(arr);
            }
        }
        return buf.array();
    }

    static Object unpackPrimitive(byte[] blob, Precision precision, long[] shape) {
        ByteBuffer buf = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN);
        int elemSize = precision.elementSize();
        int n = blob.length / elemSize;
        return switch (precision) {
            case FLOAT32 -> {
                float[] arr = new float[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getFloat();
                yield arr;
            }
            case FLOAT64 -> {
                double[] arr = new double[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getDouble();
                yield arr;
            }
            case INT32 -> {
                int[] arr = new int[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getInt();
                yield arr;
            }
            case UINT32 -> {
                // Python reads as uint32, Java keeps raw int bits — same bytes.
                int[] arr = new int[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getInt();
                yield arr;
            }
            case INT64 -> {
                long[] arr = new long[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getLong();
                yield arr;
            }
            case COMPLEX128 -> {
                // Interleaved real+imag doubles, returned as double[] of length 2N.
                double[] arr = new double[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getDouble();
                yield arr;
            }
            case UINT8 -> {
                // v0.11 M79: raw byte channel.
                byte[] arr = new byte[n];
                buf.get(arr);
                yield arr;
            }
        };
    }

    // ── JSON helpers (minimal — no Jackson dependency needed) ────────────

    /**
     * Serialize a list of Map&lt;String,Object&gt; to JSON array of objects.
     * Values must be String, Number, or null.
     */
    static String rowsToJson(List<Map<String, Object>> rows) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < rows.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append("{");
            Map<String, Object> row = rows.get(i);
            boolean first = true;
            for (Map.Entry<String, Object> e : row.entrySet()) {
                if (!first) sb.append(",");
                first = false;
                sb.append(jsonString(e.getKey()));
                sb.append(":");
                sb.append(jsonValue(e.getValue()));
            }
            sb.append("}");
        }
        sb.append("]");
        return sb.toString();
    }

    static String fieldsToJson(List<CompoundField> fields) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < fields.size(); i++) {
            if (i > 0) sb.append(",");
            CompoundField f = fields.get(i);
            sb.append("{\"name\":").append(jsonString(f.name()))
              .append(",\"kind\":").append(jsonString(fieldKindValue(f.kind())))
              .append("}");
        }
        sb.append("]");
        return sb.toString();
    }

    static List<CompoundField> fieldsFromJson(String json) {
        // Parse [{\"name\":\"x\",\"kind\":\"vl_string\"}, ...]
        List<CompoundField> result = new ArrayList<>();
        // Simple hand-parser for the known structure.
        json = json.trim();
        if (json.equals("[]")) return result;
        // Strip outer brackets
        json = json.substring(1, json.length() - 1).trim();
        // Split on "},{" — safe since field values don't contain objects/arrays.
        String[] objects = splitJsonObjects(json);
        for (String obj : objects) {
            String name = extractJsonString(obj, "name");
            String kind = extractJsonString(obj, "kind");
            result.add(new CompoundField(name, fieldKindFromValue(kind)));
        }
        return result;
    }

    static List<Map<String, Object>> rowsFromJson(String json) {
        List<Map<String, Object>> result = new ArrayList<>();
        json = json.trim();
        if (json.equals("[]")) return result;
        json = json.substring(1, json.length() - 1).trim();
        String[] objects = splitJsonObjects(json);
        for (String obj : objects) {
            result.add(parseJsonObject(obj));
        }
        return result;
    }

    static long[] shapeFromJson(String json) {
        json = json.trim();
        if (json.equals("[]")) return new long[0];
        json = json.substring(1, json.length() - 1).trim();
        if (json.isEmpty()) return new long[0];
        String[] parts = json.split(",");
        long[] shape = new long[parts.length];
        for (int i = 0; i < parts.length; i++) {
            shape[i] = Long.parseLong(parts[i].trim());
        }
        return shape;
    }

    static String shapeToJson(long[] shape) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < shape.length; i++) {
            if (i > 0) sb.append(",");
            sb.append(shape[i]);
        }
        sb.append("]");
        return sb.toString();
    }

    // ── Minimal JSON helpers ─────────────────────────────────────────────

    private static String jsonString(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    private static String jsonValue(Object v) {
        if (v == null) return "null";
        if (v instanceof String s) return jsonString(s);
        if (v instanceof Boolean b) return b ? "true" : "false";
        // Numbers — emit as JSON number literal
        return v.toString();
    }

    private static String fieldKindValue(CompoundField.Kind kind) {
        return switch (kind) {
            case UINT32 -> "uint32";
            case INT64 -> "int64";
            case FLOAT64 -> "float64";
            case VL_STRING -> "vl_string";
            case VL_BYTES -> throw new UnsupportedOperationException(
                "SQLite provider does not yet support VL_BYTES compound "
                + "fields; use the HDF5 provider for opt_per_au_encryption");
        };
    }

    private static CompoundField.Kind fieldKindFromValue(String value) {
        return switch (value.toLowerCase(Locale.ROOT)) {
            case "uint32" -> CompoundField.Kind.UINT32;
            case "int64" -> CompoundField.Kind.INT64;
            case "float64" -> CompoundField.Kind.FLOAT64;
            case "vl_string" -> CompoundField.Kind.VL_STRING;
            default -> throw new IllegalArgumentException("Unknown CompoundFieldKind: " + value);
        };
    }

    /**
     * Split a JSON array body (no outer brackets) on top-level object boundaries.
     * Handles nested arrays/objects by tracking depth.
     */
    private static String[] splitJsonObjects(String body) {
        List<String> parts = new ArrayList<>();
        int depth = 0;
        int start = 0;
        boolean inString = false;
        boolean escape = false;
        for (int i = 0; i < body.length(); i++) {
            char c = body.charAt(i);
            if (escape) { escape = false; continue; }
            if (c == '\\' && inString) { escape = true; continue; }
            if (c == '"') { inString = !inString; continue; }
            if (inString) continue;
            if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') depth--;
            else if (c == ',' && depth == 0) {
                parts.add(body.substring(start, i).trim());
                start = i + 1;
            }
        }
        if (start < body.length()) parts.add(body.substring(start).trim());
        return parts.toArray(new String[0]);
    }

    private static String extractJsonString(String obj, String key) {
        String search = "\"" + key + "\":\"";
        int idx = obj.indexOf(search);
        if (idx < 0) return null;
        idx += search.length();
        StringBuilder sb = new StringBuilder();
        boolean escape = false;
        for (int i = idx; i < obj.length(); i++) {
            char c = obj.charAt(i);
            if (escape) { sb.append(c); escape = false; continue; }
            if (c == '\\') { escape = true; continue; }
            if (c == '"') break;
            sb.append(c);
        }
        return sb.toString();
    }

    /**
     * Parse a single JSON object (with braces) into Map&lt;String,Object&gt;.
     * Values can be strings, numbers (long/double), booleans, or null.
     */
    private static Map<String, Object> parseJsonObject(String obj) {
        Map<String, Object> map = new LinkedHashMap<>();
        obj = obj.trim();
        if (obj.startsWith("{")) obj = obj.substring(1);
        if (obj.endsWith("}")) obj = obj.substring(0, obj.length() - 1);
        obj = obj.trim();
        if (obj.isEmpty()) return map;
        // Split on top-level commas
        String[] pairs = splitJsonObjects(obj);
        for (String pair : pairs) {
            pair = pair.trim();
            if (pair.isEmpty()) continue;
            // Find key: "key":value
            if (!pair.startsWith("\"")) continue;
            int keyEnd = 1;
            boolean escape = false;
            while (keyEnd < pair.length()) {
                char c = pair.charAt(keyEnd);
                if (escape) { escape = false; keyEnd++; continue; }
                if (c == '\\') { escape = true; keyEnd++; continue; }
                if (c == '"') break;
                keyEnd++;
            }
            String key = pair.substring(1, keyEnd);
            // value starts after ":"
            int colonIdx = pair.indexOf(':', keyEnd + 1);
            if (colonIdx < 0) continue;
            String valStr = pair.substring(colonIdx + 1).trim();
            map.put(key, parseJsonScalar(valStr));
        }
        return map;
    }

    private static Object parseJsonScalar(String s) {
        if (s.equals("null")) return null;
        if (s.equals("true")) return true;
        if (s.equals("false")) return false;
        if (s.startsWith("\"")) {
            // String value
            StringBuilder sb = new StringBuilder();
            boolean escape = false;
            for (int i = 1; i < s.length(); i++) {
                char c = s.charAt(i);
                if (escape) {
                    switch (c) {
                        case 'n' -> sb.append('\n');
                        case 't' -> sb.append('\t');
                        case 'r' -> sb.append('\r');
                        default -> sb.append(c);
                    }
                    escape = false;
                    continue;
                }
                if (c == '\\') { escape = true; continue; }
                if (c == '"') break;
                sb.append(c);
            }
            return sb.toString();
        }
        // Number
        if (s.contains(".") || s.contains("e") || s.contains("E")) {
            try { return Double.parseDouble(s); } catch (NumberFormatException ignored) {}
        }
        try { return Long.parseLong(s); } catch (NumberFormatException ignored) {}
        try { return Double.parseDouble(s); } catch (NumberFormatException ignored) {}
        return s;
    }

    // ── Array type coercions ─────────────────────────────────────────────

    private static int arrayLength(Object data) {
        if (data instanceof double[] a) return a.length;
        if (data instanceof float[] a) return a.length;
        if (data instanceof int[] a) return a.length;
        if (data instanceof long[] a) return a.length;
        if (data instanceof byte[] a) return a.length;
        if (data instanceof Object[] a) return a.length;
        throw new IllegalArgumentException("Cannot determine array length for: " + data.getClass());
    }

    private static double[] toDoubleArray(Object data) {
        if (data instanceof double[] a) return a;
        if (data instanceof float[] a) { double[] r = new double[a.length]; for (int i=0;i<a.length;i++) r[i]=a[i]; return r; }
        if (data instanceof int[] a)   { double[] r = new double[a.length]; for (int i=0;i<a.length;i++) r[i]=a[i]; return r; }
        if (data instanceof long[] a)  { double[] r = new double[a.length]; for (int i=0;i<a.length;i++) r[i]=a[i]; return r; }
        throw new IllegalArgumentException("Cannot convert to double[]: " + data.getClass());
    }

    private static float[] toFloatArray(Object data) {
        if (data instanceof float[] a) return a;
        if (data instanceof double[] a) { float[] r = new float[a.length]; for (int i=0;i<a.length;i++) r[i]=(float)a[i]; return r; }
        throw new IllegalArgumentException("Cannot convert to float[]: " + data.getClass());
    }

    private static int[] toIntArray(Object data) {
        if (data instanceof int[] a) return a;
        if (data instanceof long[] a) { int[] r = new int[a.length]; for (int i=0;i<a.length;i++) r[i]=(int)a[i]; return r; }
        throw new IllegalArgumentException("Cannot convert to int[]: " + data.getClass());
    }

    private static long[] toLongArray(Object data) {
        if (data instanceof long[] a) return a;
        if (data instanceof int[] a) { long[] r = new long[a.length]; for (int i=0;i<a.length;i++) r[i]=a[i]; return r; }
        throw new IllegalArgumentException("Cannot convert to long[]: " + data.getClass());
    }

    private static byte[] toByteArray(Object data) {
        if (data instanceof byte[] a) return a;
        throw new IllegalArgumentException("Cannot convert to byte[]: " + data.getClass());
    }

    // ════════════════════════════════════════════════════════════════════
    // SqliteGroup
    // ════════════════════════════════════════════════════════════════════

    /**
     * A row in the {@code groups} table, exposed as a StorageGroup.
     */
    static final class SqliteGroup implements StorageGroup {

        private final SqliteProvider provider;
        private final Connection conn;
        private final long groupId;
        private final String groupName;
        private final boolean readOnly;

        SqliteGroup(SqliteProvider provider, long groupId, String name, boolean readOnly) {
            this.provider = provider;
            this.conn = provider.conn;
            this.groupId = groupId;
            this.groupName = name;
            this.readOnly = readOnly;
        }

        @Override public String name() { return groupName; }

        // ── Children ────────────────────────────────────────────────────

        @Override
        public List<String> childNames() {
            List<String> names = new ArrayList<>();
            try {
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT name FROM groups WHERE parent_id = ? ORDER BY name")) {
                    ps.setLong(1, groupId);
                    ResultSet rs = ps.executeQuery();
                    while (rs.next()) names.add(rs.getString(1));
                }
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT name FROM datasets WHERE group_id = ? ORDER BY name")) {
                    ps.setLong(1, groupId);
                    ResultSet rs = ps.executeQuery();
                    while (rs.next()) names.add(rs.getString(1));
                }
            } catch (SQLException e) {
                throw new RuntimeException("childNames failed", e);
            }
            return names;
        }

        @Override
        public boolean hasChild(String name) {
            try {
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT 1 FROM groups WHERE parent_id = ? AND name = ?")) {
                    ps.setLong(1, groupId); ps.setString(2, name);
                    if (ps.executeQuery().next()) return true;
                }
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT 1 FROM datasets WHERE group_id = ? AND name = ?")) {
                    ps.setLong(1, groupId); ps.setString(2, name);
                    return ps.executeQuery().next();
                }
            } catch (SQLException e) {
                throw new RuntimeException("hasChild failed", e);
            }
        }

        @Override
        public StorageGroup openGroup(String name) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT id FROM groups WHERE parent_id = ? AND name = ?")) {
                ps.setLong(1, groupId); ps.setString(2, name);
                ResultSet rs = ps.executeQuery();
                if (!rs.next()) throw new NoSuchElementException(
                        "group '" + name + "' not found in '" + groupName + "'");
                return new SqliteGroup(provider, rs.getLong(1), name, readOnly);
            } catch (SQLException e) {
                throw new RuntimeException("openGroup failed", e);
            }
        }

        @Override
        public StorageGroup createGroup(String name) {
            requireWritable();
            if (hasChild(name)) throw new IllegalArgumentException(
                    "'" + name + "' already exists in '" + groupName + "'");
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO groups (parent_id, name) VALUES (?, ?)",
                    Statement.RETURN_GENERATED_KEYS)) {
                ps.setLong(1, groupId); ps.setString(2, name);
                ps.executeUpdate();
                provider.maybeCommit();
                ResultSet keys = ps.getGeneratedKeys();
                keys.next();
                return new SqliteGroup(provider, keys.getLong(1), name, readOnly);
            } catch (SQLException e) {
                throw new RuntimeException("createGroup failed", e);
            }
        }

        @Override
        public void deleteChild(String name) {
            requireWritable();
            try {
                // Try group first
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT id FROM groups WHERE parent_id = ? AND name = ?")) {
                    ps.setLong(1, groupId); ps.setString(2, name);
                    ResultSet rs = ps.executeQuery();
                    if (rs.next()) {
                        long id = rs.getLong(1);
                        try (PreparedStatement del = conn.prepareStatement(
                                "DELETE FROM groups WHERE id = ?")) {
                            del.setLong(1, id); del.executeUpdate();
                        }
                        provider.maybeCommit();
                        return;
                    }
                }
                // Try dataset
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT id FROM datasets WHERE group_id = ? AND name = ?")) {
                    ps.setLong(1, groupId); ps.setString(2, name);
                    ResultSet rs = ps.executeQuery();
                    if (rs.next()) {
                        long id = rs.getLong(1);
                        try (PreparedStatement del = conn.prepareStatement(
                                "DELETE FROM datasets WHERE id = ?")) {
                            del.setLong(1, id); del.executeUpdate();
                        }
                        provider.maybeCommit();
                    }
                }
            } catch (SQLException e) {
                throw new RuntimeException("deleteChild failed", e);
            }
        }

        // ── Datasets ────────────────────────────────────────────────────

        @Override
        public StorageDataset openDataset(String name) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT id, kind, precision, shape_json, compound_fields " +
                    "FROM datasets WHERE group_id = ? AND name = ?")) {
                ps.setLong(1, groupId); ps.setString(2, name);
                ResultSet rs = ps.executeQuery();
                if (!rs.next()) throw new NoSuchElementException(
                        "dataset '" + name + "' not found in '" + groupName + "'");
                long dsId = rs.getLong(1);
                String kind = rs.getString(2);
                String precName = rs.getString(3);
                String shapeJson = rs.getString(4);
                String fieldsJson = rs.getString(5);
                Precision prec = precName != null ? Precision.valueOf(precName) : null;
                long[] shape = shapeFromJson(shapeJson);
                List<CompoundField> fields = fieldsJson != null ? fieldsFromJson(fieldsJson) : null;
                return new SqliteDataset(provider, dsId, name, prec, shape, fields, readOnly);
            } catch (SQLException e) {
                throw new RuntimeException("openDataset failed", e);
            }
        }

        @Override
        public StorageDataset createDataset(String name, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel) {
            requireWritable();
            if (hasChild(name)) throw new IllegalArgumentException(
                    "'" + name + "' already exists in '" + groupName + "'");
            String shapeJson = "[" + length + "]";
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO datasets (group_id, name, kind, precision, shape_json, data) " +
                    "VALUES (?, ?, 'primitive', ?, ?, NULL)",
                    Statement.RETURN_GENERATED_KEYS)) {
                ps.setLong(1, groupId);
                ps.setString(2, name);
                ps.setString(3, precision.name());
                ps.setString(4, shapeJson);
                ps.executeUpdate();
                provider.maybeCommit();
                ResultSet keys = ps.getGeneratedKeys();
                keys.next();
                long dsId = keys.getLong(1);
                return new SqliteDataset(provider, dsId, name, precision,
                        new long[]{length}, null, readOnly);
            } catch (SQLException e) {
                throw new RuntimeException("createDataset failed", e);
            }
        }

        @Override
        public StorageDataset createDatasetND(String name, Precision precision,
                                               long[] shape, long[] chunks,
                                               Compression compression,
                                               int compressionLevel) {
            if (shape != null && shape.length == 1) {
                return createDataset(name, precision, shape[0],
                        chunks != null && chunks.length > 0 ? (int) chunks[0] : 0,
                        compression, compressionLevel);
            }
            requireWritable();
            if (hasChild(name)) throw new IllegalArgumentException(
                    "'" + name + "' already exists in '" + groupName + "'");
            String shapeJson = shapeToJson(shape);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO datasets (group_id, name, kind, precision, shape_json, data) " +
                    "VALUES (?, ?, 'primitive', ?, ?, NULL)",
                    Statement.RETURN_GENERATED_KEYS)) {
                ps.setLong(1, groupId);
                ps.setString(2, name);
                ps.setString(3, precision.name());
                ps.setString(4, shapeJson);
                ps.executeUpdate();
                provider.maybeCommit();
                ResultSet keys = ps.getGeneratedKeys();
                keys.next();
                long dsId = keys.getLong(1);
                return new SqliteDataset(provider, dsId, name, precision,
                        shape.clone(), null, readOnly);
            } catch (SQLException e) {
                throw new RuntimeException("createDatasetND failed", e);
            }
        }

        @Override
        public StorageDataset createCompoundDataset(String name,
                                                     List<CompoundField> fields,
                                                     long count) {
            requireWritable();
            if (hasChild(name)) throw new IllegalArgumentException(
                    "'" + name + "' already exists in '" + groupName + "'");
            String fieldsJson = fieldsToJson(fields);
            String shapeJson = "[" + count + "]";
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO datasets (group_id, name, kind, precision, shape_json, " +
                    "compound_fields, compound_rows) VALUES (?, ?, 'compound', NULL, ?, ?, '[]')",
                    Statement.RETURN_GENERATED_KEYS)) {
                ps.setLong(1, groupId);
                ps.setString(2, name);
                ps.setString(3, shapeJson);
                ps.setString(4, fieldsJson);
                ps.executeUpdate();
                provider.maybeCommit();
                ResultSet keys = ps.getGeneratedKeys();
                keys.next();
                long dsId = keys.getLong(1);
                return new SqliteDataset(provider, dsId, name, null,
                        new long[]{count}, List.copyOf(fields), readOnly);
            } catch (SQLException e) {
                throw new RuntimeException("createCompoundDataset failed", e);
            }
        }

        // ── Attributes ──────────────────────────────────────────────────

        @Override
        public boolean hasAttribute(String name) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT 1 FROM group_attributes WHERE group_id = ? AND name = ?")) {
                ps.setLong(1, groupId); ps.setString(2, name);
                return ps.executeQuery().next();
            } catch (SQLException e) {
                throw new RuntimeException("hasAttribute failed", e);
            }
        }

        @Override
        public Object getAttribute(String name) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT value_type, value FROM group_attributes " +
                    "WHERE group_id = ? AND name = ?")) {
                ps.setLong(1, groupId); ps.setString(2, name);
                ResultSet rs = ps.executeQuery();
                if (!rs.next()) throw new NoSuchElementException(
                        "attribute '" + name + "' not found on group '" + groupName + "'");
                return decodeAttr(rs.getString(1), rs.getString(2));
            } catch (SQLException e) {
                throw new RuntimeException("getAttribute failed", e);
            }
        }

        @Override
        public void setAttribute(String name, Object value) {
            requireWritable();
            String[] enc = encodeAttr(value);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT OR REPLACE INTO group_attributes " +
                    "(group_id, name, value_type, value) VALUES (?, ?, ?, ?)")) {
                ps.setLong(1, groupId);
                ps.setString(2, name);
                ps.setString(3, enc[0]);
                ps.setString(4, enc[1]);
                ps.executeUpdate();
                provider.maybeCommit();
            } catch (SQLException e) {
                throw new RuntimeException("setAttribute failed", e);
            }
        }

        @Override
        public void deleteAttribute(String name) {
            requireWritable();
            try (PreparedStatement ps = conn.prepareStatement(
                    "DELETE FROM group_attributes WHERE group_id = ? AND name = ?")) {
                ps.setLong(1, groupId); ps.setString(2, name);
                ps.executeUpdate();
                provider.maybeCommit();
            } catch (SQLException e) {
                throw new RuntimeException("deleteAttribute failed", e);
            }
        }

        @Override
        public List<String> attributeNames() {
            List<String> names = new ArrayList<>();
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT name FROM group_attributes WHERE group_id = ? ORDER BY name")) {
                ps.setLong(1, groupId);
                ResultSet rs = ps.executeQuery();
                while (rs.next()) names.add(rs.getString(1));
            } catch (SQLException e) {
                throw new RuntimeException("attributeNames failed", e);
            }
            return names;
        }

        private void requireWritable() {
            if (readOnly) throw new UnsupportedOperationException(
                    "provider opened in read-only mode");
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // SqliteDataset
    // ════════════════════════════════════════════════════════════════════

    /**
     * A row in the {@code datasets} table, exposed as a StorageDataset.
     */
    static final class SqliteDataset implements StorageDataset {

        private final SqliteProvider provider;
        private final Connection conn;
        private final long datasetId;
        private final String dsName;
        private final Precision precision;
        private long[] shape;
        private final List<CompoundField> fields;
        private final boolean readOnly;

        SqliteDataset(SqliteProvider provider, long datasetId, String name,
                       Precision precision, long[] shape,
                       List<CompoundField> fields, boolean readOnly) {
            this.provider = provider;
            this.conn = provider.conn;
            this.datasetId = datasetId;
            this.dsName = name;
            this.precision = precision;
            this.shape = shape;
            this.fields = fields;
            this.readOnly = readOnly;
        }

        @Override public String name() { return dsName; }
        @Override public Precision precision() { return precision; }
        @Override public long[] shape() { return shape.clone(); }
        @Override public List<CompoundField> compoundFields() { return fields; }

        // ── Read ────────────────────────────────────────────────────────

        @Override
        public Object readAll() {
            return readSlice(0, -1);
        }

        @SuppressWarnings("unchecked")
        @Override
        public Object readSlice(long offset, long count) {
            if (fields != null) {
                // Compound
                try (PreparedStatement ps = conn.prepareStatement(
                        "SELECT compound_rows FROM datasets WHERE id = ?")) {
                    ps.setLong(1, datasetId);
                    ResultSet rs = ps.executeQuery();
                    if (!rs.next()) return Collections.emptyList();
                    String json = rs.getString(1);
                    List<Map<String, Object>> rows = (json == null || json.isEmpty())
                            ? Collections.emptyList() : rowsFromJson(json);
                    if (count < 0) {
                        return offset == 0 ? rows : new ArrayList<>(rows.subList((int) offset, rows.size()));
                    }
                    int from = (int) offset;
                    int to = (int) Math.min(rows.size(), offset + count);
                    return new ArrayList<>(rows.subList(from, to));
                } catch (SQLException e) {
                    throw new RuntimeException("readSlice (compound) failed", e);
                }
            }
            // Primitive
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT data FROM datasets WHERE id = ?")) {
                ps.setLong(1, datasetId);
                ResultSet rs = ps.executeQuery();
                if (!rs.next()) return emptyArray();
                byte[] blob = rs.getBytes(1);
                if (blob == null) return emptyArray();
                Object arr = unpackPrimitive(blob, precision, shape);
                if (count < 0 && offset == 0) return arr;
                return slicePrimitive(arr, (int) offset,
                        count < 0 ? arrayLength(arr) - (int) offset : (int) count);
            } catch (SQLException e) {
                throw new RuntimeException("readSlice (primitive) failed", e);
            }
        }

        // ── Write ───────────────────────────────────────────────────────

        @Override
        public void writeAll(Object data) {
            requireWritable();
            if (fields != null) {
                @SuppressWarnings("unchecked")
                List<Map<String, Object>> rows = (List<Map<String, Object>>) data;
                String json = rowsToJson(rows);
                try (PreparedStatement ps = conn.prepareStatement(
                        "UPDATE datasets SET compound_rows = ? WHERE id = ?")) {
                    ps.setString(1, json); ps.setLong(2, datasetId);
                    ps.executeUpdate();
                    provider.maybeCommit();
                } catch (SQLException e) {
                    throw new RuntimeException("writeAll (compound) failed", e);
                }
            } else {
                byte[] blob = packPrimitive(data, precision);
                // For 1-D datasets, allow the shape to update to match what was written.
                // For N-D datasets, preserve the original shape (Python does the same via
                // arr.shape on the reshaped ndarray).
                String newShapeJson;
                long[] newShape;
                if (shape != null && shape.length == 1) {
                    long newLen = blob.length / precision.elementSize();
                    newShapeJson = "[" + newLen + "]";
                    newShape = new long[]{newLen};
                } else {
                    // Keep existing shape
                    newShapeJson = shapeToJson(shape);
                    newShape = shape;
                }
                try (PreparedStatement ps = conn.prepareStatement(
                        "UPDATE datasets SET data = ?, shape_json = ? WHERE id = ?")) {
                    ps.setBytes(1, blob);
                    ps.setString(2, newShapeJson);
                    ps.setLong(3, datasetId);
                    ps.executeUpdate();
                    provider.maybeCommit();
                    shape = newShape;
                } catch (SQLException e) {
                    throw new RuntimeException("writeAll (primitive) failed", e);
                }
            }
        }

        // ── Attributes ──────────────────────────────────────────────────

        @Override
        public boolean hasAttribute(String name) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT 1 FROM dataset_attributes WHERE dataset_id = ? AND name = ?")) {
                ps.setLong(1, datasetId); ps.setString(2, name);
                return ps.executeQuery().next();
            } catch (SQLException e) {
                throw new RuntimeException("hasAttribute failed", e);
            }
        }

        @Override
        public Object getAttribute(String name) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT value_type, value FROM dataset_attributes " +
                    "WHERE dataset_id = ? AND name = ?")) {
                ps.setLong(1, datasetId); ps.setString(2, name);
                ResultSet rs = ps.executeQuery();
                if (!rs.next()) throw new NoSuchElementException(
                        "attribute '" + name + "' not found on dataset '" + dsName + "'");
                return decodeAttr(rs.getString(1), rs.getString(2));
            } catch (SQLException e) {
                throw new RuntimeException("getAttribute failed", e);
            }
        }

        @Override
        public void setAttribute(String name, Object value) {
            requireWritable();
            String[] enc = encodeAttr(value);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT OR REPLACE INTO dataset_attributes " +
                    "(dataset_id, name, value_type, value) VALUES (?, ?, ?, ?)")) {
                ps.setLong(1, datasetId);
                ps.setString(2, name);
                ps.setString(3, enc[0]);
                ps.setString(4, enc[1]);
                ps.executeUpdate();
                provider.maybeCommit();
            } catch (SQLException e) {
                throw new RuntimeException("setAttribute failed", e);
            }
        }

        /** Not in interface but mirrors Python API surface. */
        public void deleteAttribute(String name) {
            requireWritable();
            try (PreparedStatement ps = conn.prepareStatement(
                    "DELETE FROM dataset_attributes WHERE dataset_id = ? AND name = ?")) {
                ps.setLong(1, datasetId); ps.setString(2, name);
                ps.executeUpdate();
                provider.maybeCommit();
            } catch (SQLException e) {
                throw new RuntimeException("deleteAttribute failed", e);
            }
        }

        /** Not in interface but mirrors Python API surface. */
        public List<String> attributeNames() {
            List<String> names = new ArrayList<>();
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT name FROM dataset_attributes WHERE dataset_id = ? ORDER BY name")) {
                ps.setLong(1, datasetId);
                ResultSet rs = ps.executeQuery();
                while (rs.next()) names.add(rs.getString(1));
            } catch (SQLException e) {
                throw new RuntimeException("attributeNames failed", e);
            }
            return names;
        }

        // ── Helpers ─────────────────────────────────────────────────────

        private void requireWritable() {
            if (readOnly) throw new UnsupportedOperationException(
                    "provider opened in read-only mode");
        }

        private Object emptyArray() {
            if (precision == null) return Collections.emptyList();
            return switch (precision) {
                case FLOAT32 -> new float[0];
                case FLOAT64 -> new double[0];
                case INT32, UINT32 -> new int[0];
                case INT64 -> new long[0];
                case COMPLEX128 -> new double[0];
                case UINT8 -> new byte[0];
            };
        }

        private static Object slicePrimitive(Object src, int offset, int count) {
            if (src instanceof double[] a) {
                double[] out = new double[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof float[] a) {
                float[] out = new float[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof int[] a) {
                int[] out = new int[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof long[] a) {
                long[] out = new long[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            throw new IllegalStateException("slicePrimitive: unsupported type " + src.getClass());
        }
    }
}
