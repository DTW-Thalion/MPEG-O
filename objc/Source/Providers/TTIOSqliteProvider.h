#ifndef TTIO_SQLITE_PROVIDER_H
#define TTIO_SQLITE_PROVIDER_H

/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

/**
 * <heading>TTIOSqliteProvider</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOStorageProvider, NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOSqliteProvider.h</p>
 *
 * <p>SQLite-backed storage provider. Single-file
 * <code>.tio.sqlite</code> backend implementing the same schema as
 * the Python and Java SqliteProviders so files are cross-language
 * portable.</p>
 *
 * <p><strong>Schema:</strong> groups (self-referential), datasets
 * (BLOB for primitive, JSON for compound), group_attributes,
 * dataset_attributes, meta. Little-endian primitive encoding, UTF-8
 * JSON for compound rows.</p>
 *
 * <p><strong>URLs:</strong>
 * <code>sqlite:///abs/path/to/data.tio.sqlite</code> or bare
 * filesystem path. File extensions <code>.tio.sqlite</code> and
 * <code>.sqlite</code> are auto-detected.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.sqlite.SqliteProvider</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.SqliteProvider</code></p>
 */
@interface TTIOSqliteProvider : NSObject <TTIOStorageProvider>
@end

#endif  /* TTIO_SQLITE_PROVIDER_H */
