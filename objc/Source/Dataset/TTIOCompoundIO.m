/*
 * TTIOCompoundIO.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOCompoundIO
 * Inherits From: NSObject
 * Declared In:   Dataset/TTIOCompoundIO.h
 *
 * Compound-type persistence helpers for identifications,
 * quantifications, provenance records, and the optional
 * spectrum_index/headers compound. Provides the generic
 * schema-driven writer/reader used by the storage-provider
 * adapter layer.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOCompoundIO.h"
#import "TTIOCompoundIO+Internal.h"
#import "TTIOIdentification.h"
#import "TTIOQuantification.h"
#import "TTIOProvenanceRecord.h"
#import "Run/TTIOSpectrumIndex.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "HDF5/TTIOHDF5CompoundType.h"
#import "Providers/TTIOCompoundField.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"
#import <hdf5.h>
#import <stdlib.h>
#import <string.h>

// Informal protocol: provider group wrappers (e.g. TTIOHDF5GroupAdapter)
// expose -unwrap to reach the underlying TTIOHDF5Group. Declared here so
// writeColumnar can fast-path an adapter without importing the provider
// header (and without a hard class dependency).
@class TTIOHDF5Group;
@protocol TTIOHDF5Unwrappable <NSObject>
- (TTIOHDF5Group *)unwrap;
@end

#pragma mark - Record structs

typedef struct {
    char *run_name;
    uint32_t spectrum_index;
    char *chemical_entity;
    double confidence_score;
    char *evidence_chain_json;
} ttio_ident_record_t;

typedef struct {
    char *chemical_entity;
    char *sample_ref;
    double abundance;
    char *normalization_method;
} ttio_quant_record_t;

typedef struct {
    int64_t timestamp_unix;
    char *software;
    char *parameters_json;
    char *input_refs_json;
    char *output_refs_json;
} ttio_prov_record_t;

typedef struct {
    uint64_t offset;
    uint32_t length;
    double   retention_time;
    uint8_t  ms_level;
    int8_t   polarity;
    double   precursor_mz;
    int32_t  precursor_charge;
    double   base_peak_intensity;
} ttio_header_record_t;

#pragma mark - JSON helpers

static NSString *jsonFromArray(NSArray *arr)
{
    if (!arr) return @"[]";
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:0 error:NULL];
    if (!d) return @"[]";
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSString *jsonFromDict(NSDictionary *dict)
{
    if (!dict) return @"{}";
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:NULL];
    if (!d) return @"{}";
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSArray *arrayFromJson(const char *cstr)
{
    if (!cstr || *cstr == '\0') return @[];
    NSString *s = [NSString stringWithUTF8String:cstr];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [parsed isKindOfClass:[NSArray class]] ? (NSArray *)parsed : @[];
}

static NSDictionary *dictFromJson(const char *cstr)
{
    if (!cstr || *cstr == '\0') return @{};
    NSString *s = [NSString stringWithUTF8String:cstr];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [parsed isKindOfClass:[NSDictionary class]] ? (NSDictionary *)parsed : @{};
}

static char *dupCString(NSString *s, NSMutableArray *retained)
{
    NSString *src = s ?: @"";
    if (retained) [retained addObject:src];
    return (char *)[src UTF8String];
}

// write a JSON-string attribute carrying the same array of
// plist dicts as the compound dataset. Lets Java (JHI5 1.10 cannot
// marshal compound-with-VL reads) recover the full record set.
// Top-level dataset names only — per-run "steps" dataset does not
// get a mirror (its parent group does not model this format-spec §6
// attribute).
static void writeJsonMirrorForDatasetNamed(id<TTIOStorageGroup> parent,
                                             NSString *datasetName,
                                             NSArray *plists)
{
    NSString *attrName = nil;
    if ([datasetName isEqualToString:@"identifications"])
        attrName = @"identifications_json";
    else if ([datasetName isEqualToString:@"quantifications"])
        attrName = @"quantifications_json";
    else if ([datasetName isEqualToString:@"provenance"])
        attrName = @"provenance_json";
    else
        return;

    NSError *jerr = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:plists options:0 error:&jerr];
    if (!d) return;
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    [parent setAttributeValue:json forName:attrName error:NULL];
}

#pragma mark - Low-level write/read

static BOOL writeCompoundDataset(hid_t group_id,
                                  const char *name,
                                  hid_t type_id,
                                  NSUInteger n,
                                  const void *buffer,
                                  NSError **error)
{
    hsize_t dims[1] = { (hsize_t)n };
    hid_t space_id = H5Screate_simple(1, dims, NULL);
    if (space_id < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite, @"H5Screate_simple failed");
        return NO;
    }
    hid_t dset_id = H5Dcreate2(group_id, name, type_id, space_id,
                               H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (dset_id < 0) {
        H5Sclose(space_id);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dcreate2 failed for compound dataset %s", name);
        return NO;
    }
    herr_t rc = H5Dwrite(dset_id, type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buffer);
    H5Dclose(dset_id);
    H5Sclose(space_id);
    if (rc < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite failed for compound dataset %s", name);
        return NO;
    }
    return YES;
}

static BOOL readCompoundDataset(hid_t group_id,
                                 const char *name,
                                 hid_t mem_type_id,
                                 size_t rec_size,
                                 NSUInteger *outCount,
                                 void **outBuffer,
                                 hid_t *outSpaceId,
                                 NSError **error)
{
    hid_t dset_id = H5Dopen2(group_id, name, H5P_DEFAULT);
    if (dset_id < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dopen2 failed for compound dataset %s", name);
        return NO;
    }
    hid_t space_id = H5Dget_space(dset_id);
    hsize_t dims[1] = { 0 };
    H5Sget_simple_extent_dims(space_id, dims, NULL);
    NSUInteger n = (NSUInteger)dims[0];

    void *buf = calloc(n > 0 ? n : 1, rec_size);
    if (!buf) {
        H5Sclose(space_id);
        H5Dclose(dset_id);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite, @"calloc failed for compound read");
        return NO;
    }
    herr_t rc = H5Dread(dset_id, mem_type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
    if (rc < 0) {
        free(buf);
        H5Sclose(space_id);
        H5Dclose(dset_id);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dread failed for compound dataset %s", name);
        return NO;
    }
    H5Dclose(dset_id);

    *outCount   = n;
    *outBuffer  = buf;
    *outSpaceId = space_id;  // caller reclaims VL with this
    return YES;
}

@implementation TTIOCompoundIO

#pragma mark - Identifications

// Schema descriptors for the three canonical compound layouts.
static NSArray<TTIOCompoundField *> *identificationFields(void)
{
    return @[
        [TTIOCompoundField fieldWithName:@"run_name"            kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"spectrum_index"      kind:TTIOCompoundFieldKindUInt32],
        [TTIOCompoundField fieldWithName:@"chemical_entity"     kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"confidence_score"    kind:TTIOCompoundFieldKindFloat64],
        [TTIOCompoundField fieldWithName:@"evidence_chain_json" kind:TTIOCompoundFieldKindVLString],
    ];
}

+ (BOOL)writeIdentifications:(NSArray<TTIOIdentification *> *)idents
                    intoGroup:(id<TTIOStorageGroup>)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error
{
    NSMutableArray<NSDictionary *> *rows =
        [NSMutableArray arrayWithCapacity:idents.count];
    for (TTIOIdentification *ident in idents) {
        [rows addObject:@{
            @"run_name":            ident.runName ?: @"",
            @"spectrum_index":      @(ident.spectrumIndex),
            @"chemical_entity":     ident.chemicalEntity ?: @"",
            @"confidence_score":    @(ident.confidenceScore),
            @"evidence_chain_json": jsonFromArray(ident.evidenceChain),
        }];
    }
    if (![self writeGeneric:rows
                   intoGroup:parent
                datasetNamed:name
                      fields:identificationFields()
                       error:error]) return NO;

    NSMutableArray *plists = [NSMutableArray arrayWithCapacity:idents.count];
    for (TTIOIdentification *i in idents) [plists addObject:[i asPlist]];
    writeJsonMirrorForDatasetNamed(parent, name, plists);
    return YES;
}

+ (NSArray<TTIOIdentification *> *)readIdentificationsFromGroup:(id<TTIOStorageGroup>)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error
{
    NSArray<NSDictionary *> *rows =
        [self readGenericFromGroup:parent
                       datasetNamed:name
                             fields:identificationFields()
                              error:error];
    if (!rows) return nil;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSString *chainJson = r[@"evidence_chain_json"] ?: @"";
        NSArray *chain = arrayFromJson([chainJson UTF8String]);
        [out addObject:[[TTIOIdentification alloc]
                         initWithRunName:r[@"run_name"] ?: @""
                           spectrumIndex:[r[@"spectrum_index"] unsignedIntValue]
                          chemicalEntity:r[@"chemical_entity"] ?: @""
                         confidenceScore:[r[@"confidence_score"] doubleValue]
                           evidenceChain:chain]];
    }
    return out;
}

#pragma mark - Quantifications

static NSArray<TTIOCompoundField *> *quantificationFields(void)
{
    return @[
        [TTIOCompoundField fieldWithName:@"chemical_entity"      kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"sample_ref"           kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"abundance"            kind:TTIOCompoundFieldKindFloat64],
        [TTIOCompoundField fieldWithName:@"normalization_method" kind:TTIOCompoundFieldKindVLString],
    ];
}

+ (BOOL)writeQuantifications:(NSArray<TTIOQuantification *> *)quants
                    intoGroup:(id<TTIOStorageGroup>)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error
{
    NSMutableArray<NSDictionary *> *rows =
        [NSMutableArray arrayWithCapacity:quants.count];
    for (TTIOQuantification *q in quants) {
        [rows addObject:@{
            @"chemical_entity":      q.chemicalEntity ?: @"",
            @"sample_ref":           q.sampleRef ?: @"",
            @"abundance":            @(q.abundance),
            @"normalization_method": q.normalizationMethod ?: @"",
        }];
    }
    if (![self writeGeneric:rows
                   intoGroup:parent
                datasetNamed:name
                      fields:quantificationFields()
                       error:error]) return NO;

    // Optional sidecar `@quantification_units` JSON-array attribute on
    // the parent group: one string per row, parallel to the compound
    // dataset above. Emitted only when at least one record carries a
    // non-empty unit; absent on legacy files (units default to "").
    BOOL anyUnit = NO;
    for (TTIOQuantification *q in quants) {
        if (q.unit.length > 0) { anyUnit = YES; break; }
    }
    if (anyUnit) {
        NSMutableArray<NSString *> *units = [NSMutableArray arrayWithCapacity:quants.count];
        for (TTIOQuantification *q in quants) {
            [units addObject:q.unit ?: @""];
        }
        NSError *jsonErr = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:units
                                                       options:0
                                                         error:&jsonErr];
        if (json) {
            NSString *s = [[NSString alloc] initWithData:json
                                                encoding:NSUTF8StringEncoding];
            [parent setAttributeValue:s
                              forName:@"quantification_units"
                                error:NULL];
        }
    }

    NSMutableArray *plists = [NSMutableArray arrayWithCapacity:quants.count];
    for (TTIOQuantification *q in quants) [plists addObject:[q asPlist]];
    writeJsonMirrorForDatasetNamed(parent, name, plists);
    return YES;
}

+ (NSArray<TTIOQuantification *> *)readQuantificationsFromGroup:(id<TTIOStorageGroup>)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error
{
    NSArray<NSDictionary *> *rows =
        [self readGenericFromGroup:parent
                       datasetNamed:name
                             fields:quantificationFields()
                              error:error];
    if (!rows) return nil;

    // Optional sidecar `@quantification_units` JSON array.
    NSArray<NSString *> *units = nil;
    if ([parent hasAttributeNamed:@"quantification_units"]) {
        NSString *s = [parent attributeValueForName:@"quantification_units" error:NULL];
        if (s.length > 0) {
            NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            if ([parsed isKindOfClass:[NSArray class]]) units = parsed;
        }
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSDictionary *r = rows[i];
        NSString *norm = r[@"normalization_method"];
        if ([norm isKindOfClass:[NSString class]] && norm.length == 0) norm = nil;
        NSString *unit = (units && i < units.count
                          && [units[i] isKindOfClass:[NSString class]])
                         ? units[i] : @"";
        [out addObject:[[TTIOQuantification alloc]
                         initWithChemicalEntity:r[@"chemical_entity"] ?: @""
                                      sampleRef:r[@"sample_ref"] ?: @""
                                      abundance:[r[@"abundance"] doubleValue]
                            normalizationMethod:norm
                                           unit:unit]];
    }
    return out;
}

#pragma mark - Provenance

static NSArray<TTIOCompoundField *> *provenanceFields(void)
{
    return @[
        [TTIOCompoundField fieldWithName:@"timestamp_unix"   kind:TTIOCompoundFieldKindInt64],
        [TTIOCompoundField fieldWithName:@"software"         kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"parameters_json"  kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"input_refs_json"  kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"output_refs_json" kind:TTIOCompoundFieldKindVLString],
    ];
}

+ (BOOL)writeProvenance:(NSArray<TTIOProvenanceRecord *> *)records
               intoGroup:(id<TTIOStorageGroup>)parent
            datasetNamed:(NSString *)name
                   error:(NSError **)error
{
    NSMutableArray<NSDictionary *> *rows =
        [NSMutableArray arrayWithCapacity:records.count];
    for (TTIOProvenanceRecord *r in records) {
        [rows addObject:@{
            @"timestamp_unix":   @(r.timestampUnix),
            @"software":         r.software ?: @"",
            @"parameters_json":  jsonFromDict(r.parameters),
            @"input_refs_json":  jsonFromArray(r.inputRefs),
            @"output_refs_json": jsonFromArray(r.outputRefs),
        }];
    }
    if (![self writeGeneric:rows
                   intoGroup:parent
                datasetNamed:name
                      fields:provenanceFields()
                       error:error]) return NO;

    NSMutableArray *plists = [NSMutableArray arrayWithCapacity:records.count];
    for (TTIOProvenanceRecord *r in records) [plists addObject:[r asPlist]];
    writeJsonMirrorForDatasetNamed(parent, name, plists);
    return YES;
}

+ (NSArray<TTIOProvenanceRecord *> *)readProvenanceFromGroup:(id<TTIOStorageGroup>)parent
                                                 datasetNamed:(NSString *)name
                                                        error:(NSError **)error
{
    NSArray<NSDictionary *> *rows =
        [self readGenericFromGroup:parent
                       datasetNamed:name
                             fields:provenanceFields()
                              error:error];
    if (!rows) return nil;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSString *paramsJson = r[@"parameters_json"]  ?: @"";
        NSString *inJson     = r[@"input_refs_json"]  ?: @"";
        NSString *outJson    = r[@"output_refs_json"] ?: @"";
        NSDictionary *params = dictFromJson([paramsJson UTF8String]);
        NSArray *inRefs  = arrayFromJson([inJson UTF8String]);
        NSArray *outRefs = arrayFromJson([outJson UTF8String]);

        [out addObject:[[TTIOProvenanceRecord alloc]
                         initWithInputRefs:inRefs
                                  software:r[@"software"] ?: @""
                                parameters:params
                                outputRefs:outRefs
                             timestampUnix:[r[@"timestamp_unix"] longLongValue]]];
    }
    return out;
}

#pragma mark - Spectrum compound headers

+ (BOOL)writeCompoundHeadersForIndex:(TTIOSpectrumIndex *)index
                            intoGroup:(TTIOHDF5Group *)parent
                                error:(NSError **)error
{
    NSUInteger n = index.count;
    TTIOHDF5CompoundType *t =
        [[TTIOHDF5CompoundType alloc] initWithSize:sizeof(ttio_header_record_t)];
    [t addField:@"offset"              type:H5T_NATIVE_UINT64 offset:HOFFSET(ttio_header_record_t, offset)];
    [t addField:@"length"              type:H5T_NATIVE_UINT32 offset:HOFFSET(ttio_header_record_t, length)];
    [t addField:@"retention_time"      type:H5T_NATIVE_DOUBLE offset:HOFFSET(ttio_header_record_t, retention_time)];
    [t addField:@"ms_level"            type:H5T_NATIVE_UINT8  offset:HOFFSET(ttio_header_record_t, ms_level)];
    [t addField:@"polarity"            type:H5T_NATIVE_INT8   offset:HOFFSET(ttio_header_record_t, polarity)];
    [t addField:@"precursor_mz"        type:H5T_NATIVE_DOUBLE offset:HOFFSET(ttio_header_record_t, precursor_mz)];
    [t addField:@"precursor_charge"    type:H5T_NATIVE_INT32  offset:HOFFSET(ttio_header_record_t, precursor_charge)];
    [t addField:@"base_peak_intensity" type:H5T_NATIVE_DOUBLE offset:HOFFSET(ttio_header_record_t, base_peak_intensity)];

    ttio_header_record_t *recs = calloc(n > 0 ? n : 1, sizeof(ttio_header_record_t));
    for (NSUInteger i = 0; i < n; i++) {
        recs[i].offset              = [index offsetAt:i];
        recs[i].length              = [index lengthAt:i];
        recs[i].retention_time      = [index retentionTimeAt:i];
        recs[i].ms_level            = (uint8_t)[index msLevelAt:i];
        recs[i].polarity            = (int8_t)[index polarityAt:i];
        recs[i].precursor_mz        = [index precursorMzAt:i];
        recs[i].precursor_charge    = (int32_t)[index precursorChargeAt:i];
        recs[i].base_peak_intensity = [index basePeakIntensityAt:i];
    }

    BOOL ok = writeCompoundDataset(parent.groupId, "headers",
                                    t.typeId, n, recs, error);
    free(recs);
    [t close];
    return ok;
}

+ (NSDictionary *)readCompoundHeaderRow:(NSUInteger)row
                               fromGroup:(TTIOHDF5Group *)parent
                                   error:(NSError **)error
{
    TTIOHDF5CompoundType *t =
        [[TTIOHDF5CompoundType alloc] initWithSize:sizeof(ttio_header_record_t)];
    [t addField:@"offset"              type:H5T_NATIVE_UINT64 offset:HOFFSET(ttio_header_record_t, offset)];
    [t addField:@"length"              type:H5T_NATIVE_UINT32 offset:HOFFSET(ttio_header_record_t, length)];
    [t addField:@"retention_time"      type:H5T_NATIVE_DOUBLE offset:HOFFSET(ttio_header_record_t, retention_time)];
    [t addField:@"ms_level"            type:H5T_NATIVE_UINT8  offset:HOFFSET(ttio_header_record_t, ms_level)];
    [t addField:@"polarity"            type:H5T_NATIVE_INT8   offset:HOFFSET(ttio_header_record_t, polarity)];
    [t addField:@"precursor_mz"        type:H5T_NATIVE_DOUBLE offset:HOFFSET(ttio_header_record_t, precursor_mz)];
    [t addField:@"precursor_charge"    type:H5T_NATIVE_INT32  offset:HOFFSET(ttio_header_record_t, precursor_charge)];
    [t addField:@"base_peak_intensity" type:H5T_NATIVE_DOUBLE offset:HOFFSET(ttio_header_record_t, base_peak_intensity)];

    hid_t dset_id = H5Dopen2(parent.groupId, "headers", H5P_DEFAULT);
    if (dset_id < 0) {
        [t close];
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite, @"compound headers dataset missing");
        return nil;
    }

    hid_t file_space = H5Dget_space(dset_id);
    hsize_t start[1] = { (hsize_t)row };
    hsize_t count[1] = { 1 };
    H5Sselect_hyperslab(file_space, H5S_SELECT_SET, start, NULL, count, NULL);

    hid_t mem_space = H5Screate_simple(1, count, NULL);

    ttio_header_record_t rec = (ttio_header_record_t){0};
    herr_t rc = H5Dread(dset_id, t.typeId, mem_space, file_space, H5P_DEFAULT, &rec);

    H5Sclose(mem_space);
    H5Sclose(file_space);
    H5Dclose(dset_id);
    [t close];

    if (rc < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite, @"H5Dread hyperslab failed for headers");
        return nil;
    }

    return @{ @"offset":              @(rec.offset),
              @"length":              @(rec.length),
              @"retention_time":      @(rec.retention_time),
              @"ms_level":            @(rec.ms_level),
              @"polarity":            @(rec.polarity),
              @"precursor_mz":        @(rec.precursor_mz),
              @"precursor_charge":    @(rec.precursor_charge),
              @"base_peak_intensity": @(rec.base_peak_intensity) };
}

#pragma mark - Generic schema-driven write/read

static size_t fieldByteSize(TTIOCompoundFieldKind kind)
{
    switch (kind) {
        case TTIOCompoundFieldKindUInt32:   return 4;
        case TTIOCompoundFieldKindInt64:    return 8;
        case TTIOCompoundFieldKindUInt64:   return 8;
        case TTIOCompoundFieldKindFloat64:  return 8;
        case TTIOCompoundFieldKindVLString: return sizeof(char *);
        case TTIOCompoundFieldKindVLBytes:  return sizeof(hvl_t);
    }
    return 0;
}

// Build the HDF5 compound H5T type for `fields`, returning it (caller
// closes) and writing each field's byte offset into fieldOff[i] and the
// total record size into *outRecSize. Shared by writeGeneric and
// writeColumnar so both produce the IDENTICAL on-disk compound type and
// field offsets. Returns nil (and sets *error) on an empty schema.
static TTIOHDF5CompoundType *
ttioMakeCompoundType(NSArray<TTIOCompoundField *> *fields,
                     size_t *fieldOff, size_t *outRecSize, NSError **error)
{
    size_t recSize = 0;
    NSUInteger nFields = fields.count;
    for (NSUInteger i = 0; i < nFields; i++) {
        fieldOff[i] = recSize;
        recSize += fieldByteSize(fields[i].kind);
    }
    if (recSize == 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"empty compound schema");
        return nil;
    }
    TTIOHDF5CompoundType *t = [[TTIOHDF5CompoundType alloc] initWithSize:recSize];
    for (NSUInteger i = 0; i < nFields; i++) {
        TTIOCompoundField *f = fields[i];
        size_t off = fieldOff[i];
        switch (f.kind) {
            case TTIOCompoundFieldKindUInt32:
                [t addField:f.name type:H5T_NATIVE_UINT32 offset:off]; break;
            case TTIOCompoundFieldKindInt64:
                [t addField:f.name type:H5T_NATIVE_INT64 offset:off]; break;
            case TTIOCompoundFieldKindUInt64:
                [t addField:f.name type:H5T_NATIVE_UINT64 offset:off]; break;
            case TTIOCompoundFieldKindFloat64:
                [t addField:f.name type:H5T_NATIVE_DOUBLE offset:off]; break;
            case TTIOCompoundFieldKindVLString:
                [t addVariableLengthStringFieldNamed:f.name atOffset:off]; break;
            case TTIOCompoundFieldKindVLBytes:
                [t addVariableLengthBytesFieldNamed:f.name atOffset:off]; break;
        }
    }
    *outRecSize = recSize;
    return t;
}

// Pack primitive rows (dictionary per record) into a record buffer of
// `recSize` bytes each; used by the extendable append path.
static void ttioPackPrimitiveRows(NSArray<NSDictionary *> *rows,
                                  NSArray<TTIOCompoundField *> *fields,
                                  const size_t *fieldOff, size_t recSize,
                                  uint8_t *buf)
{
    NSUInteger nFields = fields.count;
    for (NSUInteger r = 0; r < rows.count; r++) {
        NSDictionary *row = rows[r];
        uint8_t *base = buf + r * recSize;
        for (NSUInteger i = 0; i < nFields; i++) {
            TTIOCompoundField *f = fields[i];
            id v = row[f.name];
            size_t off = fieldOff[i];
            switch (f.kind) {
                case TTIOCompoundFieldKindUInt32: {
                    uint32_t x = (uint32_t)[v unsignedIntValue]; memcpy(base + off, &x, 4); break; }
                case TTIOCompoundFieldKindInt64: {
                    int64_t x = [v longLongValue]; memcpy(base + off, &x, 8); break; }
                case TTIOCompoundFieldKindUInt64: {
                    uint64_t x = [v unsignedLongLongValue]; memcpy(base + off, &x, 8); break; }
                case TTIOCompoundFieldKindFloat64: {
                    double x = [v doubleValue]; memcpy(base + off, &x, 8); break; }
                default: break;
            }
        }
    }
}

static BOOL ttioSchemaIsPrimitive(NSArray<TTIOCompoundField *> *fields)
{
    for (TTIOCompoundField *f in fields) {
        if (f.kind == TTIOCompoundFieldKindVLString ||
            f.kind == TTIOCompoundFieldKindVLBytes) return NO;
    }
    return YES;
}

+ (BOOL)writeGeneric:(NSArray<NSDictionary *> *)rows
            intoGroup:(id<TTIOStorageGroup>)parent
         datasetNamed:(NSString *)name
               fields:(NSArray<TTIOCompoundField *> *)fields
                error:(NSError **)error
{
    // Non-HDF5 providers route through the protocol's compound dataset
    // API (Memory/SQLite/Zarr implementations handle row serialisation).
    if (![parent isKindOfClass:[TTIOHDF5Group class]]) {
        id<TTIOStorageDataset> ds =
            [parent createCompoundDatasetNamed:name
                                         fields:fields
                                          count:rows.count
                                          error:error];
        if (!ds) return NO;
        return [ds writeAll:rows error:error];
    }
    // HDF5 fast path: build the H5T compound type and use H5Dwrite
    // directly. Preserves byte-exact compatibility with v0.2 readers.
    TTIOHDF5Group *hdf5Parent = (TTIOHDF5Group *)parent;
    NSUInteger n = rows.count;
    NSUInteger nFields = fields.count;
    size_t *fieldOff = malloc((nFields ? nFields : 1) * sizeof(size_t));
    size_t recSize = 0;
    TTIOHDF5CompoundType *t =
        ttioMakeCompoundType(fields, fieldOff, &recSize, error);
    if (!t) { free(fieldOff); return NO; }

    uint8_t *buf = calloc(n > 0 ? n : 1, recSize);
    // Keeps VL temporaries alive through writeCompoundDataset (H5Dwrite):
    //   - VLString: the NSString backing the borrowed [s UTF8String] pointer.
    //   - VLBytes:  the NSData backing the borrowed (zero-copy) hv.p pointer.
    // Cleared only AFTER writeCompoundDataset returns, so every borrowed
    // pointer outlives the single bulk H5Dwrite.
    NSMutableArray *retained = [NSMutableArray array];

    // Hoist per-field metadata out of the inner row loop: these are
    // invariant per field, so precompute once instead of re-reading the
    // field object on every row.
    TTIOCompoundFieldKind *fieldKind =
        malloc((nFields ? nFields : 1) * sizeof(TTIOCompoundFieldKind));
    __unsafe_unretained NSString **fieldName =
        (__unsafe_unretained NSString **)
        malloc((nFields ? nFields : 1) * sizeof(NSString *));
    for (NSUInteger i = 0; i < nFields; i++) {
        fieldKind[i] = fields[i].kind;
        fieldName[i] = fields[i].name;   // borrowed; `fields` alive for loop
    }

    for (NSUInteger r = 0; r < n; r++) {
        NSDictionary *row = rows[r];
        uint8_t *base = buf + r * recSize;
        for (NSUInteger i = 0; i < nFields; i++) {
            size_t off = fieldOff[i];
            id v = row[fieldName[i]];
            switch (fieldKind[i]) {
                case TTIOCompoundFieldKindUInt32: {
                    uint32_t x = (uint32_t)[v unsignedIntValue];
                    memcpy(base + off, &x, 4);
                    break;
                }
                case TTIOCompoundFieldKindInt64: {
                    int64_t x = [v longLongValue];
                    memcpy(base + off, &x, 8);
                    break;
                }
                case TTIOCompoundFieldKindUInt64: {
                    uint64_t x = [v unsignedLongLongValue];
                    memcpy(base + off, &x, 8);
                    break;
                }
                case TTIOCompoundFieldKindFloat64: {
                    double x = [v doubleValue];
                    memcpy(base + off, &x, 8);
                    break;
                }
                case TTIOCompoundFieldKindVLString: {
                    NSString *s = [v isKindOfClass:[NSString class]] ? v : @"";
                    [retained addObject:s];
                    const char *cstr = [s UTF8String];
                    memcpy(base + off, &cstr, sizeof(char *));
                    break;
                }
                case TTIOCompoundFieldKindVLBytes: {
                    // Zero-copy: point hv.p directly at the NSData's bytes and
                    // keep the NSData alive until after writeCompoundDataset.
                    // HDF5's H5Dwrite only READS hv.len bytes from hv.p (it
                    // copies them into its own global-heap VL storage; it does
                    // not modify, free, or retain hv.p), so borrowing d.bytes
                    // produces byte-identical output without a malloc+memcpy.
                    NSData *d = [v isKindOfClass:[NSData class]] ? v : [NSData data];
                    hvl_t hv;
                    hv.len = d.length;
                    hv.p = d.length ? (void *)d.bytes : NULL;
                    if (d.length) [retained addObject:d];
                    memcpy(base + off, &hv, sizeof(hvl_t));
                    break;
                }
            }
        }
    }

    BOOL ok = writeCompoundDataset(hdf5Parent.groupId, [name UTF8String],
                                    t.typeId, n, buf, error);
    free(buf);
    free(fieldOff);
    free(fieldKind);
    free(fieldName);
    // Safe to release borrowed-pointer backers now: H5Dwrite has copied
    // every VL payload out into HDF5-owned global-heap storage.
    [retained removeAllObjects];
    [t close];
    return ok;
}

+ (BOOL)writeColumnar:(NSDictionary<NSString *, id> *)columns
            intoGroup:(id<TTIOStorageGroup>)parent
         datasetNamed:(NSString *)name
               fields:(NSArray<TTIOCompoundField *> *)fields
                count:(NSUInteger)count
                error:(NSError **)error
{
    // Resolve the underlying HDF5 group for the fast path. The per-AU
    // writer hands us a `TTIOHDF5GroupAdapter` (the provider wrapper from
    // -openGroupNamed:), not a raw TTIOHDF5Group; unwrap it so we still
    // take the direct H5Dwrite path rather than the row-conversion
    // fallback. (writeGeneric only reaches the real group indirectly via
    // the adapter's createCompoundDatasetNamed:/writeAll:.)
    TTIOHDF5Group *hdf5Parent = nil;
    if ([parent isKindOfClass:[TTIOHDF5Group class]]) {
        hdf5Parent = (TTIOHDF5Group *)parent;
    } else if ([parent respondsToSelector:@selector(unwrap)]) {
        id u = [(id)parent unwrap];
        if ([u isKindOfClass:[TTIOHDF5Group class]]) hdf5Parent = u;
    }

    // Non-HDF5 providers: convert columns -> row dictionaries and route
    // through the protocol's compound dataset API (Memory/SQLite/Zarr).
    // Rare path (not the per-AU hot path); keeps every backend working.
    if (hdf5Parent == nil) {
        NSMutableArray<NSDictionary *> *rows =
            [NSMutableArray arrayWithCapacity:count];
        NSUInteger nf = fields.count;
        for (NSUInteger r = 0; r < count; r++) {
            NSMutableDictionary *row =
                [NSMutableDictionary dictionaryWithCapacity:nf];
            for (NSUInteger i = 0; i < nf; i++) {
                TTIOCompoundField *f = fields[i];
                id colObj = columns[f.name];
                id v = nil;
                switch (f.kind) {
                    case TTIOCompoundFieldKindUInt32:
                        v = [colObj isKindOfClass:[NSData class]]
                            ? @(((const uint32_t *)[colObj bytes])[r])
                            : ((NSArray *)colObj)[r];
                        break;
                    case TTIOCompoundFieldKindInt64:
                        v = [colObj isKindOfClass:[NSData class]]
                            ? @(((const int64_t *)[colObj bytes])[r])
                            : ((NSArray *)colObj)[r];
                        break;
                    case TTIOCompoundFieldKindUInt64:
                        v = [colObj isKindOfClass:[NSData class]]
                            ? @(((const uint64_t *)[colObj bytes])[r])
                            : ((NSArray *)colObj)[r];
                        break;
                    case TTIOCompoundFieldKindFloat64:
                        v = [colObj isKindOfClass:[NSData class]]
                            ? @(((const double *)[colObj bytes])[r])
                            : ((NSArray *)colObj)[r];
                        break;
                    case TTIOCompoundFieldKindVLString:
                    case TTIOCompoundFieldKindVLBytes:
                        v = ((NSArray *)colObj)[r];
                        break;
                }
                row[f.name] = v;
            }
            [rows addObject:row];
        }
        return [self writeGeneric:rows
                        intoGroup:parent
                     datasetNamed:name
                           fields:fields
                            error:error];
    }

    // HDF5 fast path: assemble the SAME row-major compound buffer as
    // writeGeneric (same ttioMakeCompoundType, same field offsets, same
    // primitive memcpy, same zero-copy hvl_t.p = NSData.bytes kept alive
    // through the single bulk H5Dwrite), but source each column directly:
    //   - primitive columns are packed C NSData -> read in place, no boxing.
    //   - VL columns are NSArray<NSData*>/NSArray<NSString*> -> borrowed.
    // This is the per-AU encryption hot path: no per-row NSDictionary and
    // no per-cell NSNumber. The inner byte assembly mirrors writeGeneric's
    // exactly, so output is byte-identical for the same logical data.
    NSUInteger n = count;
    NSUInteger nFields = fields.count;
    size_t *fieldOff = malloc((nFields ? nFields : 1) * sizeof(size_t));
    size_t recSize = 0;
    TTIOHDF5CompoundType *t =
        ttioMakeCompoundType(fields, fieldOff, &recSize, error);
    if (!t) { free(fieldOff); return NO; }

    // Resolve each field's column once, hoisting every per-row msgSend out
    // of the inner loop:
    //   - primitive columns: packed C NSData -> raw base pointer (read in
    //     place), or NSArray<NSNumber*> -> bulk-extracted element buffer.
    //   - VL columns: NSArray -> bulk-extracted into a C array of object
    //     pointers via -getObjects:range: (one call per column), so the
    //     inner loop indexes a plain C array, no objectAtIndexedSubscript:.
    // The `columns` dict (and the NSArrays / NSData it holds) stays alive
    // for the whole call, keeping every VL NSData/NSString — and the bytes
    // we borrow zero-copy — valid through the single bulk H5Dwrite. So no
    // separate `retained` array is needed.
    TTIOCompoundFieldKind *fieldKind =
        malloc((nFields ? nFields : 1) * sizeof(TTIOCompoundFieldKind));
    const void **primPtr =       // packed-primitive base, or NULL
        malloc((nFields ? nFields : 1) * sizeof(const void *));
    __unsafe_unretained id **elems =   // bulk-extracted element pointers
        (__unsafe_unretained id **)
        malloc((nFields ? nFields : 1) * sizeof(id *));
    for (NSUInteger i = 0; i < nFields; i++) {
        TTIOCompoundField *f = fields[i];
        fieldKind[i] = f.kind;
        primPtr[i] = NULL;
        elems[i]   = NULL;
        id colObj = columns[f.name];   // borrowed; `columns` alive for call
        BOOL isPrim = (f.kind == TTIOCompoundFieldKindUInt32 ||
                       f.kind == TTIOCompoundFieldKindInt64  ||
                       f.kind == TTIOCompoundFieldKindUInt64 ||
                       f.kind == TTIOCompoundFieldKindFloat64);
        if (isPrim && [colObj isKindOfClass:[NSData class]]) {
            primPtr[i] = [(NSData *)colObj bytes];   // packed C values
        } else {
            // NSArray column (NSNumber for prim-as-array, NSData/NSString
            // for VL). Bulk-copy element pointers into a C array once.
            NSArray *arr = (NSArray *)colObj;
            __unsafe_unretained id *e =
                (__unsafe_unretained id *)
                malloc((n ? n : 1) * sizeof(id));
            if (n) [arr getObjects:e range:NSMakeRange(0, n)];
            elems[i] = e;
        }
    }

    uint8_t *buf = calloc(n > 0 ? n : 1, recSize);

    for (NSUInteger r = 0; r < n; r++) {
        uint8_t *base = buf + r * recSize;
        for (NSUInteger i = 0; i < nFields; i++) {
            size_t off = fieldOff[i];
            switch (fieldKind[i]) {
                case TTIOCompoundFieldKindUInt32: {
                    uint32_t x = primPtr[i]
                        ? ((const uint32_t *)primPtr[i])[r]
                        : (uint32_t)[elems[i][r] unsignedIntValue];
                    memcpy(base + off, &x, 4);
                    break;
                }
                case TTIOCompoundFieldKindInt64: {
                    int64_t x = primPtr[i]
                        ? ((const int64_t *)primPtr[i])[r]
                        : [elems[i][r] longLongValue];
                    memcpy(base + off, &x, 8);
                    break;
                }
                case TTIOCompoundFieldKindUInt64: {
                    uint64_t x = primPtr[i]
                        ? ((const uint64_t *)primPtr[i])[r]
                        : [elems[i][r] unsignedLongLongValue];
                    memcpy(base + off, &x, 8);
                    break;
                }
                case TTIOCompoundFieldKindFloat64: {
                    double x = primPtr[i]
                        ? ((const double *)primPtr[i])[r]
                        : [elems[i][r] doubleValue];
                    memcpy(base + off, &x, 8);
                    break;
                }
                case TTIOCompoundFieldKindVLString: {
                    __unsafe_unretained id e = elems[i][r];
                    NSString *s = [e isKindOfClass:[NSString class]] ? e : @"";
                    const char *cstr = [s UTF8String];
                    memcpy(base + off, &cstr, sizeof(char *));
                    break;
                }
                case TTIOCompoundFieldKindVLBytes: {
                    __unsafe_unretained id e = elems[i][r];
                    NSData *d = [e isKindOfClass:[NSData class]] ? e : nil;
                    hvl_t hv;
                    hv.len = d ? d.length : 0;
                    hv.p = (d && d.length) ? (void *)d.bytes : NULL;
                    memcpy(base + off, &hv, sizeof(hvl_t));
                    break;
                }
            }
        }
    }

    BOOL ok = writeCompoundDataset(hdf5Parent.groupId, [name UTF8String],
                                    t.typeId, n, buf, error);
    free(buf);
    free(fieldOff);
    free(fieldKind);
    free(primPtr);
    for (NSUInteger i = 0; i < nFields; i++) free(elems[i]);
    free(elems);
    [t close];
    return ok;
}

+ (NSArray<NSDictionary *> *)readGenericFromGroup:(id<TTIOStorageGroup>)parent
                                       datasetNamed:(NSString *)name
                                             fields:(NSArray<TTIOCompoundField *> *)fields
                                              error:(NSError **)error
{
    // Non-HDF5: route through the protocol's compound read.
    if (![parent isKindOfClass:[TTIOHDF5Group class]]) {
        id<TTIOStorageDataset> ds = [parent openDatasetNamed:name error:error];
        if (!ds) return nil;
        return [ds readRows:error];
    }
    TTIOHDF5Group *hdf5Parent = (TTIOHDF5Group *)parent;
    size_t recSize = 0;
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (TTIOCompoundField *f in fields) {
        [offsets addObject:@(recSize)];
        recSize += fieldByteSize(f.kind);
    }
    if (recSize == 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"empty compound schema");
        return nil;
    }

    TTIOHDF5CompoundType *t = [[TTIOHDF5CompoundType alloc] initWithSize:recSize];
    for (NSUInteger i = 0; i < fields.count; i++) {
        TTIOCompoundField *f = fields[i];
        size_t off = (size_t)[offsets[i] unsignedIntegerValue];
        switch (f.kind) {
            case TTIOCompoundFieldKindUInt32:
                [t addField:f.name type:H5T_NATIVE_UINT32 offset:off]; break;
            case TTIOCompoundFieldKindInt64:
                [t addField:f.name type:H5T_NATIVE_INT64 offset:off]; break;
            case TTIOCompoundFieldKindUInt64:
                [t addField:f.name type:H5T_NATIVE_UINT64 offset:off]; break;
            case TTIOCompoundFieldKindFloat64:
                [t addField:f.name type:H5T_NATIVE_DOUBLE offset:off]; break;
            case TTIOCompoundFieldKindVLString:
                [t addVariableLengthStringFieldNamed:f.name atOffset:off]; break;
            case TTIOCompoundFieldKindVLBytes:
                [t addVariableLengthBytesFieldNamed:f.name atOffset:off]; break;
        }
    }

    NSUInteger n = 0;
    void *buf = NULL;
    hid_t space_id = -1;
    if (!readCompoundDataset(hdf5Parent.groupId, [name UTF8String],
                              t.typeId, recSize, &n, &buf, &space_id, error)) {
        [t close];
        return nil;
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    uint8_t *recs = (uint8_t *)buf;
    for (NSUInteger r = 0; r < n; r++) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        uint8_t *base = recs + r * recSize;
        for (NSUInteger i = 0; i < fields.count; i++) {
            TTIOCompoundField *f = fields[i];
            size_t off = (size_t)[offsets[i] unsignedIntegerValue];
            switch (f.kind) {
                case TTIOCompoundFieldKindUInt32: {
                    uint32_t x; memcpy(&x, base + off, 4);
                    row[f.name] = @(x); break;
                }
                case TTIOCompoundFieldKindInt64: {
                    int64_t x; memcpy(&x, base + off, 8);
                    row[f.name] = @(x); break;
                }
                case TTIOCompoundFieldKindUInt64: {
                    uint64_t x; memcpy(&x, base + off, 8);
                    row[f.name] = @(x); break;
                }
                case TTIOCompoundFieldKindFloat64: {
                    double x; memcpy(&x, base + off, 8);
                    row[f.name] = @(x); break;
                }
                case TTIOCompoundFieldKindVLString: {
                    char *ptr; memcpy(&ptr, base + off, sizeof(char *));
                    row[f.name] = ptr ? [NSString stringWithUTF8String:ptr] : @"";
                    break;
                }
                case TTIOCompoundFieldKindVLBytes: {
                    hvl_t hv; memcpy(&hv, base + off, sizeof(hvl_t));
                    if (hv.p && hv.len > 0) {
                        // Copy ONTO the heap the bytes H5 malloc'd for us;
                        // H5Dvlen_reclaim below will free hv.p.
                        row[f.name] = [NSData dataWithBytes:hv.p length:hv.len];
                    } else {
                        row[f.name] = [NSData data];
                    }
                    break;
                }
            }
        }
        [out addObject:row];
    }

    H5Dvlen_reclaim(t.typeId, space_id, H5P_DEFAULT, buf);
    free(buf);
    H5Sclose(space_id);
    [t close];
    return out;
}

#pragma mark - Extendable compound datasets

+ (BOOL)createExtendableCompoundInGroup:(TTIOHDF5Group *)parent
                                   name:(NSString *)name
                                 fields:(NSArray<TTIOCompoundField *> *)fields
                              chunkRows:(NSUInteger)chunkRows
                                  error:(NSError **)error
{
    if (!ttioSchemaIsPrimitive(fields)) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"extendable compound '%@': variable-length fields are not supported", name);
        return NO;
    }
    if (chunkRows == 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument, @"chunkRows must be > 0");
        return NO;
    }
    NSUInteger nFields = fields.count;
    size_t *fieldOff = malloc((nFields ? nFields : 1) * sizeof(size_t));
    size_t recSize = 0;
    TTIOHDF5CompoundType *t = ttioMakeCompoundType(fields, fieldOff, &recSize, error);
    free(fieldOff);
    if (!t) return NO;
    hsize_t dims[1] = { 0 };
    hsize_t maxdims[1] = { H5S_UNLIMITED };
    hid_t space = H5Screate_simple(1, dims, maxdims);
    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    hsize_t chunk[1] = { (hsize_t)chunkRows };
    H5Pset_chunk(plist, 1, chunk);
    hid_t dset = H5Dcreate2(parent.groupId, [name UTF8String], t.typeId, space,
                            H5P_DEFAULT, plist, H5P_DEFAULT);
    BOOL ok = dset >= 0;
    if (dset >= 0) H5Dclose(dset);
    H5Pclose(plist);
    H5Sclose(space);
    [t close];
    if (!ok && error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
        @"H5Dcreate2 failed for extendable compound '%@'", name);
    return ok;
}

+ (BOOL)appendRows:(NSArray<NSDictionary *> *)rows
           toGroup:(TTIOHDF5Group *)parent
              name:(NSString *)name
            fields:(NSArray<TTIOCompoundField *> *)fields
             error:(NSError **)error
{
    if (!ttioSchemaIsPrimitive(fields)) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"extendable compound '%@': variable-length fields are not supported", name);
        return NO;
    }
    if (rows.count == 0) return YES;
    NSUInteger nFields = fields.count;
    size_t *fieldOff = malloc((nFields ? nFields : 1) * sizeof(size_t));
    size_t recSize = 0;
    TTIOHDF5CompoundType *t = ttioMakeCompoundType(fields, fieldOff, &recSize, error);
    if (!t) { free(fieldOff); return NO; }
    uint8_t *buf = calloc(rows.count, recSize);
    ttioPackPrimitiveRows(rows, fields, fieldOff, recSize, buf);
    free(fieldOff);
    BOOL ok = NO;
    hid_t dset = H5Dopen2(parent.groupId, [name UTF8String], H5P_DEFAULT);
    if (dset < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dopen2 failed for compound '%@'", name);
    } else {
        hid_t fs0 = H5Dget_space(dset);
        hsize_t cur[1] = { 0 };
        H5Sget_simple_extent_dims(fs0, cur, NULL);
        H5Sclose(fs0);
        hsize_t n = (hsize_t)rows.count;
        hsize_t newDims[1] = { cur[0] + n };
        if (H5Dset_extent(dset, newDims) >= 0) {
            hid_t fspace = H5Dget_space(dset);
            hsize_t off[1] = { cur[0] };
            hsize_t cnt[1] = { n };
            H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);
            hid_t mspace = H5Screate_simple(1, cnt, NULL);
            ok = H5Dwrite(dset, t.typeId, mspace, fspace, H5P_DEFAULT, buf) >= 0;
            H5Sclose(mspace);
            H5Sclose(fspace);
            if (!ok && error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
                @"H5Dwrite (append) failed for compound '%@'", name);
        } else if (error) {
            *error = TTIOMakeError(TTIOErrorDatasetWrite,
                @"H5Dset_extent failed for compound '%@'", name);
        }
        H5Dclose(dset);
    }
    free(buf);
    [t close];
    return ok;
}

+ (NSArray<TTIOCompoundField *> *)schemaOfCompoundInGroup:(TTIOHDF5Group *)parent name:(NSString *)name
{
    if (![parent hasChildNamed:name]) return nil;
    hid_t dset = H5Dopen2(parent.groupId, [name UTF8String], H5P_DEFAULT);
    if (dset < 0) return nil;
    hid_t ftype = H5Dget_type(dset);
    NSMutableArray<TTIOCompoundField *> *fields = nil;
    if (H5Tget_class(ftype) == H5T_COMPOUND) {
        int n = H5Tget_nmembers(ftype);
        fields = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(n, 0)];
        for (int i = 0; i < n && fields != nil; i++) {
            char *mname = H5Tget_member_name(ftype, (unsigned)i);
            hid_t mt = H5Tget_member_type(ftype, (unsigned)i);
            H5T_class_t cls = H5Tget_class(mt);
            size_t size = H5Tget_size(mt);
            NSString *nm = [NSString stringWithUTF8String:mname ?: ""];
            H5free_memory(mname);
            TTIOCompoundFieldKind kind;
            BOOL known = YES;
            if (cls == H5T_VLEN) kind = TTIOCompoundFieldKindVLBytes;
            else if (cls == H5T_STRING && H5Tis_variable_str(mt) > 0) kind = TTIOCompoundFieldKindVLString;
            else if (cls == H5T_INTEGER && size == 4) kind = TTIOCompoundFieldKindUInt32;
            else if (cls == H5T_INTEGER && size == 8) {
                kind = (H5Tget_sign(mt) == H5T_SGN_NONE) ? TTIOCompoundFieldKindUInt64
                                                          : TTIOCompoundFieldKindInt64;
            }
            else if (cls == H5T_FLOAT && size == 8) kind = TTIOCompoundFieldKindFloat64;
            else { known = NO; kind = TTIOCompoundFieldKindVLString; }
            H5Tclose(mt);
            if (!known) { fields = nil; break; }
            [fields addObject:[TTIOCompoundField fieldWithName:nm kind:kind]];
        }
    }
    H5Tclose(ftype);
    H5Dclose(dset);
    return fields;
}

+ (BOOL)isExtendableCompoundInGroup:(TTIOHDF5Group *)parent name:(NSString *)name
{
    if (![parent hasChildNamed:name]) return NO;
    hid_t dset = H5Dopen2(parent.groupId, [name UTF8String], H5P_DEFAULT);
    if (dset < 0) return NO;
    hid_t space = H5Dget_space(dset);
    hsize_t dims[1] = { 0 }, maxdims[1] = { 0 };
    H5Sget_simple_extent_dims(space, dims, maxdims);
    H5Sclose(space);
    H5Dclose(dset);
    return maxdims[0] == H5S_UNLIMITED;
}

+ (NSUInteger)rowCountInGroup:(TTIOHDF5Group *)parent name:(NSString *)name
{
    if (![parent hasChildNamed:name]) return 0;
    hid_t dset = H5Dopen2(parent.groupId, [name UTF8String], H5P_DEFAULT);
    if (dset < 0) return 0;
    hid_t space = H5Dget_space(dset);
    hsize_t dims[1] = { 0 };
    H5Sget_simple_extent_dims(space, dims, NULL);
    H5Sclose(space);
    H5Dclose(dset);
    return (NSUInteger)dims[0];
}

@end
