/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.ByteOrder;
import com.dtwthalion.mpgo.Enums.Compression;
import com.dtwthalion.mpgo.Enums.Precision;

/**
 * Describes how a {@link SignalArray} buffer is encoded on disk:
 * numeric precision, compression algorithm, and byte order.
 * Immutable value class.
 *
 * <p><b>API status:</b> Stable. The HDF5 compression level is a
 * provider-configuration concern and lives on
 * {@code Hdf5Provider.createDataset(..., compressionLevel)}, not on
 * this record.</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code MPGOEncodingSpec}, Python
 * {@code mpeg_o.encoding_spec.EncodingSpec}.</p>
 *
 * @param precision   Numeric precision.
 * @param compression Compression algorithm.
 * @param byteOrder   Byte order on disk.
 * @since 0.6
 */
public record EncodingSpec(
    Precision precision,
    Compression compression,
    ByteOrder byteOrder
) {

    /** @return size in bytes of one element at this precision. */
    public int elementSize() {
        return precision.elementSize();
    }
}
