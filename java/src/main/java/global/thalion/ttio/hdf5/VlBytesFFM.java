/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;

/**
 * FFM (Java 21 Foreign Function &amp; Memory) helper for writing and reading
 * HDF5 compound datasets that contain {@code hvl_t} (variable-length byte
 * sequence) fields.
 *
 * <p>The HDF5 1.14 Java JNI wrapper intercepts <em>every</em>
 * {@code H5Dwrite} / {@code H5Dread} call that has an {@code H5T_VLEN} field
 * in the memory type and routes it through {@code translate_wbuf} /
 * {@code translate_rbuf}.  Those functions call
 * {@code GetObjectArrayElement(jobj, row)} -- but {@code jobj} is a
 * {@code jbyteArray}, not a {@code jobjectArray} -- causing undefined
 * behaviour (SIGSEGV) in HDF5 1.14.</p>
 *
 * <p>This class bypasses the JNI wrapper entirely by using the FFM API to
 * call the native C symbols {@code H5Dwrite} and {@code H5Dread} directly.
 * Because the call never enters the Java JNI wrapper, {@code translate_wbuf}
 * and {@code translate_rbuf} are never invoked.</p>
 *
 * <p>On-disk format: each VL_BYTES field is stored as a real
 * {@code H5T_VLEN(H5T_NATIVE_UCHAR)} sequence -- the same encoding that
 * h5py produces for {@code h5py.vlen_dtype(np.uint8)} fields.  The in-memory
 * buffer presented to {@code H5Dwrite} / received from {@code H5Dread} is an
 * array of {@code hvl_t} structs:</p>
 * <pre>
 *   typedef struct { size_t len; void *p; } hvl_t;  // 16 bytes on 64-bit
 * </pre>
 *
 * <p>This is an internal package-private class; callers are
 * {@link Hdf5CompoundIO}.</p>
 */
final class VlBytesFFM {

    private VlBytesFFM() {}

    // hvl_t is {size_t len (8 bytes); void* p (8 bytes)} on 64-bit Linux/macOS.
    // Byte offsets within hvl_t:
    static final int HVL_LEN_OFFSET = 0;   // offset of 'len' field
    static final int HVL_PTR_OFFSET = 8;   // offset of 'p' field
    static final int HVL_SIZE      = 16;   // sizeof(hvl_t) on 64-bit

    // H5S_ALL constant value (from HDF5Constants, 0 = H5S_ALL)
    static final long H5S_ALL = 0L;

    // Lazy-initialised FFM handles
    private static volatile MethodHandle H5DWRITE_HANDLE;
    private static volatile MethodHandle H5DREAD_HANDLE;
    private static volatile MethodHandle H5TRECLAIM_HANDLE;
    private static final Object INIT_LOCK = new Object();

    /** Signature: herr_t H5Dwrite(hid_t, hid_t, hid_t, hid_t, hid_t, const void*) */
    private static final FunctionDescriptor H5DWRITE_DESC = FunctionDescriptor.of(
            ValueLayout.JAVA_INT,   // herr_t return
            ValueLayout.JAVA_LONG,  // dataset_id
            ValueLayout.JAVA_LONG,  // mem_type_id
            ValueLayout.JAVA_LONG,  // mem_space_id
            ValueLayout.JAVA_LONG,  // file_space_id
            ValueLayout.JAVA_LONG,  // plist_id
            ValueLayout.ADDRESS     // const void* buf
    );

    /** Signature: herr_t H5Dread(hid_t, hid_t, hid_t, hid_t, hid_t, void*) */
    private static final FunctionDescriptor H5DREAD_DESC = FunctionDescriptor.of(
            ValueLayout.JAVA_INT,   // herr_t return
            ValueLayout.JAVA_LONG,  // dataset_id
            ValueLayout.JAVA_LONG,  // mem_type_id
            ValueLayout.JAVA_LONG,  // mem_space_id
            ValueLayout.JAVA_LONG,  // file_space_id
            ValueLayout.JAVA_LONG,  // plist_id
            ValueLayout.ADDRESS     // void* buf
    );

    /**
     * Signature: herr_t H5Treclaim(hid_t type_id, hid_t space_id,
     *                               hid_t plist_id, void* buf)
     */
    private static final FunctionDescriptor H5TRECLAIM_DESC = FunctionDescriptor.of(
            ValueLayout.JAVA_INT,   // herr_t return
            ValueLayout.JAVA_LONG,  // type_id
            ValueLayout.JAVA_LONG,  // space_id
            ValueLayout.JAVA_LONG,  // plist_id
            ValueLayout.ADDRESS     // void* buf
    );

    private static void initHandles() {
        if (H5DWRITE_HANDLE != null) return;
        synchronized (INIT_LOCK) {
            if (H5DWRITE_HANDLE != null) return;
            Linker linker = Linker.nativeLinker();
            // Use loaderLookup() first: libhdf5 is already loaded into the
            // process by the HDF5 JNI binding (System.loadLibrary("hdf5_java")
            // pulls in libhdf5.so as a dependency), so its symbols are
            // available in the process-wide symbol table.
            // Fall back to explicit libraryLookup with the known install path
            // if loaderLookup cannot resolve the symbol.
            SymbolLookup loader = SymbolLookup.loaderLookup();
            SymbolLookup fallback = null;
            if (loader.find("H5Dwrite").isEmpty()) {
                // Library not yet in process symbol table; load it explicitly.
                // Prefer the path that install-hdf5.sh uses.
                String hdf5Path = System.getProperty("hdf5.lib.path",
                        "/usr/local/lib/libhdf5.so");
                fallback = SymbolLookup.libraryLookup(hdf5Path, Arena.global());
            }
            SymbolLookup hdf5 = (fallback != null) ? fallback : loader;
            H5DWRITE_HANDLE = linker.downcallHandle(
                    hdf5.find("H5Dwrite").orElseThrow(
                        () -> new UnsatisfiedLinkError("H5Dwrite not found in libhdf5")),
                    H5DWRITE_DESC);
            H5DREAD_HANDLE = linker.downcallHandle(
                    hdf5.find("H5Dread").orElseThrow(
                        () -> new UnsatisfiedLinkError("H5Dread not found in libhdf5")),
                    H5DREAD_DESC);
            H5TRECLAIM_HANDLE = linker.downcallHandle(
                    hdf5.find("H5Treclaim").orElseThrow(
                        () -> new UnsatisfiedLinkError("H5Treclaim not found in libhdf5")),
                    H5TRECLAIM_DESC);
        }
    }

    /**
     * Write {@code count} rows of a single VL_BYTES column.
     *
     * <p>{@code dset} is the open HDF5 dataset ID. {@code memType} is a
     * compound memory type containing exactly one {@code H5T_VLEN(UCHAR)}
     * field of size 16 bytes (the {@code hvl_t} size). {@code fileSpaceId}
     * is typically {@code H5S_ALL} (0L). {@code data[row]} is the byte array
     * to write for that row.</p>
     *
     * <p>The method allocates a confined arena, packs a native buffer of
     * {@code count} {@code hvl_t} structs, and calls C {@code H5Dwrite}
     * directly.</p>
     */
    @SuppressWarnings("restricted")
    static void write(long dset, long memType, long fileSpaceId,
                      int count, byte[][] data) {
        initHandles();
        // Allocate: hvl_t array (count * 16) + per-row data regions
        // All in one confined arena; lifetime matches this call.
        try (Arena arena = Arena.ofConfined()) {
            // Per-row data segments (pinned in the arena)
            MemorySegment[] rowSegs = new MemorySegment[count];
            for (int row = 0; row < count; row++) {
                byte[] rowData = (data[row] != null) ? data[row] : new byte[0];
                if (rowData.length > 0) {
                    rowSegs[row] = arena.allocate(rowData.length, 1);
                    rowSegs[row].asByteBuffer().put(rowData);
                } else {
                    rowSegs[row] = MemorySegment.NULL;
                }
            }

            // Build hvl_t array
            MemorySegment hvlBuf = arena.allocate((long) HVL_SIZE * count, 8);
            for (int row = 0; row < count; row++) {
                long rowOff = (long) row * HVL_SIZE;
                int len = (data[row] != null) ? data[row].length : 0;
                hvlBuf.set(ValueLayout.JAVA_LONG, rowOff + HVL_LEN_OFFSET, (long) len);
                hvlBuf.set(ValueLayout.ADDRESS, rowOff + HVL_PTR_OFFSET,
                        (len > 0) ? rowSegs[row] : MemorySegment.NULL);
            }

            int rc;
            try {
                rc = (int) H5DWRITE_HANDLE.invokeExact(
                        dset, memType, H5S_ALL, fileSpaceId, 0L,
                        hvlBuf);
            } catch (Throwable t) {
                throw new Hdf5Errors.DatasetWriteException(
                        "FFM H5Dwrite for VL_BYTES failed: " + t.getMessage());
            }
            if (rc < 0) {
                throw new Hdf5Errors.DatasetWriteException(
                        "FFM H5Dwrite for VL_BYTES returned " + rc);
            }
            // hvlBuf memory is freed when arena closes; HDF5 has already
            // written data to disk so the arena lifetime is sufficient.
        }
    }

    /**
     * Read {@code count} rows of a single VL_BYTES column.
     *
     * <p>{@code dset} is the open HDF5 dataset ID. {@code memType} is a
     * compound memory type containing exactly one {@code H5T_VLEN(UCHAR)}
     * field of size 16 bytes. {@code fileSpaceId} is typically
     * {@code H5S_ALL} (0L).</p>
     *
     * <p>The method allocates native memory for the {@code hvl_t} output
     * buffer, calls C {@code H5Dread} directly, copies each row's bytes into
     * a Java {@code byte[]}, then calls {@code H5Treclaim} to free the
     * VL-allocated memory before closing the arena.</p>
     *
     * @return one {@code byte[]} per row; never null elements
     */
    @SuppressWarnings("restricted")
    static byte[][] read(long dset, long memType, long fileSpaceId, int count) {
        initHandles();
        byte[][] result = new byte[count][];

        try (Arena arena = Arena.ofConfined()) {
            // Allocate output hvl_t array; HDF5 will fill in {len, ptr} per row.
            // HDF5 allocates the pointed-to memory with malloc; H5Treclaim frees it.
            MemorySegment hvlBuf = arena.allocate((long) HVL_SIZE * count, 8);
            // Zero-initialise to be safe
            hvlBuf.fill((byte) 0);

            int rc;
            try {
                rc = (int) H5DREAD_HANDLE.invokeExact(
                        dset, memType, H5S_ALL, fileSpaceId, 0L,
                        hvlBuf);
            } catch (Throwable t) {
                throw new RuntimeException(
                        "FFM H5Dread for VL_BYTES failed: " + t.getMessage(), t);
            }
            if (rc < 0) {
                // Return empty arrays rather than crashing
                for (int row = 0; row < count; row++) result[row] = new byte[0];
                return result;
            }

            // Extract byte arrays from hvl_t structs
            for (int row = 0; row < count; row++) {
                long rowOff = (long) row * HVL_SIZE;
                long len = hvlBuf.get(ValueLayout.JAVA_LONG, rowOff + HVL_LEN_OFFSET);
                MemorySegment ptr = hvlBuf.get(ValueLayout.ADDRESS, rowOff + HVL_PTR_OFFSET);

                if (len <= 0 || ptr == MemorySegment.NULL || ptr.address() == 0L) {
                    result[row] = new byte[0];
                } else {
                    // Reinterpret the native pointer with the correct size so we can read it
                    MemorySegment dataSeg = ptr.reinterpret(len);
                    result[row] = dataSeg.toArray(ValueLayout.JAVA_BYTE);
                }
            }

            // Free VL-allocated memory via H5Treclaim
            // (this calls free() on each hvl_t.p allocated by H5Dread)
            try {
                H5TRECLAIM_HANDLE.invokeExact(memType, H5S_ALL, 0L, hvlBuf);
            } catch (Throwable t) {
                // Best-effort: non-fatal, but may leak memory
            }
        }
        return result;
    }
}
