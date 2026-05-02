/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOPerAUFile.h"
#import "TTIOPerAUEncryption.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "Dataset/TTIOCompoundIO.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "ValueClasses/TTIOEnums.h"

#include <string.h>


static NSString *const kDomain = @"TTIOPerAUFileErrorDomain";

static NSError *makeErr(NSInteger code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *makeErr(NSInteger code, NSString *fmt, ...)
{
    va_list args; va_start(args, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return [NSError errorWithDomain:kDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: m}];
}


// ---------------------------------------------------------------- helpers

static NSString *readStringAttr(id<TTIOStorageGroup> g, NSString *name)
{
    if (!g || ![g hasAttributeNamed:name]) return nil;
    id v = [g attributeValueForName:name error:NULL];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:(NSData *)v
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static int64_t readIntAttr(id<TTIOStorageGroup> g, NSString *name, int64_t defaultValue)
{
    if (!g || ![g hasAttributeNamed:name]) return defaultValue;
    id v = [g attributeValueForName:name error:NULL];
    if ([v respondsToSelector:@selector(longLongValue)])
        return [v longLongValue];
    return defaultValue;
}


static NSArray<NSString *> *splitChannelNames(NSString *raw)
{
    if (!raw.length) return @[];
    NSArray *parts = [raw componentsSeparatedByString:@","];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *p in parts) {
        if (p.length) [out addObject:p];
    }
    return out;
}

static NSArray<NSString *> *listGroupChildren(id<TTIOStorageGroup> g)
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in [g childNames]) {
        if (![n hasPrefix:@"_"]) [out addObject:n];
    }
    return out;
}


// ---------------------------------------------------------------- feature flags

// Provider-agnostic feature-flag read/write. Mirrors the Python
// _hdf5_io.read_feature_flags / write_feature_flags helpers but in
// ObjC on id<TTIOStorageGroup>.

static NSArray<NSString *> *readFeatureFlags(id<TTIOStorageGroup> root,
                                                NSString **outVersion)
{
    if (outVersion) {
        *outVersion = readStringAttr(root, @"ttio_format_version") ?: @"1.0.0";
    }
    if (![root hasAttributeNamed:@"ttio_features"]) return @[];
    NSString *json = readStringAttr(root, @"ttio_features");
    if (!json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![parsed isKindOfClass:[NSArray class]]) return @[];
    return (NSArray *)parsed;
}

static BOOL writeFeatureFlags(id<TTIOStorageGroup> root,
                                NSString *version,
                                NSArray<NSString *> *features,
                                NSError **error)
{
    if (![root setAttributeValue:version forName:@"ttio_format_version"
                            error:error]) return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:features
                                                    options:0 error:error];
    if (!json) return NO;
    NSString *s = [[NSString alloc] initWithData:json
                                          encoding:NSUTF8StringEncoding];
    return [root setAttributeValue:s forName:@"ttio_features" error:error];
}


// ---------------------------------------------------------------- segment I/O

static NSArray<TTIOCompoundField *> *channelSegmentsFields(void)
{
    return @[
        [TTIOCompoundField fieldWithName:@"offset" kind:TTIOCompoundFieldKindInt64],
        [TTIOCompoundField fieldWithName:@"length" kind:TTIOCompoundFieldKindUInt32],
        [TTIOCompoundField fieldWithName:@"iv" kind:TTIOCompoundFieldKindVLBytes],
        [TTIOCompoundField fieldWithName:@"tag" kind:TTIOCompoundFieldKindVLBytes],
        [TTIOCompoundField fieldWithName:@"ciphertext" kind:TTIOCompoundFieldKindVLBytes],
    ];
}

static NSArray<TTIOCompoundField *> *auHeaderSegmentsFields(void)
{
    return @[
        [TTIOCompoundField fieldWithName:@"iv" kind:TTIOCompoundFieldKindVLBytes],
        [TTIOCompoundField fieldWithName:@"tag" kind:TTIOCompoundFieldKindVLBytes],
        [TTIOCompoundField fieldWithName:@"ciphertext" kind:TTIOCompoundFieldKindVLBytes],
    ];
}

static BOOL writeChannelSegments(id<TTIOStorageGroup> parent,
                                    NSString *name,
                                    NSArray<TTIOChannelSegment *> *segments,
                                    NSError **error)
{
    if ([parent hasChildNamed:name]) {
        if (![parent deleteChildNamed:name error:error]) return NO;
    }
    id<TTIOStorageDataset> ds =
        [parent createCompoundDatasetNamed:name
                                      fields:channelSegmentsFields()
                                       count:segments.count
                                       error:error];
    if (!ds) return NO;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:segments.count];
    for (TTIOChannelSegment *seg in segments) {
        [rows addObject:@{
            @"offset": @(seg.offset),
            @"length": @(seg.length),
            @"iv": seg.iv,
            @"tag": seg.tag,
            @"ciphertext": seg.ciphertext,
        }];
    }
    return [ds writeAll:rows error:error];
}

// Compound-dataset reads go through TTIOCompoundIO's
// readGenericFromGroup: path because the StorageDataset protocol
// currently returns a primitive adapter on openDatasetNamed: —
// it doesn't auto-detect H5T_COMPOUND on re-open. Unwrapping the
// StorageGroup to TTIOHDF5Group is the same escape hatch used by
// TTIOSignatureManager. Write goes through the protocol; read uses
// the documented native-handle path.
static NSArray<TTIOChannelSegment *> *readChannelSegments(
    TTIOHDF5Group *hdf5Group, NSString *name, NSError **error)
{
    NSArray<NSDictionary *> *rows =
        [TTIOCompoundIO readGenericFromGroup:hdf5Group
                                  datasetNamed:name
                                        fields:channelSegmentsFields()
                                         error:error];
    if (!rows) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        [out addObject:[[TTIOChannelSegment alloc]
            initWithOffset:[r[@"offset"] unsignedLongLongValue]
                     length:[r[@"length"] unsignedIntValue]
                         iv:r[@"iv"]
                        tag:r[@"tag"]
                 ciphertext:r[@"ciphertext"]]];
    }
    return out;
}

static BOOL writeAUHeaderSegments(id<TTIOStorageGroup> parent,
                                    NSString *name,
                                    NSArray<TTIOHeaderSegment *> *segments,
                                    NSError **error)
{
    if ([parent hasChildNamed:name]) {
        if (![parent deleteChildNamed:name error:error]) return NO;
    }
    id<TTIOStorageDataset> ds =
        [parent createCompoundDatasetNamed:name
                                      fields:auHeaderSegmentsFields()
                                       count:segments.count
                                       error:error];
    if (!ds) return NO;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:segments.count];
    for (TTIOHeaderSegment *seg in segments) {
        [rows addObject:@{
            @"iv": seg.iv, @"tag": seg.tag, @"ciphertext": seg.ciphertext,
        }];
    }
    return [ds writeAll:rows error:error];
}

static NSArray<TTIOHeaderSegment *> *readAUHeaderSegments(
    TTIOHDF5Group *hdf5Group, NSString *name, NSError **error)
{
    NSArray<NSDictionary *> *rows =
        [TTIOCompoundIO readGenericFromGroup:hdf5Group
                                  datasetNamed:name
                                        fields:auHeaderSegmentsFields()
                                         error:error];
    if (!rows) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        [out addObject:[[TTIOHeaderSegment alloc]
            initWithIV:r[@"iv"] tag:r[@"tag"] ciphertext:r[@"ciphertext"]]];
    }
    return out;
}


// ---------------------------------------------------------------- impl

// ---------------------------------------------------------------- M90.4 helpers

// Read /study/genomic_runs/<name>/genomic_index/chromosomes as
// NSArray<NSString *>. L1 (Task #82 Phase B.1, 2026-05-01):
// chromosomes are stored as chromosome_ids (uint16) +
// chromosome_names (compound) instead of a single VL-string compound.
static NSArray<NSString *> *readChromosomes(TTIOHDF5Group *hdf5Idx,
                                              NSError **error)
{
    id<TTIOStorageDataset> idsDs = [hdf5Idx openDatasetNamed:@"chromosome_ids" error:error];
    if (!idsDs) return nil;
    NSData *idsData = [idsDs readAll:error];
    if (!idsData) return nil;
    NSArray *fields = @[[TTIOCompoundField fieldWithName:@"name"
                                                     kind:TTIOCompoundFieldKindVLString]];
    NSArray<NSDictionary *> *nameRows =
        [TTIOCompoundIO readGenericFromGroup:hdf5Idx
                                  datasetNamed:@"chromosome_names"
                                        fields:fields
                                         error:error];
    if (!nameRows) return nil;
    NSMutableArray *nameTable = [NSMutableArray arrayWithCapacity:nameRows.count];
    for (NSDictionary *row in nameRows) {
        id v = row[@"name"];
        if ([v isKindOfClass:[NSData class]]) {
            v = [[NSString alloc] initWithData:v
                                       encoding:NSUTF8StringEncoding];
        }
        [nameTable addObject:(NSString *)v ?: @""];
    }
    const uint16_t *ids = (const uint16_t *)idsData.bytes;
    NSUInteger nIds = idsData.length / sizeof(uint16_t);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:nIds];
    for (NSUInteger i = 0; i < nIds; i++) {
        NSUInteger idx = ids[i];
        [out addObject:idx < nameTable.count ? nameTable[idx] : @""];
    }
    return out;
}

// Per-AU dispatch for the M90.4 encrypt path. Reads on chromosomes
// in keyMap are encrypted with that key; reads on other chromosomes
// emit a clear segment (empty IV + plaintext bytes in ciphertext).
static NSArray<TTIOChannelSegment *> *encryptChannelWithDispatch(
    NSData *plaintext,
    const uint64_t *offsets, const uint32_t *lengths,
    NSArray<NSString *> *chromosomes,
    NSUInteger nReads,
    uint16_t datasetId, NSString *channelName,
    NSDictionary<NSString *, NSData *> *keyMap,
    NSError **error)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:nReads];
    const uint8_t *all = (const uint8_t *)plaintext.bytes;
    for (NSUInteger i = 0; i < nReads; i++) {
        NSUInteger byteOffset = (NSUInteger)offsets[i];
        NSUInteger byteLength = (NSUInteger)lengths[i];
        NSData *chunk = [NSData dataWithBytes:all + byteOffset
                                        length:byteLength];
        NSString *chrom = (i < chromosomes.count) ? chromosomes[i] : @"";
        NSData *key = keyMap[chrom];
        if (!key) {
            // Clear segment: empty IV + tag, plaintext rides in
            // the ciphertext slot.
            [out addObject:[[TTIOChannelSegment alloc]
                initWithOffset:offsets[i]
                         length:lengths[i]
                             iv:[NSData data]
                            tag:[NSData data]
                     ciphertext:chunk]];
        } else {
            NSData *aad = [TTIOPerAUEncryption aadForChannel:channelName
                                                    datasetId:datasetId
                                                   auSequence:(uint32_t)i];
            NSData *iv = [TTIOPerAUEncryption randomIVWithError:error];
            if (!iv) return nil;
            NSData *tag = nil;
            NSData *ct = [TTIOPerAUEncryption encryptWithPlaintext:chunk
                                                                key:key
                                                                 iv:iv
                                                                aad:aad
                                                             outTag:&tag
                                                              error:error];
            if (!ct) return nil;
            [out addObject:[[TTIOChannelSegment alloc]
                initWithOffset:offsets[i]
                         length:lengths[i]
                             iv:iv tag:tag ciphertext:ct]];
        }
    }
    return out;
}

// M90.11: reserved key name for encrypting genomic_index columns
// under encryptFilePathByRegion's keyMap. The presence of this entry
// is the opt-in signal for opt_encrypted_au_headers on genomic data.
static NSString *const kTTIOPerAUHeadersKeyName = @"_headers";

// M90.11: serialise the chromosomes list as compact JSON
// ``["chr1","chr1","chr2"]`` — must match Python's
// json.dumps(chromosomes) which uses double-quoted strings and a
// single comma+space separator. Foundation's NSJSONSerialization
// emits without whitespace by default; we then reconstruct the
// "[\"chr1\", \"chr2\"]" shape Python uses (`json.dumps` default is
// no whitespace either, both produce ``["chr1","chr2"]``). Verified
// against test_m90_11 fixtures.
static NSData *chromosomesToJSON(NSArray<NSString *> *chromosomes)
{
    NSError *jsonErr = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:chromosomes
                                                  options:0
                                                    error:&jsonErr];
    return d ?: [NSData data];
}

// M90.11 encrypt: replace the four plaintext genomic_index columns
// (chromosomes, positions, mapping_qualities, flags) with
// ``<col>_encrypted`` uint8 1-D blobs containing iv || tag || ct.
// AAD = "genomic_headers:<dataset_id>:<col>" (ASCII).
// offsets/lengths stay plaintext — structural framing.
static BOOL encryptGenomicIndex(id<TTIOStorageGroup> gIdx,
                                  uint16_t datasetId,
                                  NSData *key,
                                  NSArray<NSString *> *chromosomes,
                                  NSError **error)
{
    // Read the four columns into raw little-endian byte buffers.
    NSData *chrJson = chromosomesToJSON(chromosomes);

    id<TTIOStorageDataset> posDs =
        [gIdx openDatasetNamed:@"positions" error:error];
    if (!posDs) return NO;
    NSData *posBytes = [posDs readAll:error];
    if (!posBytes) return NO;

    id<TTIOStorageDataset> mqDs =
        [gIdx openDatasetNamed:@"mapping_qualities" error:error];
    if (!mqDs) return NO;
    NSData *mqBytes = [mqDs readAll:error];
    if (!mqBytes) return NO;

    id<TTIOStorageDataset> flagsDs =
        [gIdx openDatasetNamed:@"flags" error:error];
    if (!flagsDs) return NO;
    NSData *flagsBytes = [flagsDs readAll:error];
    if (!flagsBytes) return NO;

    NSDictionary<NSString *, NSData *> *columns = @{
        @"chromosomes": chrJson,
        @"positions": posBytes,
        @"mapping_qualities": mqBytes,
        @"flags": flagsBytes,
    };

    // Encrypt + write each column as ``<col>_encrypted`` uint8 blob.
    // Iterate in a fixed order so this routine is deterministic.
    NSArray<NSString *> *order = @[
        @"chromosomes", @"positions", @"mapping_qualities", @"flags",
    ];
    for (NSString *colName in order) {
        NSData *plaintext = columns[colName];
        NSString *aadStr =
            [NSString stringWithFormat:@"genomic_headers:%u:%@",
                (unsigned)datasetId, colName];
        NSData *aad = [aadStr dataUsingEncoding:NSASCIIStringEncoding];
        NSData *iv = [TTIOPerAUEncryption randomIVWithError:error];
        if (!iv) return NO;
        NSData *tag = nil;
        NSData *ct = [TTIOPerAUEncryption encryptWithPlaintext:plaintext
                                                            key:key
                                                             iv:iv
                                                            aad:aad
                                                         outTag:&tag
                                                          error:error];
        if (!ct) return NO;

        // Concat iv (12) || tag (16) || ciphertext into a single blob.
        NSMutableData *blob = [NSMutableData dataWithCapacity:
            iv.length + tag.length + ct.length];
        [blob appendData:iv];
        [blob appendData:tag];
        [blob appendData:ct];

        // Delete plaintext column (or any pre-existing _encrypted dataset).
        if ([gIdx hasChildNamed:colName]) {
            if (![gIdx deleteChildNamed:colName error:error]) return NO;
        }
        // L1 (Task #82 Phase B.1): the on-disk chromosomes column is
        // decomposed into chromosome_ids + chromosome_names — also
        // delete those when encrypting the logical "chromosomes"
        // column so plaintext doesn't linger alongside the encrypted
        // blob.
        if ([colName isEqualToString:@"chromosomes"]) {
            for (NSString *sub in @[@"chromosome_ids", @"chromosome_names"]) {
                if ([gIdx hasChildNamed:sub]) {
                    if (![gIdx deleteChildNamed:sub error:error]) return NO;
                }
            }
        }
        NSString *encName =
            [NSString stringWithFormat:@"%@_encrypted", colName];
        if ([gIdx hasChildNamed:encName]) {
            if (![gIdx deleteChildNamed:encName error:error]) return NO;
        }
        id<TTIOStorageDataset> outDs =
            [gIdx createDatasetNamed:encName
                            precision:TTIOPrecisionUInt8
                               length:blob.length
                            chunkSize:0
                          compression:TTIOCompressionNone
                     compressionLevel:0
                                error:error];
        if (!outDs) return NO;
        if (![outDs writeAll:blob error:error]) return NO;
    }
    return YES;
}

// M90.11 decrypt: read the ``<col>_encrypted`` blobs and recover the
// four plaintext columns. Returns a dictionary
// ``{"chromosomes": NSArray<NSString *>, "positions": NSData (i64
// LE), "mapping_qualities": NSData (u1), "flags": NSData (u32 LE)}``
// or nil + NSError on failure.
static NSDictionary *decryptGenomicIndex(id<TTIOStorageGroup> gIdx,
                                            uint16_t datasetId,
                                            NSData *key,
                                            NSError **error)
{
    NSArray<NSString *> *order = @[
        @"chromosomes", @"positions", @"mapping_qualities", @"flags",
    ];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *colName in order) {
        NSString *encName =
            [NSString stringWithFormat:@"%@_encrypted", colName];
        if (![gIdx hasChildNamed:encName]) {
            if (error) *error = [NSError errorWithDomain:kDomain code:7
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"genomic_index/%@ missing — file does not "
                        @"appear to carry M90.11 encrypted headers",
                        encName]}];
            return nil;
        }
        id<TTIOStorageDataset> ds =
            [gIdx openDatasetNamed:encName error:error];
        if (!ds) return nil;
        NSData *blob = [ds readAll:error];
        if (!blob) return nil;
        if (blob.length < 12 + 16) {
            if (error) *error = [NSError errorWithDomain:kDomain code:8
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"genomic_index/%@ too short for IV+TAG", encName]}];
            return nil;
        }
        NSData *iv = [blob subdataWithRange:NSMakeRange(0, 12)];
        NSData *tag = [blob subdataWithRange:NSMakeRange(12, 16)];
        NSData *ct = [blob subdataWithRange:NSMakeRange(28, blob.length - 28)];
        NSString *aadStr =
            [NSString stringWithFormat:@"genomic_headers:%u:%@",
                (unsigned)datasetId, colName];
        NSData *aad = [aadStr dataUsingEncoding:NSASCIIStringEncoding];
        NSData *plain = [TTIOPerAUEncryption
            decryptWithCiphertext:ct key:key iv:iv tag:tag aad:aad
                            error:error];
        if (!plain) return nil;
        if ([colName isEqualToString:@"chromosomes"]) {
            NSError *jsonErr = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:plain
                                                          options:0
                                                            error:&jsonErr];
            if (![parsed isKindOfClass:[NSArray class]]) {
                if (error) *error = [NSError errorWithDomain:kDomain code:9
                    userInfo:@{NSLocalizedDescriptionKey:
                        @"chromosomes column did not decode to JSON array"}];
                return nil;
            }
            out[colName] = parsed;
        } else {
            out[colName] = plain;
        }
    }
    return out;
}

// Per-AU dispatch decrypt — branches on len(seg.iv): 0 = clear
// segment (ciphertext is plaintext), 12 = AES-256-GCM.
static NSData *decryptChannelWithDispatch(
    NSArray<TTIOChannelSegment *> *segments,
    NSArray<NSString *> *chromosomes,
    uint16_t datasetId, NSString *channelName,
    NSDictionary<NSString *, NSData *> *keyMap,
    NSError **error)
{
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i < segments.count; i++) {
        TTIOChannelSegment *seg = segments[i];
        if (seg.iv.length == 0) {
            // Clear segment: ciphertext IS plaintext.
            [out appendData:seg.ciphertext];
            continue;
        }
        NSString *chrom = (i < chromosomes.count) ? chromosomes[i] : @"";
        NSData *key = keyMap[chrom];
        if (!key) {
            if (error) *error = [NSError errorWithDomain:kDomain code:5
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"chromosome %@ segment %lu is encrypted but "
                        @"keyMap has no entry for %@",
                        chrom, (unsigned long)i, chrom]}];
            return nil;
        }
        NSData *aad = [TTIOPerAUEncryption aadForChannel:channelName
                                                datasetId:datasetId
                                               auSequence:(uint32_t)i];
        NSData *plain = [TTIOPerAUEncryption decryptWithCiphertext:seg.ciphertext
                                                                key:key
                                                                 iv:seg.iv
                                                                tag:seg.tag
                                                                aad:aad
                                                              error:error];
        if (!plain) return nil;
        if (plain.length != (NSUInteger)seg.length) {
            if (error) *error = [NSError errorWithDomain:kDomain code:6
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"channel %@ segment %lu: decrypted %lu bytes, "
                        @"expected %u",
                        channelName, (unsigned long)i,
                        (unsigned long)plain.length, (unsigned)seg.length]}];
            return nil;
        }
        [out appendData:plain];
    }
    return out;
}


@implementation TTIOPerAUFile

+ (BOOL)encryptFilePath:(NSString *)path
                     key:(NSData *)key
         encryptHeaders:(BOOL)encryptHeaders
            providerName:(NSString *)providerName
                   error:(NSError **)error
{
    if (key.length != 32) {
        if (error) *error = makeErr(1,
            @"AES-256-GCM key must be 32 bytes, got %lu",
            (unsigned long)key.length);
        return NO;
    }

    id<TTIOStorageProvider> sp =
        [[TTIOProviderRegistry sharedRegistry] openURL:path
                                                    mode:TTIOStorageOpenModeReadWrite
                                                provider:providerName
                                                   error:error];
    if (!sp) return NO;
    @try {
        id<TTIOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return NO;
        NSString *version = nil;
        NSArray *featuresArr = readFeatureFlags(root, &version);
        NSMutableSet *featureSet = [NSMutableSet setWithArray:featuresArr];

        id<TTIOStorageGroup> study = [root openGroupNamed:@"study" error:error];
        if (!study) return NO;
        id<TTIOStorageGroup> msRuns = [study openGroupNamed:@"ms_runs" error:error];
        if (!msRuns) return NO;

        NSArray *runNames = listGroupChildren(msRuns);
        uint16_t datasetId = 1;
        for (NSString *runName in runNames) {
            id<TTIOStorageGroup> run = [msRuns openGroupNamed:runName error:error];
            if (!run) continue;
            id<TTIOStorageGroup> sig = [run openGroupNamed:@"signal_channels" error:error];
            id<TTIOStorageGroup> idx = [run openGroupNamed:@"spectrum_index" error:error];
            if (!sig || !idx) return NO;

            id<TTIOStorageDataset> offsDs = [idx openDatasetNamed:@"offsets" error:error];
            id<TTIOStorageDataset> lensDs = [idx openDatasetNamed:@"lengths" error:error];
            if (!offsDs || !lensDs) return NO;
            NSData *offsetsData = [offsDs readAll:error];
            NSData *lengthsData = [lensDs readAll:error];
            if (!offsetsData || !lengthsData) return NO;
            NSUInteger count = offsetsData.length / 8;
            const uint64_t *offsets = (const uint64_t *)offsetsData.bytes;
            const uint32_t *lengths = (const uint32_t *)lengthsData.bytes;

            NSString *channelNamesStr = readStringAttr(sig, @"channel_names") ?: @"";
            NSArray<NSString *> *channelNames = splitChannelNames(channelNamesStr);

            for (NSString *cname in channelNames) {
                NSString *valuesName = [NSString stringWithFormat:@"%@_values", cname];
                if (![sig hasChildNamed:valuesName]) continue;
                id<TTIOStorageDataset> vDs = [sig openDatasetNamed:valuesName error:error];
                if (!vDs) return NO;
                NSData *plaintext = [vDs readAll:error];
                if (!plaintext) return NO;

                NSArray<TTIOChannelSegment *> *segs =
                    [TTIOPerAUEncryption encryptChannelToSegments:plaintext
                                                              offsets:offsets
                                                              lengths:lengths
                                                             nSpectra:count
                                                            datasetId:datasetId
                                                          channelName:cname
                                                                  key:key
                                                                error:error];
                if (!segs) return NO;
                NSString *segName =
                    [NSString stringWithFormat:@"%@_segments", cname];
                if (!writeChannelSegments(sig, segName, segs, error)) return NO;
                if (![sig deleteChildNamed:valuesName error:error]) return NO;
                if (![sig setAttributeValue:@"aes-256-gcm"
                                     forName:[NSString stringWithFormat:@"%@_algorithm", cname]
                                       error:error]) return NO;
            }

            if (encryptHeaders) {
                int64_t acqMode = readIntAttr(run, @"acquisition_mode", 0);
                id<TTIOStorageDataset> msDs = [idx openDatasetNamed:@"ms_levels" error:error];
                id<TTIOStorageDataset> polDs = [idx openDatasetNamed:@"polarities" error:error];
                id<TTIOStorageDataset> rtDs = [idx openDatasetNamed:@"retention_times" error:error];
                id<TTIOStorageDataset> pmzDs = [idx openDatasetNamed:@"precursor_mzs" error:error];
                id<TTIOStorageDataset> pcDs = [idx openDatasetNamed:@"precursor_charges" error:error];
                id<TTIOStorageDataset> bpiDs = [idx openDatasetNamed:@"base_peak_intensities" error:error];
                if (!msDs || !polDs || !rtDs || !pmzDs || !pcDs || !bpiDs) return NO;
                NSData *msD = [msDs readAll:error];
                NSData *polD = [polDs readAll:error];
                NSData *rtD = [rtDs readAll:error];
                NSData *pmzD = [pmzDs readAll:error];
                NSData *pcD = [pcDs readAll:error];
                NSData *bpiD = [bpiDs readAll:error];
                if (!msD || !polD || !rtD || !pmzD || !pcD || !bpiD) return NO;
                const int32_t *ms = (const int32_t *)msD.bytes;
                const int32_t *pol = (const int32_t *)polD.bytes;
                const double *rt = (const double *)rtD.bytes;
                const double *pmz = (const double *)pmzD.bytes;
                const int32_t *pc = (const int32_t *)pcD.bytes;
                const double *bpi = (const double *)bpiD.bytes;

                NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count];
                for (NSUInteger i = 0; i < count; i++) {
                    TTIOAUHeaderPlaintext *h = [[TTIOAUHeaderPlaintext alloc] init];
                    h.acquisitionMode = (uint8_t)(acqMode & 0xFF);
                    h.msLevel = (uint8_t)(ms[i] & 0xFF);
                    h.polarity = pol[i];
                    h.retentionTime = rt[i];
                    h.precursorMz = pmz[i];
                    h.precursorCharge = (uint8_t)(pc[i] & 0xFF);
                    h.ionMobility = 0.0;
                    h.basePeakIntensity = bpi[i];
                    [rows addObject:h];
                }
                NSArray<TTIOHeaderSegment *> *hdrSegs =
                    [TTIOPerAUEncryption encryptHeaderSegments:rows
                                                       datasetId:datasetId
                                                             key:key
                                                           error:error];
                if (!hdrSegs) return NO;
                if (!writeAUHeaderSegments(idx, @"au_header_segments",
                                             hdrSegs, error)) return NO;
                for (NSString *plainName in @[@"retention_times", @"ms_levels",
                                                @"polarities", @"precursor_mzs",
                                                @"precursor_charges",
                                                @"base_peak_intensities"]) {
                    if ([idx hasChildNamed:plainName]) {
                        if (![idx deleteChildNamed:plainName error:error]) return NO;
                    }
                }
            }
            datasetId++;
        }

        // M90.1: extend encryption to genomic runs. Genomic signal
        // channels (sequences, qualities) are stored as plain uint8
        // datasets named without a "_values" suffix (different from
        // the MS layout). datasetId continues from where the MS loop
        // left off so genomic runs occupy IDs N+1..N+M (matches the
        // M89.2 transport convention and the Python reference impl).
        if ([study hasChildNamed:@"genomic_runs"]) {
            id<TTIOStorageGroup> gRuns =
                [study openGroupNamed:@"genomic_runs" error:error];
            if (!gRuns) return NO;
            NSArray *gRunNames = listGroupChildren(gRuns);
            for (NSString *gRunName in gRunNames) {
                id<TTIOStorageGroup> gRun =
                    [gRuns openGroupNamed:gRunName error:error];
                if (!gRun) continue;
                id<TTIOStorageGroup> gSig =
                    [gRun openGroupNamed:@"signal_channels" error:error];
                id<TTIOStorageGroup> gIdx =
                    [gRun openGroupNamed:@"genomic_index" error:error];
                if (!gSig || !gIdx) return NO;

                id<TTIOStorageDataset> gOffsDs =
                    [gIdx openDatasetNamed:@"offsets" error:error];
                id<TTIOStorageDataset> gLensDs =
                    [gIdx openDatasetNamed:@"lengths" error:error];
                if (!gOffsDs || !gLensDs) return NO;
                NSData *gOffsetsData = [gOffsDs readAll:error];
                NSData *gLengthsData = [gLensDs readAll:error];
                if (!gOffsetsData || !gLengthsData) return NO;
                NSUInteger gCount = gOffsetsData.length / 8;
                const uint64_t *gOffsets = (const uint64_t *)gOffsetsData.bytes;
                const uint32_t *gLengths = (const uint32_t *)gLengthsData.bytes;

                for (NSString *cname in @[@"sequences", @"qualities"]) {
                    if (![gSig hasChildNamed:cname]) continue;
                    id<TTIOStorageDataset> vDs =
                        [gSig openDatasetNamed:cname error:error];
                    if (!vDs) return NO;
                    NSData *plaintext = [vDs readAll:error];
                    if (!plaintext) return NO;
                    NSArray<TTIOChannelSegment *> *segs =
                        [TTIOPerAUEncryption
                            encryptChannelToSegments:plaintext
                                              offsets:gOffsets
                                              lengths:gLengths
                                             nSpectra:gCount
                                      bytesPerElement:1
                                            datasetId:datasetId
                                          channelName:cname
                                                  key:key
                                                error:error];
                    if (!segs) return NO;
                    NSString *segName =
                        [NSString stringWithFormat:@"%@_segments", cname];
                    if (!writeChannelSegments(gSig, segName, segs, error))
                        return NO;
                    if (![gSig deleteChildNamed:cname error:error]) return NO;
                    if (![gSig setAttributeValue:@"aes-256-gcm"
                                          forName:[NSString stringWithFormat:@"%@_algorithm", cname]
                                            error:error]) return NO;
                }
                datasetId++;
            }
        }

        [featureSet addObject:@"opt_per_au_encryption"];
        if (encryptHeaders) [featureSet addObject:@"opt_encrypted_au_headers"];
        NSArray *sorted = [featureSet.allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        if (!writeFeatureFlags(root, version, sorted, error)) return NO;
    }
    @finally {
        [sp close];
    }
    return YES;
}


+ (NSDictionary<NSString *, NSDictionary *> *)
    decryptFilePath:(NSString *)path
                key:(NSData *)key
       providerName:(NSString *)providerName
              error:(NSError **)error
{
    if (key.length != 32) {
        if (error) *error = makeErr(1,
            @"AES-256-GCM key must be 32 bytes, got %lu",
            (unsigned long)key.length);
        return nil;
    }

    id<TTIOStorageProvider> sp =
        [[TTIOProviderRegistry sharedRegistry] openURL:path
                                                    mode:TTIOStorageOpenModeRead
                                                provider:providerName
                                                   error:error];
    if (!sp) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        id<TTIOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return nil;
        NSArray *features = readFeatureFlags(root, NULL);
        if (![features containsObject:@"opt_per_au_encryption"]) {
            if (error) *error = makeErr(2,
                @"%@ does not carry opt_per_au_encryption", path);
            return nil;
        }
        BOOL headersEncrypted = [features containsObject:@"opt_encrypted_au_headers"];

        // For compound-dataset reads we still need the underlying
        // TTIOHDF5Group — see readChannelSegments comment. Unwrap
        // via the provider's nativeHandle() escape hatch.
        if (![sp.providerName isEqualToString:@"hdf5"]) {
            if (error) *error = makeErr(3,
                @"per-AU decrypt currently requires HDF5 provider (got %@)",
                sp.providerName);
            return nil;
        }
        TTIOHDF5File *hdf5File = (TTIOHDF5File *)[sp nativeHandle];
        TTIOHDF5Group *hdf5Root = hdf5File.rootGroup;

        id<TTIOStorageGroup> study = [root openGroupNamed:@"study" error:error];
        id<TTIOStorageGroup> msRuns = [study openGroupNamed:@"ms_runs" error:error];
        if (!study || !msRuns) return nil;
        NSArray *runNames = listGroupChildren(msRuns);
        uint16_t datasetId = 1;
        for (NSString *runName in runNames) {
            id<TTIOStorageGroup> run = [msRuns openGroupNamed:runName error:error];
            id<TTIOStorageGroup> sig = [run openGroupNamed:@"signal_channels" error:error];
            id<TTIOStorageGroup> idx = [run openGroupNamed:@"spectrum_index" error:error];
            if (!run || !sig || !idx) continue;
            NSString *channelNamesStr = readStringAttr(sig, @"channel_names") ?: @"";
            NSArray<NSString *> *channelNames = splitChannelNames(channelNamesStr);

            // Raw HDF5 groups for the compound-read escape hatch.
            TTIOHDF5Group *hdf5Run =
                [[hdf5Root openGroupNamed:@"study" error:NULL]
                    openGroupNamed:@"ms_runs" error:NULL];
            TTIOHDF5Group *hdf5RunGroup =
                [hdf5Run openGroupNamed:runName error:NULL];
            TTIOHDF5Group *hdf5Sig =
                [hdf5RunGroup openGroupNamed:@"signal_channels" error:NULL];
            TTIOHDF5Group *hdf5Idx =
                [hdf5RunGroup openGroupNamed:@"spectrum_index" error:NULL];

            NSMutableDictionary *runOut = [NSMutableDictionary dictionary];
            for (NSString *cname in channelNames) {
                NSString *segName = [NSString stringWithFormat:@"%@_segments", cname];
                if (![sig hasChildNamed:segName]) continue;
                NSArray *segs = readChannelSegments(hdf5Sig, segName, error);
                if (!segs) return nil;
                NSData *plain = [TTIOPerAUEncryption
                    decryptChannelFromSegments:segs
                                      datasetId:datasetId
                                    channelName:cname
                                            key:key
                                          error:error];
                if (!plain) return nil;
                runOut[cname] = plain;
            }
            if (headersEncrypted && [idx hasChildNamed:@"au_header_segments"]) {
                NSArray *hdrSegs = readAUHeaderSegments(hdf5Idx,
                                                          @"au_header_segments",
                                                          error);
                if (!hdrSegs) return nil;
                NSArray *rows = [TTIOPerAUEncryption
                    decryptHeaderSegments:hdrSegs
                                 datasetId:datasetId
                                       key:key
                                     error:error];
                if (!rows) return nil;
                runOut[@"__au_headers__"] = rows;
            }
            out[runName] = runOut;
            datasetId++;
        }

        // M90.1: also materialise genomic_runs. datasetId continues
        // from where the MS loop left off so AAD reconstruction
        // matches the encrypt path exactly.
        if ([study hasChildNamed:@"genomic_runs"]) {
            id<TTIOStorageGroup> gRuns =
                [study openGroupNamed:@"genomic_runs" error:error];
            if (!gRuns) return nil;
            NSArray *gRunNames = listGroupChildren(gRuns);
            // Raw HDF5 access for the compound-read path.
            TTIOHDF5Group *hdf5GRuns =
                [[hdf5Root openGroupNamed:@"study" error:NULL]
                    openGroupNamed:@"genomic_runs" error:NULL];
            for (NSString *gRunName in gRunNames) {
                id<TTIOStorageGroup> gRun =
                    [gRuns openGroupNamed:gRunName error:error];
                if (!gRun) continue;
                id<TTIOStorageGroup> gSig =
                    [gRun openGroupNamed:@"signal_channels" error:error];
                if (!gSig) continue;
                TTIOHDF5Group *hdf5GRun =
                    [hdf5GRuns openGroupNamed:gRunName error:NULL];
                TTIOHDF5Group *hdf5GSig =
                    [hdf5GRun openGroupNamed:@"signal_channels" error:NULL];

                NSMutableDictionary *gRunOut = [NSMutableDictionary dictionary];
                for (NSString *cname in @[@"sequences", @"qualities"]) {
                    NSString *segName =
                        [NSString stringWithFormat:@"%@_segments", cname];
                    if (![gSig hasChildNamed:segName]) continue;
                    NSArray *segs =
                        readChannelSegments(hdf5GSig, segName, error);
                    if (!segs) return nil;
                    NSData *plain = [TTIOPerAUEncryption
                        decryptChannelFromSegments:segs
                                  bytesPerElement:1
                                          datasetId:datasetId
                                        channelName:cname
                                                key:key
                                              error:error];
                    if (!plain) return nil;
                    gRunOut[cname] = plain;
                }
                out[gRunName] = gRunOut;
                datasetId++;
            }
        }
    }
    @finally {
        [sp close];
    }
    return out;
}


#pragma mark - M90.4 — region-based per-AU encryption

+ (BOOL)encryptFilePathByRegion:(NSString *)path
                          keyMap:(NSDictionary<NSString *, NSData *> *)keyMap
                    providerName:(NSString *)providerName
                           error:(NSError **)error
{
    for (NSString *chrom in keyMap) {
        NSData *k = keyMap[chrom];
        if (k.length != 32) {
            if (error) *error = makeErr(1,
                @"AES-256-GCM key for chromosome %@ must be 32 bytes, got %lu",
                chrom, (unsigned long)k.length);
            return NO;
        }
    }

    // M90.11: split out the reserved "_headers" entry from the
    // chromosome-keyed entries. Headers-key encrypts the four
    // genomic_index columns (chromosomes, positions,
    // mapping_qualities, flags). Chromosome keys encrypt signal
    // channels per-AU.
    NSData *headersKey = keyMap[kTTIOPerAUHeadersKeyName];
    NSMutableDictionary<NSString *, NSData *> *chromosomeKeys =
        [keyMap mutableCopy];
    [chromosomeKeys removeObjectForKey:kTTIOPerAUHeadersKeyName];

    id<TTIOStorageProvider> sp =
        [[TTIOProviderRegistry sharedRegistry] openURL:path
                                                    mode:TTIOStorageOpenModeReadWrite
                                                provider:providerName
                                                   error:error];
    if (!sp) return NO;
    @try {
        id<TTIOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return NO;
        NSString *version = nil;
        NSArray *featuresArr = readFeatureFlags(root, &version);
        NSMutableSet *featureSet = [NSMutableSet setWithArray:featuresArr];

        id<TTIOStorageGroup> study =
            [root openGroupNamed:@"study" error:error];
        if (!study) return NO;
        if (![study hasChildNamed:@"genomic_runs"]) {
            // No genomic data — nothing to encrypt.
            return YES;
        }

        // Match the dataset_id_counter convention from the MS path:
        // MS runs occupy 1..N, genomic N+1..N+M. Region-only
        // encryption walks MS first to *count* runs (without
        // touching them) so genomic AAD reconstruction is correct.
        NSUInteger nMs = 0;
        if ([study hasChildNamed:@"ms_runs"]) {
            id<TTIOStorageGroup> msRuns =
                [study openGroupNamed:@"ms_runs" error:error];
            if (!msRuns) return NO;
            nMs = listGroupChildren(msRuns).count;
        }
        uint16_t datasetId = (uint16_t)(nMs + 1);

        // We need raw HDF5 access for the chromosomes compound read.
        if (![sp.providerName isEqualToString:@"hdf5"]) {
            if (error) *error = makeErr(3,
                @"per-AU region encrypt currently requires HDF5 provider "
                @"(got %@)", sp.providerName);
            return NO;
        }
        TTIOHDF5File *hdf5File = (TTIOHDF5File *)[sp nativeHandle];
        TTIOHDF5Group *hdf5Root = hdf5File.rootGroup;
        TTIOHDF5Group *hdf5Study =
            [hdf5Root openGroupNamed:@"study" error:NULL];
        TTIOHDF5Group *hdf5GRuns =
            [hdf5Study openGroupNamed:@"genomic_runs" error:NULL];

        id<TTIOStorageGroup> gRuns =
            [study openGroupNamed:@"genomic_runs" error:error];
        if (!gRuns) return NO;
        NSArray *gRunNames = listGroupChildren(gRuns);
        for (NSString *gRunName in gRunNames) {
            id<TTIOStorageGroup> gRun =
                [gRuns openGroupNamed:gRunName error:error];
            if (!gRun) continue;
            id<TTIOStorageGroup> gSig =
                [gRun openGroupNamed:@"signal_channels" error:error];
            id<TTIOStorageGroup> gIdx =
                [gRun openGroupNamed:@"genomic_index" error:error];
            if (!gSig || !gIdx) return NO;

            TTIOHDF5Group *hdf5GRun =
                [hdf5GRuns openGroupNamed:gRunName error:NULL];
            TTIOHDF5Group *hdf5GIdx =
                [hdf5GRun openGroupNamed:@"genomic_index" error:NULL];

            id<TTIOStorageDataset> gOffsDs =
                [gIdx openDatasetNamed:@"offsets" error:error];
            id<TTIOStorageDataset> gLensDs =
                [gIdx openDatasetNamed:@"lengths" error:error];
            if (!gOffsDs || !gLensDs) return NO;
            NSData *gOffsetsData = [gOffsDs readAll:error];
            NSData *gLengthsData = [gLensDs readAll:error];
            if (!gOffsetsData || !gLengthsData) return NO;
            NSUInteger gCount = gOffsetsData.length / 8;
            const uint64_t *gOffsets = (const uint64_t *)gOffsetsData.bytes;
            const uint32_t *gLengths = (const uint32_t *)gLengthsData.bytes;

            NSArray<NSString *> *chromosomes =
                readChromosomes(hdf5GIdx, error);
            if (!chromosomes) return NO;

            // M90.11: signal-channel encryption runs in two cases:
            //   (a) caller supplied chromosome keys (M90.4 path)
            //   (b) caller supplied an empty key_map (M90.4 no-op:
            //       file gets opt_per_au_encryption with all-clear
            //       segments)
            // The only path that SKIPS signal-channel encryption is
            // the headers-only case (key_map == {"_headers": K}).
            BOOL runSignalEncrypt =
                (chromosomeKeys.count > 0) || (headersKey == nil);
            if (runSignalEncrypt) {
                for (NSString *cname in @[@"sequences", @"qualities"]) {
                    if (![gSig hasChildNamed:cname]) continue;
                    id<TTIOStorageDataset> vDs =
                        [gSig openDatasetNamed:cname error:error];
                    if (!vDs) return NO;
                    NSData *plaintext = [vDs readAll:error];
                    if (!plaintext) return NO;
                    NSArray<TTIOChannelSegment *> *segs =
                        encryptChannelWithDispatch(plaintext,
                                                      gOffsets, gLengths,
                                                      chromosomes, gCount,
                                                      datasetId, cname,
                                                      chromosomeKeys, error);
                    if (!segs) return NO;
                    NSString *segName =
                        [NSString stringWithFormat:@"%@_segments", cname];
                    if (!writeChannelSegments(gSig, segName, segs, error))
                        return NO;
                    if (![gSig deleteChildNamed:cname error:error]) return NO;
                    if (![gSig setAttributeValue:@"aes-256-gcm-by-region"
                                          forName:[NSString stringWithFormat:@"%@_algorithm", cname]
                                            error:error]) return NO;
                }
            }

            // M90.11: when "_headers" key is present, encrypt the
            // four genomic_index columns under it.
            if (headersKey != nil) {
                if (!encryptGenomicIndex(gIdx, datasetId, headersKey,
                                            chromosomes, error)) {
                    return NO;
                }
            }
            datasetId++;
        }

        // Feature-flag set rules:
        //  * opt_per_au_encryption — set whenever signal-channel
        //    encryption ran (chromosome keys present OR empty key_map
        //    no-op path) OR when headers_key is provided.
        //  * opt_region_keyed_encryption — only when at least one
        //    chromosome key was provided. Empty key_map leaves the
        //    file with all-clear segments — that's M90.4's no-op
        //    semantics, not a region-keyed file.
        //  * opt_encrypted_au_headers — set when _headers key was
        //    used (M90.11).
        if (chromosomeKeys.count > 0 || headersKey == nil) {
            [featureSet addObject:@"opt_per_au_encryption"];
        }
        if (chromosomeKeys.count > 0) {
            [featureSet addObject:@"opt_region_keyed_encryption"];
        }
        if (headersKey != nil) {
            [featureSet addObject:@"opt_per_au_encryption"];
            [featureSet addObject:@"opt_encrypted_au_headers"];
        }
        NSArray *sorted = [featureSet.allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        if (!writeFeatureFlags(root, version, sorted, error)) return NO;
    }
    @finally {
        [sp close];
    }
    return YES;
}


+ (NSDictionary<NSString *, NSDictionary *> *)
    decryptFilePathByRegion:(NSString *)path
                      keyMap:(NSDictionary<NSString *, NSData *> *)keyMap
                providerName:(NSString *)providerName
                       error:(NSError **)error
{
    for (NSString *chrom in keyMap) {
        NSData *k = keyMap[chrom];
        if (k.length != 32) {
            if (error) *error = makeErr(1,
                @"AES-256-GCM key for chromosome %@ must be 32 bytes, got %lu",
                chrom, (unsigned long)k.length);
            return nil;
        }
    }

    // M90.11: split out the reserved "_headers" entry from the
    // chromosome keys.
    NSData *headersKey = keyMap[kTTIOPerAUHeadersKeyName];
    NSMutableDictionary<NSString *, NSData *> *chromosomeKeys =
        [keyMap mutableCopy];
    [chromosomeKeys removeObjectForKey:kTTIOPerAUHeadersKeyName];

    id<TTIOStorageProvider> sp =
        [[TTIOProviderRegistry sharedRegistry] openURL:path
                                                    mode:TTIOStorageOpenModeRead
                                                provider:providerName
                                                   error:error];
    if (!sp) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        id<TTIOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return nil;
        NSArray *features = readFeatureFlags(root, NULL);
        if (![features containsObject:@"opt_per_au_encryption"]) {
            if (error) *error = makeErr(2,
                @"%@ does not carry opt_per_au_encryption", path);
            return nil;
        }

        // M90.11: opt_encrypted_au_headers files require the
        // "_headers" key — without it we can't even reconstruct the
        // chromosomes column needed to dispatch signal-channel
        // decryption.
        BOOL headersEncrypted =
            [features containsObject:@"opt_encrypted_au_headers"];
        if (headersEncrypted && headersKey == nil) {
            if (error) *error = makeErr(4,
                @"%@ carries opt_encrypted_au_headers; caller must "
                @"provide a '_headers' entry in keyMap to decrypt the "
                @"genomic_index columns", path);
            return nil;
        }

        id<TTIOStorageGroup> study =
            [root openGroupNamed:@"study" error:error];
        if (!study) return nil;
        if (![study hasChildNamed:@"genomic_runs"]) {
            return out;
        }

        // Walk MS runs first to keep dataset_id aligned. Region
        // decrypt does not touch MS runs; counter is purely for AAD.
        NSUInteger nMs = 0;
        if ([study hasChildNamed:@"ms_runs"]) {
            id<TTIOStorageGroup> msRuns =
                [study openGroupNamed:@"ms_runs" error:error];
            if (!msRuns) return nil;
            nMs = listGroupChildren(msRuns).count;
        }
        uint16_t datasetId = (uint16_t)(nMs + 1);

        if (![sp.providerName isEqualToString:@"hdf5"]) {
            if (error) *error = makeErr(3,
                @"per-AU region decrypt currently requires HDF5 provider "
                @"(got %@)", sp.providerName);
            return nil;
        }
        TTIOHDF5File *hdf5File = (TTIOHDF5File *)[sp nativeHandle];
        TTIOHDF5Group *hdf5Root = hdf5File.rootGroup;
        TTIOHDF5Group *hdf5Study =
            [hdf5Root openGroupNamed:@"study" error:NULL];
        TTIOHDF5Group *hdf5GRuns =
            [hdf5Study openGroupNamed:@"genomic_runs" error:NULL];

        id<TTIOStorageGroup> gRuns =
            [study openGroupNamed:@"genomic_runs" error:error];
        if (!gRuns) return nil;
        NSArray *gRunNames = listGroupChildren(gRuns);
        for (NSString *gRunName in gRunNames) {
            id<TTIOStorageGroup> gRun =
                [gRuns openGroupNamed:gRunName error:error];
            id<TTIOStorageGroup> gSig =
                [gRun openGroupNamed:@"signal_channels" error:error];
            id<TTIOStorageGroup> gIdx =
                [gRun openGroupNamed:@"genomic_index" error:error];
            if (!gRun || !gSig || !gIdx) continue;
            TTIOHDF5Group *hdf5GRun =
                [hdf5GRuns openGroupNamed:gRunName error:NULL];
            TTIOHDF5Group *hdf5GSig =
                [hdf5GRun openGroupNamed:@"signal_channels" error:NULL];
            TTIOHDF5Group *hdf5GIdx =
                [hdf5GRun openGroupNamed:@"genomic_index" error:NULL];

            NSMutableDictionary *gRunOut = [NSMutableDictionary dictionary];
            NSArray<NSString *> *chromosomes = nil;

            // M90.11: when headers are encrypted, decrypt the four
            // genomic_index columns FIRST so the per-AU signal-channel
            // dispatch (which needs chromosomes) can proceed.
            if (headersEncrypted) {
                NSDictionary *indexPlain =
                    decryptGenomicIndex(gIdx, datasetId, headersKey, error);
                if (!indexPlain) return nil;
                chromosomes = (NSArray<NSString *> *)indexPlain[@"chromosomes"];
                gRunOut[@"__index__"] = indexPlain;
            } else {
                chromosomes = readChromosomes(hdf5GIdx, error);
                if (!chromosomes) return nil;
            }

            for (NSString *cname in @[@"sequences", @"qualities"]) {
                NSString *segName =
                    [NSString stringWithFormat:@"%@_segments", cname];
                if (![gSig hasChildNamed:segName]) continue;
                NSArray *segs = readChannelSegments(hdf5GSig, segName, error);
                if (!segs) return nil;
                NSData *plain = decryptChannelWithDispatch(segs,
                                                            chromosomes,
                                                            datasetId, cname,
                                                            chromosomeKeys, error);
                if (!plain) return nil;
                gRunOut[cname] = plain;
            }
            out[gRunName] = gRunOut;
            datasetId++;
        }
    }
    @finally {
        [sp close];
    }
    return out;
}

@end
