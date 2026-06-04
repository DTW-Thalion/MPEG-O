/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

/** Raised for a {@code --format} value that maps to no known exporter.
 *
 *  <p>Mirrors Python {@code ttio.exporters.registry.UnknownFormatError}. */
public class UnknownFormatError extends IllegalArgumentException {
    public UnknownFormatError(String format) {
        super(format);
    }
}
