/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_GFA_READER_H
#define TTIO_GFA_READER_H

#import <Foundation/Foundation.h>

@class TTIOWrittenAssemblyGraph;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Import/TTIOGfaReader.h</p>
 *
 * <p>GFA 1.x parser (M98). Splits a GFA byte stream into the S/L/P
 * tables of a <code>TTIOWrittenAssemblyGraph</code>, keeps every
 * other line verbatim in <code>extras</code>, and records the
 * file-order line index, so
 * <code>TTIOGfaWriter</code> reproduces the input byte for byte:
 * <code>write(read(x)) == x</code> for any input, including
 * producer extensions (hifiasm <code>A</code> lines), headers,
 * containments, comments, and files without a final newline.</p>
 *
 * <p>Structural rules (mirrors the Python and Java parsers): a line
 * is an <code>S</code> record when it has ≥ 3 tab-separated fields,
 * an <code>L</code> record at ≥ 6 fields, a <code>P</code> record at
 * ≥ 4 fields; anything else, including short S/L/P lines, lands in
 * <code>extras</code> verbatim. The <code>gfaVersion</code> is taken
 * from a leading <code>H</code> line's <code>VN:Z:</code> tag when
 * present, else <code>"1.0"</code>.</p>
 *
 * <p><strong>API status:</strong> New in M98.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.gfa.GfaReader</code><br/>
 * Java: <code>global.thalion.ttio.importers.GfaReader</code></p>
 */
@interface TTIOGfaReader : NSObject

/** Parse GFA bytes. Returns nil with <code>*error</code> set when
 *  the bytes are not valid UTF-8. */
+ (nullable TTIOWrittenAssemblyGraph *)graphFromData:(NSData *)data
                                               error:(NSError **)error;

/** Parse the GFA file at <code>path</code>. */
+ (nullable TTIOWrittenAssemblyGraph *)graphFromPath:(NSString *)path
                                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
