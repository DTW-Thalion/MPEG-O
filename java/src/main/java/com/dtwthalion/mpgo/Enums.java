/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

/**
 * Enumerations mirroring the ObjC {@code MPGOEnums.h} integer values.
 *
 * <p>Declaration order in each {@code enum} matches the ObjC
 * {@code NS_ENUM} integer values so that {@link Enum#ordinal()} is a
 * direct pass-through of the on-disk attribute. No translation table
 * can go stale.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOEnums.h}, Python {@code mpeg_o.enums}.</p>
 *
 * @since 0.6
 */
public final class Enums {

    private Enums() {}

    /** Numeric precision of a signal buffer.
     *
     * <p><b>Appendix B Gap 7:</b> this enum used to hold a
     * {@code HDF5Constants.H5T_NATIVE_*} id per constant, which made
     * the HDF5 JNI wrapper a load-time dependency of every consumer,
     * including non-HDF5 providers such as SQLite. The HDF5 type ids
     * have moved to {@code Hdf5Group.hdf5TypeFor(Precision)} so this
     * enum no longer pulls in the native library.</p>
     */
    public enum Precision {
        /** 32-bit IEEE 754 single-precision float (4 bytes). */
        FLOAT32(4),
        /** 64-bit IEEE 754 double-precision float (8 bytes). */
        FLOAT64(8),
        /** Signed 32-bit integer (4 bytes). */
        INT32(4),
        /** Signed 64-bit integer (8 bytes). */
        INT64(8),
        /** Unsigned 32-bit integer stored as signed {@code int} (4 bytes). */
        UINT32(4),
        /** 128-bit complex: two {@code double} values per element (16 bytes). */
        COMPLEX128(16);

        private final int elementSize;

        Precision(int elementSize) {
            this.elementSize = elementSize;
        }

        /** @return size in bytes of a single element at this precision. */
        public int elementSize() { return elementSize; }
    }

    /** Compression algorithm applied to a signal buffer. */
    public enum Compression {
        /** No compression; raw binary layout. */
        NONE,
        /** Deflate (zlib/gzip-compatible) compression. */
        ZLIB,
        /** LZ4 block compression. */
        LZ4,
        /** NumPRESS delta-integer compression for ordered m/z or retention-time arrays. */
        NUMPRESS_DELTA
    }

    /** Ion polarity for mass spectrometry. */
    public enum Polarity {
        /** Polarity not specified or not applicable. */
        UNKNOWN(0),
        /** Positive-ion mode. */
        POSITIVE(1),
        /** Negative-ion mode. */
        NEGATIVE(-1);

        private final int value;
        Polarity(int value) { this.value = value; }

        /** @return the integer on-disk representation of this polarity. */
        public int intValue() { return value; }

        /**
         * Resolve an integer on-disk value to a {@link Polarity} constant.
         *
         * @param v the integer value read from the file
         * @return the matching constant, or {@link #UNKNOWN} if unrecognised
         */
        public static Polarity fromInt(int v) {
            return switch (v) {
                case 1 -> POSITIVE;
                case -1 -> NEGATIVE;
                default -> UNKNOWN;
            };
        }
    }

    /** Axis sampling regularity. */
    public enum SamplingMode {
        /** Evenly-spaced samples (fixed step size). */
        UNIFORM,
        /** Arbitrarily-spaced samples (coordinate array required). */
        NON_UNIFORM
    }

    /** High-level acquisition scheme for a run. */
    public enum AcquisitionMode {
        /** Data-dependent acquisition, MS1 survey scan. */
        MS1_DDA,
        /** Data-dependent acquisition, MS2 fragmentation scan. */
        MS2_DDA,
        /** Data-independent acquisition. */
        DIA,
        /** Selected reaction monitoring. */
        SRM,
        /** One-dimensional NMR experiment. */
        NMR_1D,
        /** Two-dimensional NMR experiment. */
        NMR_2D,
        /** Mass spectrometry imaging. */
        IMAGING
    }

    /** Chromatogram kind. */
    public enum ChromatogramType {
        /** Total ion chromatogram. */
        TIC,
        /** Extracted ion chromatogram. */
        XIC,
        /** Selected reaction monitoring chromatogram. */
        SRM
    }

    /** Byte order of a signal buffer on disk. */
    public enum ByteOrder {
        /** Least-significant byte first (x86 native). */
        LITTLE_ENDIAN,
        /** Most-significant byte first (network order). */
        BIG_ENDIAN
    }

    /** Multi-level protection granularity (MPEG-G style). */
    public enum EncryptionLevel {
        /** No encryption applied. */
        NONE,
        /** Protection spans a complete dataset group. */
        DATASET_GROUP,
        /** Protection spans a single dataset. */
        DATASET,
        /** Protection spans a descriptor stream within a dataset. */
        DESCRIPTOR_STREAM,
        /** Protection spans a single access unit (finest granularity). */
        ACCESS_UNIT
    }
}
