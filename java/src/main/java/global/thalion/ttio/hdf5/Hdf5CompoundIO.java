/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * Write/read helper for the fixed compound metadata datasets described
 * in format-spec §6. Supports variable-length strings in writes via a
 * {@link NativeStringPool}; reads recover only the primitive fields,
 * returning empty strings for VL slots (see {@link global.thalion.ttio.SpectralDataset}
 * for the read-path rationale).
 *
 *
 */
public final class Hdf5CompoundIO {

    private Hdf5CompoundIO() {}

    public enum FieldKind {
        UINT32(4, HDF5Constants.H5T_NATIVE_UINT32),
        INT64(8, HDF5Constants.H5T_NATIVE_INT64),
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

    public record Field(String name, FieldKind kind) {}

    public static final class Schema {
        public final List<Field> fields;
        public final int[] offsets;
        public final int totalSize;

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

    /** Packs row values into the compound byte slot. */
    @FunctionalInterface
    public interface RowPacker {
        /**
         * Return boxed field values for record {@code row}. Strings are
         * returned as {@link Long} native pointers obtained from
         * {@link NativeStringPool#addString(String)}; primitives are
         * returned as their boxed numeric types matching the field kind.
         */
        Object[] valuesFor(int row, NativeStringPool pool);
    }

    // ── Standard schemas (format-spec §6.1–§6.3) ────────────────────

    public static Schema identificationSchema() {
        return new Schema(List.of(
                new Field("run_name", FieldKind.VL_STRING),
                new Field("spectrum_index", FieldKind.UINT32),
                new Field("chemical_entity", FieldKind.VL_STRING),
                new Field("confidence_score", FieldKind.FLOAT64),
                new Field("evidence_chain_json", FieldKind.VL_STRING)));
    }

    public static Schema quantificationSchema() {
        return new Schema(List.of(
                new Field("chemical_entity", FieldKind.VL_STRING),
                new Field("sample_ref", FieldKind.VL_STRING),
                new Field("abundance", FieldKind.FLOAT64),
                new Field("normalization_method", FieldKind.VL_STRING)));
    }

    public static Schema provenanceSchema() {
        return new Schema(List.of(
                new Field("timestamp_unix", FieldKind.INT64),
                new Field("software", FieldKind.VL_STRING),
                new Field("parameters_json", FieldKind.VL_STRING),
                new Field("input_refs_json", FieldKind.VL_STRING),
                new Field("output_refs_json", FieldKind.VL_STRING)));
    }

    // ── Write ───────────────────────────────────────────────────────

    public static void writeCompoundDataset(Hdf5Group parent, String datasetName,
                                             Schema schema, int count,
                                             RowPacker packer) {
        Hdf5File owner = parent.owningFile();
        owner.lockForWriting();
        long strType = -1, vlBytesType = -1, ctype = -1, dspace = -1, dset = -1;
        try (NativeStringPool pool = new NativeStringPool();
             NativeBytesPool bytesPool = new NativeBytesPool()) {
            strType = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
            H5.H5Tset_size(strType, HDF5Constants.H5T_VARIABLE);
            vlBytesType = H5.H5Tvlen_create(HDF5Constants.H5T_NATIVE_UCHAR);

            ctype = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                long t = switch (f.kind()) {
                    case VL_STRING -> strType;
                    case VL_BYTES -> vlBytesType;
                    default -> f.kind().nativeType;
                };
                H5.H5Tinsert(ctype, f.name(), schema.offsets[i], t);
            }

            ByteBuffer buf = ByteBuffer.allocate(schema.totalSize * count)
                    .order(ByteOrder.nativeOrder());
            for (int row = 0; row < count; row++) {
                Object[] vals = packer.valuesFor(row, pool);
                int base = row * schema.totalSize;
                for (int i = 0; i < schema.fields.size(); i++) {
                    int off = base + schema.offsets[i];
                    switch (schema.fields.get(i).kind()) {
                        case VL_STRING -> buf.putLong(off, (Long) vals[i]);
                        case VL_BYTES -> {
                            byte[] b = (byte[]) vals[i];
                            if (b == null) b = new byte[0];
                            long addr = bytesPool.addBytes(b);
                            // hvl_t = { size_t len; void* p } in native order.
                            buf.putLong(off, b.length);
                            buf.putLong(off + 8, addr);
                        }
                        case UINT32 -> buf.putInt(off, ((Number) vals[i]).intValue());
                        case INT64 -> buf.putLong(off, ((Number) vals[i]).longValue());
                        case FLOAT64 -> buf.putDouble(off, ((Number) vals[i]).doubleValue());
                    }
                }
            }

            dspace = H5.H5Screate_simple(1, new long[]{count}, null);
            dset = H5.H5Dcreate(parent.getGroupId(), datasetName, ctype, dspace,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT);
            if (dset < 0) {
                throw new Hdf5Errors.Hdf5Exception(
                        "H5Dcreate failed for compound '" + datasetName + "'", null);
            }
            int rc = H5.H5Dwrite(dset, ctype, HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                    HDF5Constants.H5P_DEFAULT, buf.array());
            if (rc < 0) {
                throw new Hdf5Errors.DatasetWriteException(
                        "H5Dwrite failed for compound '" + datasetName + "'");
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.DatasetWriteException(
                    "compound write '" + datasetName + "' failed: " + e.getMessage());
        } finally {
            if (dset >= 0) try { H5.H5Dclose(dset); } catch (Exception ignored) {}
            if (dspace >= 0) try { H5.H5Sclose(dspace); } catch (Exception ignored) {}
            if (ctype >= 0) try { H5.H5Tclose(ctype); } catch (Exception ignored) {}
            if (vlBytesType >= 0) try { H5.H5Tclose(vlBytesType); } catch (Exception ignored) {}
            if (strType >= 0) try { H5.H5Tclose(strType); } catch (Exception ignored) {}
            owner.unlockForWriting();
        }
    }

    // ── Read (primitive fields only; VL fields decode as "") ────────

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

            // Build a primitive-only projection so JHI5 accepts byte[] read
            Schema primSchema = primitiveProjection(schema);
            if (primSchema.fields.isEmpty() || count == 0) {
                // All-VL compound — no recoverable fields; emit placeholders.
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
                            case UINT32 -> bb.getInt(off);
                            case INT64 -> bb.getLong(off);
                            case FLOAT64 -> bb.getDouble(off);
                            default -> ""; // unreachable
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
            if (dset >= 0) try { H5.H5Dclose(dset); } catch (Exception ignored) {}
            owner.unlockForReading();
        }
    }

    // ── Read (full path — handles VL_BYTES; VL_STRING still "") ────

    /** Read a compound dataset returning all fields. Primitive fields
     *  decode normally; VL_STRING fields decode as {@code ""} (JHI5
     *  limitation we haven't worked around on the read side);
     *  VL_BYTES fields decode as real {@code byte[]} via hvl_t
     *  walk + H5Dvlen_reclaim. */
    public static List<Object[]> readCompoundFull(Hdf5Group parent,
                                                    String datasetName,
                                                    Schema schema) {
        Hdf5File owner = parent.owningFile();
        owner.lockForReading();
        long dset = -1, memType = -1, strType = -1, vlBytesType = -1, fspace = -1;
        byte[] buf = null;
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

            memType = H5.H5Tcreate(HDF5Constants.H5T_COMPOUND, schema.totalSize);
            for (int i = 0; i < schema.fields.size(); i++) {
                Field f = schema.fields.get(i);
                long t = switch (f.kind()) {
                    case VL_STRING -> strType;
                    case VL_BYTES -> vlBytesType;
                    default -> f.kind().nativeType;
                };
                H5.H5Tinsert(memType, f.name(), schema.offsets[i], t);
            }

            buf = new byte[schema.totalSize * count];
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
                        case UINT32 -> bb.getInt(off);
                        case INT64 -> bb.getLong(off);
                        case FLOAT64 -> bb.getDouble(off);
                        case VL_STRING -> {
                            // M82.4: HDF5 stores VL_STRING as a char*
                            // pointer (8 bytes) at the field offset.
                            // Walk bytes from the native address until
                            // the null terminator; decode UTF-8.
                            long addr = bb.getLong(off);
                            yield addr == 0 ? "" : readCStringUtf8(addr);
                        }
                        case VL_BYTES -> {
                            long len = bb.getLong(off);
                            long addr = bb.getLong(off + 8);
                            yield len == 0 || addr == 0
                                ? new byte[0]
                                : NativeBytesPool.readBytes(addr, len);
                        }
                    };
                }
                out.add(rec);
            }
            return out;
        } catch (HDF5LibraryException e) {
            return List.of();
        } finally {
            if (buf != null && memType >= 0 && fspace >= 0) {
                try {
                    H5.H5Dvlen_reclaim(memType, fspace, HDF5Constants.H5P_DEFAULT,
                                       buf);
                } catch (Exception ignored) {}
            }
            if (fspace >= 0) try { H5.H5Sclose(fspace); } catch (Exception ignored) {}
            if (memType >= 0) try { H5.H5Tclose(memType); } catch (Exception ignored) {}
            if (vlBytesType >= 0) try { H5.H5Tclose(vlBytesType); } catch (Exception ignored) {}
            if (strType >= 0) try { H5.H5Tclose(strType); } catch (Exception ignored) {}
            if (dset >= 0) try { H5.H5Dclose(dset); } catch (Exception ignored) {}
            owner.unlockForReading();
        }
    }

    /** v0.11 M82.4: Read a C-style null-terminated UTF-8 string from
     *  a native address. Uses {@link NativeBytesPool#readBytes} to
     *  walk bytes one at a time via {@code Unsafe.getByte}; stops at
     *  the first 0x00 byte. JHI5 1.10 doesn't expose VL_STRING
     *  marshalling out of compounds, but the underlying char*
     *  pointers are sitting in the H5Dread buffer — we just have to
     *  dereference them ourselves.
     *
     *  Capped at 64 KiB per string to bound runaway reads on a
     *  malformed buffer. Genomic identifiers (CIGAR, read names,
     *  chromosome names) are well under that limit. */
    private static String readCStringUtf8(long addr) {
        final int MAX = 65536;
        byte[] tmp = new byte[256];
        int n = 0;
        while (n < MAX) {
            byte b = sun.misc.Unsafe.class
                .cast(unsafeInstance()).getByte(addr + n);
            if (b == 0) break;
            if (n == tmp.length) {
                byte[] grown = new byte[tmp.length * 2];
                System.arraycopy(tmp, 0, grown, 0, tmp.length);
                tmp = grown;
            }
            tmp[n++] = b;
        }
        return new String(tmp, 0, n, java.nio.charset.StandardCharsets.UTF_8);
    }

    private static sun.misc.Unsafe unsafeInstance() {
        try {
            java.lang.reflect.Field f =
                sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            return (sun.misc.Unsafe) f.get(null);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private static Schema primitiveProjection(Schema full) {
        List<Field> prims = new ArrayList<>();
        for (Field f : full.fields) {
            if (f.kind() != FieldKind.VL_STRING
                    && f.kind() != FieldKind.VL_BYTES) {
                prims.add(f);
            }
        }
        return new Schema(prims);
    }

    private static List<Object[]> placeholders(Schema schema, int count) {
        List<Object[]> out = new ArrayList<>(count);
        for (int row = 0; row < count; row++) {
            Object[] rec = new Object[schema.fields.size()];
            for (int i = 0; i < schema.fields.size(); i++) {
                rec[i] = switch (schema.fields.get(i).kind()) {
                    case UINT32 -> 0;
                    case INT64 -> 0L;
                    case FLOAT64 -> 0.0;
                    case VL_STRING -> "";
                    case VL_BYTES -> new byte[0];
                };
            }
            out.add(rec);
        }
        return out;
    }
}
