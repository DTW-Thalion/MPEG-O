/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * Write/read helper for the fixed compound metadata datasets described
 * in format-spec section 6. Supports variable-length fields (VL_STRING and
 * VL_BYTES) in writes via a split-write strategy compatible with HDF5 1.14
 * Java bindings.
 *
 * <p><b>HDF5 1.14 compatibility note:</b> The HDF5 1.14 JNI wrapper for
 * {@code H5Dwrite} and {@code H5DwriteVL} calls {@code h5str_detect_vlen}
 * on the memory type before every write, and if any {@code H5T_VLEN} field
 * is present it routes through {@code translate_wbuf} /
 * {@code translate_rbuf}, which calls {@code GetObjectArrayElement} on a
 * {@code jbyteArray} -- undefined behaviour that causes a JVM SIGSEGV.</p>
 *
 * <p>When a schema contains any VL field (VL_STRING or VL_BYTES), the write
 * path splits:
 * <ol>
 *   <li>Create the dataset with the full compound file type.</li>
 *   <li>Write only the non-VL (primitive) fields via
 *       {@code H5Dwrite(byte[])} with a projection memory type that excludes
 *       all VL fields.</li>
 *   <li>Write each VL_STRING column via
 *       {@link H5#H5Dwrite_VLStrings(long,long,long,long,long,Object[])}.</li>
 *   <li>Write each VL_BYTES column via the {@link VlBytesFFM} helper, which
 *       uses the Java 21 Foreign Function &amp; Memory (FFM) API to call the
 *       native C {@code H5Dwrite} directly, bypassing the JNI
 *       {@code translate_wbuf} path entirely.</li>
 * </ol>
 * For schemas with no VL fields at all, the original full-compound
 * byte-buffer approach is used unchanged (compatible with HDF5 1.14).</p>
 *
 * <p>The read path applies the same split strategy when any VL field is
 * present.</p>
 */
public final class Hdf5CompoundIO {

    private Hdf5CompoundIO() {}

    /** Field kinds covered by the compound-IO helper. The byte width and
     *  native HDF5 type id pair determine the in-memory and on-disk
     *  representation of a single field. */
    public enum FieldKind {
        UINT32(4, HDF5Constants.H5T_NATIVE_UINT32),
        INT64(8, HDF5Constants.H5T_NATIVE_INT64),
        UINT64(8, HDF5Constants.H5T_NATIVE_UINT64),
        FLOAT64(8, HDF5Constants.H5T_NATIVE_DOUBLE),
        VL_STRING(8, -1),
        /** hvl_t on 64-bit: {size_t len; void* p} = 16 bytes. */
        VL_BYTES(16, -1);

        final int byteSize;
        final long nativeType;

        FieldKind(int byteSize, long nativeType) {
            this.byteSize = byteSize;
            this.nativeType = nativeType;
        }
    }

    /** One field in a compound schema, paired with its on-disk kind. */
    public record Field(String name, FieldKind kind) {}

    /** Immutable layout description for a compound dataset. Carries the
     *  ordered field list, the per-field byte offsets, and the total
     *  byte size of one record. */
    public static final class Schema {
        public final List<Field> fields;
        public final int[] offsets;
        public final int totalSize;

        /**
         * Build a schema from an ordered list of fields. Byte offsets are
         * computed by accumulating {@link FieldKind#byteSize} entries in
         * field order.
         *
         * @param fields  the ordered list of fields (defensively copied)
         */
        public Schema(List<Field> fields) {
            this.fields = List.copyOf(fields);
            this.offsets = new int[fields.size()];
            int off = 0;
            for (int i = 0; i < fields.size(); i++) {
                offsets[i] = off;
                off += fields.get(i).kind().byteSize;
            }
            this.totalSize = off;
        }
    }

    /**
     * Packs row values into the compound value array. VL_STRING fields are
     * returned as {@link String} objects; primitives as their boxed numeric
     * types; VL_BYTES as {@code byte[]}.
     */
    @FunctionalInterface
    public interface RowPacker {
        /**
         * Return boxed field values for record {@code row}. VL_STRING fields
         * must be returned as {@link String}; primitives as their boxed numeric
         * types; VL_BYTES as {@code byte[]}.
         */
        Object[] valuesFor(int row, NativeStringPool pool);
    }

    // -- Standard schemas (format-spec section 6.1-6.3) ----------------

    /**
     * Schema for the {@code identifications} compound dataset as defined
     * in format-spec section 6.1: run name, spectrum index, chemical
     * entity, confidence score, and a JSON-encoded evidence chain.
     *
     * @return  a fresh {@link Schema} instance describing the layout
     */
    public static Schema identificationSchema() {
        return new Schema(List.of(
                new Field("run_name", FieldKind.VL_STRING),
                new Field("spectrum_index", FieldKind.UINT32),
                new Field("chemical_entity", FieldKind.VL_STRING),
                new Field("confidence_score", FieldKind.FLOAT64),
                new Field("evidence_chain_json", FieldKind.VL_STRING)));
    }

    /**
     * Schema for the {@code quantifications} compound dataset as defined
     * in format-spec section 6.2: chemical entity, sample reference,
     * abundance value, and normalisation method.
     *
     * @return  a fresh {@link Schema} instance describing the layout
     */
    public static Schema quantificationSchema() {
        return new Schema(List.of(
                new Field("chemical_entity", FieldKind.VL_STRING),
                new Field("sample_ref", FieldKind.VL_STRING),
                new Field("abundance", FieldKind.FLOAT64),
                new Field("normalization_method", FieldKind.VL_STRING)));
    }

    /**
     * Schema for the {@code provenance} compound dataset as defined in
     * format-spec section 6.3: Unix timestamp, software identifier, and
     * JSON-encoded parameters / input refs / output refs.
     *
     * @return  a fresh {@link Schema} instance describing the layout
     */
    public static Schema provenanceSchema() {
        return new Schema(List.of(
                new Field("timestamp_unix", FieldKind.INT64),
                new Field("software", FieldKind.VL_STRING),
                new Field("parameters_json", FieldKind.VL_STRING),
                new Field("input_refs_json", FieldKind.VL_STRING),
                new Field("output_refs_json", FieldKind.VL_STRING)));
    }

    // -- Write ---------------------------------------------------------

    /**
     * Write a compound dataset. For schemas with any VL field (VL_STRING or
     * VL_BYTES), uses a split strategy to avoid the HDF5 1.14 crash.
     * For schemas without any VL fields, uses the original full-compound
     * byte-buffer approach.
     */
    public static void writeCompoundDataset(Hdf5Group parent, String datasetName,
                                             Schema schema, int count,
                                             RowPacker packer) {
        if (count == 0) {
            writeEmptyCompoundDataset(parent, datasetName, schema);
            return;
        }

        boolean hasVl = schema.fields.stream()
                .anyMatch(f -> f.kind() == FieldKind.VL_STRING
                            || f.kind() == FieldKind.VL_BYTES);

        if (hasVl) {
            writeCompoundSplit(parent, datasetName, schema, count, packer);
        } else {
            writeCompoundOriginal(parent, datasetName, schema, count, packer);
        }
    }

    /**
     * Original byte-buffer write path -- used when no VL fields are present
     * (compatible with HDF5 1.14).
     */
    private static void writeCompoundOriginal(Hdf5Group parent, String datasetName,
                                               Schema schema, int count,
                                               RowPacker packer) {
        Hdf5File owner = parent.owningFile();
        owner.lockForWriting();
        long ctype = -1, dspace = -1, dset = -1;
        try (NativeStringPool pool = new NativeStringPool()) {
            ctype = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                H5.H5Tinsert(ctype, f.name(), schema.offsets[i], f.kind().nativeType);
            }

            ByteBuffer buf = ByteBuffer.allocate(schema.totalSize * count)
                    .order(ByteOrder.nativeOrder());
            for (int row = 0; row < count; row++) {
                Object[] vals = packer.valuesFor(row, pool);
                int base = row * schema.totalSize;
                for (int i = 0; i < schema.fields.size(); i++) {
                    int off = base + schema.offsets[i];
                    switch (schema.fields.get(i).kind()) {
                        case UINT32  -> buf.putInt(off, ((Number) vals[i]).intValue());
                        case INT64, UINT64 -> buf.putLong(off, ((Number) vals[i]).longValue());
                        case FLOAT64 -> buf.putDouble(off, ((Number) vals[i]).doubleValue());
                        default -> { /* no VL fields in this path */ }
                    }
                }
            }

            dspace = H5.H5Screate_simple(1, new long[]{count}, null);
            dset = H5.H5Dcreate(parent.getGroupId(), datasetName, ctype, dspace,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT);
            if (dset < 0) {
                throw new Hdf5Errors.Hdf5Exception(
                        "H5Dcreate failed for compound '%s'".formatted(datasetName), null);
            }
            int rc = H5.H5Dwrite(dset, ctype, HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                    HDF5Constants.H5P_DEFAULT, buf.array());
            if (rc < 0) {
                throw new Hdf5Errors.DatasetWriteException(
                        "H5Dwrite failed for compound '%s'".formatted(datasetName));
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException(
                    "compound write '%s' failed: %s"
                    .formatted(datasetName, e.getMessage()));
        } finally {
            if (dset >= 0)   try { H5.H5Dclose(dset);   } catch (Exception ig) {}
            if (dspace >= 0) try { H5.H5Sclose(dspace); } catch (Exception ig) {}
            if (ctype >= 0)  try { H5.H5Tclose(ctype);  } catch (Exception ig) {}
            owner.unlockForWriting();
        }
    }

    /**
     * Split write path -- used when any VL field (VL_STRING or VL_BYTES) is
     * present.
     * <p>Pass 1: primitive (non-VL) fields via byte buffer with a projection
     * memory type that contains no VL fields, so HDF5 1.14
     * {@code translate_wbuf} does not fire.
     * <p>Pass 2: each VL_STRING column via {@code H5Dwrite_VLStrings}.
     * <p>Pass 3: each VL_BYTES column via the FFM helper
     * {@link VlBytesFFM#write(long, long, long, int, byte[][])} which calls
     * the native C {@code H5Dwrite} directly, bypassing the JNI
     * {@code translate_wbuf} interception entirely.
     */
    private static void writeCompoundSplit(Hdf5Group parent, String datasetName,
                                            Schema schema, int count,
                                            RowPacker packer) {
        Hdf5File owner = parent.owningFile();
        owner.lockForWriting();
        long strType = -1, vlBytesType = -1, fileType = -1, dspace = -1, dset = -1;
        try (NativeStringPool pool = new NativeStringPool()) {

            strType = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(strType, HDF5Constants.H5T_VARIABLE);
            vlBytesType = H5.H5Tvlen_create(HDF5Constants.H5T_NATIVE_UCHAR);

            // Build the full compound file type (defines on-disk layout)
            fileType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                long t = switch (f.kind()) {
                    case VL_STRING -> strType;
                    case VL_BYTES  -> vlBytesType;
                    default        -> f.kind().nativeType;
                };
                H5.H5Tinsert(fileType, f.name(), schema.offsets[i], t);
            }

            dspace = H5.H5Screate_simple(1, new long[]{count}, null);
            dset = H5.H5Dcreate(parent.getGroupId(), datasetName, fileType, dspace,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT);
            if (dset < 0) {
                throw new Hdf5Errors.Hdf5Exception(
                        "H5Dcreate failed for compound '%s'".formatted(datasetName), null);
            }

            // Collect all row values up front
            Object[][] allVals = new Object[count][];
            for (int row = 0; row < count; row++) {
                allVals[row] = packer.valuesFor(row, pool);
            }

            // -- Pass 1: primitive (non-VL) fields via byte buffer ---------
            // Memory type contains no VL fields, so HDF5 1.14's
            // translate_wbuf does not fire for VL_STRING or VL_BYTES.
            Schema primSchema = primitiveProjection(schema);
            if (!primSchema.fields.isEmpty()) {
                long memType = -1;
                try {
                    memType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND,
                                           primSchema.totalSize);
                    for (int i = 0; i < primSchema.fields.size(); i++) {
                        Field f = primSchema.fields.get(i);
                        H5.H5Tinsert(memType, f.name(), primSchema.offsets[i],
                                     f.kind().nativeType);
                    }
                    ByteBuffer buf =
                        ByteBuffer.allocate(primSchema.totalSize * count)
                                  .order(ByteOrder.nativeOrder());
                    for (int row = 0; row < count; row++) {
                        Object[] vals = allVals[row];
                        int base = row * primSchema.totalSize;
                        for (int pi = 0; pi < primSchema.fields.size(); pi++) {
                            Field f = primSchema.fields.get(pi);
                            int off = base + primSchema.offsets[pi];
                            int origIdx = schema.fields.indexOf(f);
                            switch (f.kind()) {
                                case UINT32  ->
                                    buf.putInt(off, ((Number) vals[origIdx]).intValue());
                                case INT64, UINT64 ->
                                    buf.putLong(off, ((Number) vals[origIdx]).longValue());
                                case FLOAT64 ->
                                    buf.putDouble(off, ((Number) vals[origIdx]).doubleValue());
                                default -> { /* no VL in primitive projection */ }
                            }
                        }
                    }
                    int rc = H5.H5Dwrite(dset, memType,
                            HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                            HDF5Constants.H5P_DEFAULT, buf.array());
                    if (rc < 0) {
                        throw new Hdf5Errors.DatasetWriteException(
                                "H5Dwrite (primitives) failed for '%s'"
                                .formatted(datasetName));
                    }
                } finally {
                    if (memType >= 0) try { H5.H5Tclose(memType); } catch (Exception ig) {}
                }
            }

            // -- Pass 2: VL_STRING columns via H5Dwrite_VLStrings ----------
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                if (f.kind() != FieldKind.VL_STRING) continue;

                Object[] colData = new Object[count];
                for (int row = 0; row < count; row++) {
                    Object v = allVals[row][i];
                    colData[row] = (v instanceof String s) ? s
                                 : (v == null ? "" : v.toString());
                }

                long memType = -1;
                try {
                    memType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND,
                                           FieldKind.VL_STRING.byteSize);
                    H5.H5Tinsert(memType, f.name(), 0, strType);
                    int rc = H5.H5Dwrite_VLStrings(dset, memType,
                            HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                            HDF5Constants.H5P_DEFAULT, colData);
                    if (rc < 0) {
                        throw new Hdf5Errors.DatasetWriteException(
                                "H5Dwrite_VLStrings failed for '%s' in '%s'"
                                .formatted(f.name(), datasetName));
                    }
                } finally {
                    if (memType >= 0) try { H5.H5Tclose(memType); } catch (Exception ig) {}
                }
            }

            // -- Pass 3: VL_BYTES columns via FFM (bypass translate_wbuf) ---
            // Build a compound memtype containing only this one VL_BYTES field
            // and call the native C H5Dwrite directly via the FFM API.
            // This avoids the HDF5 1.14 JNI translate_wbuf SIGSEGV entirely.
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                if (f.kind() != FieldKind.VL_BYTES) continue;

                byte[][] colData = new byte[count][];
                for (int row = 0; row < count; row++) {
                    Object v = allVals[row][i];
                    colData[row] = (v instanceof byte[] b) ? b : new byte[0];
                }

                long memType = -1;
                try {
                    memType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND,
                                           FieldKind.VL_BYTES.byteSize);
                    H5.H5Tinsert(memType, f.name(), 0, vlBytesType);
                    VlBytesFFM.write(dset, memType,
                            HDF5Constants.H5S_ALL, count, colData);
                } finally {
                    if (memType >= 0) try { H5.H5Tclose(memType); } catch (Exception ig) {}
                }
            }

        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException(
                    "compound write '%s' failed: %s"
                    .formatted(datasetName, e.getMessage()));
        } finally {
            if (dset >= 0)        try { H5.H5Dclose(dset);         } catch (Exception ig) {}
            if (dspace >= 0)      try { H5.H5Sclose(dspace);       } catch (Exception ig) {}
            if (fileType >= 0)    try { H5.H5Tclose(fileType);     } catch (Exception ig) {}
            if (vlBytesType >= 0) try { H5.H5Tclose(vlBytesType);  } catch (Exception ig) {}
            if (strType >= 0)     try { H5.H5Tclose(strType);      } catch (Exception ig) {}
            owner.unlockForWriting();
        }
    }

    /** Write an empty (zero-row) compound dataset. */
    private static void writeEmptyCompoundDataset(Hdf5Group parent,
                                                   String datasetName,
                                                   Schema schema) {
        Hdf5File owner = parent.owningFile();
        owner.lockForWriting();
        long strType = -1, vlBytesType = -1, ctype = -1, dspace = -1, dset = -1;
        try {
            strType = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(strType, HDF5Constants.H5T_VARIABLE);
            vlBytesType = H5.H5Tvlen_create(HDF5Constants.H5T_NATIVE_UCHAR);
            ctype = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                long t = switch (f.kind()) {
                    case VL_STRING -> strType;
                    case VL_BYTES  -> vlBytesType;
                    default        -> f.kind().nativeType;
                };
                H5.H5Tinsert(ctype, f.name(), schema.offsets[i], t);
            }
            dspace = H5.H5Screate_simple(1, new long[]{0}, null);
            dset = H5.H5Dcreate(parent.getGroupId(), datasetName, ctype, dspace,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT);
            if (dset < 0) {
                throw new Hdf5Errors.Hdf5Exception(
                        "H5Dcreate failed for empty compound '%s'"
                        .formatted(datasetName), null);
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException(
                    "empty compound write '%s' failed: %s"
                    .formatted(datasetName, e.getMessage()));
        } finally {
            if (dset >= 0)        try { H5.H5Dclose(dset);         } catch (Exception ig) {}
            if (dspace >= 0)      try { H5.H5Sclose(dspace);       } catch (Exception ig) {}
            if (ctype >= 0)       try { H5.H5Tclose(ctype);        } catch (Exception ig) {}
            if (vlBytesType >= 0) try { H5.H5Tclose(vlBytesType);  } catch (Exception ig) {}
            if (strType >= 0)     try { H5.H5Tclose(strType);      } catch (Exception ig) {}
            owner.unlockForWriting();
        }
    }

    // -- Read (primitive fields only; VL fields decode as "") ----------

    /**
     * Read a compound dataset returning only the primitive (non-VL)
     * fields. VL_STRING fields are returned as empty strings and
     * VL_BYTES fields as empty byte arrays. Use {@link #readCompoundFull}
     * to also decode the VL fields.
     *
     * @param parent       the group that owns the dataset
     * @param datasetName  the dataset name inside {@code parent}
     * @param schema       the full schema describing the on-disk layout
     * @return  one {@code Object[]} per record, in field order; an
     *          empty list if the dataset is missing or empty
     */
    public static List<Object[]> readCompoundPrimitives(Hdf5Group parent,
                                                          String datasetName,
                                                          Schema schema) {
        Hdf5File owner = parent.owningFile();
        owner.lockForReading();
        long dset = -1, memType = -1;
        try {
            dset = H5.H5Dopen(parent.getGroupId(), datasetName, HDF5Constants.H5P_DEFAULT);
            if (dset < 0) return List.of();

            long fspace = H5.H5Dget_space(dset);
            long[] dims = {0};
            H5.H5Sget_simple_extent_dims(fspace, dims, null);
            int count = (int) dims[0];
            H5.H5Sclose(fspace);

            Schema primSchema = primitiveProjection(schema);
            if (primSchema.fields.isEmpty() || count == 0) {
                return placeholders(schema, count);
            }

            memType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, primSchema.totalSize);
            for (int i = 0; i < primSchema.fields.size(); i++) {
                Field f = primSchema.fields.get(i);
                H5.H5Tinsert(memType, f.name(), primSchema.offsets[i], f.kind().nativeType);
            }

            byte[] buf = new byte[primSchema.totalSize * count];
            int rc = H5.H5Dread(dset, memType, HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                    HDF5Constants.H5P_DEFAULT, buf);
            if (rc < 0) return placeholders(schema, count);

            ByteBuffer bb = ByteBuffer.wrap(buf).order(ByteOrder.nativeOrder());
            List<Object[]> out = new ArrayList<>(count);
            for (int row = 0; row < count; row++) {
                Object[] rec = new Object[schema.fields.size()];
                for (int i = 0; i < schema.fields.size(); i++) {
                    Field f = schema.fields.get(i);
                    int primIdx = primSchema.fields.indexOf(f);
                    if (primIdx < 0) {
                        rec[i] = "";
                    } else {
                        int off = row * primSchema.totalSize + primSchema.offsets[primIdx];
                        rec[i] = switch (f.kind()) {
                            case UINT32  -> bb.getInt(off);
                            case INT64, UINT64 -> bb.getLong(off);
                            case FLOAT64 -> bb.getDouble(off);
                            default      -> ""; // unreachable
                        };
                    }
                }
                out.add(rec);
            }
            return out;
        } catch (HDF5LibraryException e) {
            return List.of();
        } finally {
            if (memType >= 0) try { H5.H5Tclose(memType); } catch (Exception ignored) {}
            if (dset >= 0)    try { H5.H5Dclose(dset);    } catch (Exception ignored) {}
            owner.unlockForReading();
        }
    }

    // -- Extendable compound datasets (primitive kinds only) -----------

    private static void requirePrimitiveSchema(Schema schema, String datasetName) {
        for (Field f : schema.fields) {
            if (f.kind() == FieldKind.VL_STRING || f.kind() == FieldKind.VL_BYTES) {
                throw new UnsupportedOperationException(
                    "extendable compound '" + datasetName
                    + "': variable-length fields are not supported; primitive kinds only");
            }
        }
    }

    private static long compoundType(Schema schema) throws HDF5LibraryException {
        long ctype = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
        for (int i = 0; i < schema.fields.size(); i++) {
            Field f = schema.fields.get(i);
            H5.H5Tinsert(ctype, f.name(), schema.offsets[i], f.kind().nativeType);
        }
        return ctype;
    }

    private static byte[] packRows(Schema schema, List<Object[]> rows) {
        ByteBuffer buf = ByteBuffer.allocate(schema.totalSize * rows.size())
                .order(ByteOrder.nativeOrder());
        for (int row = 0; row < rows.size(); row++) {
            Object[] vals = rows.get(row);
            int base = row * schema.totalSize;
            for (int i = 0; i < schema.fields.size(); i++) {
                int off = base + schema.offsets[i];
                switch (schema.fields.get(i).kind()) {
                    case UINT32 -> buf.putInt(off, ((Number) vals[i]).intValue());
                    case INT64, UINT64 -> buf.putLong(off, ((Number) vals[i]).longValue());
                    case FLOAT64 -> buf.putDouble(off, ((Number) vals[i]).doubleValue());
                    default -> { }
                }
            }
        }
        return buf.array();
    }

    /**
     * Create an empty compound dataset with an unlimited first dimension,
     * chunked in {@code chunkRows} records. Rows are added with
     * {@link #appendCompoundRows}. Primitive field kinds only.
     */
    public static void createExtendableCompound(Hdf5Group parent, String datasetName,
                                                Schema schema, int chunkRows) {
        requirePrimitiveSchema(schema, datasetName);
        if (chunkRows <= 0) {
            throw new IllegalArgumentException("chunkRows must be > 0");
        }
        Hdf5File owner = parent.owningFile();
        owner.lockForWriting();
        long ctype = -1, dspace = -1, plist = -1, dset = -1;
        try {
            ctype = compoundType(schema);
            dspace = H5.H5Screate_simple(1, new long[]{0},
                    new long[]{HDF5Constants.H5S_UNLIMITED});
            plist = H5.H5Pcreate(HDF5Constants.H5P_DATASET_CREATE);
            H5.H5Pset_chunk(plist, 1, new long[]{chunkRows});
            dset = H5.H5Dcreate(parent.getGroupId(), datasetName, ctype, dspace,
                    HDF5Constants.H5P_DEFAULT, plist, HDF5Constants.H5P_DEFAULT);
            if (dset < 0) {
                throw new Hdf5Errors.Hdf5Exception(
                        "H5Dcreate failed for extendable compound '%s'".formatted(datasetName), null);
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException(
                    "extendable compound create '%s' failed: %s".formatted(datasetName, e.getMessage()));
        } finally {
            if (dset >= 0)   try { H5.H5Dclose(dset);   } catch (Exception ig) {}
            if (plist >= 0)  try { H5.H5Pclose(plist);  } catch (Exception ig) {}
            if (dspace >= 0) try { H5.H5Sclose(dspace); } catch (Exception ig) {}
            if (ctype >= 0)  try { H5.H5Tclose(ctype);  } catch (Exception ig) {}
            owner.unlockForWriting();
        }
    }

    /**
     * Append rows ({@code Object[]} per record, field order) to a dataset
     * created by {@link #createExtendableCompound}.
     */
    public static void appendCompoundRows(Hdf5Group parent, String datasetName,
                                          Schema schema, List<Object[]> rows) {
        requirePrimitiveSchema(schema, datasetName);
        if (rows.isEmpty()) return;
        Hdf5File owner = parent.owningFile();
        owner.lockForWriting();
        long ctype = -1, dset = -1, fspace = -1, mspace = -1;
        try {
            dset = H5.H5Dopen(parent.getGroupId(), datasetName, HDF5Constants.H5P_DEFAULT);
            if (dset < 0) {
                throw new Hdf5Errors.DatasetOpenException(datasetName);
            }
            long cur = currentCount(dset);
            long n = rows.size();
            H5.H5Dset_extent(dset, new long[]{cur + n});
            fspace = H5.H5Dget_space(dset);
            H5.H5Sselect_hyperslab(fspace, HDF5Constants.H5S_SELECT_SET,
                    new long[]{cur}, null, new long[]{n}, null);
            mspace = H5.H5Screate_simple(1, new long[]{n}, null);
            ctype = compoundType(schema);
            int rc = H5.H5Dwrite(dset, ctype, mspace, fspace,
                    HDF5Constants.H5P_DEFAULT, packRows(schema, rows));
            if (rc < 0) {
                throw new Hdf5Errors.DatasetWriteException(
                        "H5Dwrite (append) failed for compound '%s'".formatted(datasetName));
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException(
                    "compound append '%s' failed: %s".formatted(datasetName, e.getMessage()));
        } finally {
            if (mspace >= 0) try { H5.H5Sclose(mspace); } catch (Exception ig) {}
            if (fspace >= 0) try { H5.H5Sclose(fspace); } catch (Exception ig) {}
            if (ctype >= 0)  try { H5.H5Tclose(ctype);  } catch (Exception ig) {}
            if (dset >= 0)   try { H5.H5Dclose(dset);   } catch (Exception ig) {}
            owner.unlockForWriting();
        }
    }

    private static long currentCount(long dset) throws HDF5LibraryException {
        long space = H5.H5Dget_space(dset);
        try {
            long[] dims = {0};
            H5.H5Sget_simple_extent_dims(space, dims, null);
            return dims[0];
        } finally {
            H5.H5Sclose(space);
        }
    }

    /** @return the record count of an existing compound dataset. */
    public static long rowCount(Hdf5Group parent, String datasetName) {
        Hdf5File owner = parent.owningFile();
        owner.lockForReading();
        long dset = -1;
        try {
            dset = H5.H5Dopen(parent.getGroupId(), datasetName, HDF5Constants.H5P_DEFAULT);
            if (dset < 0) return 0;
            return currentCount(dset);
        } catch (HDF5LibraryException e) {
            return 0;
        } finally {
            if (dset >= 0) try { H5.H5Dclose(dset); } catch (Exception ig) {}
            owner.unlockForReading();
        }
    }

    /** @return {@code true} when the dataset exists with an unlimited
     *  first dimension. */
    public static boolean isExtendable(Hdf5Group parent, String datasetName) {
        Hdf5File owner = parent.owningFile();
        owner.lockForReading();
        long dset = -1, space = -1;
        try {
            dset = H5.H5Dopen(parent.getGroupId(), datasetName, HDF5Constants.H5P_DEFAULT);
            if (dset < 0) return false;
            space = H5.H5Dget_space(dset);
            long[] dims = {0}, maxdims = {0};
            H5.H5Sget_simple_extent_dims(space, dims, maxdims);
            return maxdims[0] == HDF5Constants.H5S_UNLIMITED;
        } catch (HDF5LibraryException e) {
            return false;
        } finally {
            if (space >= 0) try { H5.H5Sclose(space); } catch (Exception ig) {}
            if (dset >= 0)  try { H5.H5Dclose(dset);  } catch (Exception ig) {}
            owner.unlockForReading();
        }
    }

    // -- Read (full path) ----------------------------------------------

    /**
     * Read a compound dataset returning all fields. Uses a split-read strategy
     * for HDF5 1.14 compatibility when any VL field (VL_STRING or VL_BYTES) is
     * present:
     * <ol>
     *   <li>Read primitive (non-VL) fields via {@code H5Dread(byte[])} with a
     *       projection memory type that excludes all VL fields.</li>
     *   <li>Read each VL_STRING column via
     *       {@link H5#H5Dread_VLStrings(long,long,long,long,long,Object[])}.</li>
     *   <li>Read each VL_BYTES column via the FFM helper
     *       {@link VlBytesFFM#read(long, long, long, int)} which calls
     *       the native C {@code H5Dread} directly, bypassing the JNI
     *       {@code translate_rbuf} interception entirely.</li>
     * </ol>
     * When no VL fields are present, uses the original full-compound
     * byte-buffer approach.
     */
    public static List<Object[]> readCompoundFull(Hdf5Group parent,
                                                    String datasetName,
                                                    Schema schema) {
        Hdf5File owner = parent.owningFile();
        owner.lockForReading();
        long dset = -1, memType = -1, strType = -1, vlBytesType = -1, fspace = -1;
        int count = 0;
        try {
            dset = H5.H5Dopen(parent.getGroupId(), datasetName,
                              HDF5Constants.H5P_DEFAULT);
            if (dset < 0) return List.of();

            fspace = H5.H5Dget_space(dset);
            long[] dims = {0};
            H5.H5Sget_simple_extent_dims(fspace, dims, null);
            count = (int) dims[0];
            if (count == 0) return List.of();

            strType = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(strType, HDF5Constants.H5T_VARIABLE);
            vlBytesType = H5.H5Tvlen_create(HDF5Constants.H5T_NATIVE_UCHAR);

            boolean hasVl = schema.fields.stream()
                    .anyMatch(f -> f.kind() == FieldKind.VL_STRING
                                || f.kind() == FieldKind.VL_BYTES);

            if (!hasVl) {
                // Original full-compound path -- safe in 1.14 without VL fields
                memType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
                for (int i = 0; i < schema.fields.size(); i++) {
                    Field f = schema.fields.get(i);
                    H5.H5Tinsert(memType, f.name(), schema.offsets[i],
                                 f.kind().nativeType);
                }

                byte[] buf = new byte[schema.totalSize * count];
                int rc = H5.H5Dread(dset, memType,
                                    HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                                    HDF5Constants.H5P_DEFAULT, buf);
                if (rc < 0) return List.of();

                ByteBuffer bb = ByteBuffer.wrap(buf).order(ByteOrder.nativeOrder());
                List<Object[]> out = new ArrayList<>(count);
                for (int row = 0; row < count; row++) {
                    Object[] rec = new Object[schema.fields.size()];
                    for (int i = 0; i < schema.fields.size(); i++) {
                        Field f = schema.fields.get(i);
                        int off = row * schema.totalSize + schema.offsets[i];
                        rec[i] = switch (f.kind()) {
                            case UINT32  -> bb.getInt(off);
                            case INT64, UINT64 -> bb.getLong(off);
                            case FLOAT64 -> bb.getDouble(off);
                            default      -> null; // unreachable: no VL in this branch
                        };
                    }
                    out.add(rec);
                }
                return out;
            }

            // -- Split read path for schemas with any VL field -------------
            Object[][] result = new Object[count][schema.fields.size()];

            // Pass 1: primitive (non-VL) fields via byte buffer
            Schema primSchema = primitiveProjection(schema);
            if (!primSchema.fields.isEmpty()) {
                long primMemType = -1;
                try {
                    primMemType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND,
                                               primSchema.totalSize);
                    for (int i = 0; i < primSchema.fields.size(); i++) {
                        Field f = primSchema.fields.get(i);
                        H5.H5Tinsert(primMemType, f.name(),
                                     primSchema.offsets[i], f.kind().nativeType);
                    }
                    byte[] primBuf = new byte[primSchema.totalSize * count];
                    int rc = H5.H5Dread(dset, primMemType,
                            HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                            HDF5Constants.H5P_DEFAULT, primBuf);
                    if (rc < 0) return List.of();

                    ByteBuffer bb = ByteBuffer.wrap(primBuf)
                                              .order(ByteOrder.nativeOrder());
                    for (int row = 0; row < count; row++) {
                        for (int pi = 0; pi < primSchema.fields.size(); pi++) {
                            Field f = primSchema.fields.get(pi);
                            int off = row * primSchema.totalSize
                                    + primSchema.offsets[pi];
                            int origIdx = schema.fields.indexOf(f);
                            result[row][origIdx] = switch (f.kind()) {
                                case UINT32  -> bb.getInt(off);
                                case INT64, UINT64 -> bb.getLong(off);
                                case FLOAT64 -> bb.getDouble(off);
                                default -> null;
                            };
                        }
                    }
                } finally {
                    if (primMemType >= 0)
                        try { H5.H5Tclose(primMemType); } catch (Exception ig) {}
                }
            }

            // Pass 2: VL_STRING columns via H5Dread_VLStrings
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                if (f.kind() != FieldKind.VL_STRING) continue;

                Object[] colData = new Object[count];
                long strMemType = -1;
                try {
                    strMemType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND,
                                              FieldKind.VL_STRING.byteSize);
                    H5.H5Tinsert(strMemType, f.name(), 0, strType);
                    int rc = H5.H5Dread_VLStrings(dset, strMemType,
                            HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                            HDF5Constants.H5P_DEFAULT, colData);
                    if (rc < 0) {
                        java.util.Arrays.fill(colData, "");
                    }
                } finally {
                    if (strMemType >= 0)
                        try { H5.H5Tclose(strMemType); } catch (Exception ig) {}
                }
                for (int row = 0; row < count; row++) {
                    result[row][i] = colData[row] instanceof String s ? s : "";
                }
            }

            // Pass 3: VL_BYTES columns via FFM (bypass translate_rbuf)
            // Call native C H5Dread directly to read hvl_t compound fields
            // without triggering the JNI translate_rbuf crash.
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                if (f.kind() != FieldKind.VL_BYTES) continue;

                long vlMemType = -1;
                try {
                    vlMemType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND,
                                             FieldKind.VL_BYTES.byteSize);
                    H5.H5Tinsert(vlMemType, f.name(), 0, vlBytesType);
                    byte[][] colData = VlBytesFFM.read(dset, vlMemType,
                            HDF5Constants.H5S_ALL, count);
                    for (int row = 0; row < count; row++) {
                        result[row][i] = colData[row];
                    }
                } finally {
                    if (vlMemType >= 0)
                        try { H5.H5Tclose(vlMemType); } catch (Exception ig) {}
                }
            }

            // Assemble output, filling nulls with defaults
            List<Object[]> out = new ArrayList<>(count);
            for (int row = 0; row < count; row++) {
                Object[] rec = result[row];
                for (int i = 0; i < schema.fields.size(); i++) {
                    if (rec[i] == null) {
                        rec[i] = switch (schema.fields.get(i).kind()) {
                            case UINT32    -> 0;
                            case INT64, UINT64 -> 0L;
                            case FLOAT64   -> 0.0;
                            case VL_STRING -> "";
                            case VL_BYTES  -> new byte[0];
                        };
                    }
                }
                out.add(rec);
            }
            return out;

        } catch (HDF5LibraryException e) {
            return List.of();
        } finally {
            if (fspace >= 0)      try { H5.H5Sclose(fspace);       } catch (Exception ignored) {}
            if (memType >= 0)     try { H5.H5Tclose(memType);      } catch (Exception ignored) {}
            if (vlBytesType >= 0) try { H5.H5Tclose(vlBytesType);  } catch (Exception ignored) {}
            if (strType >= 0)     try { H5.H5Tclose(strType);      } catch (Exception ignored) {}
            if (dset >= 0)        try { H5.H5Dclose(dset);         } catch (Exception ignored) {}
            owner.unlockForReading();
        }
    }

    /** Projection: only primitive (non-VL) fields. */
    private static Schema primitiveProjection(Schema full) {
        List<Field> out = new ArrayList<>();
        for (Field f : full.fields) {
            if (f.kind() != FieldKind.VL_STRING && f.kind() != FieldKind.VL_BYTES)
                out.add(f);
        }
        return new Schema(out);
    }

    private static List<Object[]> placeholders(Schema schema, int count) {
        List<Object[]> out = new ArrayList<>(count);
        for (int row = 0; row < count; row++) {
            Object[] rec = new Object[schema.fields.size()];
            for (int i = 0; i < schema.fields.size(); i++) {
                rec[i] = switch (schema.fields.get(i).kind()) {
                    case UINT32    -> 0;
                    case INT64, UINT64 -> 0L;
                    case FLOAT64   -> 0.0;
                    case VL_STRING -> "";
                    case VL_BYTES  -> new byte[0];
                };
            }
            out.add(rec);
        }
        return out;
    }
}
