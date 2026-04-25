/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.hdf5;

import sun.misc.Unsafe;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;

/**
 * Pool of {@code sun.misc.Unsafe}-allocated byte blobs for VL_BYTES
 * compound fields. Mirrors {@link NativeStringPool}: JHI5 1.10.x
 * cannot marshal {@code hvl_t} slots inside a compound dataset from
 * Java objects, so this pool hands out pointers the caller packs
 * into the raw compound byte buffer as {@code {size_t len; void* p}}.
 *
 * <p>{@link #close()} must run after {@code H5Dwrite} so the native
 * memory stays valid for the duration of the write.</p>
 *
 * @since 1.0
 */
public final class NativeBytesPool implements AutoCloseable {

    private static final Unsafe UNSAFE = obtainUnsafe();

    private final List<Long> allocations = new ArrayList<>();

    /** Copy {@code bytes} (or {@code new byte[0]} if null) into native
     *  memory; return its address. */
    public long addBytes(byte[] bytes) {
        byte[] src = bytes == null ? new byte[0] : bytes;
        long addr = UNSAFE.allocateMemory(Math.max(1, src.length));
        for (int i = 0; i < src.length; i++) {
            UNSAFE.putByte(addr + i, src[i]);
        }
        allocations.add(addr);
        return addr;
    }

    /** Read {@code len} bytes from native address {@code addr}. */
    public static byte[] readBytes(long addr, long len) {
        byte[] out = new byte[Math.toIntExact(len)];
        for (int i = 0; i < out.length; i++) {
            out[i] = UNSAFE.getByte(addr + i);
        }
        return out;
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
