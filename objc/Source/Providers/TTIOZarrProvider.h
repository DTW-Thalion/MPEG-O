/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ZARR_PROVIDER_H
#define TTIO_ZARR_PROVIDER_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

/**
 * <heading>TTIOZarrProvider</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOStorageProvider, NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOZarrProvider.h</p>
 *
 * <p>Zarr v3 storage provider. Self-contained <code>LocalStore</code>
 * implementation; no external Zarr C library required. The on-disk
 * layout is the Zarr v3 convention (single <code>zarr.json</code>
 * per node, <code>c/N1/N2/...</code> chunk paths, canonical dtype
 * names) and matches the Python
 * <code>ttio.providers.zarr.ZarrProvider</code> and the Java
 * <code>global.thalion.ttio.providers.ZarrProvider</code>, so all
 * three implementations can cross-read one another's stores
 * byte-for-byte.</p>
 *
 * <p><strong>Scope:</strong></p>
 * <ul>
 *  <li>URL schemes: <code>zarr:///abs/path</code>, bare local
 *      paths. (<code>zarr+memory://</code>, <code>zarr+s3://</code>
 *      remain Python-only.)</li>
 *  <li>Compression: write side emits uncompressed chunks. Read side
 *      accepts the <code>gzip</code> codec entry written by
 *      zarr-python's <code>GzipCodec</code>; other codecs raise.</li>
 *  <li>Primitive types: <code>float64</code>, <code>float32</code>,
 *      <code>int64</code>, <code>int32</code>,
 *      <code>uint32</code>.</li>
 *  <li>Byte order: little-endian (canonical).</li>
 * </ul>
 *
 * <p>Compound datasets use the same "sub-group + JSON attrs"
 * convention the Python and Java providers emit:
 * <code>_ttio_kind=compound</code>,
 * <code>_ttio_schema=[{name,kind}]</code>,
 * <code>_ttio_rows=[{...}]</code>.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.zarr.ZarrProvider</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.ZarrProvider</code></p>
 */
@interface TTIOZarrProvider : NSObject <TTIOStorageProvider>
@end

#endif /* TTIO_ZARR_PROVIDER_H */
