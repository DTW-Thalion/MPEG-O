/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Identification;
import global.thalion.ttio.MiniJson;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.Sample;
import global.thalion.ttio.Subject;

import org.apache.arrow.memory.RootAllocator;
import org.apache.arrow.vector.BigIntVector;
import org.apache.arrow.vector.Float8Vector;
import org.apache.arrow.vector.IntVector;
import org.apache.arrow.vector.VarCharVector;
import org.apache.arrow.vector.VectorSchemaRoot;
import org.apache.arrow.vector.ipc.ArrowStreamReader;
import org.apache.arrow.vector.ipc.ArrowStreamWriter;
import org.apache.arrow.vector.types.FloatingPointPrecision;
import org.apache.arrow.vector.types.pojo.ArrowType;
import org.apache.arrow.vector.types.pojo.Field;
import org.apache.arrow.vector.types.pojo.FieldType;
import org.apache.arrow.vector.types.pojo.Schema;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.channels.Channels;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Stateless encoder/decoder for tabular transport-spec v0.11 packet
 * payloads — {@link Identification} (packet 0x16 IDENTIFICATIONS_TABLE),
 * {@link Quantification} (packet 0x17 QUANTIFICATIONS_TABLE),
 * {@link Subject} (packet 0x19 SUBJECT_METADATA), and {@link Sample}
 * (packet 0x1A SAMPLE_METADATA) — as Apache Arrow IPC streams.
 *
 * <p><b>Schemas.</b> Derived from the actual record shapes in
 * {@code global.thalion.ttio}:</p>
 *
 * <pre>
 *   IDENTIFICATION_SCHEMA:
 *     run_name             : utf8        // Identification.runName
 *     spectrum_index       : int32       // Identification.spectrumIndex
 *     chemical_entity      : utf8        // Identification.chemicalEntity
 *     confidence_score     : float64     // Identification.confidenceScore
 *     evidence_chain_json  : utf8        // JSON array of evidence strings
 *
 *   QUANTIFICATION_SCHEMA:
 *     chemical_entity      : utf8        // Quantification.chemicalEntity
 *     sample_ref           : utf8        // Quantification.sampleRef
 *     abundance            : float64     // Quantification.abundance
 *     normalization_method : utf8        // Quantification.normalizationMethod
 *     unit                 : utf8        // Quantification.unit
 *
 *   SUBJECT_SCHEMA (Stage 6, design spec §6.1):
 *     external_id          : utf8 (notNullable)  // Subject.externalId — required
 *     project              : utf8 (nullable)     // Subject.project
 *     sex                  : utf8 (nullable)     // Subject.sex
 *     birth_year           : int32 (nullable)    // widened from on-disk int64
 *     attributes_json      : utf8 (nullable)     // sort-keys JSON object
 *
 *   SAMPLE_SCHEMA (Stage 6, design spec §6.2):
 *     sample_id            : utf8 (notNullable)  // Sample.sampleId — required
 *     subject_external_id  : utf8 (nullable)     // soft FK
 *     sample_kind          : utf8 (nullable)
 *     collected_at         : int64 (nullable)
 *     attributes_json      : utf8 (nullable)
 * </pre>
 *
 * <p><b>Null handling for Subject / Sample</b> (spec §11):</p>
 * <ul>
 *   <li>Optional string columns ({@code project}, {@code sex},
 *       {@code subject_external_id}, {@code sample_kind}) emit Arrow
 *       <i>null</i> when the source is the empty string {@code ""}.
 *       On read, Arrow null decodes back to {@code ""} so the Java
 *       records' "empty-string = unset" invariant is preserved end to
 *       end.</li>
 *   <li>Optional integer columns ({@code birth_year},
 *       {@code collected_at}) emit Arrow <i>null</i> when the source
 *       value is the sentinel {@code 0}; Arrow null decodes back to
 *       {@code 0}. This mirrors the on-disk sentinel-0 convention so
 *       Python and ObjC implementations of this codec can interoperate
 *       byte-for-byte at the value level (the IPC envelope itself is
 *       not required to be byte-equal cross-language — only the
 *       decoded row contents are).</li>
 *   <li>The {@code attributes_json} column is <b>always</b> emitted
 *       with a value ({@code "{}"} for empty maps), never Arrow null;
 *       its semantics are well-defined as a sort-keys JSON object.</li>
 * </ul>
 *
 * <p><b>Allocator lifecycle.</b> A single static {@link RootAllocator}
 * is shared across all encode/decode calls. Each per-call
 * {@link VectorSchemaRoot} / reader / writer is opened in a
 * try-with-resources block so all per-call Arrow buffers are released
 * before the method returns; the static allocator itself lives for
 * the JVM lifetime.</p>
 */
public final class ArrowIpcCodec {

    /** Process-wide root allocator. All per-call buffers are children
     *  of this and are freed by the try-with-resources blocks below. */
    private static final RootAllocator ALLOC = new RootAllocator(Long.MAX_VALUE);

    private ArrowIpcCodec() {
        // utility class — non-instantiable
    }

    // ====================================================================
    //  Identifications
    // ====================================================================

    private static final Schema IDENTIFICATION_SCHEMA = new Schema(List.of(
        new Field("run_name",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("spectrum_index",
            FieldType.nullable(new ArrowType.Int(32, true)), null),
        new Field("chemical_entity",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("confidence_score",
            FieldType.nullable(new ArrowType.FloatingPoint(FloatingPointPrecision.DOUBLE)), null),
        new Field("evidence_chain_json",
            FieldType.nullable(new ArrowType.Utf8()), null)
    ));

    /**
     * Encode a list of {@link Identification} rows as an Arrow IPC
     * stream. Empty input yields a valid empty IPC stream that round
     * trips back to an empty list.
     */
    public static byte[] encodeIdentifications(List<Identification> rows) {
        Objects.requireNonNull(rows, "rows");
        try (VectorSchemaRoot root = VectorSchemaRoot.create(IDENTIFICATION_SCHEMA, ALLOC);
             ByteArrayOutputStream buf = new ByteArrayOutputStream();
             ArrowStreamWriter writer = new ArrowStreamWriter(root, null, Channels.newChannel(buf))) {

            root.allocateNew();
            VarCharVector runName        = (VarCharVector) root.getVector("run_name");
            IntVector     spectrumIndex  = (IntVector)     root.getVector("spectrum_index");
            VarCharVector chemicalEntity = (VarCharVector) root.getVector("chemical_entity");
            Float8Vector  confidence     = (Float8Vector)  root.getVector("confidence_score");
            VarCharVector evidence       = (VarCharVector) root.getVector("evidence_chain_json");

            for (int i = 0; i < rows.size(); i++) {
                Identification r = rows.get(i);
                runName.setSafe(i, bytes(r.runName()));
                spectrumIndex.setSafe(i, r.spectrumIndex());
                chemicalEntity.setSafe(i, bytes(r.chemicalEntity()));
                confidence.setSafe(i, r.confidenceScore());
                evidence.setSafe(i, bytes(r.evidenceChainJson()));
            }
            root.setRowCount(rows.size());

            writer.start();
            writer.writeBatch();
            writer.end();
            return buf.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC encode (identifications) failed", e);
        }
    }

    /** Decode an Arrow IPC stream into a list of {@link Identification}. */
    public static List<Identification> decodeIdentifications(byte[] ipc) {
        if (ipc == null || ipc.length == 0) return List.of();
        try (ByteArrayInputStream in = new ByteArrayInputStream(ipc);
             ArrowStreamReader reader = new ArrowStreamReader(in, ALLOC)) {
            List<Identification> out = new ArrayList<>();
            VectorSchemaRoot root = reader.getVectorSchemaRoot();
            while (reader.loadNextBatch()) {
                int n = root.getRowCount();
                VarCharVector runName        = (VarCharVector) root.getVector("run_name");
                IntVector     spectrumIndex  = (IntVector)     root.getVector("spectrum_index");
                VarCharVector chemicalEntity = (VarCharVector) root.getVector("chemical_entity");
                Float8Vector  confidence     = (Float8Vector)  root.getVector("confidence_score");
                VarCharVector evidence       = (VarCharVector) root.getVector("evidence_chain_json");
                for (int i = 0; i < n; i++) {
                    out.add(new Identification(
                        readString(runName, i),
                        spectrumIndex.get(i),
                        readString(chemicalEntity, i),
                        confidence.get(i),
                        parseStringArrayJson(readString(evidence, i))));
                }
            }
            return out;
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC decode (identifications) failed", e);
        }
    }

    // ====================================================================
    //  Quantifications
    // ====================================================================

    private static final Schema QUANTIFICATION_SCHEMA = new Schema(List.of(
        new Field("chemical_entity",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("sample_ref",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("abundance",
            FieldType.nullable(new ArrowType.FloatingPoint(FloatingPointPrecision.DOUBLE)), null),
        new Field("normalization_method",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("unit",
            FieldType.nullable(new ArrowType.Utf8()), null)
    ));

    /**
     * Encode a list of {@link Quantification} rows as an Arrow IPC
     * stream. Empty input yields a valid empty IPC stream.
     */
    public static byte[] encodeQuantifications(List<Quantification> rows) {
        Objects.requireNonNull(rows, "rows");
        try (VectorSchemaRoot root = VectorSchemaRoot.create(QUANTIFICATION_SCHEMA, ALLOC);
             ByteArrayOutputStream buf = new ByteArrayOutputStream();
             ArrowStreamWriter writer = new ArrowStreamWriter(root, null, Channels.newChannel(buf))) {

            root.allocateNew();
            VarCharVector chemicalEntity = (VarCharVector) root.getVector("chemical_entity");
            VarCharVector sampleRef      = (VarCharVector) root.getVector("sample_ref");
            Float8Vector  abundance      = (Float8Vector)  root.getVector("abundance");
            VarCharVector normalization  = (VarCharVector) root.getVector("normalization_method");
            VarCharVector unit           = (VarCharVector) root.getVector("unit");

            for (int i = 0; i < rows.size(); i++) {
                Quantification r = rows.get(i);
                chemicalEntity.setSafe(i, bytes(r.chemicalEntity()));
                sampleRef.setSafe(i, bytes(r.sampleRef()));
                abundance.setSafe(i, r.abundance());
                normalization.setSafe(i, bytes(r.normalizationMethod()));
                unit.setSafe(i, bytes(r.unit()));
            }
            root.setRowCount(rows.size());

            writer.start();
            writer.writeBatch();
            writer.end();
            return buf.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC encode (quantifications) failed", e);
        }
    }

    /** Decode an Arrow IPC stream into a list of {@link Quantification}. */
    public static List<Quantification> decodeQuantifications(byte[] ipc) {
        if (ipc == null || ipc.length == 0) return List.of();
        try (ByteArrayInputStream in = new ByteArrayInputStream(ipc);
             ArrowStreamReader reader = new ArrowStreamReader(in, ALLOC)) {
            List<Quantification> out = new ArrayList<>();
            VectorSchemaRoot root = reader.getVectorSchemaRoot();
            while (reader.loadNextBatch()) {
                int n = root.getRowCount();
                VarCharVector chemicalEntity = (VarCharVector) root.getVector("chemical_entity");
                VarCharVector sampleRef      = (VarCharVector) root.getVector("sample_ref");
                Float8Vector  abundance      = (Float8Vector)  root.getVector("abundance");
                VarCharVector normalization  = (VarCharVector) root.getVector("normalization_method");
                VarCharVector unit           = (VarCharVector) root.getVector("unit");
                for (int i = 0; i < n; i++) {
                    out.add(new Quantification(
                        readString(chemicalEntity, i),
                        readString(sampleRef, i),
                        abundance.get(i),
                        readString(normalization, i),
                        readString(unit, i)));
                }
            }
            return out;
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC decode (quantifications) failed", e);
        }
    }

    // ====================================================================
    //  Subjects  (transport-spec §4.22 / 0x19 SUBJECT_METADATA)
    // ====================================================================

    private static final Schema SUBJECT_SCHEMA = new Schema(List.of(
        new Field("external_id",
            FieldType.notNullable(new ArrowType.Utf8()), null),
        new Field("project",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("sex",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("birth_year",
            FieldType.nullable(new ArrowType.Int(32, true)), null),
        new Field("attributes_json",
            FieldType.nullable(new ArrowType.Utf8()), null)
    ));

    /**
     * Encode a list of {@link Subject} rows as an Arrow IPC stream.
     * Empty input yields a valid empty IPC stream that round-trips back
     * to an empty list. See the class-level Javadoc for null-handling
     * conventions on each column.
     */
    public static byte[] encodeSubjects(List<Subject> rows) {
        Objects.requireNonNull(rows, "rows");
        try (VectorSchemaRoot root = VectorSchemaRoot.create(SUBJECT_SCHEMA, ALLOC);
             ByteArrayOutputStream buf = new ByteArrayOutputStream();
             ArrowStreamWriter writer = new ArrowStreamWriter(root, null, Channels.newChannel(buf))) {

            root.allocateNew();
            VarCharVector externalId = (VarCharVector) root.getVector("external_id");
            VarCharVector project    = (VarCharVector) root.getVector("project");
            VarCharVector sex        = (VarCharVector) root.getVector("sex");
            IntVector     birthYear  = (IntVector)     root.getVector("birth_year");
            VarCharVector attrsJson  = (VarCharVector) root.getVector("attributes_json");

            for (int i = 0; i < rows.size(); i++) {
                Subject r = rows.get(i);
                // external_id is notNullable — always write.
                externalId.setSafe(i, bytes(r.externalId()));
                setOptionalString(project, i, r.project());
                setOptionalString(sex, i, r.sex());
                // birth_year sentinel 0 -> Arrow null on the wire. The
                // on-disk record stores int64; we narrow to int32 here
                // (design spec §6.1 — column-width consistency with the
                // identification table).
                long by = r.birthYear();
                if (by == 0L) {
                    birthYear.setNull(i);
                } else {
                    birthYear.setSafe(i, (int) by);
                }
                // attributes_json is never null on the wire — empty maps
                // surface as the literal "{}" string.
                attrsJson.setSafe(i, bytes(r.attributesJson()));
            }
            root.setRowCount(rows.size());

            writer.start();
            writer.writeBatch();
            writer.end();
            return buf.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC encode (subjects) failed", e);
        }
    }

    /** Decode an Arrow IPC stream into a list of {@link Subject}. Arrow
     *  null in {@code project} / {@code sex} decodes to {@code ""};
     *  Arrow null in {@code birth_year} decodes to {@code 0}. */
    public static List<Subject> decodeSubjects(byte[] ipc) {
        if (ipc == null || ipc.length == 0) return List.of();
        try (ByteArrayInputStream in = new ByteArrayInputStream(ipc);
             ArrowStreamReader reader = new ArrowStreamReader(in, ALLOC)) {
            List<Subject> out = new ArrayList<>();
            VectorSchemaRoot root = reader.getVectorSchemaRoot();
            while (reader.loadNextBatch()) {
                int n = root.getRowCount();
                VarCharVector externalId = (VarCharVector) root.getVector("external_id");
                VarCharVector project    = (VarCharVector) root.getVector("project");
                VarCharVector sex        = (VarCharVector) root.getVector("sex");
                IntVector     birthYear  = (IntVector)     root.getVector("birth_year");
                VarCharVector attrsJson  = (VarCharVector) root.getVector("attributes_json");
                for (int i = 0; i < n; i++) {
                    String extId = readString(externalId, i);
                    String proj  = readString(project, i);
                    String sx    = readString(sex, i);
                    long by      = birthYear.isNull(i) ? 0L : (long) birthYear.get(i);
                    Map<String, String> attrs =
                        parseAttributesJson(readString(attrsJson, i));
                    out.add(new Subject(extId, proj, sx, by, attrs));
                }
            }
            return out;
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC decode (subjects) failed", e);
        }
    }

    // ====================================================================
    //  Samples  (transport-spec §4.22 / 0x1A SAMPLE_METADATA)
    // ====================================================================

    private static final Schema SAMPLE_SCHEMA = new Schema(List.of(
        new Field("sample_id",
            FieldType.notNullable(new ArrowType.Utf8()), null),
        new Field("subject_external_id",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("sample_kind",
            FieldType.nullable(new ArrowType.Utf8()), null),
        new Field("collected_at",
            FieldType.nullable(new ArrowType.Int(64, true)), null),
        new Field("attributes_json",
            FieldType.nullable(new ArrowType.Utf8()), null)
    ));

    /**
     * Encode a list of {@link Sample} rows as an Arrow IPC stream.
     * Empty input yields a valid empty IPC stream that round-trips back
     * to an empty list. See the class-level Javadoc for null-handling
     * conventions on each column.
     */
    public static byte[] encodeSamples(List<Sample> rows) {
        Objects.requireNonNull(rows, "rows");
        try (VectorSchemaRoot root = VectorSchemaRoot.create(SAMPLE_SCHEMA, ALLOC);
             ByteArrayOutputStream buf = new ByteArrayOutputStream();
             ArrowStreamWriter writer = new ArrowStreamWriter(root, null, Channels.newChannel(buf))) {

            root.allocateNew();
            VarCharVector sampleId      = (VarCharVector) root.getVector("sample_id");
            VarCharVector subjectExtId  = (VarCharVector) root.getVector("subject_external_id");
            VarCharVector sampleKind    = (VarCharVector) root.getVector("sample_kind");
            BigIntVector  collectedAt   = (BigIntVector)  root.getVector("collected_at");
            VarCharVector attrsJson     = (VarCharVector) root.getVector("attributes_json");

            for (int i = 0; i < rows.size(); i++) {
                Sample r = rows.get(i);
                sampleId.setSafe(i, bytes(r.sampleId()));
                setOptionalString(subjectExtId, i, r.subjectExternalId());
                setOptionalString(sampleKind, i, r.sampleKind());
                long ts = r.collectedAt();
                if (ts == 0L) {
                    collectedAt.setNull(i);
                } else {
                    collectedAt.setSafe(i, ts);
                }
                attrsJson.setSafe(i, bytes(r.attributesJson()));
            }
            root.setRowCount(rows.size());

            writer.start();
            writer.writeBatch();
            writer.end();
            return buf.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC encode (samples) failed", e);
        }
    }

    /** Decode an Arrow IPC stream into a list of {@link Sample}. Arrow
     *  null in {@code subject_external_id} / {@code sample_kind}
     *  decodes to {@code ""}; Arrow null in {@code collected_at}
     *  decodes to {@code 0}. */
    public static List<Sample> decodeSamples(byte[] ipc) {
        if (ipc == null || ipc.length == 0) return List.of();
        try (ByteArrayInputStream in = new ByteArrayInputStream(ipc);
             ArrowStreamReader reader = new ArrowStreamReader(in, ALLOC)) {
            List<Sample> out = new ArrayList<>();
            VectorSchemaRoot root = reader.getVectorSchemaRoot();
            while (reader.loadNextBatch()) {
                int n = root.getRowCount();
                VarCharVector sampleId      = (VarCharVector) root.getVector("sample_id");
                VarCharVector subjectExtId  = (VarCharVector) root.getVector("subject_external_id");
                VarCharVector sampleKind    = (VarCharVector) root.getVector("sample_kind");
                BigIntVector  collectedAt   = (BigIntVector)  root.getVector("collected_at");
                VarCharVector attrsJson     = (VarCharVector) root.getVector("attributes_json");
                for (int i = 0; i < n; i++) {
                    String sid   = readString(sampleId, i);
                    String sext  = readString(subjectExtId, i);
                    String skind = readString(sampleKind, i);
                    long ts      = collectedAt.isNull(i) ? 0L : collectedAt.get(i);
                    Map<String, String> attrs =
                        parseAttributesJson(readString(attrsJson, i));
                    out.add(new Sample(sid, sext, skind, ts, attrs));
                }
            }
            return out;
        } catch (IOException e) {
            throw new RuntimeException("Arrow IPC decode (samples) failed", e);
        }
    }

    // ====================================================================
    //  Internals
    // ====================================================================

    private static byte[] bytes(String s) {
        return (s == null ? "" : s).getBytes(StandardCharsets.UTF_8);
    }

    private static String readString(VarCharVector v, int i) {
        if (v.isNull(i)) return "";
        byte[] b = v.get(i);
        return new String(b, StandardCharsets.UTF_8);
    }

    /**
     * Parse a JSON array of strings (the format emitted by
     * {@link Identification#evidenceChainJson()}). This is intentionally
     * minimal — we only consume what we produce — so we do not introduce
     * a JSON library dependency. Handles {@code "} escapes and treats
     * blank / {@code "[]"} as empty.
     */
    static List<String> parseStringArrayJson(String s) {
        if (s == null) return List.of();
        String t = s.trim();
        if (t.isEmpty() || t.equals("[]")) return List.of();
        if (t.charAt(0) != '[' || t.charAt(t.length() - 1) != ']') {
            throw new IllegalArgumentException(
                "evidence_chain_json must be a JSON array, got: " + s);
        }
        List<String> out = new ArrayList<>();
        int i = 1;
        int end = t.length() - 1;
        while (i < end) {
            // skip whitespace + commas between items
            while (i < end && (Character.isWhitespace(t.charAt(i)) || t.charAt(i) == ',')) i++;
            if (i >= end) break;
            if (t.charAt(i) != '"') {
                throw new IllegalArgumentException(
                    "evidence_chain_json item must start with '\"' at pos " + i + ": " + s);
            }
            i++; // consume opening quote
            StringBuilder item = new StringBuilder();
            while (i < end) {
                char c = t.charAt(i);
                if (c == '\\' && i + 1 < end) {
                    char esc = t.charAt(i + 1);
                    switch (esc) {
                        case '"':  item.append('"');  break;
                        case '\\': item.append('\\'); break;
                        case '/':  item.append('/');  break;
                        case 'n':  item.append('\n'); break;
                        case 't':  item.append('\t'); break;
                        case 'r':  item.append('\r'); break;
                        case 'b':  item.append('\b'); break;
                        case 'f':  item.append('\f'); break;
                        default:   item.append(esc);  break;
                    }
                    i += 2;
                } else if (c == '"') {
                    i++; // consume closing quote
                    break;
                } else {
                    item.append(c);
                    i++;
                }
            }
            out.add(item.toString());
        }
        return List.copyOf(out);
    }

    /** Write an Arrow null for an empty source string; otherwise write
     *  the UTF-8 bytes. Encodes the spec §11 convention that
     *  empty-string ↔ Arrow null on the wire for optional string
     *  columns of the SUBJECT_METADATA and SAMPLE_METADATA payloads. */
    private static void setOptionalString(VarCharVector v, int i, String s) {
        if (s == null || s.isEmpty()) {
            v.setNull(i);
        } else {
            v.setSafe(i, s.getBytes(StandardCharsets.UTF_8));
        }
    }

    /** Parse an {@code attributes_json} value back into a
     *  {@code Map<String,String>} compatible with the {@link Subject}
     *  / {@link Sample} record constructors. Defers to the shared
     *  {@link MiniJson#parseStringMap} so byte-for-byte round-trips are
     *  guaranteed: the writer emits sort-keys JSON, the reader returns
     *  a {@link LinkedHashMap} preserving the on-the-wire key order. */
    private static Map<String, String> parseAttributesJson(String s) {
        if (s == null || s.isEmpty() || "{}".equals(s)) return Map.of();
        return MiniJson.parseStringMap(s);
    }

    /** Exposed for introspection / debugging. */
    static Schema identificationSchema() { return IDENTIFICATION_SCHEMA; }
    /** Exposed for introspection / debugging. */
    static Schema quantificationSchema() { return QUANTIFICATION_SCHEMA; }
    /** Exposed for introspection / debugging. */
    static Schema subjectSchema() { return SUBJECT_SCHEMA; }
    /** Exposed for introspection / debugging. */
    static Schema sampleSchema() { return SAMPLE_SCHEMA; }
}
