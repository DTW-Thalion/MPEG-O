/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.hdf5;

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
 * <p>Thread-safety model (mirrors ObjC M23): each Hdf5File owns a
 * {@link ReentrantReadWriteLock} that serialises access from derived
 * {@link Hdf5Group} and {@link Hdf5Dataset} instances. Readers do not
 * block readers; writers are exclusive. When the native HDF5 library is
 * not thread-safe, readers are promoted to the write (exclusive) lock.</p>
 *
 * @since 0.5
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

    /** Create a new HDF5 file, truncating any existing file at path. */
    public static Hdf5File create(String path) {
        try {
            long fid = H5.H5Fcreate(path,
                    HDF5Constants.H5F_ACC_TRUNC,
                    HDF5Constants.H5P_DEFAULT,
                    HDF5Constants.H5P_DEFAULT);
            if (fid < 0) throw new Hdf5Errors.FileCreateException(path);
            return new Hdf5File(fid, path);
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

    public String getPath() { return path; }
    public long getFileId() { return fileId; }

    /**
     * Returns true iff the linked libhdf5 is thread-safe AND the wrapper
     * lock initialised. When false, concurrent use is undefined.
     */
    public boolean isThreadSafe() {
        return libThreadSafe;
    }

    public void lockForReading() {
        if (libThreadSafe) {
            rwLock.readLock().lock();
        } else {
            rwLock.writeLock().lock();
        }
    }

    public void unlockForReading() {
        if (libThreadSafe) {
            rwLock.readLock().unlock();
        } else {
            rwLock.writeLock().unlock();
        }
    }

    public void lockForWriting() {
        rwLock.writeLock().lock();
    }

    public void unlockForWriting() {
        rwLock.writeLock().unlock();
    }

    @Override
    public void close() {
        if (closed) return;
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
        return Boolean.getBoolean("mpgo.hdf5.threadsafe");
    }
}
