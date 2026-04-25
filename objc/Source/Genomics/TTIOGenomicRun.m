#import "TTIOGenomicRun.h"
#import "TTIOAlignedRead.h"
#import "TTIOGenomicIndex.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "Dataset/TTIOCompoundIO.h"
#import "HDF5/TTIOHDF5Group.h"

@implementation TTIOGenomicRun {
    id<TTIOStorageGroup> _group;
    id<TTIOStorageGroup> _signalChannelsGroup;       // lazily opened, cached
    NSMutableDictionary<NSString *, id<TTIOStorageDataset>> *_signalCache;
    NSMutableDictionary<NSString *, NSArray *> *_compoundCache;
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

    // Hyperslab reads on sequences + qualities
    id<TTIOStorageDataset> seqDs = [self signalDatasetNamed:@"sequences" error:error];
    if (!seqDs) return nil;
    id seqRaw = [seqDs readSliceAtOffset:offset count:length error:error];
    if (![seqRaw isKindOfClass:[NSData class]]) return nil;
    NSString *sequence = [[NSString alloc] initWithData:(NSData *)seqRaw
                                               encoding:NSASCIIStringEncoding];

    id<TTIOStorageDataset> qualDs = [self signalDatasetNamed:@"qualities" error:error];
    if (!qualDs) return nil;
    id qualRaw = [qualDs readSliceAtOffset:offset count:length error:error];
    if (![qualRaw isKindOfClass:[NSData class]]) return nil;
    NSData *qualities = (NSData *)qualRaw;

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
