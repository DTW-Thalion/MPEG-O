/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.hdf5;

/**
 * Exception hierarchy for HDF5 wrapper operations.
 * Mirrors ObjC TTIOErrorCode enum as typed exception subclasses.
 *
 *
 */
public class Hdf5Errors {

    private Hdf5Errors() {}

    public static class Hdf5Exception extends RuntimeException {
        public Hdf5Exception(String message) { super(message); }
        public Hdf5Exception(String message, Throwable cause) { super(message, cause); }
    }

    public static class FileNotFoundException extends Hdf5Exception {
        public FileNotFoundException(String path) {
            super("file not found: " + path);
        }
    }

    public static class FileCreateException extends Hdf5Exception {
        public FileCreateException(String path) {
            super("H5Fcreate failed for " + path);
        }
    }

    public static class FileOpenException extends Hdf5Exception {
        public FileOpenException(String path) {
            super("H5Fopen failed for " + path);
        }
    }

    public static class GroupCreateException extends Hdf5Exception {
        public GroupCreateException(String name) {
            super("H5Gcreate2 failed for '" + name + "'");
        }
    }

    public static class GroupOpenException extends Hdf5Exception {
        public GroupOpenException(String name) {
            super("H5Gopen2 failed for '" + name + "'");
        }
    }

    public static class DatasetCreateException extends Hdf5Exception {
        public DatasetCreateException(String message) {
            super(message);
        }
    }

    public static class DatasetOpenException extends Hdf5Exception {
        public DatasetOpenException(String name) {
            super("H5Dopen2 failed for '" + name + "'");
        }
    }

    public static class DatasetWriteException extends Hdf5Exception {
        public DatasetWriteException(String message) {
            super(message);
        }
    }

    public static class DatasetReadException extends Hdf5Exception {
        public DatasetReadException(String message) {
            super(message);
        }
    }

    public static class AttributeException extends Hdf5Exception {
        public AttributeException(String message) {
            super(message);
        }
    }

    public static class OutOfRangeException extends Hdf5Exception {
        public OutOfRangeException(long offset, long count, long length) {
            super(String.format("hyperslab [%d, %d) exceeds dataset length %d",
                    offset, offset + count, length));
        }
    }
}
