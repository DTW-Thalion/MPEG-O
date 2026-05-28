/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;
import hdf.hdf5lib.exceptions.HDF5LibraryException;

import java.io.File;
import java.util.concurrent.locks.ReadWriteLock;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/**
 * Thin wrapper around an HDF5 file handle. Implements {@link AutoCloseable}
 * for try-with-resources support.
 *
 * <p>Thread-safety model: each Hdf5File owns a
 * {@link ReentrantReadWriteLock} that serialises access from derived
 * {@link Hdf5Group} and {@link Hdf5Dataset} instances. Readers do not
 * block readers; writers are exclusive. When the native HDF5 library is
 * not thread-safe, readers are promoted to the write (exclusive) lock.</p>
 *
 *
 */
public class Hdf5File implements AutoCloseable {

    private final String path;
    private long fileId;
    private boolean closed;
    private final ReadWriteLock rwLock;
    private final boolean libThreadSafe;

    private Hdf5File(long fileId, String path) {
        this.fileId = fileId;
        this.path = path;
        this.closed = false;
        this.rwLock = new ReentrantReadWriteLock();
        this.libThreadSafe = probeThreadSafety();
    }

    // Perf B: meta block size + small data block size. HDF5 defaults
    // to 2 KB for both, which means each new group / attribute / tiny
    // dataset triggers its own file-block allocation + b-tree update.
    // For workloads with thousands of small objects (e.g. a whale-
    // genome FASTA reference with ~25k contigs), this pegs the
    // encoder at ~17 records/s on metadata-cache flushes. Raising the
    // meta block to 8 MB and small-data block to 2 MB amortises the
    // allocations across hundreds of objects per native call.
    private static final long META_BLOCK_SIZE        = 8L * 1024L * 1024L;
    private static final long SMALL_DATA_BLOCK_SIZE  = 2L * 1024L * 1024L;

    /** Create a new HDF5 file, truncating any existing file at path. */
    public static Hdf5File create(String path) {
        try {
            long fapl = H5.H5Pcreate(HDF5Constants.H5P_FILE_ACCESS);
            try {
                H5.H5Pset_meta_block_size(fapl, META_BLOCK_SIZE);
                H5.H5Pset_small_data_block_size(fapl, SMALL_DATA_BLOCK_SIZE);
                long fid = H5.H5Fcreate(path,
                        HDF5Constants.H5F_ACC_TRUNC,
                        HDF5Constants.H5P_DEFAULT,
                        fapl);
                if (fid < 0) throw new Hdf5Errors.FileCreateException(path);
                return new Hdf5File(fid, path);
            } finally {
                try { H5.H5Pclose(fapl); } catch (HDF5LibraryException ignored) {}
            }
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.FileCreateException(path);
        }
    }

    /** Open an existing HDF5 file for read/write. */
    public static Hdf5File open(String path) {
        if (!new File(path).exists()) {
            throw new Hdf5Errors.FileNotFoundException(path);
        }
        try {
            long fid = H5.H5Fopen(path,
                    HDF5Constants.H5F_ACC_RDWR,
                    HDF5Constants.H5P_DEFAULT);
            if (fid < 0) throw new Hdf5Errors.FileOpenException(path);
            return new Hdf5File(fid, path);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.FileOpenException(path);
        }
    }

    /** Open an existing HDF5 file read-only. */
    public static Hdf5File openReadOnly(String path) {
        if (!new File(path).exists()) {
            throw new Hdf5Errors.FileNotFoundException(path);
        }
        try {
            long fid = H5.H5Fopen(path,
                    HDF5Constants.H5F_ACC_RDONLY,
                    HDF5Constants.H5P_DEFAULT);
            if (fid < 0) throw new Hdf5Errors.FileOpenException(path);
            return new Hdf5File(fid, path);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.FileOpenException(path);
        }
    }

    /** The root group ("/") of this file. */
    public Hdf5Group rootGroup() {
        lockForReading();
        try {
            long gid = H5.H5Gopen(fileId, "/", HDF5Constants.H5P_DEFAULT);
            if (gid < 0) throw new Hdf5Errors.GroupOpenException("/");
            return new Hdf5Group(gid, this);
        } catch (HDF5LibraryException e) {
            throw new Hdf5Errors.GroupOpenException("/");
        } finally {
            unlockForReading();
        }
    }

    /** @return the filesystem path this file was opened from. */
    public String getPath() { return path; }

    /** @return the underlying HDF5 file id. */
    public long getFileId() { return fileId; }

    /**
     * Returns true iff the linked libhdf5 is thread-safe AND the wrapper
     * lock initialised. When false, concurrent use is undefined.
     */
    public boolean isThreadSafe() {
        return libThreadSafe;
    }

    /** Acquire the read lock for the duration of an HDF5 read call.
     *  Promoted to the write (exclusive) lock when the linked libhdf5
     *  is not thread-safe. Must be paired with {@link #unlockForReading}. */
    public void lockForReading() {
        if (libThreadSafe) {
            rwLock.readLock().lock();
        } else {
            rwLock.writeLock().lock();
        }
    }

    /** Release the lock acquired by {@link #lockForReading}. */
    public void unlockForReading() {
        if (libThreadSafe) {
            rwLock.readLock().unlock();
        } else {
            rwLock.writeLock().unlock();
        }
    }

    /** Acquire the exclusive write lock for the duration of an HDF5
     *  write call. Must be paired with {@link #unlockForWriting}. */
    public void lockForWriting() {
        rwLock.writeLock().lock();
    }

    /** Release the lock acquired by {@link #lockForWriting}. */
    public void unlockForWriting() {
        rwLock.writeLock().unlock();
    }

    /** Flush pending metadata to the OS buffer, then release the HDF5
     *  file id. Idempotent. */
    @Override
    public void close() {
        if (closed) return;
        try {
            // Force a flush before close so pending metadata updates
            // (new datasets, attribute writes) are written to the OS
            // buffer even if child handles were leaked by caller code.
            H5.H5Fflush(fileId, HDF5Constants.H5F_SCOPE_GLOBAL);
        } catch (HDF5LibraryException ignored) {}
        try {
            H5.H5Fclose(fileId);
        } catch (HDF5LibraryException e) {
            // best-effort close
        }
        closed = true;
    }

    private static boolean probeThreadSafety() {
        // In HDF5 Java 1.10.x, H5is_library_threadsafe is not public.
        // The apt serial build of libhdf5 is not thread-safe, so default
        // to false (degraded exclusive-lock mode). CI and runtime with a
        // thread-safe build can override via system property.
        return Boolean.getBoolean("ttio.hdf5.threadsafe");
    }
}
