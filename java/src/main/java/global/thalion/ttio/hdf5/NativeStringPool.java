/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

/**
 * String pass-through for HDF5 1.14 compatibility.
 *
 * <p>In HDF5 1.10, {@code H5Dwrite(byte[])} with a compound memory type
 * containing VL_STRING fields required raw C-string pointers in the byte
 * buffer. This class formerly allocated those pointers via
 * {@code sun.misc.Unsafe}. In HDF5 1.14, the JNI path detects VL_STRING
 * fields in the memory type and calls {@code GetObjectArrayElement},
 * expecting Java {@link String} objects — making the raw-pointer approach
 * crash.</p>
 *
 * <p>The write path now routes VL_STRING columns through
 * {@link hdf.hdf5lib.H5#H5Dwrite_VLStrings}, so this pool is reduced to a
 * no-op pass-through that returns the {@link String} directly. The
 * {@link AutoCloseable} contract is preserved for API compatibility.</p>
 *
 *
 */
public final class NativeStringPool implements AutoCloseable {

    /** Return {@code s} as-is (or empty string if null). No native allocation. */
    public String addString(String s) {
        return s == null ? "" : s;
    }

    @Override
    public void close() {
        // nothing to free
    }
}
