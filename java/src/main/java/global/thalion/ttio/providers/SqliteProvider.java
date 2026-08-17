/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.providers;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;

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
 *
 */
public final class SqliteProvider implements StorageProvider {

    /** Structural JSON reader for the compound-dataset encoding. Read-only
     *  use; the byte-canonical serializer is hand-rolled and untouched. */
    private static final ObjectMapper JSON = new ObjectMapper();

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
        "  extendable       INTEGER NOT NULL DEFAULT 0," +
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

    // ── Transactions ──────────────────────────────────

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
        ensureExtendableColumn();
    }

    /** Databases created before extendable datasets lack the column. */
    private void ensureExtendableColumn() throws SQLException {
        boolean present = false;
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery("PRAGMA table_info(datasets)")) {
            while (rs.next()) {
                if ("extendable".equals(rs.getString("name"))) { present = true; break; }
            }
        }
        if (!present) {
            try (Statement st = conn.createStatement()) {
                st.execute("ALTER TABLE datasets ADD COLUMN extendable INTEGER NOT NULL DEFAULT 0");
            }
        }
    }

    /** {@code true} when the open database has the {@code extendable} column. */
    boolean hasExtendableColumn() {
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery("PRAGMA table_info(datasets)")) {
            while (rs.next()) {
                if ("extendable".equals(rs.getString("name"))) return true;
            }
            return false;
        } catch (SQLException e) {
            return false;
        }
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
            case INT64, UINT64 -> {  // UINT64 packs identically to INT64
                long[] arr = toLongArray(data);
                for (long v : arr) buf.putLong(v);
            }
            case COMPLEX128 -> {
                // Interleaved real+imag doubles. Data arrives as double[] of length 2N.
                double[] arr = toDoubleArray(data);
                for (double v : arr) buf.putDouble(v);
            }
            case UINT8 -> {
                // raw bytes — genomic base/quality channels.
                byte[] arr = toByteArray(data);
                buf.put(arr);
            }
            case UINT16 -> {
                // L1 (Task #82 Phase B.1): chromosome_ids.
                short[] arr = toShortArray(data);
                for (short s : arr) buf.putShort(s);
            }
            case _RESERVED_INT8 ->
                throw new UnsupportedOperationException(
                    "Precision " + precision + " is reserved (cross-lang parity)");
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
            case INT64, UINT64 -> {  // UINT64 unpacks identically to INT64
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
                // raw byte channel.
                byte[] arr = new byte[n];
                buf.get(arr);
                yield arr;
            }
            case UINT16 -> {
                // L1: chromosome_ids unpacks as little-endian uint16.
                short[] arr = new short[n];
                for (int i = 0; i < n; i++) arr[i] = buf.getShort();
                yield arr;
            }
            case _RESERVED_INT8 ->
                throw new UnsupportedOperationException(
                    "Precision " + precision + " is reserved (cross-lang parity)");
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
        // Parse [{"name":"x","kind":"vl_string"}, ...] structurally (Jackson),
        // so whitespace, key order, and escapes a non-Java writer emits are all
        // handled (cross-language compat — #205).
        List<CompoundField> result = new ArrayList<>();
        JsonNode arr = readJsonTree(json);
        for (JsonNode obj : arr) {
            result.add(new CompoundField(
                obj.get("name").asText(),
                fieldKindFromValue(obj.get("kind").asText())));
        }
        return result;
    }

    static List<Map<String, Object>> rowsFromJson(String json) {
        List<Map<String, Object>> result = new ArrayList<>();
        JsonNode arr = readJsonTree(json);
        for (JsonNode obj : arr) {
            Map<String, Object> row = new LinkedHashMap<>();
            Iterator<String> names = obj.fieldNames();
            while (names.hasNext()) {
                String key = names.next();
                row.put(key, jsonNodeToValue(obj.get(key)));
            }
            result.add(row);
        }
        return result;
    }

    static long[] shapeFromJson(String json) {
        JsonNode arr = readJsonTree(json);
        long[] shape = new long[arr.size()];
        for (int i = 0; i < shape.length; i++) {
            shape[i] = arr.get(i).asLong();
        }
        return shape;
    }

    /** Parse {@code json} to a tree, wrapping Jackson's checked failure as an
     *  unchecked {@link IllegalArgumentException} (the reader's bad-input
     *  contract — callers never declared a checked throw). */
    private static JsonNode readJsonTree(String json) {
        try {
            return JSON.readTree(json);
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            throw new IllegalArgumentException("Malformed compound JSON: " + e.getMessage(), e);
        }
    }

    /**
     * Map a JSON value node to a Java value with the SAME typing the old
     * hand-rolled {@code parseJsonScalar} produced: {@code null}; Boolean;
     * integral number &rarr; Long; floating number &rarr; Double; textual
     * &rarr; String.
     */
    private static Object jsonNodeToValue(JsonNode node) {
        if (node.isNull()) return null;
        if (node.isBoolean()) return node.asBoolean();
        if (node.isIntegralNumber()) return node.asLong();
        if (node.isFloatingPointNumber()) return node.asDouble();
        return node.asText();
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
            case UINT64 -> "uint64";
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
            case "uint64" -> CompoundField.Kind.UINT64;
            case "float64" -> CompoundField.Kind.FLOAT64;
            case "vl_string" -> CompoundField.Kind.VL_STRING;
            default -> throw new IllegalArgumentException("Unknown CompoundFieldKind: " + value);
        };
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

    private static short[] toShortArray(Object data) {
        if (data instanceof short[] a) return a;
        if (data instanceof int[] a) { short[] r = new short[a.length]; for (int i=0;i<a.length;i++) r[i]=(short)a[i]; return r; }
        throw new IllegalArgumentException("Cannot convert to short[]: " + data.getClass());
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
            boolean hasExt = provider.hasExtendableColumn();
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT id, kind, precision, shape_json, compound_fields" +
                    (hasExt ? ", extendable " : " ") +
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
                boolean extendable = hasExt && rs.getInt(6) != 0;
                Precision prec = precName != null ? Precision.valueOf(precName) : null;
                long[] shape = shapeFromJson(shapeJson);
                List<CompoundField> fields = fieldsJson != null ? fieldsFromJson(fieldsJson) : null;
                return new SqliteDataset(provider, dsId, name, prec, shape, fields, readOnly, extendable);
            } catch (SQLException e) {
                throw new RuntimeException("openDataset failed", e);
            }
        }

        @Override
        public StorageDataset createDataset(String name, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel) {
            return createDataset(name, precision, length, chunkSize,
                                  compression, compressionLevel, false);
        }

        @Override
        public StorageDataset createDataset(String name, Precision precision,
                                             long length, int chunkSize,
                                             Compression compression,
                                             int compressionLevel,
                                             boolean extendable) {
            StorageGroup.requireChunkForExtendable(extendable, chunkSize);
            requireWritable();
            if (hasChild(name)) throw new IllegalArgumentException(
                    "'" + name + "' already exists in '" + groupName + "'");
            String shapeJson = "[" + length + "]";
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO datasets (group_id, name, kind, precision, shape_json, data, extendable) " +
                    "VALUES (?, ?, 'primitive', ?, ?, NULL, ?)",
                    Statement.RETURN_GENERATED_KEYS)) {
                ps.setLong(1, groupId);
                ps.setString(2, name);
                ps.setString(3, precision.name());
                ps.setString(4, shapeJson);
                ps.setInt(5, extendable ? 1 : 0);
                ps.executeUpdate();
                provider.maybeCommit();
                ResultSet keys = ps.getGeneratedKeys();
                keys.next();
                long dsId = keys.getLong(1);
                return new SqliteDataset(provider, dsId, name, precision,
                        new long[]{length}, null, readOnly, extendable);
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
            return createCompoundDataset(name, fields, count, false, 0);
        }

        @Override
        public StorageDataset createCompoundDataset(String name,
                                                     List<CompoundField> fields,
                                                     long count,
                                                     boolean extendable,
                                                     int chunkRows) {
            StorageGroup.requireChunkForExtendable(extendable, chunkRows);
            requireWritable();
            if (hasChild(name)) throw new IllegalArgumentException(
                    "'" + name + "' already exists in '" + groupName + "'");
            String fieldsJson = fieldsToJson(fields);
            String shapeJson = "[" + count + "]";
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO datasets (group_id, name, kind, precision, shape_json, " +
                    "compound_fields, compound_rows, extendable) VALUES (?, ?, 'compound', NULL, ?, ?, '[]', ?)",
                    Statement.RETURN_GENERATED_KEYS)) {
                ps.setLong(1, groupId);
                ps.setString(2, name);
                ps.setString(3, shapeJson);
                ps.setString(4, fieldsJson);
                ps.setInt(5, extendable ? 1 : 0);
                ps.executeUpdate();
                provider.maybeCommit();
                ResultSet keys = ps.getGeneratedKeys();
                keys.next();
                long dsId = keys.getLong(1);
                return new SqliteDataset(provider, dsId, name, null,
                        new long[]{count}, List.copyOf(fields), readOnly, extendable);
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
        private final boolean extendable;

        SqliteDataset(SqliteProvider provider, long datasetId, String name,
                       Precision precision, long[] shape,
                       List<CompoundField> fields, boolean readOnly) {
            this(provider, datasetId, name, precision, shape, fields, readOnly, false);
        }

        SqliteDataset(SqliteProvider provider, long datasetId, String name,
                       Precision precision, long[] shape,
                       List<CompoundField> fields, boolean readOnly,
                       boolean extendable) {
            this.provider = provider;
            this.conn = provider.conn;
            this.datasetId = datasetId;
            this.dsName = name;
            this.precision = precision;
            this.shape = shape;
            this.fields = fields;
            this.readOnly = readOnly;
            this.extendable = extendable;
        }

        @Override public String name() { return dsName; }
        @Override public Precision precision() { return precision; }
        @Override public long[] shape() { return shape.clone(); }
        @Override public List<CompoundField> compoundFields() { return fields; }
        @Override public boolean extendable() { return extendable; }

        /** Read-modify-write: one blob (or one JSON row list) per dataset. */
        @Override
        @SuppressWarnings("unchecked")
        public void append(Object data) {
            if (!extendable) {
                throw new UnsupportedOperationException(
                    "dataset '" + dsName + "' is not extendable");
            }
            if (fields != null) {
                List<Map<String, Object>> rows = new ArrayList<>((List<Map<String, Object>>) readAll());
                for (Object o : (List<?>) data) {
                    if (o instanceof Map<?, ?> m) {
                        rows.add((Map<String, Object>) m);
                    } else {
                        Object[] arr = (Object[]) o;
                        Map<String, Object> row = new LinkedHashMap<>();
                        for (int i = 0; i < fields.size() && i < arr.length; i++) {
                            row.put(fields.get(i).name(), arr[i]);
                        }
                        rows.add(row);
                    }
                }
                writeAll(rows);
                shape = new long[]{ rows.size() };
                return;
            }
            Object cur = readAll();
            int na = arrayLength(cur), nb = arrayLength(data);
            if (nb == 0) return;
            Object out = java.lang.reflect.Array.newInstance(data.getClass().getComponentType(), na + nb);
            System.arraycopy(cur, 0, out, 0, na);
            System.arraycopy(data, 0, out, na, nb);
            writeAll(out);
        }

        @Override
        public void writeSlice(long offset, Object data) {
            Object cur = readAll();
            int n = arrayLength(data);
            if (offset < 0 || offset + n > arrayLength(cur)) {
                throw new IndexOutOfBoundsException("writeSlice out of range");
            }
            System.arraycopy(data, 0, cur, (int) offset, n);
            writeAll(cur);
        }

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
                List<Map<String, Object>> rows = new ArrayList<>();
                for (Object o : (List<?>) data) {
                    if (o instanceof Map<?, ?> m) {
                        @SuppressWarnings("unchecked")
                        Map<String, Object> mm = (Map<String, Object>) m;
                        rows.add(mm);
                    } else {
                        Object[] arr = (Object[]) o;
                        Map<String, Object> row = new LinkedHashMap<>();
                        for (int i = 0; i < fields.size() && i < arr.length; i++) {
                            row.put(fields.get(i).name(), arr[i]);
                        }
                        rows.add(row);
                    }
                }
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
                case INT64, UINT64 -> new long[0];
                case COMPLEX128 -> new double[0];
                case UINT8 -> new byte[0];
                case UINT16 -> new short[0];  // L1: chromosome_ids
                case _RESERVED_INT8 ->
                    throw new UnsupportedOperationException(
                        "Precision " + precision + " is reserved (cross-lang parity)");
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
            if (src instanceof byte[] a) {
                byte[] out = new byte[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            if (src instanceof short[] a) {
                short[] out = new short[count];
                System.arraycopy(a, offset, out, 0, count);
                return out;
            }
            throw new IllegalStateException("slicePrimitive: unsupported type " + src.getClass());
        }
    }
}
