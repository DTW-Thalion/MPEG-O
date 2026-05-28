/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
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

    /** Base unchecked exception for any failure raised by the HDF5
     *  wrapper layer. All other exceptions in this class extend it. */
    public static class Hdf5Exception extends RuntimeException {
        /** @param message  human-readable description of the failure */
        public Hdf5Exception(String message) { super(message); }

        /** @param message  human-readable description of the failure
         *  @param cause    the underlying native exception, may be {@code null} */
        public Hdf5Exception(String message, Throwable cause) { super(message, cause); }
    }

    /** Raised when an HDF5 file path is requested but the file does not
     *  exist on disk. */
    public static class FileNotFoundException extends Hdf5Exception {
        /** @param path  the missing file path */
        public FileNotFoundException(String path) {
            super("file not found: " + path);
        }
    }

    /** Raised when {@code H5Fcreate} returns a negative file id, typically
     *  due to permissions or a missing parent directory. */
    public static class FileCreateException extends Hdf5Exception {
        /** @param path  the file path that could not be created */
        public FileCreateException(String path) {
            super("H5Fcreate failed for " + path);
        }
    }

    /** Raised when {@code H5Fopen} returns a negative file id, typically
     *  due to a corrupt header or a non-HDF5 file. */
    public static class FileOpenException extends Hdf5Exception {
        /** @param path  the file path that could not be opened */
        public FileOpenException(String path) {
            super("H5Fopen failed for " + path);
        }
    }

    /** Raised when {@code H5Gcreate2} returns a negative group id. */
    public static class GroupCreateException extends Hdf5Exception {
        /** @param name  the group name that could not be created */
        public GroupCreateException(String name) {
            super("H5Gcreate2 failed for '" + name + "'");
        }
    }

    /** Raised when {@code H5Gopen2} returns a negative group id. */
    public static class GroupOpenException extends Hdf5Exception {
        /** @param name  the group name that could not be opened */
        public GroupOpenException(String name) {
            super("H5Gopen2 failed for '" + name + "'");
        }
    }

    /** Raised when dataset creation fails — type setup, dataspace setup,
     *  or the {@code H5Dcreate2} call itself. */
    public static class DatasetCreateException extends Hdf5Exception {
        /** @param message  human-readable description of the failure */
        public DatasetCreateException(String message) {
            super(message);
        }
    }

    /** Raised when {@code H5Dopen2} returns a negative dataset id. */
    public static class DatasetOpenException extends Hdf5Exception {
        /** @param name  the dataset name that could not be opened */
        public DatasetOpenException(String name) {
            super("H5Dopen2 failed for '" + name + "'");
        }
    }

    /** Raised when {@code H5Dwrite} (or any of its split-write variants)
     *  reports failure. */
    public static class DatasetWriteException extends Hdf5Exception {
        /** @param message  human-readable description of the failure */
        public DatasetWriteException(String message) {
            super(message);
        }
    }

    /** Raised when {@code H5Dread} (or any of its split-read variants)
     *  reports failure. */
    public static class DatasetReadException extends Hdf5Exception {
        /** @param message  human-readable description of the failure */
        public DatasetReadException(String message) {
            super(message);
        }
    }

    /** Raised when an attribute create / read / write / delete call
     *  fails on a group or dataset. */
    public static class AttributeException extends Hdf5Exception {
        /** @param message  human-readable description of the failure */
        public AttributeException(String message) {
            super(message);
        }
    }

    /** Raised when a hyperslab request extends past the dataset extent. */
    public static class OutOfRangeException extends Hdf5Exception {
        /** @param offset  the starting element index of the request
         *  @param count   the number of elements requested
         *  @param length  the total element count of the dataset
         */
        public OutOfRangeException(long offset, long count, long length) {
            super(String.format("hyperslab [%d, %d) exceeds dataset length %d",
                    offset, offset + count, length));
        }
    }
}
