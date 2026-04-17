#ifndef MPGO_SQLITE_PROVIDER_H
#define MPGO_SQLITE_PROVIDER_H

/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

/**
 * SQLite-backed storage provider. Single-file `.mpgo.sqlite` backend
 * implementing the same schema as the Python and Java SqliteProviders
 * so files are cross-language portable.
 *
 * Schema: groups (self-referential), datasets (BLOB for primitive,
 * JSON for compound), group_attributes, dataset_attributes, meta.
 * Little-endian primitive encoding, UTF-8 JSON for compound rows.
 *
 * URLs: @c sqlite:///abs/path/to/data.mpgo.sqlite or bare filesystem path.
 * File extensions @c .mpgo.sqlite and @c .sqlite are auto-detected.
 *
 * API status: Provisional (per M39 storage-provider subsystem).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.sqlite.SqliteProvider
 *   Java:   com.dtwthalion.mpgo.providers.SqliteProvider
 */
@interface MPGOSqliteProvider : NSObject <MPGOStorageProvider>
@end

#endif  /* MPGO_SQLITE_PROVIDER_H */
