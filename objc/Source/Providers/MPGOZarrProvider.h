/*
 * MPGOZarrProvider.h — Zarr v2 storage provider (v0.8 M52).
 *
 * Self-contained DirectoryStore implementation; no external zarr C
 * library required. The on-disk layout matches the Python
 * ``mpeg_o.providers.zarr.ZarrProvider`` and the Java
 * ``com.dtwthalion.mpgo.providers.ZarrProvider``, so all three can
 * cross-read one another's stores (M52 acceptance).
 *
 * Scope of this v0.8 port:
 *   * URL schemes: zarr:///abs/path, bare local paths.
 *     (zarr+memory://, zarr+s3:// are Python-only; v0.9.)
 *   * Compression: NONE only. Compressed chunks from Python-authored
 *     stores raise an "unsupported codec" error on read.
 *   * Primitive types: float64, float32, int64, int32, uint32.
 *   * Byte order: little-endian (canonical).
 *
 * Compound datasets use the same "sub-group + JSON attrs" convention
 * the Python / Java providers emit: ``_mpgo_kind=compound``,
 * ``_mpgo_schema=[{name,kind}]``, ``_mpgo_rows=[{...}]``.
 *
 * API status: Provisional (v0.8 M52).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.zarr.ZarrProvider
 *   Java:   com.dtwthalion.mpgo.providers.ZarrProvider
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_ZARR_PROVIDER_H
#define MPGO_ZARR_PROVIDER_H

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

@interface MPGOZarrProvider : NSObject <MPGOStorageProvider>
@end

#endif /* MPGO_ZARR_PROVIDER_H */
