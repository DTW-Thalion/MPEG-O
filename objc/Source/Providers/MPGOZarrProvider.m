/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOZarrProvider.h"
#import "MPGOProviderRegistry.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "ValueClasses/MPGOEnums.h"
#import <zlib.h>

// v0.9 M64.5-objc-java: JDK-style Inflater over libz. Python's
// numcodecs.Zlib emits raw zlib (2-byte header + Adler32 trailer),
// which libz's default inflate handles directly.
static NSData *zInflate(NSData *in, NSUInteger expectedBytes)
{
    if (in.length == 0) return nil;
    z_stream strm = {0};
    if (inflateInit(&strm) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:expectedBytes];
    strm.next_in = (Bytef *)in.bytes;
    strm.avail_in = (uInt)in.length;
    strm.next_out = out.mutableBytes;
    strm.avail_out = (uInt)expectedBytes;
    int rc = inflate(&strm, Z_FINISH);
    NSUInteger produced = expectedBytes - strm.avail_out;
    inflateEnd(&strm);
    if (rc != Z_STREAM_END && produced == 0) return nil;
    if (produced < expectedBytes) out.length = produced;
    return out;
}

// Reserved-attribute prefix (matches Python / Java).
static NSString *const kZ_KIND_ATTR   = @"_mpgo_kind";
static NSString *const kZ_SCHEMA_ATTR = @"_mpgo_schema";
static NSString *const kZ_ROWS_ATTR   = @"_mpgo_rows";
static NSString *const kZ_COUNT_ATTR  = @"_mpgo_count";
static NSString *const kZ_COMPOUND_KIND = @"compound";

// ─────────────────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────────────────

static NSString *zDtypeFor(MPGOPrecision p)
{
    switch (p) {
        case MPGOPrecisionFloat64: return @"<f8";
        case MPGOPrecisionFloat32: return @"<f4";
        case MPGOPrecisionInt64:   return @"<i8";
        case MPGOPrecisionInt32:   return @"<i4";
        case MPGOPrecisionUInt32:  return @"<u4";
        case MPGOPrecisionComplex128:
        default:
            [NSException raise:NSInvalidArgumentException
                        format:@"ZarrProvider: precision %ld not supported",
                               (long)p];
    }
    return nil;
}

static MPGOPrecision zPrecisionFor(NSString *dtype)
{
    if ([dtype isEqualToString:@"<f8"] || [dtype isEqualToString:@"|f8"] ||
        [dtype isEqualToString:@"float64"])  return MPGOPrecisionFloat64;
    if ([dtype isEqualToString:@"<f4"] || [dtype isEqualToString:@"|f4"] ||
        [dtype isEqualToString:@"float32"])  return MPGOPrecisionFloat32;
    if ([dtype isEqualToString:@"<i8"] || [dtype isEqualToString:@"|i8"] ||
        [dtype isEqualToString:@"int64"])    return MPGOPrecisionInt64;
    if ([dtype isEqualToString:@"<i4"] || [dtype isEqualToString:@"|i4"] ||
        [dtype isEqualToString:@"int32"])    return MPGOPrecisionInt32;
    if ([dtype isEqualToString:@"<u4"] || [dtype isEqualToString:@"|u4"] ||
        [dtype isEqualToString:@"uint32"])   return MPGOPrecisionUInt32;
    return MPGOPrecisionFloat64;  // caller should check dtype separately
}

static NSUInteger zBytesPerElement(MPGOPrecision p)
{
    switch (p) {
        case MPGOPrecisionFloat64:
        case MPGOPrecisionInt64:   return 8;
        case MPGOPrecisionFloat32:
        case MPGOPrecisionInt32:
        case MPGOPrecisionUInt32:  return 4;
        case MPGOPrecisionComplex128: return 16;
    }
    return 8;
}

static NSString *zChunkFileName(NSArray<NSNumber *> *idx)
{
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < idx.count; i++) {
        if (i > 0) [s appendString:@"."];
        [s appendFormat:@"%@", idx[i]];
    }
    return s;
}

static NSString *zKindToString(MPGOCompoundFieldKind kind)
{
    switch (kind) {
        case MPGOCompoundFieldKindUInt32:   return @"uint32";
        case MPGOCompoundFieldKindInt64:    return @"int64";
        case MPGOCompoundFieldKindFloat64:  return @"float64";
        case MPGOCompoundFieldKindVLString: return @"vl_string";
    }
    return @"vl_string";
}

static MPGOCompoundFieldKind zKindFromString(NSString *s)
{
    if ([s isEqualToString:@"uint32"])    return MPGOCompoundFieldKindUInt32;
    if ([s isEqualToString:@"int64"])     return MPGOCompoundFieldKindInt64;
    if ([s isEqualToString:@"float64"])   return MPGOCompoundFieldKindFloat64;
    return MPGOCompoundFieldKindVLString;
}

// Coerce attribute values into NSJSONSerialization-compatible forms.
static id zCoerceAttr(id v)
{
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSNull class]]) return v;
    if ([v isKindOfClass:[NSData class]]) {
        NSString *s = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
        return s ?: @"";
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[v count]];
        for (id x in v) [out addObject:zCoerceAttr(x)];
        return out;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (id k in v) out[[k description]] = zCoerceAttr(((NSDictionary *)v)[k]);
        return out;
    }
    return [v description];
}

static NSString *zJsonString(id obj)
{
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                                 options:0
                                                   error:&err];
    if (!d) return @"null";
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static id zJsonParse(NSString *s)
{
    if (s.length == 0) return nil;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nil;
    NSError *err = nil;
    return [NSJSONSerialization JSONObjectWithData:d
                                              options:NSJSONReadingAllowFragments
                                                error:&err];
}

// Read/write simple JSON files inside a group dir.
static BOOL zWriteFile(NSString *path, NSData *bytes, NSError **error)
{
    return [bytes writeToFile:path options:NSDataWritingAtomic error:error];
}

static NSData *zReadFile(NSString *path, NSError **error)
{
    return [NSData dataWithContentsOfFile:path options:0 error:error];
}

static BOOL zWriteZGroup(NSString *dir, NSError **error)
{
    NSData *d = [@"{\"zarr_format\":2}" dataUsingEncoding:NSUTF8StringEncoding];
    return zWriteFile([dir stringByAppendingPathComponent:@".zgroup"], d, error);
}

static BOOL zWriteZArray(NSString *dir, NSArray<NSNumber *> *shape,
                           NSArray<NSNumber *> *chunks, MPGOPrecision p,
                           NSError **error)
{
    NSDictionary *meta = @{
        @"chunks":       chunks,
        @"compressor":   [NSNull null],
        @"dtype":        zDtypeFor(p),
        @"fill_value":   @(0),
        @"filters":      [NSNull null],
        @"order":        @"C",
        @"shape":        shape,
        @"zarr_format":  @(2),
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:meta
                                                 options:NSJSONWritingSortedKeys
                                                   error:error];
    if (!d) return NO;
    return zWriteFile([dir stringByAppendingPathComponent:@".zarray"], d, error);
}

static NSDictionary *zReadZArray(NSString *dir, NSError **error)
{
    NSData *d = zReadFile([dir stringByAppendingPathComponent:@".zarray"], error);
    if (!d) return nil;
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:error];
}

static NSMutableDictionary *zReadZAttrs(NSString *dir)
{
    NSError *err = nil;
    NSData *d = zReadFile([dir stringByAppendingPathComponent:@".zattrs"], &err);
    if (!d) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        return [NSMutableDictionary dictionary];
    }
    return [NSMutableDictionary dictionaryWithDictionary:obj];
}

static BOOL zWriteZAttrs(NSString *dir, NSDictionary *attrs, NSError **error)
{
    NSString *path = [dir stringByAppendingPathComponent:@".zattrs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (attrs.count == 0) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:NULL];
        }
        return YES;
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:attrs
                                                 options:NSJSONWritingSortedKeys
                                                   error:error];
    if (!d) return NO;
    return zWriteFile(path, d, error);
}

static NSArray *zSchemaToList(NSArray<MPGOCompoundField *> *fields)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:fields.count];
    for (MPGOCompoundField *f in fields) {
        [out addObject:@{@"name": f.name, @"kind": zKindToString(f.kind)}];
    }
    return out;
}

static NSArray<MPGOCompoundField *> *zSchemaFromList(NSArray *list)
{
    NSMutableArray<MPGOCompoundField *> *out = [NSMutableArray array];
    for (NSDictionary *entry in list) {
        MPGOCompoundField *f =
            [[MPGOCompoundField alloc] initWithName:entry[@"name"]
                                                kind:zKindFromString(entry[@"kind"])];
        [out addObject:f];
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// Primitive dataset adapter
// ─────────────────────────────────────────────────────────────────────────

@interface _ZPrimitiveDataset : NSObject <MPGOStorageDataset>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, assign) MPGOPrecision precision;
@property (nonatomic, copy) NSArray<NSNumber *> *shape;
@property (nonatomic, copy) NSArray<NSNumber *> *chunks;
@property (nonatomic, strong) id compressor;  // v0.9: nil = uncompressed; NSDictionary{id=zlib,level=…}
@end

@implementation _ZPrimitiveDataset

- (NSArray<MPGOCompoundField *> *)compoundFields { return nil; }

- (NSUInteger)length
{
    return self.shape.count > 0 ? self.shape[0].unsignedIntegerValue : 0;
}

- (NSUInteger)totalElements
{
    NSUInteger n = 1;
    for (NSNumber *d in self.shape) n *= d.unsignedIntegerValue;
    return n;
}

- (NSUInteger)chunkElements
{
    NSUInteger n = 1;
    for (NSNumber *c in self.chunks) n *= c.unsignedIntegerValue;
    return n;
}

- (NSData *)readChunkAt:(NSArray<NSNumber *> *)idx bytesPerElement:(NSUInteger)bpe
{
    NSString *fname = zChunkFileName(idx);
    NSString *path = [self.dir stringByAppendingPathComponent:fname];
    NSUInteger chunkBytes = self.chunkElements * bpe;
    NSError *err = nil;
    NSData *raw = zReadFile(path, &err);
    if (!raw) {
        return [NSMutableData dataWithLength:chunkBytes];  // fill_value=0
    }
    // v0.9: decompress if a compressor is set.
    if (self.compressor && ![self.compressor isKindOfClass:[NSNull class]]) {
        NSData *plain = zInflate(raw, chunkBytes);
        if (!plain) return [NSMutableData dataWithLength:chunkBytes];
        raw = plain;
    }
    if (raw.length >= chunkBytes) return [raw subdataWithRange:NSMakeRange(0, chunkBytes)];
    NSMutableData *padded = [NSMutableData dataWithLength:chunkBytes];
    memcpy(padded.mutableBytes, raw.bytes, raw.length);
    return padded;
}

- (void)copyChunk:(NSData *)chunkBytes
             into:(NSMutableData *)out
          atIndex:(NSArray<NSNumber *> *)idx
  bytesPerElement:(NSUInteger)bpe
{
    NSUInteger rank = self.shape.count;
    NSUInteger *origin = calloc(rank, sizeof(NSUInteger));
    NSUInteger *logicalSize = calloc(rank, sizeof(NSUInteger));
    for (NSUInteger i = 0; i < rank; i++) {
        origin[i] = idx[i].unsignedIntegerValue *
                    self.chunks[i].unsignedIntegerValue;
        NSUInteger end = MIN(origin[i] + self.chunks[i].unsignedIntegerValue,
                              self.shape[i].unsignedIntegerValue);
        logicalSize[i] = end - origin[i];
    }
    NSUInteger *sub = calloc(rank, sizeof(NSUInteger));
    const uint8_t *src = chunkBytes.bytes;
    uint8_t *dst = out.mutableBytes;

    // Iterate over the logical clipped chunk region.
    while (YES) {
        // Source offset in chunk (chunk shape stride).
        NSUInteger srcIdx = 0, srcStride = 1;
        for (NSInteger i = (NSInteger)rank - 1; i >= 0; i--) {
            srcIdx += sub[i] * srcStride;
            srcStride *= self.chunks[i].unsignedIntegerValue;
        }
        // Destination offset in global buffer (shape stride).
        NSUInteger dstIdx = 0, dstStride = 1;
        for (NSInteger i = (NSInteger)rank - 1; i >= 0; i--) {
            dstIdx += (origin[i] + sub[i]) * dstStride;
            dstStride *= self.shape[i].unsignedIntegerValue;
        }
        memcpy(dst + dstIdx * bpe, src + srcIdx * bpe, bpe);

        // Increment sub[] with carry.
        NSInteger i = (NSInteger)rank - 1;
        while (i >= 0) {
            sub[i]++;
            if (sub[i] < logicalSize[i]) break;
            sub[i] = 0;
            i--;
        }
        if (i < 0) break;
    }
    free(origin);
    free(logicalSize);
    free(sub);
}

- (id)readAll:(NSError **)error
{
    (void)error;
    NSUInteger bpe = zBytesPerElement(self.precision);
    NSUInteger total = [self totalElements];
    NSMutableData *out = [NSMutableData dataWithLength:total * bpe];

    // Enumerate chunk grid.
    NSUInteger rank = self.shape.count;
    NSUInteger *counts = calloc(rank, sizeof(NSUInteger));
    NSUInteger *idx = calloc(rank, sizeof(NSUInteger));
    for (NSUInteger i = 0; i < rank; i++) {
        NSUInteger s = self.shape[i].unsignedIntegerValue;
        NSUInteger c = self.chunks[i].unsignedIntegerValue;
        counts[i] = (s + c - 1) / c;
    }

    while (YES) {
        NSMutableArray<NSNumber *> *idxArr = [NSMutableArray arrayWithCapacity:rank];
        for (NSUInteger i = 0; i < rank; i++) [idxArr addObject:@(idx[i])];
        NSData *chunkBytes = [self readChunkAt:idxArr bytesPerElement:bpe];
        [self copyChunk:chunkBytes into:out atIndex:idxArr bytesPerElement:bpe];

        NSInteger i = (NSInteger)rank - 1;
        while (i >= 0) {
            idx[i]++;
            if (idx[i] < counts[i]) break;
            idx[i] = 0;
            i--;
        }
        if (i < 0) break;
    }
    free(counts);
    free(idx);
    return out;
}

- (id)readSliceAtOffset:(NSUInteger)offset count:(NSUInteger)count error:(NSError **)error
{
    NSData *all = [self readAll:error];
    NSUInteger bpe = zBytesPerElement(self.precision);
    NSUInteger beg = offset * bpe;
    NSUInteger len = count * bpe;
    if (beg + len > all.length) len = all.length - beg;
    return [all subdataWithRange:NSMakeRange(beg, len)];
}

- (void)writeChunkFrom:(const uint8_t *)src
                    at:(NSArray<NSNumber *> *)idx
       bytesPerElement:(NSUInteger)bpe
{
    NSUInteger rank = self.shape.count;
    NSUInteger chunkBytes = [self chunkElements] * bpe;
    NSMutableData *buf = [NSMutableData dataWithLength:chunkBytes];
    uint8_t *dst = buf.mutableBytes;

    NSUInteger *origin = calloc(rank, sizeof(NSUInteger));
    NSUInteger *logicalSize = calloc(rank, sizeof(NSUInteger));
    for (NSUInteger i = 0; i < rank; i++) {
        origin[i] = idx[i].unsignedIntegerValue *
                    self.chunks[i].unsignedIntegerValue;
        NSUInteger end = MIN(origin[i] + self.chunks[i].unsignedIntegerValue,
                              self.shape[i].unsignedIntegerValue);
        logicalSize[i] = end - origin[i];
    }
    NSUInteger *sub = calloc(rank, sizeof(NSUInteger));
    while (YES) {
        NSUInteger srcIdx = 0, srcStride = 1;
        for (NSInteger i = (NSInteger)rank - 1; i >= 0; i--) {
            srcIdx += (origin[i] + sub[i]) * srcStride;
            srcStride *= self.shape[i].unsignedIntegerValue;
        }
        NSUInteger dstIdx = 0, dstStride = 1;
        for (NSInteger i = (NSInteger)rank - 1; i >= 0; i--) {
            dstIdx += sub[i] * dstStride;
            dstStride *= self.chunks[i].unsignedIntegerValue;
        }
        memcpy(dst + dstIdx * bpe, src + srcIdx * bpe, bpe);

        NSInteger i = (NSInteger)rank - 1;
        while (i >= 0) {
            sub[i]++;
            if (sub[i] < logicalSize[i]) break;
            sub[i] = 0;
            i--;
        }
        if (i < 0) break;
    }
    free(origin);
    free(logicalSize);
    free(sub);

    NSString *path = [self.dir stringByAppendingPathComponent:zChunkFileName(idx)];
    [buf writeToFile:path atomically:YES];
}

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    if (![data isKindOfClass:[NSData class]]) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ZarrProvider primitive writeAll expects NSData");
        return NO;
    }
    NSData *src = data;
    NSUInteger bpe = zBytesPerElement(self.precision);
    NSUInteger total = [self totalElements];
    NSUInteger expected = total * bpe;
    if (src.length != expected) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ZarrProvider writeAll: expected %lu bytes, got %lu",
            (unsigned long)expected, (unsigned long)src.length);
        return NO;
    }

    NSUInteger rank = self.shape.count;
    NSUInteger *counts = calloc(rank, sizeof(NSUInteger));
    NSUInteger *idx = calloc(rank, sizeof(NSUInteger));
    for (NSUInteger i = 0; i < rank; i++) {
        NSUInteger s = self.shape[i].unsignedIntegerValue;
        NSUInteger c = self.chunks[i].unsignedIntegerValue;
        counts[i] = (s + c - 1) / c;
    }
    const uint8_t *srcBytes = src.bytes;
    while (YES) {
        NSMutableArray<NSNumber *> *idxArr = [NSMutableArray arrayWithCapacity:rank];
        for (NSUInteger i = 0; i < rank; i++) [idxArr addObject:@(idx[i])];
        [self writeChunkFrom:srcBytes at:idxArr bytesPerElement:bpe];

        NSInteger i = (NSInteger)rank - 1;
        while (i >= 0) {
            idx[i]++;
            if (idx[i] < counts[i]) break;
            idx[i] = 0;
            i--;
        }
        if (i < 0) break;
    }
    free(counts);
    free(idx);
    return YES;
}

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
        @"readRows called on primitive dataset '%@'", self.name);
    return nil;
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    // Primitive LE layout IS the canonical layout for Zarr.
    return [self readAll:error];
}

- (BOOL)hasAttributeNamed:(NSString *)n
{
    return zReadZAttrs(self.dir)[n] != nil;
}
- (id)attributeValueForName:(NSString *)n error:(NSError **)error
{
    (void)error;
    return zReadZAttrs(self.dir)[n];
}
- (BOOL)setAttributeValue:(id)v forName:(NSString *)n error:(NSError **)error
{
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    a[n] = zCoerceAttr(v);
    return zWriteZAttrs(self.dir, a, error);
}
- (BOOL)deleteAttributeNamed:(NSString *)n error:(NSError **)error
{
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    [a removeObjectForKey:n];
    return zWriteZAttrs(self.dir, a, error);
}
- (NSArray<NSString *> *)attributeNames
{
    return [zReadZAttrs(self.dir) allKeys];
}

@end

// ─────────────────────────────────────────────────────────────────────────
// Compound dataset adapter
// ─────────────────────────────────────────────────────────────────────────

@interface _ZCompoundDataset : NSObject <MPGOStorageDataset>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, copy) NSArray<MPGOCompoundField *> *fields;
@property (nonatomic, assign) NSUInteger count;
@end

@implementation _ZCompoundDataset

- (MPGOPrecision)precision { return MPGOPrecisionFloat64; }  // N/A
- (NSArray<NSNumber *> *)shape  { return @[@(self.count)]; }
- (NSArray<NSNumber *> *)chunks { return nil; }
- (NSUInteger)length { return self.count; }
- (NSArray<MPGOCompoundField *> *)compoundFields { return self.fields; }

- (id)readAll:(NSError **)error
{
    (void)error;
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    NSString *rowsJson = a[kZ_ROWS_ATTR] ?: @"[]";
    id parsed = zJsonParse(rowsJson);
    if (![parsed isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[parsed count]];
    for (NSDictionary *row in parsed) {
        NSMutableDictionary *keep = [NSMutableDictionary dictionary];
        for (MPGOCompoundField *f in self.fields) {
            id v = row[f.name] ?: [NSNull null];
            keep[f.name] = v;
        }
        [out addObject:keep];
    }
    return out;
}
- (id)readSliceAtOffset:(NSUInteger)offset count:(NSUInteger)count error:(NSError **)error
{
    NSArray *all = [self readAll:error];
    NSUInteger end = MIN(all.count, offset + count);
    if (offset >= all.count) return @[];
    return [all subarrayWithRange:NSMakeRange(offset, end - offset)];
}
- (BOOL)writeAll:(id)data error:(NSError **)error
{
    if (![data isKindOfClass:[NSArray class]]) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"compound writeAll expects NSArray<NSDictionary*>");
        return NO;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *r in data) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (MPGOCompoundField *f in self.fields) {
            id v = r[f.name];
            switch (f.kind) {
                case MPGOCompoundFieldKindVLString:
                    out[f.name] = v ? [v description] : @"";
                    break;
                case MPGOCompoundFieldKindFloat64:
                    out[f.name] = @([v doubleValue]);
                    break;
                case MPGOCompoundFieldKindUInt32:
                case MPGOCompoundFieldKindInt64:
                    out[f.name] = @([v longLongValue]);
                    break;
            }
        }
        [rows addObject:out];
    }
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    a[kZ_ROWS_ATTR] = zJsonString(rows);
    a[kZ_COUNT_ATTR] = @(rows.count);
    self.count = rows.count;
    return zWriteZAttrs(self.dir, a, error);
}
- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    return [self readAll:error];
}
- (NSData *)readCanonicalBytes:(NSError **)error
{
    NSArray<NSDictionary *> *rows = [self readAll:error];
    NSMutableData *out = [NSMutableData data];
    for (NSDictionary *row in rows) {
        for (MPGOCompoundField *f in self.fields) {
            id v = row[f.name];
            switch (f.kind) {
                case MPGOCompoundFieldKindVLString: {
                    NSString *s = ([v isKindOfClass:[NSString class]] ? v : @"");
                    NSData *b = [s dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
                    uint32_t len = (uint32_t)b.length;
                    uint8_t le[4] = { (uint8_t)(len & 0xFF),
                                       (uint8_t)((len >> 8) & 0xFF),
                                       (uint8_t)((len >> 16) & 0xFF),
                                       (uint8_t)((len >> 24) & 0xFF) };
                    [out appendBytes:le length:4];
                    [out appendData:b];
                    break;
                }
                case MPGOCompoundFieldKindFloat64: {
                    double d = [v doubleValue];
                    [out appendBytes:&d length:8];
                    break;
                }
                case MPGOCompoundFieldKindUInt32: {
                    uint32_t u = (uint32_t)[v longLongValue];
                    [out appendBytes:&u length:4];
                    break;
                }
                case MPGOCompoundFieldKindInt64: {
                    int64_t i = (int64_t)[v longLongValue];
                    [out appendBytes:&i length:8];
                    break;
                }
            }
        }
    }
    return out;
}

- (BOOL)hasAttributeNamed:(NSString *)n
{
    if ([n hasPrefix:@"_mpgo_"]) return NO;
    return zReadZAttrs(self.dir)[n] != nil;
}
- (id)attributeValueForName:(NSString *)n error:(NSError **)error
{
    (void)error; return zReadZAttrs(self.dir)[n];
}
- (BOOL)setAttributeValue:(id)v forName:(NSString *)n error:(NSError **)error
{
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    a[n] = zCoerceAttr(v);
    return zWriteZAttrs(self.dir, a, error);
}
- (BOOL)deleteAttributeNamed:(NSString *)n error:(NSError **)error
{
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    [a removeObjectForKey:n];
    return zWriteZAttrs(self.dir, a, error);
}
- (NSArray<NSString *> *)attributeNames
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in zReadZAttrs(self.dir)) {
        if (![k hasPrefix:@"_mpgo_"]) [out addObject:k];
    }
    return out;
}

@end

// ─────────────────────────────────────────────────────────────────────────
// Group adapter
// ─────────────────────────────────────────────────────────────────────────

@interface _ZGroup : NSObject <MPGOStorageGroup>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *dir;
@end

@implementation _ZGroup

- (NSString *)childPath:(NSString *)n
{
    return [self.dir stringByAppendingPathComponent:n];
}

- (BOOL)isCompoundDir:(NSString *)p
{
    NSMutableDictionary *a = zReadZAttrs(p);
    return [a[kZ_KIND_ATTR] isEqualToString:kZ_COMPOUND_KIND];
}

- (BOOL)isArrayDir:(NSString *)p
{
    return [[NSFileManager defaultManager] fileExistsAtPath:
        [p stringByAppendingPathComponent:@".zarray"]];
}

- (NSArray<NSString *> *)childNames
{
    NSError *err = nil;
    NSArray<NSString *> *entries =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.dir
                                                             error:&err] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in entries) {
        if ([n hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:[self childPath:n]
                                              isDirectory:&isDir];
        if (isDir) [out addObject:n];
    }
    return out;
}

- (BOOL)hasChildNamed:(NSString *)n
{
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:[self childPath:n]
                                                 isDirectory:&isDir] && isDir;
}

- (id<MPGOStorageGroup>)openGroupNamed:(NSString *)n error:(NSError **)error
{
    NSString *p = [self childPath:n];
    if (![[NSFileManager defaultManager] fileExistsAtPath:
            [p stringByAppendingPathComponent:@".zgroup"]]) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"Zarr: group %@ not found", n);
        return nil;
    }
    if ([self isCompoundDir:p]) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupOpen,
            @"Zarr: '%@' is a compound dataset; use openDatasetNamed:", n);
        return nil;
    }
    _ZGroup *g = [[_ZGroup alloc] init];
    g.name = n; g.dir = p;
    return g;
}

- (id<MPGOStorageGroup>)createGroupNamed:(NSString *)n error:(NSError **)error
{
    NSString *p = [self childPath:n];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
            @"Zarr: '%@' already exists", n);
        return nil;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:p
                                    withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:error]) return nil;
    if (!zWriteZGroup(p, error)) return nil;
    _ZGroup *g = [[_ZGroup alloc] init];
    g.name = n; g.dir = p;
    return g;
}

- (BOOL)deleteChildNamed:(NSString *)n error:(NSError **)error
{
    NSString *p = [self childPath:n];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return YES;
    return [[NSFileManager defaultManager] removeItemAtPath:p error:error];
}

- (id<MPGOStorageDataset>)openDatasetNamed:(NSString *)n error:(NSError **)error
{
    NSString *p = [self childPath:n];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
            @"Zarr: dataset %@ not found", n);
        return nil;
    }
    if ([self isCompoundDir:p]) {
        NSMutableDictionary *a = zReadZAttrs(p);
        id schemaBlob = a[kZ_SCHEMA_ATTR];
        id schemaList = schemaBlob;
        if ([schemaBlob isKindOfClass:[NSString class]]) {
            schemaList = zJsonParse(schemaBlob);
        }
        NSArray<MPGOCompoundField *> *fields =
            [schemaList isKindOfClass:[NSArray class]]
                ? zSchemaFromList(schemaList) : @[];
        NSNumber *c = a[kZ_COUNT_ATTR];
        _ZCompoundDataset *ds = [[_ZCompoundDataset alloc] init];
        ds.name = n; ds.dir = p; ds.fields = fields;
        ds.count = c.unsignedIntegerValue;
        return ds;
    }
    if ([self isArrayDir:p]) {
        NSError *err = nil;
        NSDictionary *meta = zReadZArray(p, &err);
        if (!meta) {
            if (error) *error = err; return nil;
        }
        id comp = meta[@"compressor"];
        if (comp && ![comp isKindOfClass:[NSNull class]]) {
            // v0.9 M64.5-objc-java: support zlib-compressed chunks so
            // ObjC can read Python-written zarr .mpgo. Non-zlib codecs
            // (blosc / lz4 / zstd) still rejected.
            NSString *codecId = nil;
            if ([comp isKindOfClass:[NSDictionary class]]) {
                codecId = [(NSDictionary *)comp objectForKey:@"id"];
            }
            if (![codecId isEqualToString:@"zlib"]) {
                if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
                    @"Zarr (ObjC): compressor '%@' not supported in v0.9 "
                    @"(array %@ uses %@)", codecId ?: @"(unknown)", n, comp);
                return nil;
            }
        }
        _ZPrimitiveDataset *ds = [[_ZPrimitiveDataset alloc] init];
        ds.name = n; ds.dir = p;
        ds.precision = zPrecisionFor(meta[@"dtype"]);
        ds.shape = meta[@"shape"];
        ds.chunks = meta[@"chunks"];
        ds.compressor = comp;
        return ds;
    }
    if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
        @"Zarr: '%@' is a group, not a dataset", n);
    return nil;
}

- (id<MPGOStorageDataset>)createDatasetNamed:(NSString *)n
                                    precision:(MPGOPrecision)precision
                                       length:(NSUInteger)length
                                    chunkSize:(NSUInteger)chunkSize
                                  compression:(MPGOCompression)compression
                             compressionLevel:(int)compressionLevel
                                        error:(NSError **)error
{
    (void)compressionLevel;
    if (compression != MPGOCompressionNone) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"ZarrProvider: compression not implemented in v0.8");
        return nil;
    }
    NSString *p = [self childPath:n];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"Zarr: '%@' already exists", n);
        return nil;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:p
                                    withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:error]) return nil;
    NSArray *shape = @[@(length)];
    NSArray *chunks = @[@(chunkSize > 0 ? chunkSize : length)];
    if (!zWriteZArray(p, shape, chunks, precision, error)) return nil;
    _ZPrimitiveDataset *ds = [[_ZPrimitiveDataset alloc] init];
    ds.name = n; ds.dir = p; ds.precision = precision;
    ds.shape = shape; ds.chunks = chunks;
    return ds;
}

- (id<MPGOStorageDataset>)createDatasetNDNamed:(NSString *)n
                                      precision:(MPGOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(MPGOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error
{
    (void)compressionLevel;
    if (compression != MPGOCompressionNone) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"ZarrProvider: compression not implemented in v0.8");
        return nil;
    }
    NSString *p = [self childPath:n];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"Zarr: '%@' already exists", n);
        return nil;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:p
                                    withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:error]) return nil;
    NSArray<NSNumber *> *resolvedChunks = chunks ?: shape;
    if (!zWriteZArray(p, shape, resolvedChunks, precision, error)) return nil;
    _ZPrimitiveDataset *ds = [[_ZPrimitiveDataset alloc] init];
    ds.name = n; ds.dir = p; ds.precision = precision;
    ds.shape = shape; ds.chunks = resolvedChunks;
    return ds;
}

- (id<MPGOStorageDataset>)createCompoundDatasetNamed:(NSString *)n
                                                fields:(NSArray<MPGOCompoundField *> *)fields
                                                 count:(NSUInteger)count
                                                 error:(NSError **)error
{
    NSString *p = [self childPath:n];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"Zarr: '%@' already exists", n);
        return nil;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:p
                                    withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:error]) return nil;
    if (!zWriteZGroup(p, error)) return nil;
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[kZ_KIND_ATTR]   = kZ_COMPOUND_KIND;
    a[kZ_SCHEMA_ATTR] = zJsonString(zSchemaToList(fields));
    a[kZ_COUNT_ATTR]  = @(count);
    a[kZ_ROWS_ATTR]   = @"[]";
    if (!zWriteZAttrs(p, a, error)) return nil;
    _ZCompoundDataset *ds = [[_ZCompoundDataset alloc] init];
    ds.name = n; ds.dir = p; ds.fields = fields; ds.count = count;
    return ds;
}

- (BOOL)hasAttributeNamed:(NSString *)n
{
    if ([n hasPrefix:@"_mpgo_"]) return NO;
    return zReadZAttrs(self.dir)[n] != nil;
}
- (id)attributeValueForName:(NSString *)n error:(NSError **)error
{
    (void)error; return zReadZAttrs(self.dir)[n];
}
- (BOOL)setAttributeValue:(id)v forName:(NSString *)n error:(NSError **)error
{
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    a[n] = zCoerceAttr(v);
    return zWriteZAttrs(self.dir, a, error);
}
- (BOOL)deleteAttributeNamed:(NSString *)n error:(NSError **)error
{
    NSMutableDictionary *a = zReadZAttrs(self.dir);
    [a removeObjectForKey:n];
    return zWriteZAttrs(self.dir, a, error);
}
- (NSArray<NSString *> *)attributeNames
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in zReadZAttrs(self.dir)) {
        if (![k hasPrefix:@"_mpgo_"]) [out addObject:k];
    }
    return out;
}

@end

// ─────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────

@interface MPGOZarrProvider ()
@property (nonatomic, copy) NSString *rootDir;
@property (nonatomic, assign) BOOL open;
@end

@implementation MPGOZarrProvider

- (NSString *)providerName { return @"zarr"; }

- (BOOL)supportsURL:(NSString *)url
{
    return [url hasPrefix:@"zarr://"] || [url hasSuffix:@".zarr"];
}

- (NSString *)pathForURL:(NSString *)url
{
    NSString *raw = url;
    if ([raw hasPrefix:@"zarr+memory://"] || [raw hasPrefix:@"zarr+s3://"]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"ZarrProvider (ObjC): in-memory and S3 stores "
                           @"are Python-only in v0.8 (M52 scope)."];
    }
    if ([raw hasPrefix:@"zarr://"]) {
        raw = [raw substringFromIndex:[@"zarr://" length]];
        while ([raw hasPrefix:@"//"]) raw = [raw substringFromIndex:1];
    }
    return raw;
}

- (BOOL)openURL:(NSString *)url mode:(MPGOStorageOpenMode)mode error:(NSError **)error
{
    if (self.open) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ZarrProvider already open");
        return NO;
    }
    self.rootDir = [self pathForURL:url];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *zgroup = [self.rootDir stringByAppendingPathComponent:@".zgroup"];
    switch (mode) {
        case MPGOStorageOpenModeCreate: {
            if ([fm fileExistsAtPath:self.rootDir]) {
                [fm removeItemAtPath:self.rootDir error:NULL];
            }
            if (![fm createDirectoryAtPath:self.rootDir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:error]) return NO;
            if (!zWriteZGroup(self.rootDir, error)) return NO;
            break;
        }
        case MPGOStorageOpenModeRead: {
            if (![fm fileExistsAtPath:zgroup]) {
                if (error) *error = MPGOMakeError(MPGOErrorFileOpen,
                    @"Zarr store not found: %@", self.rootDir);
                return NO;
            }
            break;
        }
        case MPGOStorageOpenModeReadWrite:
        case MPGOStorageOpenModeAppend: {
            if (![fm fileExistsAtPath:self.rootDir]) {
                if (![fm createDirectoryAtPath:self.rootDir
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:error]) return NO;
            }
            if (![fm fileExistsAtPath:zgroup]) {
                if (!zWriteZGroup(self.rootDir, error)) return NO;
            }
            break;
        }
    }
    self.open = YES;
    return YES;
}

- (id<MPGOStorageGroup>)rootGroupWithError:(NSError **)error
{
    (void)error;
    if (!self.open) return nil;
    _ZGroup *g = [[_ZGroup alloc] init];
    g.name = @"/"; g.dir = self.rootDir;
    return g;
}

- (BOOL)isOpen { return self.open; }
- (void)close  { self.open = NO; }
- (id)nativeHandle { return self.rootDir; }

- (BOOL)supportsChunking { return YES; }
- (BOOL)supportsCompression { return NO; }

+ (void)load
{
    [[MPGOProviderRegistry sharedRegistry]
            registerProviderClass:self forName:@"zarr"];
}

@end
