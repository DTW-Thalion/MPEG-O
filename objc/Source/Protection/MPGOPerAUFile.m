/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOPerAUFile.h"
#import "MPGOPerAUEncryption.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOCompoundField.h"
#import "Dataset/MPGOCompoundIO.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "ValueClasses/MPGOEnums.h"

#include <string.h>


static NSString *const kDomain = @"MPGOPerAUFileErrorDomain";

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

static NSString *readStringAttr(id<MPGOStorageGroup> g, NSString *name)
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

static int64_t readIntAttr(id<MPGOStorageGroup> g, NSString *name, int64_t defaultValue)
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

static NSArray<NSString *> *listGroupChildren(id<MPGOStorageGroup> g)
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
// ObjC on id<MPGOStorageGroup>.

static NSArray<NSString *> *readFeatureFlags(id<MPGOStorageGroup> root,
                                                NSString **outVersion)
{
    if (outVersion) {
        *outVersion = readStringAttr(root, @"mpeg_o_format_version") ?: @"1.0.0";
    }
    if (![root hasAttributeNamed:@"mpeg_o_features"]) return @[];
    NSString *json = readStringAttr(root, @"mpeg_o_features");
    if (!json.length) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![parsed isKindOfClass:[NSArray class]]) return @[];
    return (NSArray *)parsed;
}

static BOOL writeFeatureFlags(id<MPGOStorageGroup> root,
                                NSString *version,
                                NSArray<NSString *> *features,
                                NSError **error)
{
    if (![root setAttributeValue:version forName:@"mpeg_o_format_version"
                            error:error]) return NO;
    NSData *json = [NSJSONSerialization dataWithJSONObject:features
                                                    options:0 error:error];
    if (!json) return NO;
    NSString *s = [[NSString alloc] initWithData:json
                                          encoding:NSUTF8StringEncoding];
    return [root setAttributeValue:s forName:@"mpeg_o_features" error:error];
}


// ---------------------------------------------------------------- segment I/O

static NSArray<MPGOCompoundField *> *channelSegmentsFields(void)
{
    return @[
        [MPGOCompoundField fieldWithName:@"offset" kind:MPGOCompoundFieldKindInt64],
        [MPGOCompoundField fieldWithName:@"length" kind:MPGOCompoundFieldKindUInt32],
        [MPGOCompoundField fieldWithName:@"iv" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"tag" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"ciphertext" kind:MPGOCompoundFieldKindVLBytes],
    ];
}

static NSArray<MPGOCompoundField *> *auHeaderSegmentsFields(void)
{
    return @[
        [MPGOCompoundField fieldWithName:@"iv" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"tag" kind:MPGOCompoundFieldKindVLBytes],
        [MPGOCompoundField fieldWithName:@"ciphertext" kind:MPGOCompoundFieldKindVLBytes],
    ];
}

static BOOL writeChannelSegments(id<MPGOStorageGroup> parent,
                                    NSString *name,
                                    NSArray<MPGOChannelSegment *> *segments,
                                    NSError **error)
{
    if ([parent hasChildNamed:name]) {
        if (![parent deleteChildNamed:name error:error]) return NO;
    }
    id<MPGOStorageDataset> ds =
        [parent createCompoundDatasetNamed:name
                                      fields:channelSegmentsFields()
                                       count:segments.count
                                       error:error];
    if (!ds) return NO;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:segments.count];
    for (MPGOChannelSegment *seg in segments) {
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

// Compound-dataset reads go through MPGOCompoundIO's
// readGenericFromGroup: path because the StorageDataset protocol
// currently returns a primitive adapter on openDatasetNamed: —
// it doesn't auto-detect H5T_COMPOUND on re-open. Unwrapping the
// StorageGroup to MPGOHDF5Group is the same escape hatch used by
// MPGOSignatureManager. Write goes through the protocol; read uses
// the documented native-handle path.
static NSArray<MPGOChannelSegment *> *readChannelSegments(
    MPGOHDF5Group *hdf5Group, NSString *name, NSError **error)
{
    NSArray<NSDictionary *> *rows =
        [MPGOCompoundIO readGenericFromGroup:hdf5Group
                                  datasetNamed:name
                                        fields:channelSegmentsFields()
                                         error:error];
    if (!rows) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        [out addObject:[[MPGOChannelSegment alloc]
            initWithOffset:[r[@"offset"] unsignedLongLongValue]
                     length:[r[@"length"] unsignedIntValue]
                         iv:r[@"iv"]
                        tag:r[@"tag"]
                 ciphertext:r[@"ciphertext"]]];
    }
    return out;
}

static BOOL writeAUHeaderSegments(id<MPGOStorageGroup> parent,
                                    NSString *name,
                                    NSArray<MPGOHeaderSegment *> *segments,
                                    NSError **error)
{
    if ([parent hasChildNamed:name]) {
        if (![parent deleteChildNamed:name error:error]) return NO;
    }
    id<MPGOStorageDataset> ds =
        [parent createCompoundDatasetNamed:name
                                      fields:auHeaderSegmentsFields()
                                       count:segments.count
                                       error:error];
    if (!ds) return NO;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:segments.count];
    for (MPGOHeaderSegment *seg in segments) {
        [rows addObject:@{
            @"iv": seg.iv, @"tag": seg.tag, @"ciphertext": seg.ciphertext,
        }];
    }
    return [ds writeAll:rows error:error];
}

static NSArray<MPGOHeaderSegment *> *readAUHeaderSegments(
    MPGOHDF5Group *hdf5Group, NSString *name, NSError **error)
{
    NSArray<NSDictionary *> *rows =
        [MPGOCompoundIO readGenericFromGroup:hdf5Group
                                  datasetNamed:name
                                        fields:auHeaderSegmentsFields()
                                         error:error];
    if (!rows) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        [out addObject:[[MPGOHeaderSegment alloc]
            initWithIV:r[@"iv"] tag:r[@"tag"] ciphertext:r[@"ciphertext"]]];
    }
    return out;
}


// ---------------------------------------------------------------- impl

@implementation MPGOPerAUFile

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

    id<MPGOStorageProvider> sp =
        [[MPGOProviderRegistry sharedRegistry] openURL:path
                                                    mode:MPGOStorageOpenModeReadWrite
                                                provider:providerName
                                                   error:error];
    if (!sp) return NO;
    @try {
        id<MPGOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return NO;
        NSString *version = nil;
        NSArray *featuresArr = readFeatureFlags(root, &version);
        NSMutableSet *featureSet = [NSMutableSet setWithArray:featuresArr];

        id<MPGOStorageGroup> study = [root openGroupNamed:@"study" error:error];
        if (!study) return NO;
        id<MPGOStorageGroup> msRuns = [study openGroupNamed:@"ms_runs" error:error];
        if (!msRuns) return NO;

        NSArray *runNames = listGroupChildren(msRuns);
        uint16_t datasetId = 1;
        for (NSString *runName in runNames) {
            id<MPGOStorageGroup> run = [msRuns openGroupNamed:runName error:error];
            if (!run) continue;
            id<MPGOStorageGroup> sig = [run openGroupNamed:@"signal_channels" error:error];
            id<MPGOStorageGroup> idx = [run openGroupNamed:@"spectrum_index" error:error];
            if (!sig || !idx) return NO;

            id<MPGOStorageDataset> offsDs = [idx openDatasetNamed:@"offsets" error:error];
            id<MPGOStorageDataset> lensDs = [idx openDatasetNamed:@"lengths" error:error];
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
                id<MPGOStorageDataset> vDs = [sig openDatasetNamed:valuesName error:error];
                if (!vDs) return NO;
                NSData *plaintext = [vDs readAll:error];
                if (!plaintext) return NO;

                NSArray<MPGOChannelSegment *> *segs =
                    [MPGOPerAUEncryption encryptChannelToSegments:plaintext
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
                id<MPGOStorageDataset> msDs = [idx openDatasetNamed:@"ms_levels" error:error];
                id<MPGOStorageDataset> polDs = [idx openDatasetNamed:@"polarities" error:error];
                id<MPGOStorageDataset> rtDs = [idx openDatasetNamed:@"retention_times" error:error];
                id<MPGOStorageDataset> pmzDs = [idx openDatasetNamed:@"precursor_mzs" error:error];
                id<MPGOStorageDataset> pcDs = [idx openDatasetNamed:@"precursor_charges" error:error];
                id<MPGOStorageDataset> bpiDs = [idx openDatasetNamed:@"base_peak_intensities" error:error];
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
                    MPGOAUHeaderPlaintext *h = [[MPGOAUHeaderPlaintext alloc] init];
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
                NSArray<MPGOHeaderSegment *> *hdrSegs =
                    [MPGOPerAUEncryption encryptHeaderSegments:rows
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

    id<MPGOStorageProvider> sp =
        [[MPGOProviderRegistry sharedRegistry] openURL:path
                                                    mode:MPGOStorageOpenModeRead
                                                provider:providerName
                                                   error:error];
    if (!sp) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        id<MPGOStorageGroup> root = [sp rootGroupWithError:error];
        if (!root) return nil;
        NSArray *features = readFeatureFlags(root, NULL);
        if (![features containsObject:@"opt_per_au_encryption"]) {
            if (error) *error = makeErr(2,
                @"%@ does not carry opt_per_au_encryption", path);
            return nil;
        }
        BOOL headersEncrypted = [features containsObject:@"opt_encrypted_au_headers"];

        // For compound-dataset reads we still need the underlying
        // MPGOHDF5Group — see readChannelSegments comment. Unwrap
        // via the provider's nativeHandle() escape hatch.
        if (![sp.providerName isEqualToString:@"hdf5"]) {
            if (error) *error = makeErr(3,
                @"per-AU decrypt currently requires HDF5 provider (got %@)",
                sp.providerName);
            return nil;
        }
        MPGOHDF5File *hdf5File = (MPGOHDF5File *)[sp nativeHandle];
        MPGOHDF5Group *hdf5Root = hdf5File.rootGroup;

        id<MPGOStorageGroup> study = [root openGroupNamed:@"study" error:error];
        id<MPGOStorageGroup> msRuns = [study openGroupNamed:@"ms_runs" error:error];
        if (!study || !msRuns) return nil;
        NSArray *runNames = listGroupChildren(msRuns);
        uint16_t datasetId = 1;
        for (NSString *runName in runNames) {
            id<MPGOStorageGroup> run = [msRuns openGroupNamed:runName error:error];
            id<MPGOStorageGroup> sig = [run openGroupNamed:@"signal_channels" error:error];
            id<MPGOStorageGroup> idx = [run openGroupNamed:@"spectrum_index" error:error];
            if (!run || !sig || !idx) continue;
            NSString *channelNamesStr = readStringAttr(sig, @"channel_names") ?: @"";
            NSArray<NSString *> *channelNames = splitChannelNames(channelNamesStr);

            // Raw HDF5 groups for the compound-read escape hatch.
            MPGOHDF5Group *hdf5Run =
                [[hdf5Root openGroupNamed:@"study" error:NULL]
                    openGroupNamed:@"ms_runs" error:NULL];
            MPGOHDF5Group *hdf5RunGroup =
                [hdf5Run openGroupNamed:runName error:NULL];
            MPGOHDF5Group *hdf5Sig =
                [hdf5RunGroup openGroupNamed:@"signal_channels" error:NULL];
            MPGOHDF5Group *hdf5Idx =
                [hdf5RunGroup openGroupNamed:@"spectrum_index" error:NULL];

            NSMutableDictionary *runOut = [NSMutableDictionary dictionary];
            for (NSString *cname in channelNames) {
                NSString *segName = [NSString stringWithFormat:@"%@_segments", cname];
                if (![sig hasChildNamed:segName]) continue;
                NSArray *segs = readChannelSegments(hdf5Sig, segName, error);
                if (!segs) return nil;
                NSData *plain = [MPGOPerAUEncryption
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
                NSArray *rows = [MPGOPerAUEncryption
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
    }
    @finally {
        [sp close];
    }
    return out;
}

@end
