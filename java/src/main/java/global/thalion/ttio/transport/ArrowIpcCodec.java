/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Identification;
import global.thalion.ttio.Quantification;

import org.apache.arrow.memory.RootAllocator;
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
import java.util.List;
import java.util.Objects;

/**
 * Stateless encoder/decoder for tabular transport-spec v0.11 packet
 * payloads — {@link Identification} (packet 0x16 IDENTIFICATIONS_TABLE)
 * and {@link Quantification} (packet 0x17 QUANTIFICATIONS_TABLE) — as
 * Apache Arrow IPC streams.
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
 * </pre>
 *
 * <p><b>Allocator lifecycle.</b> A single static {@link RootAllocator}
 * is shared across all encode/decode calls. Each per-call
 * {@link VectorSchemaRoot} / reader / writer is opened in a
 * try-with-resources block so all per-call Arrow buffers are released
 * before the method returns; the static allocator itself lives for
 * the JVM lifetime.</p>
 *
 * <p><b>Subjects + Samples</b> (packets 0x19, 0x1A) are not handled by
 * this codec — they are added in Task 1.9 of the v0.11 plan.</p>
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

    /** Exposed for introspection / debugging. */
    static Schema identificationSchema() { return IDENTIFICATION_SCHEMA; }
    /** Exposed for introspection / debugging. */
    static Schema quantificationSchema() { return QUANTIFICATION_SCHEMA; }
}
