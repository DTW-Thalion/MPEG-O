/*
 * TTIOZarrProvider.h — Zarr v3 storage provider.
 *
 * Self-contained LocalStore implementation; no external zarr C
 * library required. The on-disk layout is the Zarr v3 convention
 * (single ``zarr.json`` per node, ``c/N1/N2/...`` chunk paths,
 * canonical dtype names) and matches the Python
 * ``ttio.providers.zarr.ZarrProvider`` and the Java
 * ``global.thalion.ttio.providers.ZarrProvider``, so all three can
 * cross-read one another's stores byte-for-byte.
 *
 * Scope:
 *   * URL schemes: zarr:///abs/path, bare local paths.
 *     (zarr+memory://, zarr+s3:// remain Python-only.)
 *   * Compression: write side emits uncompressed chunks. Read side
 *     accepts the ``gzip`` codec entry written by zarr-python's
 *     GzipCodec; other codecs raise.
 *   * Primitive types: float64, float32, int64, int32, uint32.
 *   * Byte order: little-endian (canonical).
 *
 * Compound datasets use the same "sub-group + JSON attrs" convention
 * the Python / Java providers emit: ``_ttio_kind=compound``,
 * ``_ttio_schema=[{name,kind}]``, ``_ttio_rows=[{...}]``.
 *
 * API status: Provisional.
 *
 * Cross-language equivalents:
 *   Python: ttio.providers.zarr.ZarrProvider
 *   Java:   global.thalion.ttio.providers.ZarrProvider
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_ZARR_PROVIDER_H
#define TTIO_ZARR_PROVIDER_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

@interface TTIOZarrProvider : NSObject <TTIOStorageProvider>
@end

#endif /* TTIO_ZARR_PROVIDER_H */
