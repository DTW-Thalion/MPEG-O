#ifndef TTIO_SQLITE_PROVIDER_H
#define TTIO_SQLITE_PROVIDER_H

/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

/**
 * SQLite-backed storage provider. Single-file `.tio.sqlite` backend
 * implementing the same schema as the Python and Java SqliteProviders
 * so files are cross-language portable.
 *
 * Schema: groups (self-referential), datasets (BLOB for primitive,
 * JSON for compound), group_attributes, dataset_attributes, meta.
 * Little-endian primitive encoding, UTF-8 JSON for compound rows.
 *
 * URLs: @c sqlite:///abs/path/to/data.tio.sqlite or bare filesystem path.
 * File extensions @c .tio.sqlite and @c .sqlite are auto-detected.
 *
 * API status: Provisional (per M39 storage-provider subsystem).
 *
 * Cross-language equivalents:
 *   Python: ttio.providers.sqlite.SqliteProvider
 *   Java:   global.thalion.ttio.providers.SqliteProvider
 */
@interface TTIOSqliteProvider : NSObject <TTIOStorageProvider>
@end

#endif  /* TTIO_SQLITE_PROVIDER_H */
