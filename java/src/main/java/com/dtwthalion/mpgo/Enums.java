/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import hdf.hdf5lib.HDF5Constants;

/**
 * Enumerations mirroring the ObjC/Python value sets.
 * Ordinal values match the ObjC NS_ENUM values for cross-language parity.
 */
public final class Enums {

    private Enums() {}

    public enum Precision {
        INT32(4, HDF5Constants.H5T_NATIVE_INT32, 0),
        FLOAT32(4, HDF5Constants.H5T_NATIVE_FLOAT, 1),
        FLOAT64(8, HDF5Constants.H5T_NATIVE_DOUBLE, 2),
        INT64(8, HDF5Constants.H5T_NATIVE_INT64, 3),
        UINT32(4, HDF5Constants.H5T_NATIVE_UINT32, 4),
        UINT8(1, -1, 5),          // raw bytes, no native HDF5 type
        COMPLEX128(16, -1, 6);    // compound type, built at runtime

        private final int elementSize;
        private final long nativeTypeId;
        private final int hdf5Value;

        Precision(int elementSize, long nativeTypeId, int hdf5Value) {
            this.elementSize = elementSize;
            this.nativeTypeId = nativeTypeId;
            this.hdf5Value = hdf5Value;
        }

        public int elementSize() { return elementSize; }
        public long nativeTypeId() { return nativeTypeId; }
        public boolean isBuiltin() { return nativeTypeId >= 0; }
        public int hdf5Value() { return hdf5Value; }

        public static Precision fromHdf5Value(int v) {
            for (Precision p : values()) {
                if (p.hdf5Value == v) return p;
            }
            throw new IllegalArgumentException("Unknown HDF5 precision value: " + v);
        }
    }

    public enum Compression {
        NONE,
        ZLIB,
        LZ4,
        NUMPRESS_DELTA
    }

    public enum Polarity {
        UNKNOWN(0),
        POSITIVE(1),
        NEGATIVE(-1);

        private final int value;
        Polarity(int value) { this.value = value; }
        public int intValue() { return value; }

        public static Polarity fromInt(int v) {
            return switch (v) {
                case 1 -> POSITIVE;
                case -1 -> NEGATIVE;
                default -> UNKNOWN;
            };
        }
    }

    public enum SamplingMode {
        UNIFORM,
        NON_UNIFORM
    }

    public enum AcquisitionMode {
        MS1_DDA,
        MS2_DDA,
        DIA,
        SRM,
        NMR_1D,
        NMR_2D,
        IMAGING
    }

    public enum ChromatogramType {
        TIC,
        XIC,
        SRM
    }

    public enum ByteOrder {
        LITTLE_ENDIAN,
        BIG_ENDIAN
    }

    public enum EncryptionLevel {
        NONE,
        DATASET_GROUP,
        DATASET,
        DESCRIPTOR_STREAM,
        ACCESS_UNIT
    }
}
