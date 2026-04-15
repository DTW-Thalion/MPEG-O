#import "MPGOCompoundIO.h"
#import "MPGOIdentification.h"
#import "MPGOQuantification.h"
#import "MPGOProvenanceRecord.h"
#import "Run/MPGOSpectrumIndex.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOHDF5CompoundType.h"
#import "ValueClasses/MPGOEnums.h"
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
} mpgo_ident_record_t;

typedef struct {
    char *chemical_entity;
    char *sample_ref;
    double abundance;
    char *normalization_method;
} mpgo_quant_record_t;

typedef struct {
    int64_t timestamp_unix;
    char *software;
    char *parameters_json;
    char *input_refs_json;
    char *output_refs_json;
} mpgo_prov_record_t;

typedef struct {
    uint64_t offset;
    uint32_t length;
    double   retention_time;
    uint8_t  ms_level;
    int8_t   polarity;
    double   precursor_mz;
    int32_t  precursor_charge;
    double   base_peak_intensity;
} mpgo_header_record_t;

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
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite, @"H5Screate_simple failed");
        return NO;
    }
    hid_t dset_id = H5Dcreate2(group_id, name, type_id, space_id,
                               H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (dset_id < 0) {
        H5Sclose(space_id);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"H5Dcreate2 failed for compound dataset %s", name);
        return NO;
    }
    herr_t rc = H5Dwrite(dset_id, type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buffer);
    H5Dclose(dset_id);
    H5Sclose(space_id);
    if (rc < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
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
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
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
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite, @"calloc failed for compound read");
        return NO;
    }
    herr_t rc = H5Dread(dset_id, mem_type_id, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
    if (rc < 0) {
        free(buf);
        H5Sclose(space_id);
        H5Dclose(dset_id);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
            @"H5Dread failed for compound dataset %s", name);
        return NO;
    }
    H5Dclose(dset_id);

    *outCount   = n;
    *outBuffer  = buf;
    *outSpaceId = space_id;  // caller reclaims VL with this
    return YES;
}

@implementation MPGOCompoundIO

#pragma mark - Identifications

+ (BOOL)writeIdentifications:(NSArray<MPGOIdentification *> *)idents
                    intoGroup:(MPGOHDF5Group *)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error
{
    NSUInteger n = idents.count;
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_ident_record_t)];
    if (!t) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite, @"compound type alloc failed");
        return NO;
    }
    [t addVariableLengthStringFieldNamed:@"run_name"
                                 atOffset:HOFFSET(mpgo_ident_record_t, run_name)];
    [t addField:@"spectrum_index"
           type:H5T_NATIVE_UINT32
         offset:HOFFSET(mpgo_ident_record_t, spectrum_index)];
    [t addVariableLengthStringFieldNamed:@"chemical_entity"
                                 atOffset:HOFFSET(mpgo_ident_record_t, chemical_entity)];
    [t addField:@"confidence_score"
           type:H5T_NATIVE_DOUBLE
         offset:HOFFSET(mpgo_ident_record_t, confidence_score)];
    [t addVariableLengthStringFieldNamed:@"evidence_chain_json"
                                 atOffset:HOFFSET(mpgo_ident_record_t, evidence_chain_json)];

    mpgo_ident_record_t *records = calloc(n > 0 ? n : 1, sizeof(mpgo_ident_record_t));
    NSMutableArray *retained = [NSMutableArray array];  // keep NSStrings alive
    for (NSUInteger i = 0; i < n; i++) {
        MPGOIdentification *ident = idents[i];
        records[i].run_name            = dupCString(ident.runName, retained);
        records[i].spectrum_index      = (uint32_t)ident.spectrumIndex;
        records[i].chemical_entity     = dupCString(ident.chemicalEntity, retained);
        records[i].confidence_score    = ident.confidenceScore;
        records[i].evidence_chain_json = dupCString(jsonFromArray(ident.evidenceChain), retained);
    }

    BOOL ok = writeCompoundDataset(parent.groupId, [name UTF8String],
                                    t.typeId, n, records, error);
    free(records);
    [retained removeAllObjects];
    [t close];
    return ok;
}

+ (NSArray<MPGOIdentification *> *)readIdentificationsFromGroup:(MPGOHDF5Group *)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error
{
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_ident_record_t)];
    [t addVariableLengthStringFieldNamed:@"run_name"
                                 atOffset:HOFFSET(mpgo_ident_record_t, run_name)];
    [t addField:@"spectrum_index"
           type:H5T_NATIVE_UINT32
         offset:HOFFSET(mpgo_ident_record_t, spectrum_index)];
    [t addVariableLengthStringFieldNamed:@"chemical_entity"
                                 atOffset:HOFFSET(mpgo_ident_record_t, chemical_entity)];
    [t addField:@"confidence_score"
           type:H5T_NATIVE_DOUBLE
         offset:HOFFSET(mpgo_ident_record_t, confidence_score)];
    [t addVariableLengthStringFieldNamed:@"evidence_chain_json"
                                 atOffset:HOFFSET(mpgo_ident_record_t, evidence_chain_json)];

    NSUInteger n = 0;
    void *buf = NULL;
    hid_t space_id = -1;
    if (!readCompoundDataset(parent.groupId, [name UTF8String],
                              t.typeId, sizeof(mpgo_ident_record_t),
                              &n, &buf, &space_id, error)) {
        [t close];
        return nil;
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    mpgo_ident_record_t *records = (mpgo_ident_record_t *)buf;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *runName = records[i].run_name
            ? [NSString stringWithUTF8String:records[i].run_name] : @"";
        NSString *chem = records[i].chemical_entity
            ? [NSString stringWithUTF8String:records[i].chemical_entity] : @"";
        NSArray *chain = arrayFromJson(records[i].evidence_chain_json);

        [out addObject:[[MPGOIdentification alloc]
                         initWithRunName:runName
                           spectrumIndex:records[i].spectrum_index
                          chemicalEntity:chem
                         confidenceScore:records[i].confidence_score
                           evidenceChain:chain]];
    }

    H5Dvlen_reclaim(t.typeId, space_id, H5P_DEFAULT, buf);
    free(buf);
    H5Sclose(space_id);
    [t close];
    return out;
}

#pragma mark - Quantifications

+ (BOOL)writeQuantifications:(NSArray<MPGOQuantification *> *)quants
                    intoGroup:(MPGOHDF5Group *)parent
                 datasetNamed:(NSString *)name
                        error:(NSError **)error
{
    NSUInteger n = quants.count;
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_quant_record_t)];
    [t addVariableLengthStringFieldNamed:@"chemical_entity"
                                 atOffset:HOFFSET(mpgo_quant_record_t, chemical_entity)];
    [t addVariableLengthStringFieldNamed:@"sample_ref"
                                 atOffset:HOFFSET(mpgo_quant_record_t, sample_ref)];
    [t addField:@"abundance"
           type:H5T_NATIVE_DOUBLE
         offset:HOFFSET(mpgo_quant_record_t, abundance)];
    [t addVariableLengthStringFieldNamed:@"normalization_method"
                                 atOffset:HOFFSET(mpgo_quant_record_t, normalization_method)];

    mpgo_quant_record_t *records = calloc(n > 0 ? n : 1, sizeof(mpgo_quant_record_t));
    NSMutableArray *retained = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        MPGOQuantification *q = quants[i];
        records[i].chemical_entity      = dupCString(q.chemicalEntity, retained);
        records[i].sample_ref           = dupCString(q.sampleRef, retained);
        records[i].abundance            = q.abundance;
        records[i].normalization_method = dupCString(q.normalizationMethod ?: @"", retained);
    }

    BOOL ok = writeCompoundDataset(parent.groupId, [name UTF8String],
                                    t.typeId, n, records, error);
    free(records);
    [retained removeAllObjects];
    [t close];
    return ok;
}

+ (NSArray<MPGOQuantification *> *)readQuantificationsFromGroup:(MPGOHDF5Group *)parent
                                                    datasetNamed:(NSString *)name
                                                           error:(NSError **)error
{
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_quant_record_t)];
    [t addVariableLengthStringFieldNamed:@"chemical_entity"
                                 atOffset:HOFFSET(mpgo_quant_record_t, chemical_entity)];
    [t addVariableLengthStringFieldNamed:@"sample_ref"
                                 atOffset:HOFFSET(mpgo_quant_record_t, sample_ref)];
    [t addField:@"abundance"
           type:H5T_NATIVE_DOUBLE
         offset:HOFFSET(mpgo_quant_record_t, abundance)];
    [t addVariableLengthStringFieldNamed:@"normalization_method"
                                 atOffset:HOFFSET(mpgo_quant_record_t, normalization_method)];

    NSUInteger n = 0;
    void *buf = NULL;
    hid_t space_id = -1;
    if (!readCompoundDataset(parent.groupId, [name UTF8String],
                              t.typeId, sizeof(mpgo_quant_record_t),
                              &n, &buf, &space_id, error)) {
        [t close];
        return nil;
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    mpgo_quant_record_t *records = (mpgo_quant_record_t *)buf;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *chem   = records[i].chemical_entity
            ? [NSString stringWithUTF8String:records[i].chemical_entity] : @"";
        NSString *sample = records[i].sample_ref
            ? [NSString stringWithUTF8String:records[i].sample_ref] : @"";
        NSString *norm   = records[i].normalization_method
            ? [NSString stringWithUTF8String:records[i].normalization_method] : nil;
        if (norm.length == 0) norm = nil;

        [out addObject:[[MPGOQuantification alloc]
                         initWithChemicalEntity:chem
                                      sampleRef:sample
                                      abundance:records[i].abundance
                            normalizationMethod:norm]];
    }

    H5Dvlen_reclaim(t.typeId, space_id, H5P_DEFAULT, buf);
    free(buf);
    H5Sclose(space_id);
    [t close];
    return out;
}

#pragma mark - Provenance

+ (BOOL)writeProvenance:(NSArray<MPGOProvenanceRecord *> *)records
               intoGroup:(MPGOHDF5Group *)parent
            datasetNamed:(NSString *)name
                   error:(NSError **)error
{
    NSUInteger n = records.count;
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_prov_record_t)];
    [t addField:@"timestamp_unix"
           type:H5T_NATIVE_INT64
         offset:HOFFSET(mpgo_prov_record_t, timestamp_unix)];
    [t addVariableLengthStringFieldNamed:@"software"
                                 atOffset:HOFFSET(mpgo_prov_record_t, software)];
    [t addVariableLengthStringFieldNamed:@"parameters_json"
                                 atOffset:HOFFSET(mpgo_prov_record_t, parameters_json)];
    [t addVariableLengthStringFieldNamed:@"input_refs_json"
                                 atOffset:HOFFSET(mpgo_prov_record_t, input_refs_json)];
    [t addVariableLengthStringFieldNamed:@"output_refs_json"
                                 atOffset:HOFFSET(mpgo_prov_record_t, output_refs_json)];

    mpgo_prov_record_t *recs = calloc(n > 0 ? n : 1, sizeof(mpgo_prov_record_t));
    NSMutableArray *retained = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        MPGOProvenanceRecord *r = records[i];
        recs[i].timestamp_unix  = r.timestampUnix;
        recs[i].software        = dupCString(r.software, retained);
        recs[i].parameters_json = dupCString(jsonFromDict(r.parameters), retained);
        recs[i].input_refs_json = dupCString(jsonFromArray(r.inputRefs), retained);
        recs[i].output_refs_json= dupCString(jsonFromArray(r.outputRefs), retained);
    }

    BOOL ok = writeCompoundDataset(parent.groupId, [name UTF8String],
                                    t.typeId, n, recs, error);
    free(recs);
    [retained removeAllObjects];
    [t close];
    return ok;
}

+ (NSArray<MPGOProvenanceRecord *> *)readProvenanceFromGroup:(MPGOHDF5Group *)parent
                                                 datasetNamed:(NSString *)name
                                                        error:(NSError **)error
{
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_prov_record_t)];
    [t addField:@"timestamp_unix"
           type:H5T_NATIVE_INT64
         offset:HOFFSET(mpgo_prov_record_t, timestamp_unix)];
    [t addVariableLengthStringFieldNamed:@"software"
                                 atOffset:HOFFSET(mpgo_prov_record_t, software)];
    [t addVariableLengthStringFieldNamed:@"parameters_json"
                                 atOffset:HOFFSET(mpgo_prov_record_t, parameters_json)];
    [t addVariableLengthStringFieldNamed:@"input_refs_json"
                                 atOffset:HOFFSET(mpgo_prov_record_t, input_refs_json)];
    [t addVariableLengthStringFieldNamed:@"output_refs_json"
                                 atOffset:HOFFSET(mpgo_prov_record_t, output_refs_json)];

    NSUInteger n = 0;
    void *buf = NULL;
    hid_t space_id = -1;
    if (!readCompoundDataset(parent.groupId, [name UTF8String],
                              t.typeId, sizeof(mpgo_prov_record_t),
                              &n, &buf, &space_id, error)) {
        [t close];
        return nil;
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    mpgo_prov_record_t *recs = (mpgo_prov_record_t *)buf;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *software = recs[i].software
            ? [NSString stringWithUTF8String:recs[i].software] : @"";
        NSDictionary *params = dictFromJson(recs[i].parameters_json);
        NSArray *inRefs  = arrayFromJson(recs[i].input_refs_json);
        NSArray *outRefs = arrayFromJson(recs[i].output_refs_json);

        [out addObject:[[MPGOProvenanceRecord alloc]
                         initWithInputRefs:inRefs
                                  software:software
                                parameters:params
                                outputRefs:outRefs
                             timestampUnix:recs[i].timestamp_unix]];
    }

    H5Dvlen_reclaim(t.typeId, space_id, H5P_DEFAULT, buf);
    free(buf);
    H5Sclose(space_id);
    [t close];
    return out;
}

#pragma mark - Spectrum compound headers

+ (BOOL)writeCompoundHeadersForIndex:(MPGOSpectrumIndex *)index
                            intoGroup:(MPGOHDF5Group *)parent
                                error:(NSError **)error
{
    NSUInteger n = index.count;
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_header_record_t)];
    [t addField:@"offset"              type:H5T_NATIVE_UINT64 offset:HOFFSET(mpgo_header_record_t, offset)];
    [t addField:@"length"              type:H5T_NATIVE_UINT32 offset:HOFFSET(mpgo_header_record_t, length)];
    [t addField:@"retention_time"      type:H5T_NATIVE_DOUBLE offset:HOFFSET(mpgo_header_record_t, retention_time)];
    [t addField:@"ms_level"            type:H5T_NATIVE_UINT8  offset:HOFFSET(mpgo_header_record_t, ms_level)];
    [t addField:@"polarity"            type:H5T_NATIVE_INT8   offset:HOFFSET(mpgo_header_record_t, polarity)];
    [t addField:@"precursor_mz"        type:H5T_NATIVE_DOUBLE offset:HOFFSET(mpgo_header_record_t, precursor_mz)];
    [t addField:@"precursor_charge"    type:H5T_NATIVE_INT32  offset:HOFFSET(mpgo_header_record_t, precursor_charge)];
    [t addField:@"base_peak_intensity" type:H5T_NATIVE_DOUBLE offset:HOFFSET(mpgo_header_record_t, base_peak_intensity)];

    mpgo_header_record_t *recs = calloc(n > 0 ? n : 1, sizeof(mpgo_header_record_t));
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
                               fromGroup:(MPGOHDF5Group *)parent
                                   error:(NSError **)error
{
    MPGOHDF5CompoundType *t =
        [[MPGOHDF5CompoundType alloc] initWithSize:sizeof(mpgo_header_record_t)];
    [t addField:@"offset"              type:H5T_NATIVE_UINT64 offset:HOFFSET(mpgo_header_record_t, offset)];
    [t addField:@"length"              type:H5T_NATIVE_UINT32 offset:HOFFSET(mpgo_header_record_t, length)];
    [t addField:@"retention_time"      type:H5T_NATIVE_DOUBLE offset:HOFFSET(mpgo_header_record_t, retention_time)];
    [t addField:@"ms_level"            type:H5T_NATIVE_UINT8  offset:HOFFSET(mpgo_header_record_t, ms_level)];
    [t addField:@"polarity"            type:H5T_NATIVE_INT8   offset:HOFFSET(mpgo_header_record_t, polarity)];
    [t addField:@"precursor_mz"        type:H5T_NATIVE_DOUBLE offset:HOFFSET(mpgo_header_record_t, precursor_mz)];
    [t addField:@"precursor_charge"    type:H5T_NATIVE_INT32  offset:HOFFSET(mpgo_header_record_t, precursor_charge)];
    [t addField:@"base_peak_intensity" type:H5T_NATIVE_DOUBLE offset:HOFFSET(mpgo_header_record_t, base_peak_intensity)];

    hid_t dset_id = H5Dopen2(parent.groupId, "headers", H5P_DEFAULT);
    if (dset_id < 0) {
        [t close];
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite, @"compound headers dataset missing");
        return nil;
    }

    hid_t file_space = H5Dget_space(dset_id);
    hsize_t start[1] = { (hsize_t)row };
    hsize_t count[1] = { 1 };
    H5Sselect_hyperslab(file_space, H5S_SELECT_SET, start, NULL, count, NULL);

    hid_t mem_space = H5Screate_simple(1, count, NULL);

    mpgo_header_record_t rec = (mpgo_header_record_t){0};
    herr_t rc = H5Dread(dset_id, t.typeId, mem_space, file_space, H5P_DEFAULT, &rec);

    H5Sclose(mem_space);
    H5Sclose(file_space);
    H5Dclose(dset_id);
    [t close];

    if (rc < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite, @"H5Dread hyperslab failed for headers");
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

@end
