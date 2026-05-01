#import "TTIOCompoundIO.h"
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

// M37: write a JSON-string attribute carrying the same array of
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

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSString *norm = r[@"normalization_method"];
        if ([norm isKindOfClass:[NSString class]] && norm.length == 0) norm = nil;
        [out addObject:[[TTIOQuantification alloc]
                         initWithChemicalEntity:r[@"chemical_entity"] ?: @""
                                      sampleRef:r[@"sample_ref"] ?: @""
                                      abundance:[r[@"abundance"] doubleValue]
                            normalizationMethod:norm]];
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
        case TTIOCompoundFieldKindFloat64:  return 8;
        case TTIOCompoundFieldKindVLString: return sizeof(char *);
        case TTIOCompoundFieldKindVLBytes:  return sizeof(hvl_t);
    }
    return 0;
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
    size_t recSize = 0;
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (TTIOCompoundField *f in fields) {
        [offsets addObject:@(recSize)];
        recSize += fieldByteSize(f.kind);
    }
    if (recSize == 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"empty compound schema");
        return NO;
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
            case TTIOCompoundFieldKindFloat64:
                [t addField:f.name type:H5T_NATIVE_DOUBLE offset:off]; break;
            case TTIOCompoundFieldKindVLString:
                [t addVariableLengthStringFieldNamed:f.name atOffset:off]; break;
            case TTIOCompoundFieldKindVLBytes:
                [t addVariableLengthBytesFieldNamed:f.name atOffset:off]; break;
        }
    }

    uint8_t *buf = calloc(n > 0 ? n : 1, recSize);
    NSMutableArray *retained = [NSMutableArray array];
    // Each VL_BYTES row writes an hvl_t that points at heap-allocated
    // bytes. Record those pointers so we can free() them after
    // H5Dwrite has copied the data out.
    NSMutableArray *vlBytesAllocs = [NSMutableArray array];
    for (NSUInteger r = 0; r < n; r++) {
        NSDictionary *row = rows[r];
        uint8_t *base = buf + r * recSize;
        for (NSUInteger i = 0; i < fields.count; i++) {
            TTIOCompoundField *f = fields[i];
            size_t off = (size_t)[offsets[i] unsignedIntegerValue];
            id v = row[f.name];
            switch (f.kind) {
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
                    NSData *d = [v isKindOfClass:[NSData class]] ? v : [NSData data];
                    hvl_t hv;
                    hv.len = d.length;
                    if (d.length > 0) {
                        void *p = malloc(d.length);
                        memcpy(p, d.bytes, d.length);
                        hv.p = p;
                        [vlBytesAllocs addObject:[NSValue valueWithPointer:p]];
                    } else {
                        hv.p = NULL;
                    }
                    memcpy(base + off, &hv, sizeof(hvl_t));
                    break;
                }
            }
        }
    }

    BOOL ok = writeCompoundDataset(hdf5Parent.groupId, [name UTF8String],
                                    t.typeId, n, buf, error);
    free(buf);
    for (NSValue *v in vlBytesAllocs) {
        void *p = NULL;
        [v getValue:&p];
        if (p) free(p);
    }
    [retained removeAllObjects];
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

@end
