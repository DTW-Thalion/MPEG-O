/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import sun.misc.Unsafe;

import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Pool of {@code sun.misc.Unsafe}-allocated, UTF-8 encoded, null-terminated
 * C strings.
 *
 * <p>Exists because the HDF5 Java native binding (JHI5 1.10.x) cannot
 * marshal variable-length string fields inside a compound dataset: its
 * {@code H5Dwrite(byte[])} path treats the buffer as opaque, which is
 * exactly what we need as long as the VL-string slots contain valid C
 * pointers. This pool hands out those pointers. {@link #close()} must
 * run after the {@code H5Dwrite} call so the native memory stays valid
 * for the duration of the write.</p>
 *
 * @since 0.6
 */
public final class NativeStringPool implements AutoCloseable {

    private static final Unsafe UNSAFE = obtainUnsafe();

    private final List<Long> allocations = new ArrayList<>();

    /** Copy {@code s} (or {@code ""} if null) into native memory. */
    public long addString(String s) {
        String src = s == null ? "" : s;
        byte[] bytes = src.getBytes(StandardCharsets.UTF_8);
        long addr = UNSAFE.allocateMemory(bytes.length + 1L);
        for (int i = 0; i < bytes.length; i++) {
            UNSAFE.putByte(addr + i, bytes[i]);
        }
        UNSAFE.putByte(addr + bytes.length, (byte) 0);
        allocations.add(addr);
        return addr;
    }

    @Override
    public void close() {
        for (long a : allocations) UNSAFE.freeMemory(a);
        allocations.clear();
    }

    private static Unsafe obtainUnsafe() {
        try {
            Field f = Unsafe.class.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            return (Unsafe) f.get(null);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }
}
