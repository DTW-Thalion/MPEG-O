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
        FLOAT32(4, HDF5Constants.H5T_NATIVE_FLOAT),
        FLOAT64(8, HDF5Constants.H5T_NATIVE_DOUBLE),
        INT32(4, HDF5Constants.H5T_NATIVE_INT32),
        INT64(8, HDF5Constants.H5T_NATIVE_INT64),
        UINT32(4, HDF5Constants.H5T_NATIVE_UINT32),
        COMPLEX128(16, -1); // compound type, built at runtime

        private final int elementSize;
        private final long nativeTypeId;

        Precision(int elementSize, long nativeTypeId) {
            this.elementSize = elementSize;
            this.nativeTypeId = nativeTypeId;
        }

        public int elementSize() { return elementSize; }
        public long nativeTypeId() { return nativeTypeId; }
        public boolean isBuiltin() { return nativeTypeId >= 0; }
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
