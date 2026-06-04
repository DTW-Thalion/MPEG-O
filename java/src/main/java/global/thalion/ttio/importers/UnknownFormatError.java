/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

/** Raised for a {@code --format} value that maps to no known codec.
 *
 *  <p>Mirrors Python {@code ttio.importers.registry.UnknownFormatError}. */
public class UnknownFormatError extends IllegalArgumentException {
    public UnknownFormatError(String format) {
        super(format);
    }
}
