#import "TTIOGenomicRun.h"
#import "TTIOAlignedRead.h"
#import "TTIOGenomicIndex.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "Dataset/TTIOCompoundIO.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "Codecs/TTIORans.h"
#import "Codecs/TTIOBasePack.h"
#import "Codecs/TTIOQuality.h"   // M86 Phase D
#import <hdf5.h>

@implementation TTIOGenomicRun {
    id<TTIOStorageGroup> _group;
    id<TTIOStorageGroup> _signalChannelsGroup;       // lazily opened, cached
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_signalCache;
    NSMutableDictionary<NSString *, NSArray *> *_compoundCache;
    // M86: lazy whole-channel decode cache for byte channels whose
    // @compression attribute names a TTIO codec (rANS / BASE_PACK).
    // Codec output is byte-stream non-sliceable, so the whole channel
    // is decoded once on first access and the decoded buffer is
    // sliced from memory thereafter (Binding Decision §89). Cache
    // lifetime is the TTIOGenomicRun instance — re-opening the file
    // incurs the decode cost again (Gotcha §101).
    NSMutableDictionary<NSString *, NSData *> *_decodedByteChannels;
}

- (NSUInteger)readCount { return _index.count; }

- (instancetype)initWithName:(NSString *)name
              acquisitionMode:(TTIOAcquisitionMode)mode
                     modality:(NSString *)modality
                 referenceUri:(NSString *)refUri
                     platform:(NSString *)platform
                   sampleName:(NSString *)sampleName
                        index:(TTIOGenomicIndex *)index
                        group:(id<TTIOStorageGroup>)group
{
    self = [super init];
    if (self) {
        _name             = [name copy];
        _acquisitionMode  = mode;
        _modality         = [modality copy];
        _referenceUri     = [refUri copy];
        _platform         = [platform copy];
        _sampleName       = [sampleName copy];
        _index            = index;
        _group            = group;
        _signalCache      = [NSMutableDictionary dictionary];
        _compoundCache    = [NSMutableDictionary dictionary];
        _decodedByteChannels = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (instancetype)openFromGroup:(id<TTIOStorageGroup>)runGroup
                          name:(NSString *)name
                         error:(NSError **)error
{
    if (!runGroup) return nil;

    id<TTIOStorageGroup> idxGroup = [runGroup openGroupNamed:@"genomic_index" error:error];
    if (!idxGroup) return nil;
    TTIOGenomicIndex *index = [TTIOGenomicIndex readFromGroup:idxGroup error:error];
    if (!index) return nil;

    // Integer attribute: the storage-protocol adapter tries
    // stringAttributeNamed first which silently returns garbage bytes
    // for INT64 attrs (TTIOHDF5Group.stringAttributeNamed doesn't
    // type-check). Read directly via the underlying HDF5Group when
    // available; fall back to the protocol for non-HDF5 providers.
    int64_t modeValue = 0;
    if ([runGroup respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *h5 = [(id)runGroup performSelector:@selector(unwrap)];
        BOOL exists = NO;
        modeValue = [h5 integerAttributeNamed:@"acquisition_mode"
                                        exists:&exists error:NULL];
    } else {
        id v = [runGroup attributeValueForName:@"acquisition_mode" error:NULL];
        if ([v isKindOfClass:[NSNumber class]]) modeValue = [v longLongValue];
    }
    NSString *modality  = [runGroup attributeValueForName:@"modality"         error:error];
    NSString *refUri    = [runGroup attributeValueForName:@"reference_uri"    error:error];
    NSString *platform  = [runGroup attributeValueForName:@"platform"         error:error];
    NSString *sampleN   = [runGroup attributeValueForName:@"sample_name"      error:error];

    return [[TTIOGenomicRun alloc]
        initWithName:name
     acquisitionMode:(TTIOAcquisitionMode)modeValue
            modality:modality ?: @"genomic_sequencing"
        referenceUri:refUri ?: @""
            platform:platform ?: @""
          sampleName:sampleN ?: @""
               index:index
               group:runGroup];
}

- (id<TTIOStorageGroup>)signalChannelsGroupWithError:(NSError **)error
{
    if (!_signalChannelsGroup) {
        _signalChannelsGroup = [_group openGroupNamed:@"signal_channels" error:error];
    }
    return _signalChannelsGroup;
}

- (id<TTIOStorageDataset>)signalDatasetNamed:(NSString *)name error:(NSError **)error
{
    id<TTIOStorageDataset> ds = _signalCache[name];
    if (!ds) {
        id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
        if (!sig) return nil;
        ds = [sig openDatasetNamed:name error:error];
        if (ds) _signalCache[name] = ds;
    }
    return ds;
}

- (NSArray *)compoundRowsNamed:(NSString *)name
                         field:(TTIOCompoundField *)field
                         error:(NSError **)error
{
    NSArray *rows = _compoundCache[name];
    if (rows) return rows;

    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
    if (!sig) return nil;

    NSArray *fields = field ? @[field] : nil;
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *h5 = [(id)sig performSelector:@selector(unwrap)];
        rows = [TTIOCompoundIO readGenericFromGroup:h5
                                        datasetNamed:name
                                              fields:fields
                                               error:error];
    } else {
        id<TTIOStorageDataset> ds = [sig openDatasetNamed:name error:error];
        if (ds) rows = [ds readAll:error];
    }
    if (rows) _compoundCache[name] = rows;
    return rows;
}

// M86: read the @compression attribute (uint8) on an HDF5 dataset.
// Returns 0 (NONE) when the attribute is absent — equivalent to
// "uncompressed at the TTIO-codec layer". The dataset hid_t is taken
// from the underlying TTIOHDF5Dataset; non-HDF5 backends fall back to
// the storage protocol's attributeValueForName:error:.
static uint8_t _ttio_m86_read_compression_attr(hid_t did)
{
    if (H5Aexists(did, "compression") <= 0) return 0;
    hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
    if (aid < 0) return 0;
    uint8_t value = 0;
    H5Aread(aid, H5T_NATIVE_UINT8, &value);
    H5Aclose(aid);
    return value;
}

// M86: read the @compression attribute via the storage protocol (used
// for non-HDF5 backends). Returns 0 when absent or non-numeric.
static uint8_t _ttio_m86_read_compression_attr_protocol(id<TTIOStorageDataset> ds)
{
    if (![ds hasAttributeNamed:@"compression"]) return 0;
    NSError *e = nil;
    id v = [ds attributeValueForName:@"compression" error:&e];
    if ([v isKindOfClass:[NSNumber class]]) {
        return (uint8_t)[v unsignedIntegerValue];
    }
    return 0;
}

// M86: byte-channel slice helper.
//
// For byte channels (sequences, qualities) the read path may need to
// decode through a TTIO codec when @compression > 0. We implement the
// decode-once-then-slice tradeoff (Binding Decision §89) — the whole
// channel is decoded on first access and cached on the GenomicRun
// instance. For uncompressed channels the existing per-slice
// HDF5 hyperslab read path is preserved unchanged.
- (NSData *)byteChannelSliceNamed:(NSString *)name
                            offset:(NSUInteger)offset
                             count:(NSUInteger)count
                             error:(NSError **)error
{
    NSData *cached = _decodedByteChannels[name];
    if (cached) {
        NSUInteger from = MIN(offset, cached.length);
        NSUInteger to   = MIN(from + count, cached.length);
        return [cached subdataWithRange:NSMakeRange(from, to - from)];
    }

    id<TTIOStorageDataset> ds = [self signalDatasetNamed:name error:error];
    if (!ds) return nil;

    // Detect codec via @compression on the dataset. Two paths: HDF5
    // backend exposes the underlying TTIOHDF5Dataset whose hid_t the
    // H5A* calls need; non-HDF5 backends route through the storage
    // protocol's attributeValueForName:.
    uint8_t codec_id = 0;
    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:NULL];
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        TTIOHDF5Dataset *hds = [hg openDatasetNamed:name error:NULL];
        if (hds) {
            codec_id = _ttio_m86_read_compression_attr([hds datasetId]);
        }
    } else {
        codec_id = _ttio_m86_read_compression_attr_protocol(ds);
    }

    if (codec_id == 0) {
        // No TTIO-codec dispatch — existing hyperslab path.
        id raw = [ds readSliceAtOffset:offset count:count error:error];
        if (![raw isKindOfClass:[NSData class]]) return nil;
        return (NSData *)raw;
    }

    // Codec-compressed: read all bytes, decode, cache, slice.
    id allRaw = [ds readAll:error];
    if (![allRaw isKindOfClass:[NSData class]]) return nil;
    NSData *encoded = (NSData *)allRaw;
    NSData *decoded = nil;
    NSError *decErr = nil;
    switch (codec_id) {
        case 4: // TTIOCompressionRansOrder0
        case 5: // TTIOCompressionRansOrder1
            decoded = TTIORansDecode(encoded, &decErr);
            break;
        case 6: // TTIOCompressionBasePack
            decoded = TTIOBasePackDecode(encoded, &decErr);
            break;
        case 7: // TTIOCompressionQualityBinned (M86 Phase D)
            decoded = TTIOQualityDecode(encoded, &decErr);
            break;
        default:
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2020
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel '%@': @compression=%u "
                                @"is not a supported TTIO codec id",
                                name, (unsigned)codec_id]}];
            return nil;
    }
    if (!decoded) {
        if (error) *error = decErr ?: [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2021
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"signal_channel '%@' codec %u decode failed",
                            name, (unsigned)codec_id]}];
        return nil;
    }
    _decodedByteChannels[name] = decoded;
    NSUInteger from = MIN(offset, decoded.length);
    NSUInteger to   = MIN(from + count, decoded.length);
    return [decoded subdataWithRange:NSMakeRange(from, to - from)];
}

- (TTIOAlignedRead *)readAtIndex:(NSUInteger)i error:(NSError **)error
{
    if (i >= _index.count) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:0
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"index %lu out of range [0, %lu)",
                            (unsigned long)i, (unsigned long)_index.count]}];
        return nil;
    }

    uint64_t offset = [_index offsetAt:i];
    uint32_t length = [_index lengthAt:i];

    int64_t  position = [_index positionAt:i];
    uint8_t  mapq     = [_index mappingQualityAt:i];
    uint32_t flag     = [_index flagsAt:i];
    NSString *chrom   = [_index chromosomeAt:i];

    // M86: routed through byteChannelSliceNamed: so codec-compressed
    // channels (@compression > 0) are decoded transparently before
    // slicing. Uncompressed channels go through the existing
    // hyperslab path.
    NSData *seqData = [self byteChannelSliceNamed:@"sequences"
                                            offset:offset count:length
                                             error:error];
    if (!seqData) return nil;
    NSString *sequence = [[NSString alloc] initWithData:seqData
                                               encoding:NSASCIIStringEncoding];

    NSData *qualities = [self byteChannelSliceNamed:@"qualities"
                                              offset:offset count:length
                                               error:error];
    if (!qualities) return nil;

    // Compound rows (cached after first access)
    TTIOCompoundField *vlValue =
        [TTIOCompoundField fieldWithName:@"value" kind:TTIOCompoundFieldKindVLString];

    NSArray *cigars = [self compoundRowsNamed:@"cigars" field:vlValue error:error];
    if (!cigars) return nil;
    id cigarV = cigars[i][@"value"];
    NSString *cigar = [cigarV isKindOfClass:[NSData class]]
        ? [[NSString alloc] initWithData:cigarV encoding:NSUTF8StringEncoding]
        : (NSString *)cigarV;

    NSArray *names = [self compoundRowsNamed:@"read_names" field:vlValue error:error];
    if (!names) return nil;
    id nameV = names[i][@"value"];
    NSString *readName = [nameV isKindOfClass:[NSData class]]
        ? [[NSString alloc] initWithData:nameV encoding:NSUTF8StringEncoding]
        : (NSString *)nameV;

    // mate_info has 3 fields (chrom VL, pos int64, tlen int32)
    NSArray *mateFields = @[
        [TTIOCompoundField fieldWithName:@"chrom" kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"pos"   kind:TTIOCompoundFieldKindInt64],
        [TTIOCompoundField fieldWithName:@"tlen"  kind:TTIOCompoundFieldKindInt64],  // int32 boxed as int64
    ];
    NSArray *mates = _compoundCache[@"mate_info"];
    if (!mates) {
        id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
        if (!sig) return nil;
        if ([sig respondsToSelector:@selector(unwrap)]) {
            TTIOHDF5Group *h5 = [(id)sig performSelector:@selector(unwrap)];
            mates = [TTIOCompoundIO readGenericFromGroup:h5
                                             datasetNamed:@"mate_info"
                                                   fields:mateFields
                                                    error:error];
        } else {
            id<TTIOStorageDataset> ds = [sig openDatasetNamed:@"mate_info" error:error];
            if (ds) mates = [ds readAll:error];
        }
        if (!mates) return nil;
        _compoundCache[@"mate_info"] = mates;
    }
    NSDictionary *mate = mates[i];
    id mcv = mate[@"chrom"];
    NSString *mateChromosome = [mcv isKindOfClass:[NSData class]]
        ? [[NSString alloc] initWithData:mcv encoding:NSUTF8StringEncoding]
        : (NSString *)(mcv ?: @"");
    int64_t matePosition = [mate[@"pos"] longLongValue];
    int32_t templateLength = (int32_t)[mate[@"tlen"] integerValue];

    return [[TTIOAlignedRead alloc]
        initWithReadName:readName
              chromosome:chrom
                position:position
          mappingQuality:mapq
                   cigar:cigar
                sequence:sequence
               qualities:qualities
                   flags:flag
          mateChromosome:mateChromosome
            matePosition:matePosition
          templateLength:templateLength];
}

- (NSArray<TTIOAlignedRead *> *)readsInRegion:(NSString *)chromosome
                                          start:(int64_t)start
                                            end:(int64_t)end
{
    NSIndexSet *indices = [_index indicesForRegion:chromosome start:start end:end];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:indices.count];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSError *err = nil;
        TTIOAlignedRead *r = [self readAtIndex:idx error:&err];
        if (r) [result addObject:r];
    }];
    return result;
}

@end
