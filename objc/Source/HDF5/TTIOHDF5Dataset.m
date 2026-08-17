/*
 * TTIOHDF5Dataset.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOHDF5Dataset
 * Inherits From: NSObject
 * Declared In:   HDF5/TTIOHDF5Dataset.h
 *
 * Thin wrapper around a 1-D HDF5 dataset. Owns its dataset id and
 * the type id (for compound types); both are released in -dealloc.
 * Hyperslab reads support partial-spectrum access without
 * materialising the entire dataset.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOHDF5Dataset.h"
#import "TTIOHDF5File.h"
#import "TTIOHDF5Errors.h"
#import "TTIOHDF5Types.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import <hdf5.h>

@implementation TTIOHDF5Dataset
{
    hid_t          _did;
    TTIOPrecision  _precision;
    NSUInteger     _length;
    id             _retainer;
    TTIOHDF5File  *_file;   // cached owning file for wrapper rwlock (M23)
    BOOL           _extendable;
}

- (instancetype)initWithDatasetId:(hid_t)did
                        precision:(TTIOPrecision)precision
                           length:(NSUInteger)length
                         retainer:(id)retainer
{
    return [self initWithDatasetId:did precision:precision length:length
                          retainer:retainer extendable:NO];
}

- (instancetype)initWithDatasetId:(hid_t)did
                        precision:(TTIOPrecision)precision
                           length:(NSUInteger)length
                         retainer:(id)retainer
                       extendable:(BOOL)extendable
{
    self = [super init];
    if (self) {
        _did = did;
        _precision = precision;
        _length = length;
        _retainer = retainer;
        _extendable = extendable;
        if ([retainer respondsToSelector:@selector(owningFile)]) {
            _file = [(id)retainer owningFile];
        }
    }
    return self;
}

- (hid_t)datasetId         { return _did; }
- (TTIOPrecision)precision { return _precision; }
- (NSUInteger)length       { return _length; }
- (BOOL)isExtendable       { return _extendable; }

- (BOOL)_writeRange:(NSData *)data atOffset:(NSUInteger)offset count:(NSUInteger)n error:(NSError **)error
{
    hid_t fspace = H5Dget_space(_did);
    hsize_t off[1] = { (hsize_t)offset };
    hsize_t cnt[1] = { (hsize_t)n };
    H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);
    hid_t mspace = H5Screate_simple(1, cnt, NULL);
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dwrite(_did, htype, mspace, fspace, H5P_DEFAULT, data.bytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    H5Sclose(mspace); H5Sclose(fspace);
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite (hyperslab) failed");
        return NO;
    }
    return YES;
}

- (BOOL)appendData:(NSData *)data error:(NSError **)error
{
    if (!_extendable) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"dataset is not extendable");
        return NO;
    }
    NSUInteger elem = TTIOPrecisionElementSize(_precision);
    NSUInteger n = elem ? data.length / elem : 0;
    if (n == 0) return YES;
    [_file lockForWriting];
    hsize_t newDims[1] = { (hsize_t)(_length + n) };
    herr_t rc = H5Dset_extent(_did, newDims);
    BOOL ok = NO;
    if (rc < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dset_extent failed");
    } else {
        ok = [self _writeRange:data atOffset:_length count:n error:error];
        if (ok) _length += n;
    }
    [_file unlockForWriting];
    return ok;
}

- (BOOL)writeSlice:(NSData *)data atOffset:(NSUInteger)offset error:(NSError **)error
{
    NSUInteger elem = TTIOPrecisionElementSize(_precision);
    NSUInteger n = elem ? data.length / elem : 0;
    if (n == 0) return YES;
    if (offset + n > _length) {
        if (error) *error = TTIOMakeError(TTIOErrorOutOfRange,
            @"writeSlice [%lu, %lu) exceeds dataset length %lu",
            (unsigned long)offset, (unsigned long)(offset + n), (unsigned long)_length);
        return NO;
    }
    [_file lockForWriting];
    BOOL ok = [self _writeRange:data atOffset:offset count:n error:error];
    [_file unlockForWriting];
    return ok;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error
{
    NSUInteger expected = _length * TTIOPrecisionElementSize(_precision);
    if (data.length != expected) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"writeData: expected %lu bytes, got %lu",
            (unsigned long)expected, (unsigned long)data.length);
        return NO;
    }
    [_file lockForWriting];
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dwrite(_did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, data.bytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    [_file unlockForWriting];
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite failed");
        return NO;
    }
    return YES;
}

- (NSData *)readDataWithError:(NSError **)error
{
    NSUInteger bytes = _length * TTIOPrecisionElementSize(_precision);
    NSMutableData *out = [NSMutableData dataWithLength:bytes];
    [_file lockForReading];
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dread(_did, htype, H5S_ALL, H5S_ALL, H5P_DEFAULT, out.mutableBytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    [_file unlockForReading];
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"H5Dread failed");
        return nil;
    }
    return out;
}

- (NSData *)readDataAtOffset:(NSUInteger)offset
                       count:(NSUInteger)count
                       error:(NSError **)error
{
    if (offset + count > _length) {
        if (error) *error = TTIOMakeError(TTIOErrorOutOfRange,
            @"hyperslab [%lu, %lu) exceeds dataset length %lu",
            (unsigned long)offset, (unsigned long)(offset + count),
            (unsigned long)_length);
        return nil;
    }

    [_file lockForReading];

    hid_t fspace = H5Dget_space(_did);
    hsize_t off[1]   = { (hsize_t)offset };
    hsize_t cnt[1]   = { (hsize_t)count };
    H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);

    hid_t mspace = H5Screate_simple(1, cnt, NULL);

    NSUInteger bytes = count * TTIOPrecisionElementSize(_precision);
    NSMutableData *out = [NSMutableData dataWithLength:bytes];
    hid_t htype = TTIOHDF5TypeForPrecision(_precision);
    herr_t s = H5Dread(_did, htype, mspace, fspace, H5P_DEFAULT, out.mutableBytes);
    if (!TTIOHDF5TypeIsBuiltin(_precision)) H5Tclose(htype);
    H5Sclose(mspace); H5Sclose(fspace);

    [_file unlockForReading];

    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"H5Dread (hyperslab) failed");
        return nil;
    }
    return out;
}

- (void)dealloc
{
    if (_did >= 0) H5Dclose(_did);
}

#pragma mark - <TTIOStorageDataset> bridge methods (Option B)

// Protocol method names that delegate to the HDF5-typed methods above.
// Upper-layer writers (SignalArray, AcquisitionRun, ...) call only these
// protocol methods so they work against any provider.

- (NSString *)name
{
    [_file lockForReading];
    ssize_t sz = H5Iget_name(_did, NULL, 0);
    if (sz <= 0) { [_file unlockForReading]; return @""; }
    char *buf = malloc((size_t)sz + 1);
    H5Iget_name(_did, buf, (size_t)sz + 1);
    [_file unlockForReading];
    NSString *full = [NSString stringWithUTF8String:buf];
    free(buf);
    NSRange slash = [full rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound || slash.location + 1 >= full.length) {
        return full;
    }
    return [full substringFromIndex:slash.location + 1];
}

- (NSArray<NSNumber *> *)shape
{
    return @[@(_length)];
}

- (NSArray<NSNumber *> *)chunks
{
    // Best-effort introspection; HDF5 layout interrogation is uncommon.
    [_file lockForReading];
    hid_t dcpl = H5Dget_create_plist(_did);
    H5D_layout_t layout = H5Pget_layout(dcpl);
    NSArray<NSNumber *> *out = nil;
    if (layout == H5D_CHUNKED) {
        int rank = H5Pget_chunk(dcpl, 0, NULL);
        if (rank > 0) {
            hsize_t *dims = malloc(sizeof(hsize_t) * (size_t)rank);
            H5Pget_chunk(dcpl, rank, dims);
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)rank];
            for (int i = 0; i < rank; i++) [arr addObject:@((unsigned long long)dims[i])];
            out = arr;
            free(dims);
        }
    }
    H5Pclose(dcpl);
    [_file unlockForReading];
    return out;
}

- (NSArray<TTIOCompoundField *> *)compoundFields
{
    return nil;  // compound datasets are exposed via TTIOHDF5CompoundDatasetAdapter
}

- (id)readAll:(NSError **)error
{
    return [self readDataWithError:error];
}

- (id)readSliceAtOffset:(NSUInteger)offset
                  count:(NSUInteger)count
                  error:(NSError **)error
{
    return [self readDataAtOffset:offset count:count error:error];
}

- (BOOL)writeAll:(id)data error:(NSError **)error
{
    if (![data isKindOfClass:[NSData class]]) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"writeAll: expects NSData for primitive HDF5 dataset, got %@",
            [data class]);
        return NO;
    }
    return [self writeData:(NSData *)data error:error];
}

- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error
{
    if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
        @"readRows: not supported on primitive TTIOHDF5Dataset; "
        @"compound reads go through TTIOHDF5CompoundDatasetAdapter");
    return nil;
}

- (NSData *)readCanonicalBytes:(NSError **)error
{
    // Primitive numeric: little-endian packed values. HDF5 native reads
    // produce LE on x86_64; matches Python/Java canonical layout.
    return [self readDataWithError:error];
}

- (BOOL)hasAttributeNamed:(NSString *)name
{
    [_file lockForReading];
    htri_t exists = H5Aexists(_did, [name UTF8String]);
    [_file unlockForReading];
    return exists > 0;
}

/* Scalar attribute support (numeric + string). Added for the
   FLOAT_DELTA_ZSTD codec dispatch, whose @compression attribute lives
   on the channel DATASET per format-spec 10.5 — until codec id 17 no
   consumer needed dataset-level attributes through this legacy
   wrapper (the provider adapter always supported them). */
- (id)attributeValueForName:(NSString *)name error:(NSError **)error
{
    id out = nil;
    [_file lockForReading];
    htri_t exists = H5Aexists(_did, [name UTF8String]);
    if (exists <= 0) {
        [_file unlockForReading];
        return nil;   /* absent (or probe failed): nil, no error */
    }
    hid_t aid = H5Aopen(_did, [name UTF8String], H5P_DEFAULT);
    if (aid < 0) {
        [_file unlockForReading];
        if (error) *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"H5Aopen failed for dataset attribute '%@'", name);
        return nil;
    }
    hid_t tid = H5Aget_type(aid);
    H5T_class_t cls = H5Tget_class(tid);
    if (cls == H5T_INTEGER) {
        long long v = 0;
        if (H5Aread(aid, H5T_NATIVE_LLONG, &v) >= 0) out = @(v);
    } else if (cls == H5T_FLOAT) {
        double v = 0;
        if (H5Aread(aid, H5T_NATIVE_DOUBLE, &v) >= 0) out = @(v);
    } else if (cls == H5T_STRING) {
        if (H5Tis_variable_str(tid) > 0) {
            char *s = NULL;
            hid_t mem = H5Tcopy(H5T_C_S1);
            H5Tset_size(mem, H5T_VARIABLE);
            if (H5Aread(aid, mem, &s) >= 0 && s) {
                out = [NSString stringWithUTF8String:s];
                H5free_memory(s);
            }
            H5Tclose(mem);
        } else {
            size_t sz = H5Tget_size(tid);
            char *buf = calloc(1, sz + 1);
            if (buf && H5Aread(aid, tid, buf) >= 0) {
                out = [NSString stringWithUTF8String:buf];
            }
            free(buf);
        }
    }
    H5Tclose(tid);
    H5Aclose(aid);
    [_file unlockForReading];
    if (!out && error) {
        *error = TTIOMakeError(TTIOErrorAttributeRead,
            @"unsupported type class for dataset attribute '%@'", name);
    }
    return out;
}

- (BOOL)setAttributeValue:(id)value forName:(NSString *)name error:(NSError **)error
{
    BOOL ok = NO;
    [_file lockForWriting];
    if (H5Aexists(_did, [name UTF8String]) > 0) {
        H5Adelete(_did, [name UTF8String]);
    }
    hid_t space = H5Screate(H5S_SCALAR);
    if ([value isKindOfClass:[NSNumber class]]) {
        const char *objType = [(NSNumber *)value objCType];
        if (strcmp(objType, @encode(double)) == 0
            || strcmp(objType, @encode(float)) == 0) {
            hid_t aid = H5Acreate2(_did, [name UTF8String], H5T_NATIVE_DOUBLE,
                                   space, H5P_DEFAULT, H5P_DEFAULT);
            if (aid >= 0) {
                double v = [(NSNumber *)value doubleValue];
                ok = H5Awrite(aid, H5T_NATIVE_DOUBLE, &v) >= 0;
                H5Aclose(aid);
            }
        } else {
            long long ll = [(NSNumber *)value longLongValue];
            if (ll >= 0 && ll <= 255) {
                /* Codec ids and other u8 dispatch bytes: match the
                   Python writer's H5T_NATIVE_UINT8 (10.5). */
                hid_t aid = H5Acreate2(_did, [name UTF8String],
                                       H5T_NATIVE_UCHAR, space,
                                       H5P_DEFAULT, H5P_DEFAULT);
                if (aid >= 0) {
                    unsigned char v = (unsigned char)ll;
                    ok = H5Awrite(aid, H5T_NATIVE_UCHAR, &v) >= 0;
                    H5Aclose(aid);
                }
            } else {
                hid_t aid = H5Acreate2(_did, [name UTF8String],
                                       H5T_NATIVE_LLONG, space,
                                       H5P_DEFAULT, H5P_DEFAULT);
                if (aid >= 0) {
                    ok = H5Awrite(aid, H5T_NATIVE_LLONG, &ll) >= 0;
                    H5Aclose(aid);
                }
            }
        }
    } else if ([value isKindOfClass:[NSString class]]) {
        hid_t mem = H5Tcopy(H5T_C_S1);
        H5Tset_size(mem, H5T_VARIABLE);
        hid_t aid = H5Acreate2(_did, [name UTF8String], mem, space,
                               H5P_DEFAULT, H5P_DEFAULT);
        if (aid >= 0) {
            const char *cs = [(NSString *)value UTF8String];
            ok = H5Awrite(aid, mem, &cs) >= 0;
            H5Aclose(aid);
        }
        H5Tclose(mem);
    }
    H5Sclose(space);
    [_file unlockForWriting];
    if (!ok && error) {
        *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"failed to write dataset attribute '%@'", name);
    }
    return ok;
}

- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error
{
    [_file lockForWriting];
    herr_t s = H5Adelete(_did, [name UTF8String]);
    [_file unlockForWriting];
    if (s < 0 && error) {
        *error = TTIOMakeError(TTIOErrorAttributeWrite,
            @"H5Adelete failed for '%@'", name);
    }
    return s >= 0;
}

- (NSArray<NSString *> *)attributeNames
{
    return @[];  // not commonly used for primitive HDF5 datasets
}

@end
