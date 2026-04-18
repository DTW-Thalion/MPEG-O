/*
 * MPGOSqliteProvider.m — SQLite storage provider for MPEG-O
 *
 * Three classes in one file:
 *   MPGOSqliteProvider   — conforms to <MPGOStorageProvider>
 *   MPGOSqliteGroup      — conforms to <MPGOStorageGroup>     (internal)
 *   MPGOSqliteDataset    — conforms to <MPGOStorageDataset>   (internal)
 *
 * Schema is byte-identical to the Python and Java SqliteProviders.
 * Primitive datasets: little-endian packed BLOBs via memcpy (x86-64 is
 * already little-endian; document assumption below).
 * Compound datasets: JSON arrays of dicts via NSJSONSerialization.
 *
 * BYTE-ORDER NOTE: The build target for MPEG-O tests is Linux x86-64,
 * which is little-endian. We use memcpy directly into the BLOB rather
 * than OSSwapHostToLittle* to avoid pulling in <libkern/OSByteOrder.h>
 * which may not be available on all GNUstep Linux builds. If MPEG-O is
 * ever ported to a big-endian host this file needs explicit byteswapping.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "MPGOSqliteProvider.h"
#import "MPGOProviderRegistry.h"
#import "MPGOCanonicalBytes.h"
#import "HDF5/MPGOHDF5Errors.h"   /* MPGOMakeError, MPGOErrorDomain */
#import "Providers/MPGOCompoundField.h"

#include <sqlite3.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

// ──────────────────────────────────────────────────────────────
// SQL schema (identical to Python / Java)
// ──────────────────────────────────────────────────────────────

static const char *kDDL =
    "PRAGMA foreign_keys = ON;"
    "CREATE TABLE IF NOT EXISTS groups ("
    "  id          INTEGER PRIMARY KEY AUTOINCREMENT,"
    "  parent_id   INTEGER REFERENCES groups(id) ON DELETE CASCADE,"
    "  name        TEXT NOT NULL,"
    "  UNIQUE(parent_id, name)"
    ");"
    "CREATE TABLE IF NOT EXISTS datasets ("
    "  id               INTEGER PRIMARY KEY AUTOINCREMENT,"
    "  group_id         INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,"
    "  name             TEXT NOT NULL,"
    "  kind             TEXT NOT NULL CHECK(kind IN ('primitive','compound')),"
    "  precision        TEXT,"
    "  shape_json       TEXT NOT NULL,"
    "  data             BLOB,"
    "  compound_fields  TEXT,"
    "  compound_rows    TEXT,"
    "  UNIQUE(group_id, name)"
    ");"
    "CREATE TABLE IF NOT EXISTS group_attributes ("
    "  group_id    INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,"
    "  name        TEXT NOT NULL,"
    "  value_type  TEXT NOT NULL CHECK(value_type IN ('string','int','float')),"
    "  value       TEXT NOT NULL,"
    "  PRIMARY KEY (group_id, name)"
    ");"
    "CREATE TABLE IF NOT EXISTS dataset_attributes ("
    "  dataset_id  INTEGER NOT NULL REFERENCES datasets(id) ON DELETE CASCADE,"
    "  name        TEXT NOT NULL,"
    "  value_type  TEXT NOT NULL CHECK(value_type IN ('string','int','float')),"
    "  value       TEXT NOT NULL,"
    "  PRIMARY KEY (dataset_id, name)"
    ");"
    "CREATE TABLE IF NOT EXISTS meta ("
    "  key    TEXT PRIMARY KEY,"
    "  value  TEXT NOT NULL"
    ");"
    "CREATE INDEX IF NOT EXISTS idx_datasets_group ON datasets(group_id);"
    "CREATE INDEX IF NOT EXISTS idx_ga_group ON group_attributes(group_id);"
    "CREATE INDEX IF NOT EXISTS idx_da_dataset ON dataset_attributes(dataset_id);";

static const char *kMetaInserts =
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '1');"
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('provider', 'mpeg_o.providers.sqlite');";

// ──────────────────────────────────────────────────────────────
// Precision helpers — name strings stored in DB must match Python
// ──────────────────────────────────────────────────────────────

/** Return the precision-name string stored in the `precision` column.
 *  Matches Python's Precision.name (FLOAT32, FLOAT64, etc.). */
static NSString *precisionName(MPGOPrecision p)
{
    switch (p) {
        case MPGOPrecisionFloat32:    return @"FLOAT32";
        case MPGOPrecisionFloat64:    return @"FLOAT64";
        case MPGOPrecisionInt32:      return @"INT32";
        case MPGOPrecisionInt64:      return @"INT64";
        case MPGOPrecisionUInt32:     return @"UINT32";
        case MPGOPrecisionComplex128: return @"COMPLEX128";
        default:                      return @"FLOAT64";
    }
}

/** Parse stored precision name back to enum. */
static MPGOPrecision precisionFromName(const char *name)
{
    if (!name) return MPGOPrecisionFloat64;
    if (strcmp(name, "FLOAT32")    == 0) return MPGOPrecisionFloat32;
    if (strcmp(name, "FLOAT64")    == 0) return MPGOPrecisionFloat64;
    if (strcmp(name, "INT32")      == 0) return MPGOPrecisionInt32;
    if (strcmp(name, "INT64")      == 0) return MPGOPrecisionInt64;
    if (strcmp(name, "UINT32")     == 0) return MPGOPrecisionUInt32;
    if (strcmp(name, "COMPLEX128") == 0) return MPGOPrecisionComplex128;
    return MPGOPrecisionFloat64;
}

/** Bytes per element for a given precision. */
static NSUInteger precisionElementSize(MPGOPrecision p)
{
    switch (p) {
        case MPGOPrecisionFloat32:    return 4;
        case MPGOPrecisionFloat64:    return 8;
        case MPGOPrecisionInt32:      return 4;
        case MPGOPrecisionInt64:      return 8;
        case MPGOPrecisionUInt32:     return 4;
        case MPGOPrecisionComplex128: return 16;
        default:                      return 8;
    }
}

// ──────────────────────────────────────────────────────────────
// CompoundField kind helpers — JSON strings must match Python
// ──────────────────────────────────────────────────────────────

/** Return the kind string stored in compound_fields JSON.
 *  Matches Python CompoundFieldKind.value ("uint32", "int64", etc.). */
static NSString *kindString(MPGOCompoundFieldKind k)
{
    switch (k) {
        case MPGOCompoundFieldKindUInt32:   return @"uint32";
        case MPGOCompoundFieldKindInt64:    return @"int64";
        case MPGOCompoundFieldKindFloat64:  return @"float64";
        case MPGOCompoundFieldKindVLString: return @"vl_string";
        default:                            return @"vl_string";
    }
}

/** Parse kind string back to enum. */
static MPGOCompoundFieldKind kindFromString(NSString *s)
{
    if ([s isEqualToString:@"uint32"])    return MPGOCompoundFieldKindUInt32;
    if ([s isEqualToString:@"int64"])     return MPGOCompoundFieldKindInt64;
    if ([s isEqualToString:@"float64"])   return MPGOCompoundFieldKindFloat64;
    if ([s isEqualToString:@"vl_string"]) return MPGOCompoundFieldKindVLString;
    return MPGOCompoundFieldKindVLString;
}

// ──────────────────────────────────────────────────────────────
// Attribute encoding helpers
// ──────────────────────────────────────────────────────────────

/** Encode an attribute value to (value_type, string_value).
 *  NSNumber with integer tag → "int"; with float tag → "float";
 *  NSString → "string". */
static void encodeAttr(id value, NSString **outType, NSString **outStr)
{
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *n = (NSNumber *)value;
        // Check if the number was created from a float/double
        const char *objcType = [n objCType];
        if (strcmp(objcType, @encode(float))  == 0 ||
            strcmp(objcType, @encode(double)) == 0) {
            *outType = @"float";
            *outStr  = [NSString stringWithFormat:@"%.17g", [n doubleValue]];
        } else {
            *outType = @"int";
            *outStr  = [NSString stringWithFormat:@"%lld", [n longLongValue]];
        }
    } else {
        *outType = @"string";
        *outStr  = [value description];
    }
}

/** Decode attribute back from (value_type, string_value) to NSString/NSNumber. */
static id decodeAttr(const char *valueType, const char *valueStr)
{
    if (!valueType || !valueStr) return nil;
    if (strcmp(valueType, "int") == 0) {
        long long v = strtoll(valueStr, NULL, 10);
        return @(v);
    }
    if (strcmp(valueType, "float") == 0) {
        double v = strtod(valueStr, NULL);
        return @(v);
    }
    // string
    return [NSString stringWithUTF8String:valueStr];
}

// ──────────────────────────────────────────────────────────────
// sqlite3_step helper — returns error on failure
// ──────────────────────────────────────────────────────────────

static BOOL stepAndExpect(sqlite3_stmt *stmt, int expected,
                          sqlite3 *db, NSError **error)
{
    int rc = sqlite3_step(stmt);
    if (rc != expected && rc != SQLITE_DONE) {
        if (error) {
            *error = MPGOMakeError(MPGOErrorUnknown,
                @"SQLite step error %d: %s", rc, sqlite3_errmsg(db));
        }
        return NO;
    }
    return YES;
}

// ──────────────────────────────────────────────────────────────
// Forward declarations
// ──────────────────────────────────────────────────────────────

@class MPGOSqliteGroup;
@class MPGOSqliteDataset;

// ══════════════════════════════════════════════════════════════
// MPGOSqliteDataset
// ══════════════════════════════════════════════════════════════

@interface MPGOSqliteDataset : NSObject <MPGOStorageDataset> {
    sqlite3    *_db;
    int64_t     _datasetId;
    NSString   *_name;
    MPGOPrecision _precision;
    NSArray<NSNumber *>         *_shape;
    NSArray<MPGOCompoundField *> *_fields;
    BOOL        _readOnly;
}
- (instancetype)initWithDB:(sqlite3 *)db
                 datasetId:(int64_t)datasetId
                      name:(NSString *)name
                 precision:(MPGOPrecision)precision
                     shape:(NSArray<NSNumber *> *)shape
                    fields:(NSArray<MPGOCompoundField *> *)fields
                  readOnly:(BOOL)readOnly;
@end

@implementation MPGOSqliteDataset

- (instancetype)initWithDB:(sqlite3 *)db
                 datasetId:(int64_t)datasetId
                      name:(NSString *)name
                 precision:(MPGOPrecision)precision
                     shape:(NSArray<NSNumber *> *)shape
                    fields:(NSArray<MPGOCompoundField *> *)fields
                  readOnly:(BOOL)readOnly
{
    self = [super init];
    if (self) {
        _db        = db;
        _datasetId = datasetId;
        _name      = [name copy];
        _precision = precision;
        _shape     = [shape copy];
        _fields    = [fields copy];
        _readOnly  = readOnly;
    }
    return self;
}

- (NSString *)name { return _name; }
- (MPGOPrecision)precision { return _precision; }
- (NSArray<NSNumber *> *)shape { return _shape; }
- (NSArray<NSNumber *> *)chunks { return nil; }
- (NSUInteger)length
{
    return (_shape.count > 0) ? (NSUInteger)[_shape[0] unsignedIntegerValue] : 0;
}
- (NSArray<MPGOCompoundField *> *)compoundFields { return _fields; }

// ── Read all ────────────────────────────────────────────────

- (id)readAll:(NSError **)error
{
    return [self readSliceAtOffset:0 count:NSUIntegerMax error:error];
}

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (_fields == nil) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"readRows: is only valid for compound datasets");
        return nil;
    }
    return [self readAll:error];
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    if (_fields != nil) {
        NSArray<NSDictionary<NSString *, id> *> *rows = [self readRows:error];
        if (!rows) return nil;
        return [MPGOCanonicalBytes canonicalBytesForCompoundRows:rows
                                                            fields:_fields];
    }
    id raw = [self readAll:error];
    if (![raw isKindOfClass:[NSData class]]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"SqliteDataset.readCanonicalBytes: primitive readAll: "
            @"did not return NSData");
        return nil;
    }
    return [MPGOCanonicalBytes canonicalBytesForNumericData:(NSData *)raw
                                                   precision:_precision];
}

- (id)readSliceAtOffset:(NSUInteger)offset
                  count:(NSUInteger)count
                  error:(NSError **)error
{
    if (_fields) {
        // Compound: JSON rows
        sqlite3_stmt *stmt = NULL;
        int rc = sqlite3_prepare_v2(_db,
            "SELECT compound_rows FROM datasets WHERE id = ?",
            -1, &stmt, NULL);
        if (rc != SQLITE_OK) {
            if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
                @"SQLite prepare error: %s", sqlite3_errmsg(_db));
            return nil;
        }
        sqlite3_bind_int64(stmt, 1, _datasetId);
        id result = nil;
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *json = (const char *)sqlite3_column_text(stmt, 0);
            if (json) {
                NSData *d = [NSData dataWithBytes:json length:strlen(json)];
                NSArray *rows = [NSJSONSerialization
                    JSONObjectWithData:d options:0 error:nil];
                if (rows) {
                    NSUInteger from = MIN(offset, rows.count);
                    NSUInteger avail = rows.count - from;
                    NSUInteger take = (count == NSUIntegerMax)
                        ? avail : MIN(count, avail);
                    result = [rows subarrayWithRange:NSMakeRange(from, take)];
                }
            }
        }
        sqlite3_finalize(stmt);
        if (!result) result = @[];
        return result;
    }

    // Primitive: BLOB
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(_db,
        "SELECT data FROM datasets WHERE id = ?",
        -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"SQLite prepare error: %s", sqlite3_errmsg(_db));
        return nil;
    }
    sqlite3_bind_int64(stmt, 1, _datasetId);
    NSData *result = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        int blobType = sqlite3_column_type(stmt, 0);
        if (blobType != SQLITE_NULL) {
            const void *blob = sqlite3_column_blob(stmt, 0);
            int blobLen      = sqlite3_column_bytes(stmt, 0);
            if (blob && blobLen > 0) {
                NSUInteger elemSize = precisionElementSize(_precision);
                NSUInteger totalElems = (NSUInteger)blobLen / elemSize;
                NSUInteger from  = MIN(offset, totalElems);
                NSUInteger avail = totalElems - from;
                NSUInteger take  = (count == NSUIntegerMax)
                    ? avail : MIN(count, avail);
                NSUInteger startByte = from * elemSize;
                NSUInteger takeBytes = take * elemSize;
                result = [NSData dataWithBytes:(const uint8_t *)blob + startByte
                                        length:takeBytes];
            }
        }
    }
    sqlite3_finalize(stmt);
    if (!result) result = [NSData data];
    return result;
}

// ── Write all ────────────────────────────────────────────────

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"SQLite provider opened read-only");
        return NO;
    }

    if (_fields) {
        // Compound: serialize NSArray<NSDictionary*> to JSON
        NSError *jsonErr = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data
                                                           options:0
                                                             error:&jsonErr];
        if (!jsonData) {
            if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
                @"JSON serialization failed: %@", jsonErr.localizedDescription);
            return NO;
        }
        NSString *jsonStr = [[NSString alloc]
            initWithData:jsonData encoding:NSUTF8StringEncoding];

        sqlite3_stmt *stmt = NULL;
        int rc = sqlite3_prepare_v2(_db,
            "UPDATE datasets SET compound_rows = ? WHERE id = ?",
            -1, &stmt, NULL);
        if (rc != SQLITE_OK) {
            if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
                @"SQLite prepare error: %s", sqlite3_errmsg(_db));
            return NO;
        }
        sqlite3_bind_text(stmt, 1, [jsonStr UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, _datasetId);
        rc = sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        if (rc != SQLITE_DONE) {
            if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
                @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
            return NO;
        }
        sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
        return YES;
    }

    // Primitive: store NSData as BLOB
    if (![data isKindOfClass:[NSData class]]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"writeAll: primitive dataset requires NSData");
        return NO;
    }
    NSData *blob = (NSData *)data;

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(_db,
        "UPDATE datasets SET data = ? WHERE id = ?",
        -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"SQLite prepare error: %s", sqlite3_errmsg(_db));
        return NO;
    }
    sqlite3_bind_blob(stmt, 1, blob.bytes, (int)blob.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, _datasetId);
    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return NO;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return YES;
}

// ── Attributes ──────────────────────────────────────────────

- (BOOL)hasAttributeNamed:(NSString *)name
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT 1 FROM dataset_attributes WHERE dataset_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _datasetId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    BOOL found = (sqlite3_step(stmt) == SQLITE_ROW);
    sqlite3_finalize(stmt);
    return found;
}

- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT value_type, value FROM dataset_attributes "
        "WHERE dataset_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _datasetId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    id result = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *vtype = (const char *)sqlite3_column_text(stmt, 0);
        const char *vstr  = (const char *)sqlite3_column_text(stmt, 1);
        result = decodeAttr(vtype, vstr);
    } else if (error) {
        *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"no attribute '%@' on dataset '%@'", name, _name);
    }
    sqlite3_finalize(stmt);
    return result;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"SQLite provider opened read-only");
        return NO;
    }
    NSString *vtype, *vstr;
    encodeAttr(value, &vtype, &vstr);

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "INSERT OR REPLACE INTO dataset_attributes "
        "(dataset_id, name, value_type, value) VALUES (?, ?, ?, ?)",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _datasetId);
    sqlite3_bind_text(stmt, 2, [name UTF8String],  -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, [vtype UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, [vstr UTF8String],  -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return NO;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return YES;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"SQLite provider opened read-only");
        return NO;
    }
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "DELETE FROM dataset_attributes WHERE dataset_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _datasetId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return NO;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return YES;
}

- (NSArray<NSString *> *)attributeNames
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT name FROM dataset_attributes WHERE dataset_id = ? ORDER BY name",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _datasetId);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [names addObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)]];
    }
    sqlite3_finalize(stmt);
    return names;
}

@end

// ══════════════════════════════════════════════════════════════
// MPGOSqliteGroup
// ══════════════════════════════════════════════════════════════

@interface MPGOSqliteGroup : NSObject <MPGOStorageGroup> {
    sqlite3    *_db;
    int64_t     _groupId;
    NSString   *_name;
    BOOL        _readOnly;
}
- (instancetype)initWithDB:(sqlite3 *)db
                   groupId:(int64_t)groupId
                      name:(NSString *)name
                  readOnly:(BOOL)readOnly;
@end

@implementation MPGOSqliteGroup

- (instancetype)initWithDB:(sqlite3 *)db
                   groupId:(int64_t)groupId
                      name:(NSString *)name
                  readOnly:(BOOL)readOnly
{
    self = [super init];
    if (self) {
        _db       = db;
        _groupId  = groupId;
        _name     = [name copy];
        _readOnly = readOnly;
    }
    return self;
}

- (NSString *)name { return _name; }

// ── Children ────────────────────────────────────────────────

- (NSArray<NSString *> *)childNames
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    // Sub-groups
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT name FROM groups WHERE parent_id = ? ORDER BY name",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *n = (const char *)sqlite3_column_text(stmt, 0);
        if (n) [out addObject:[NSString stringWithUTF8String:n]];
    }
    sqlite3_finalize(stmt);

    // Datasets
    stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT name FROM datasets WHERE group_id = ? ORDER BY name",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *n = (const char *)sqlite3_column_text(stmt, 0);
        if (n) [out addObject:[NSString stringWithUTF8String:n]];
    }
    sqlite3_finalize(stmt);
    return out;
}

- (BOOL)hasChildNamed:(NSString *)name
{
    sqlite3_stmt *stmt = NULL;
    // Check groups
    sqlite3_prepare_v2(_db,
        "SELECT 1 FROM groups WHERE parent_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    BOOL found = (sqlite3_step(stmt) == SQLITE_ROW);
    sqlite3_finalize(stmt);
    if (found) return YES;

    // Check datasets
    stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT 1 FROM datasets WHERE group_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    found = (sqlite3_step(stmt) == SQLITE_ROW);
    sqlite3_finalize(stmt);
    return found;
}

- (id<MPGOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT id FROM groups WHERE parent_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    MPGOSqliteGroup *g = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        int64_t gid = sqlite3_column_int64(stmt, 0);
        g = [[MPGOSqliteGroup alloc] initWithDB:_db groupId:gid
                                            name:name readOnly:_readOnly];
    } else if (error) {
        *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"group '%@' not found in '%@'", name, _name);
    }
    sqlite3_finalize(stmt);
    return g;
}

- (id<MPGOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
            @"SQLite provider opened read-only");
        return nil;
    }
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
            @"'%@' already exists in '%@'", name, _name);
        return nil;
    }

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "INSERT INTO groups (parent_id, name) VALUES (?, ?)",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    int64_t newId = sqlite3_last_insert_rowid(_db);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return nil;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return [[MPGOSqliteGroup alloc] initWithDB:_db groupId:newId
                                          name:name readOnly:_readOnly];
}

- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"SQLite provider opened read-only");
        return NO;
    }

    // Try groups first (CASCADE handles descendants + attrs)
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT id FROM groups WHERE parent_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    int64_t childId = 0;
    BOOL isGroup = NO;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        childId = sqlite3_column_int64(stmt, 0);
        isGroup = YES;
    }
    sqlite3_finalize(stmt);

    if (isGroup) {
        stmt = NULL;
        sqlite3_prepare_v2(_db,
            "DELETE FROM groups WHERE id = ?", -1, &stmt, NULL);
        sqlite3_bind_int64(stmt, 1, childId);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
        return YES;
    }

    // Try datasets
    stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT id FROM datasets WHERE group_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    BOOL isDataset = NO;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        childId = sqlite3_column_int64(stmt, 0);
        isDataset = YES;
    }
    sqlite3_finalize(stmt);

    if (isDataset) {
        stmt = NULL;
        sqlite3_prepare_v2(_db,
            "DELETE FROM datasets WHERE id = ?", -1, &stmt, NULL);
        sqlite3_bind_int64(stmt, 1, childId);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    }
    return YES;
}

// ── Datasets ────────────────────────────────────────────────

- (id<MPGOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT id, kind, precision, shape_json, compound_fields "
        "FROM datasets WHERE group_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);

    MPGOSqliteDataset *ds = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        int64_t dsId         = sqlite3_column_int64(stmt, 0);
        const char *kind     = (const char *)sqlite3_column_text(stmt, 1);
        const char *precName = (const char *)sqlite3_column_text(stmt, 2);
        const char *shapeStr = (const char *)sqlite3_column_text(stmt, 3);
        const char *fieldsStr= (const char *)sqlite3_column_text(stmt, 4);

        MPGOPrecision prec = precisionFromName(precName);

        // Parse shape JSON: "[N]" or "[N,M,...]"
        NSMutableArray<NSNumber *> *shape = [NSMutableArray array];
        if (shapeStr) {
            NSData *sd = [NSData dataWithBytes:shapeStr length:strlen(shapeStr)];
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:sd
                                                           options:0 error:nil];
            for (id n in arr) [shape addObject:n];
        }

        // Parse compound_fields JSON if compound
        NSArray<MPGOCompoundField *> *fields = nil;
        if (kind && strcmp(kind, "compound") == 0 && fieldsStr) {
            NSData *fd = [NSData dataWithBytes:fieldsStr length:strlen(fieldsStr)];
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:fd
                                                           options:0 error:nil];
            NSMutableArray<MPGOCompoundField *> *mf = [NSMutableArray array];
            for (NSDictionary *d in arr) {
                NSString *fn = d[@"name"];
                NSString *fk = d[@"kind"];
                [mf addObject:[MPGOCompoundField fieldWithName:fn
                                                          kind:kindFromString(fk)]];
            }
            fields = mf;
        }

        ds = [[MPGOSqliteDataset alloc]
              initWithDB:_db datasetId:dsId name:name precision:prec
                   shape:shape fields:fields readOnly:_readOnly];
    } else if (error) {
        *error = MPGOMakeError(MPGOErrorDatasetOpen,
            @"dataset '%@' not found in '%@'", name, _name);
    }
    sqlite3_finalize(stmt);
    return ds;
}

- (id<MPGOStorageDataset>)createDatasetNamed:(NSString *)name
                                     precision:(MPGOPrecision)precision
                                        length:(NSUInteger)length
                                     chunkSize:(NSUInteger)chunkSize
                                   compression:(MPGOCompression)compression
                              compressionLevel:(int)compressionLevel
                                         error:(NSError **)error
{
    (void)chunkSize; (void)compression; (void)compressionLevel;
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"SQLite provider opened read-only");
        return nil;
    }
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"'%@' already exists in '%@'", name, _name);
        return nil;
    }

    NSString *precStr  = precisionName(precision);
    NSString *shapeStr = [NSString stringWithFormat:@"[%lu]", (unsigned long)length];

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "INSERT INTO datasets "
        "(group_id, name, kind, precision, shape_json, data) "
        "VALUES (?, ?, 'primitive', ?, ?, NULL)",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String],     -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, [precStr UTF8String],  -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, [shapeStr UTF8String], -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    int64_t newId = sqlite3_last_insert_rowid(_db);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return nil;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    NSArray<NSNumber *> *shape = @[@(length)];
    return [[MPGOSqliteDataset alloc]
            initWithDB:_db datasetId:newId name:name precision:precision
                 shape:shape fields:nil readOnly:_readOnly];
}

- (id<MPGOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(MPGOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(MPGOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error
{
    (void)chunks; (void)compression; (void)compressionLevel;
    if (shape.count == 1) {
        return [self createDatasetNamed:name
                              precision:precision
                                 length:[shape[0] unsignedIntegerValue]
                              chunkSize:0
                            compression:MPGOCompressionNone
                       compressionLevel:0
                                  error:error];
    }

    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"SQLite provider opened read-only");
        return nil;
    }
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"'%@' already exists in '%@'", name, _name);
        return nil;
    }

    NSString *precStr = precisionName(precision);

    // Build shape JSON
    NSError *jsonErr = nil;
    NSData *shapeData = [NSJSONSerialization dataWithJSONObject:shape
                                                        options:0 error:&jsonErr];
    NSString *shapeStr = [[NSString alloc]
        initWithData:shapeData encoding:NSUTF8StringEncoding];

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "INSERT INTO datasets "
        "(group_id, name, kind, precision, shape_json, data) "
        "VALUES (?, ?, 'primitive', ?, ?, NULL)",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String],     -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, [precStr UTF8String],  -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, [shapeStr UTF8String], -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    int64_t newId = sqlite3_last_insert_rowid(_db);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return nil;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return [[MPGOSqliteDataset alloc]
            initWithDB:_db datasetId:newId name:name precision:precision
                 shape:[shape copy] fields:nil readOnly:_readOnly];
}

- (id<MPGOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                 fields:(NSArray<MPGOCompoundField *> *)fields
                                                  count:(NSUInteger)count
                                                  error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"SQLite provider opened read-only");
        return nil;
    }
    if ([self hasChildNamed:name]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"'%@' already exists in '%@'", name, _name);
        return nil;
    }

    // Serialize fields to JSON: [{"name":"...","kind":"..."},...]
    NSMutableArray *fdArr = [NSMutableArray arrayWithCapacity:fields.count];
    for (MPGOCompoundField *f in fields) {
        [fdArr addObject:@{@"name": f.name, @"kind": kindString(f.kind)}];
    }
    NSData *fdData = [NSJSONSerialization dataWithJSONObject:fdArr
                                                     options:0 error:nil];
    NSString *fdStr = [[NSString alloc]
        initWithData:fdData encoding:NSUTF8StringEncoding];
    NSString *shapeStr = [NSString stringWithFormat:@"[%lu]", (unsigned long)count];

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "INSERT INTO datasets "
        "(group_id, name, kind, precision, shape_json, compound_fields, compound_rows) "
        "VALUES (?, ?, 'compound', NULL, ?, ?, '[]')",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String],     -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, [shapeStr UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, [fdStr UTF8String],    -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    int64_t newId = sqlite3_last_insert_rowid(_db);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return nil;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    NSArray<NSNumber *> *shape = @[@(count)];
    return [[MPGOSqliteDataset alloc]
            initWithDB:_db datasetId:newId name:name precision:0
                 shape:shape fields:[fields copy] readOnly:_readOnly];
}

// ── Group attributes ────────────────────────────────────────

- (BOOL)hasAttributeNamed:(NSString *)name
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT 1 FROM group_attributes WHERE group_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    BOOL found = (sqlite3_step(stmt) == SQLITE_ROW);
    sqlite3_finalize(stmt);
    return found;
}

- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT value_type, value FROM group_attributes "
        "WHERE group_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    id result = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *vtype = (const char *)sqlite3_column_text(stmt, 0);
        const char *vstr  = (const char *)sqlite3_column_text(stmt, 1);
        result = decodeAttr(vtype, vstr);
    } else if (error) {
        *error = MPGOMakeError(MPGOErrorAttributeRead,
            @"no attribute '%@' on group '%@'", name, _name);
    }
    sqlite3_finalize(stmt);
    return result;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"SQLite provider opened read-only");
        return NO;
    }
    NSString *vtype, *vstr;
    encodeAttr(value, &vtype, &vstr);

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "INSERT OR REPLACE INTO group_attributes "
        "(group_id, name, value_type, value) VALUES (?, ?, ?, ?)",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String],  -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, [vtype UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, [vstr UTF8String],  -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        if (error) *error = MPGOMakeError(MPGOErrorAttributeWrite,
            @"SQLite step error %d: %s", rc, sqlite3_errmsg(_db));
        return NO;
    }
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return YES;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    if (_readOnly) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"SQLite provider opened read-only");
        return NO;
    }
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "DELETE FROM group_attributes WHERE group_id = ? AND name = ?",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    sqlite3_bind_text(stmt, 2, [name UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return YES;
}

- (NSArray<NSString *> *)attributeNames
{
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT name FROM group_attributes WHERE group_id = ? ORDER BY name",
        -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, _groupId);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *n = (const char *)sqlite3_column_text(stmt, 0);
        if (n) [out addObject:[NSString stringWithUTF8String:n]];
    }
    sqlite3_finalize(stmt);
    return out;
}

@end

// ══════════════════════════════════════════════════════════════
// MPGOSqliteProvider
// ══════════════════════════════════════════════════════════════

@implementation MPGOSqliteProvider {
    sqlite3  *_db;
    NSString *_path;
    BOOL      _readOnly;
    BOOL      _open;
}

+ (void)load
{
    [[MPGOProviderRegistry sharedRegistry]
            registerProviderClass:self forName:@"sqlite"];
}

// ── URL helpers ─────────────────────────────────────────────

static NSString *resolveURLToPath(NSString *url)
{
    if ([url hasPrefix:@"sqlite://"]) {
        return [url substringFromIndex:[@"sqlite://" length]];
    }
    return url;
}

- (NSString *)providerName { return @"sqlite"; }

- (BOOL)supportsURL:(NSString *)url
{
    if ([url hasPrefix:@"sqlite://"]) return YES;
    NSString *lower = [url lowercaseString];
    return [lower hasSuffix:@".mpgo.sqlite"] || [lower hasSuffix:@".sqlite"];
}

// ── Open / close ─────────────────────────────────────────────

- (BOOL)openURL:(NSString *)url
           mode:(MPGOStorageOpenMode)mode
          error:(NSError **)error
{
    NSString *path = resolveURLToPath(url);
    return [self _openPath:path mode:mode error:error];
}

- (BOOL)_openPath:(NSString *)path
             mode:(MPGOStorageOpenMode)mode
            error:(NSError **)error
{
    _readOnly = (mode == MPGOStorageOpenModeRead);
    const char *cpath = [path fileSystemRepresentation];

    if (mode == MPGOStorageOpenModeRead) {
        if (access(cpath, F_OK) != 0) {
            if (error) *error = MPGOMakeError(MPGOErrorFileNotFound,
                @"SQLite file not found (mode=Read): %@", path);
            return NO;
        }
        if (sqlite3_open_v2(cpath, &_db,
                SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
                @"sqlite3_open failed: %s", sqlite3_errmsg(_db));
            sqlite3_close(_db); _db = NULL;
            return NO;
        }
        sqlite3_exec(_db, "PRAGMA foreign_keys = ON", NULL, NULL, NULL);
        sqlite3_exec(_db, "PRAGMA journal_mode = WAL", NULL, NULL, NULL);
        sqlite3_exec(_db, "PRAGMA synchronous = NORMAL", NULL, NULL, NULL);
    } else if (mode == MPGOStorageOpenModeReadWrite) {
        if (access(cpath, F_OK) != 0) {
            if (error) *error = MPGOMakeError(MPGOErrorFileNotFound,
                @"SQLite file not found (mode=ReadWrite): %@", path);
            return NO;
        }
        if (sqlite3_open_v2(cpath, &_db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
            if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
                @"sqlite3_open failed: %s", sqlite3_errmsg(_db));
            sqlite3_close(_db); _db = NULL;
            return NO;
        }
        if (![self _applyPragmasAndDDL:error]) return NO;
    } else if (mode == MPGOStorageOpenModeCreate) {
        // Truncate existing file
        if (access(cpath, F_OK) == 0) unlink(cpath);
        if (sqlite3_open_v2(cpath, &_db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
            if (error) *error = MPGOMakeError(MPGOErrorFileCreate,
                @"sqlite3_open failed: %s", sqlite3_errmsg(_db));
            sqlite3_close(_db); _db = NULL;
            return NO;
        }
        if (![self _applyPragmasAndDDL:error]) return NO;
    } else {
        // Append: create if absent
        if (sqlite3_open_v2(cpath, &_db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
            if (error) *error = MPGOMakeError(MPGOErrorFileCreate,
                @"sqlite3_open failed: %s", sqlite3_errmsg(_db));
            sqlite3_close(_db); _db = NULL;
            return NO;
        }
        if (![self _applyPragmasAndDDL:error]) return NO;
    }

    _path = [path copy];
    _open = YES;
    return YES;
}

/** Apply PRAGMAs, DDL, meta inserts, and ensure root group.
 *  Leaves the connection in an open transaction (BEGIN). */
- (BOOL)_applyPragmasAndDDL:(NSError **)error
{
    char *errmsg = NULL;

    sqlite3_exec(_db, "PRAGMA foreign_keys = ON", NULL, NULL, NULL);
    sqlite3_exec(_db, "PRAGMA journal_mode = WAL", NULL, NULL, NULL);
    sqlite3_exec(_db, "PRAGMA synchronous = NORMAL", NULL, NULL, NULL);

    if (sqlite3_exec(_db, kDDL, NULL, NULL, &errmsg) != SQLITE_OK) {
        if (error) *error = MPGOMakeError(MPGOErrorFileCreate,
            @"DDL failed: %s", errmsg);
        sqlite3_free(errmsg);
        sqlite3_close(_db); _db = NULL;
        return NO;
    }
    if (sqlite3_exec(_db, kMetaInserts, NULL, NULL, &errmsg) != SQLITE_OK) {
        if (error) *error = MPGOMakeError(MPGOErrorFileCreate,
            @"meta inserts failed: %s", errmsg);
        sqlite3_free(errmsg);
        sqlite3_close(_db); _db = NULL;
        return NO;
    }
    // Ensure root group '/'
    sqlite3_exec(_db,
        "INSERT OR IGNORE INTO groups (parent_id, name) VALUES (NULL, '/')",
        NULL, NULL, NULL);
    // Commit DDL and begin a new transaction for data writes
    sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
    return YES;
}

- (void)close
{
    if (_db) {
        // Commit any open transaction before closing
        sqlite3_exec(_db, "COMMIT", NULL, NULL, NULL);
        sqlite3_close(_db);
        _db = NULL;
    }
    _open = NO;
}

// ── StorageProvider contract ─────────────────────────────────

- (BOOL)isOpen { return _open; }

// ── Transactions (Appendix B Gap 11) ─────────────────────────
// The provider runs in a permanent BEGIN...COMMIT loop (writes sit
// in an implicit transaction after open; every attr setter ends with
// "COMMIT; BEGIN"). These overrides surface the batch boundaries
// explicitly for callers that opt in.

- (void)beginTransaction
{
    // No-op: the provider already opens a transaction after every
    // commit. Documented for API symmetry with HDF5/Memory.
}

- (void)commitTransaction
{
    if (_db) sqlite3_exec(_db, "COMMIT; BEGIN", NULL, NULL, NULL);
}

- (void)rollbackTransaction
{
    if (_db) sqlite3_exec(_db, "ROLLBACK; BEGIN", NULL, NULL, NULL);
}

- (id<MPGOStorageGroup>)rootGroupWithError:(NSError **)error
{
    if (!_db) {
        if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
            @"SQLite provider is not open");
        return nil;
    }

    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db,
        "SELECT id FROM groups WHERE parent_id IS NULL AND name = '/'",
        -1, &stmt, NULL);
    MPGOSqliteGroup *g = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        int64_t rootId = sqlite3_column_int64(stmt, 0);
        g = [[MPGOSqliteGroup alloc] initWithDB:_db groupId:rootId
                                            name:@"/" readOnly:_readOnly];
    } else if (error) {
        *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"root group '/' missing from SQLite store");
    }
    sqlite3_finalize(stmt);
    return g;
}

- (id)nativeHandle { return nil; }  /* sqlite3 * is a C pointer; not bridgeable */

@end
