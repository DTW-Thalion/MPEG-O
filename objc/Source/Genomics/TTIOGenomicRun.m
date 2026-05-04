#import "TTIOGenomicRun.h"
#import "TTIOAlignedRead.h"
#import "TTIOGenomicIndex.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "Dataset/TTIOCompoundIO.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "Codecs/TTIORans.h"
#import "Codecs/TTIOBasePack.h"
#import "Codecs/TTIOQuality.h"   // M86 Phase D
// v1.0 reset Phase 2c: TTIONameTokenizer (v1, codec id 8) and
// TTIORefDiff (v1, codec id 9) impl files removed. Reader paths
// rejected with NSError; v2 codec headers used for the surviving
// reader dispatch.
#import "Codecs/TTIOFqzcompNx16Z.h"        // M94.Z v1.2
#import "Codecs/TTIODeltaRans.h"           // M95 v1.2
#import "Codecs/TTIOReferenceResolver.h"  // M93 v1.2
#import "Codecs/TTIOMateInfoV2.h"          // v1.7 #11: inline mate-pair codec
#import "Codecs/TTIORefDiffV2.h"          // v1.8 #11: bit-packed ref-diff v2
#import "Codecs/TTIONameTokenizerV2.h"     // v1.8 #11 ch3: adaptive name-tokenizer v2
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
    // M86 Phase E: lazy whole-list decode cache for read_names when
    // it's stored as a flat 1-D uint8 dataset with @compression == 8
    // (NAME_TOKENIZED). Held as NSArray<NSString *> rather than NSData
    // because the codec returns a list of names indexed by read
    // number — separate from _decodedByteChannels per Binding
    // Decision §114. Cache lifetime is the TTIOGenomicRun instance
    // (Gotcha §125 — re-opening the file incurs the decode cost
    // again; for very large runs the decoded list is materialised in
    // RAM in one shot since the codec is per-batch, Gotcha §124).
    NSArray<NSString *> *_decodedReadNames;
    // M86 Phase C: lazy whole-list decode cache for cigars when it's
    // stored as a flat 1-D uint8 dataset with @compression in
    // {RANS_ORDER0 (4), RANS_ORDER1 (5), NAME_TOKENIZED (8)}. Held as
    // NSArray<NSString *> because all three codec paths return a
    // list of CIGAR strings indexed by read number — separate from
    // _decodedReadNames per Binding Decision §123 since the two
    // channels have independent dispatch shapes (rANS uses length-
    // prefix-concat, NAME_TOKENIZED uses its own self-describing
    // wire format). Cache lifetime is the TTIOGenomicRun instance
    // (Gotcha §138 — re-opening the file incurs the decode cost
    // again).
    NSArray<NSString *> *_decodedCigars;
    // M86 Phase B: lazy whole-channel decode cache for integer
    // channels (positions / flags / mapping_qualities) whose
    // @compression attribute names a TTIO rANS id. Held as NSData
    // (LE byte representation of the original integer array) keyed
    // by channel name. Separate from _decodedByteChannels per
    // Binding Decision §116 — the codec output is interpreted as
    // typed integers via channel-name dtype lookup (§115), not as
    // a uint8 byte stream. Cache lifetime is the TTIOGenomicRun
    // instance.
    // v1.6 (L4): _decodedIntChannels removed (cache for the dropped
    // intChannelArrayNamed: helper).
    // M86 Phase F: combined per-field cache for the mate_info subgroup
    // (Binding Decision §129). Single NSMutableDictionary keyed by the
    // on-disk child name (@"chrom", @"pos", @"tlen") since the three
    // fields have three different value types — chrom is
    // NSArray<NSString *>, pos is NSData carrying int64 LE bytes, tlen
    // is NSData carrying int32 LE bytes. Separate from
    // _decodedByteChannels / _decodedIntChannels / _decodedReadNames /
    // _decodedCigars per Binding Decision §129. Cache lifetime is the
    // TTIOGenomicRun instance (re-opening the file incurs the decode
    // cost again).
    NSMutableDictionary<NSString *, id> *_decodedMateInfo;
    // M86 Phase F: cached link-type query result for
    // signal_channels/mate_info. -1 = not yet probed; 0 = M82 compound
    // dataset; 1 = Phase F subgroup. Probed once via H5Oget_info_by_name
    // on first mate-field access (Binding Decision §128, Gotcha §141).
    int8_t _mateInfoLinkType;
    // v1.8 #11: cached link-type query result for
    // signal_channels/sequences. -1 = not yet probed; 0 = flat dataset
    // (v1 REF_DIFF / BASE_PACK / rANS / uncompressed); 1 = GROUP (v1.8
    // refdiff_v2 layout). Probed once on first sequences access.
    int8_t _sequencesLinkType;
    // v1.8 #11: decoded flat sequence bytes from the refdiff_v2 blob.
    // Populated on first access when _sequencesLinkType == 1.
    NSData *_decodedRefDiffV2Sequences;
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
        _decodedMateInfo     = [NSMutableDictionary dictionary];
        _mateInfoLinkType    = -1;  // not yet probed
        _sequencesLinkType   = -1;  // not yet probed
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

// M90.10: probe @compression on a signal channel without decoding
// anything. Used by the transport writer to decide whether to re-
// encode each per-AU UINT8 slice with the same M86 codec on the
// wire. Returns 0 (NONE) when the attribute is absent or unreadable.
- (uint8_t)wireCompressionForChannel:(NSString *)name
{
    if (!name.length) return 0;
    id<TTIOStorageDataset> ds = [self signalDatasetNamed:name error:NULL];
    if (!ds) return 0;
    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:NULL];
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        TTIOHDF5Dataset *hds = [hg openDatasetNamed:name error:NULL];
        if (hds) return _ttio_m86_read_compression_attr([hds datasetId]);
    }
    return _ttio_m86_read_compression_attr_protocol(ds);
}

// M86: byte-channel slice helper.
//
// For byte channels (sequences, qualities) the read path may need to
// decode through a TTIO codec when @compression > 0. We implement the
// decode-once-then-slice tradeoff (Binding Decision §89) — the whole
// channel is decoded on first access and cached on the GenomicRun
// instance. For uncompressed channels the existing per-slice
// HDF5 hyperslab read path is preserved unchanged.
//
// v1.8 #11: for the sequences channel, probe whether signal_channels/sequences
// is a GROUP (refdiff_v2 layout) and decode via TTIORefDiffV2 when true.
- (NSData *)byteChannelSliceNamed:(NSString *)name
                            offset:(NSUInteger)offset
                             count:(NSUInteger)count
                             error:(NSError **)error
{
    // v1.8 #11: refdiff_v2 group layout probe for sequences channel.
    if ([name isEqualToString:@"sequences"] && [self _sequencesIsRefDiffV2]) {
        NSData *decoded = _decodedRefDiffV2Sequences;
        if (!decoded) {
            decoded = [self _decodeRefDiffV2Sequences:error];
            if (!decoded) return nil;
        }
        NSUInteger from = MIN(offset, decoded.length);
        NSUInteger to   = MIN(from + count, decoded.length);
        return [decoded subdataWithRange:NSMakeRange(from, to - from)];
    }

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
        case 9: // TTIOCompressionRefDiff (v1 — removed in Phase 2c)
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2020
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"REF_DIFF v1 (codec id 9) is no longer "
                           @"supported in v1.0; file was written with "
                           @"an older TTI-O version. Re-encode with "
                           @"v1.0+ which uses REF_DIFF_V2 (codec id "
                           @"14)."}];
            return nil;
        case 11: // TTIOCompressionDeltaRansOrder0 (M95 v1.2)
            decoded = TTIODeltaRansDecode(encoded, &decErr);
            break;
        case 12: // TTIOCompressionFqzcompNx16Z (M94.Z v1.2)
            decoded = [self _ttio_m94z_decodeFqzcompNx16Z:encoded error:&decErr];
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

// v1.0 reset Phase 2c: _ttio_m93_decodeRefDiff (v1 REF_DIFF reader)
// removed alongside TTIORefDiff codec impl. The byte-channel codec
// dispatcher above raises a clear NSError when @compression == 9 is
// encountered on legacy files.

// M94.Z v1.2: FQZCOMP_NX16_Z (CRAM-mimic rANS-Nx16) decode helper.
// Same plumbing as the old NX16: revcomp_flags from run.flags & 16,
// read_lengths carried inside the codec wire format.
- (NSData *)_ttio_m94z_decodeFqzcompNx16Z:(NSData *)encoded
                                     error:(NSError **)error
{
    NSUInteger n = _index ? _index.count : 0;
    NSMutableArray<NSNumber *> *revcompFlags = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        uint32_t f = [_index flagsAt:i];
        [revcompFlags addObject:(f & 16u) ? @1 : @0];
    }
    NSError *decErr = nil;
    NSDictionary *out = [TTIOFqzcompNx16Z decodeData:encoded
                                          revcompFlags:revcompFlags
                                                 error:&decErr];
    if (!out) {
        if (error) *error = decErr;
        return nil;
    }
    return out[@"qualities"];
}

// M86 Phase E: read_names dispatch helper.
//
// The read_names channel has two on-disk layouts (Binding Decisions
// §111, §112):
//
//   - **M82 compound** (no override): VL_STRING-in-compound dataset,
//     read whole-and-cache via -compoundRowsNamed:.
//   - **NAME_TOKENIZED** (override active): flat 1-D uint8 dataset
//     of the same name carrying the codec output, with
//     @compression == 8. Decoded once on first access via
//     TTIONameTokenizerDecode and cached as NSArray<NSString *>
//     on this TTIOGenomicRun instance per Binding Decision §114.
//
// Dispatch is on dataset shape — a flat uint8 dataset routes through
// the codec path; otherwise fall through to the compound path.
// All call sites that touch read_names should route through this
// helper (Gotcha §126).
- (NSString *)readNameAtIndex:(NSUInteger)i error:(NSError **)error
{
    if (_decodedReadNames != nil) {
        if (i >= _decodedReadNames.count) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2040
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"read_names index %lu out of range "
                                @"[0, %lu)",
                                (unsigned long)i,
                                (unsigned long)_decodedReadNames.count]}];
            return nil;
        }
        return _decodedReadNames[i];
    }

    id<TTIOStorageDataset> ds = [self signalDatasetNamed:@"read_names"
                                                   error:error];
    if (!ds) return nil;

    // Shape dispatch: precision == UInt8 is a flat uint8 dataset and
    // therefore the codec path; anything else is the M82 compound.
    // The HDF5 backend's -openDatasetNamed: returns precision UInt8
    // for the schema-lifted layout (TTIOHDF5Group introspects via
    // H5Tequal(H5T_NATIVE_UINT8)); for compound datasets none of the
    // primitive H5Tequal checks match, so precision falls through
    // (here we treat anything other than UInt8 as compound).
    if ([ds precision] == TTIOPrecisionUInt8) {
        uint8_t codec_id = 0;
        id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:NULL];
        if ([sig respondsToSelector:@selector(unwrap)]) {
            TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
            TTIOHDF5Dataset *hds = [hg openDatasetNamed:@"read_names"
                                                  error:NULL];
            if (hds) {
                codec_id = _ttio_m86_read_compression_attr([hds datasetId]);
            }
        } else {
            codec_id = _ttio_m86_read_compression_attr_protocol(ds);
        }
        // v1.0 reset Phase 2c: NAME_TOKENIZED v1 (codec id 8) reader
        // path removed — reject with a clear error so legacy files
        // surface a re-encode hint instead of silently mis-decoding.
        if (codec_id == (uint8_t)8 /* NAME_TOKENIZED v1 */) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2041
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"NAME_TOKENIZED v1 (codec id 8) is no "
                           @"longer supported in v1.0; file was "
                           @"written with an older TTI-O version. "
                           @"Re-encode with v1.0+ which uses "
                           @"NAME_TOKENIZED_V2 (codec id 15)."}];
            return nil;
        }
        if (codec_id != (uint8_t)15 /* NAME_TOKENIZED_V2 */) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2041
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel 'read_names': "
                                @"@compression=%u is not a supported "
                                @"TTIO codec id for the read_names "
                                @"channel (only NAME_TOKENIZED_V2 = "
                                @"15 is recognised under v1.0)",
                                (unsigned)codec_id]}];
            return nil;
        }
        id allRaw = [ds readAll:error];
        if (![allRaw isKindOfClass:[NSData class]]) return nil;
        NSData *encoded = (NSData *)allRaw;
        // Empty-run short-circuit: zero-length blob → empty list.
        if (encoded.length == 0) {
            _decodedReadNames = @[];
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2040
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"read_names index %lu out of range "
                                @"[0, 0) — empty read_names blob",
                                (unsigned long)i]}];
            return nil;
        }
        NSError *decErr = nil;
        NSArray<NSString *> *decoded =
            [TTIONameTokenizerV2 decodeData:encoded error:&decErr];
        if (decoded == nil) {
            if (error) *error = decErr ?: [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2042
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"signal_channel 'read_names' "
                           @"NAME_TOKENIZED_V2 decode failed"}];
            return nil;
        }
        _decodedReadNames = [decoded copy];
        if (i >= _decodedReadNames.count) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2043
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"read_names index %lu out of range "
                                @"[0, %lu) after NAME_TOKENIZED decode",
                                (unsigned long)i,
                                (unsigned long)_decodedReadNames.count]}];
            return nil;
        }
        return _decodedReadNames[i];
    }

    // v1.0 reset Phase 2c: M82 read_names compound layout removed.
    // A non-UInt8 read_names dataset is from an older TTI-O version.
    if (error) *error = [NSError
        errorWithDomain:@"TTIOGenomicRun" code:2044
               userInfo:@{NSLocalizedDescriptionKey:
                   @"signal_channels/read_names is a compound layout "
                   @"(M82 / VL-string). The compound layout is no "
                   @"longer supported in v1.0; file was written with "
                   @"an older TTI-O version. Re-encode with v1.0+ "
                   @"which uses NAME_TOKENIZED_V2 (codec id 15)."}];
    return nil;
}

// M86 Phase C: unsigned LEB128 varint reader for the cigars rANS
// length-prefix-concat path. Mirrors NAME_TOKENIZED's varint_read
// (in TTIONameTokenizer.m) — reproduced here to avoid coupling the
// run reader to the codec module's private symbols. Returns 1 on
// success and advances *io_offset past the consumed bytes; returns
// 0 on truncated/oversize varints (>10 bytes / >64 bits).
static int _ttio_m86_cigars_varint_read(const uint8_t *buf, size_t buf_len,
                                         size_t *io_offset,
                                         uint64_t *out_value)
{
    uint64_t value = 0;
    int shift = 0;
    size_t pos = *io_offset;
    for (;;) {
        if (pos >= buf_len) return 0;
        const uint8_t b = buf[pos++];
        if (shift >= 64) return 0;
        value |= ((uint64_t)(b & 0x7Fu)) << shift;
        if ((b & 0x80u) == 0) {
            *io_offset = pos;
            *out_value = value;
            return 1;
        }
        shift += 7;
    }
}

// M86 Phase C: cigars dispatch helper.
//
// The cigars channel has two on-disk layouts (Binding Decisions
// §120-§123, HANDOFF M86 Phase C §2.7):
//
//   - **M82 compound** (no override): VL_STRING-in-compound dataset,
//     read whole-and-cache via -compoundRowsNamed:.
//   - **TTIO codec** (override active): flat 1-D uint8 dataset
//     of the same name carrying the codec output, with @compression
//     in {4, 5, 8}. Decoded once on first access and cached as
//     NSArray<NSString *> on this TTIOGenomicRun instance per
//     Binding Decision §123 — a separate field from
//     _decodedReadNames since the two channels have independent
//     dispatch shapes.
//
//     * @compression == 4 (RANS_ORDER0) or 5 (RANS_ORDER1): the
//       decoded byte buffer is a length-prefix-concat sequence
//       (varint(len) + bytes per CIGAR; §2.5 of the Phase C plan;
//       Gotcha §139). Walk the buffer until exhausted.
//     * @compression == 8 (NAME_TOKENIZED): pass the bytes through
//       TTIONameTokenizerDecode directly (the codec's self-describing
//       wire format records the read count internally).
//
// Dispatch is on dataset shape — a flat uint8 dataset routes through
// the codec path; otherwise fall through to the compound path (same
// pattern Phase E uses for read_names).
- (NSString *)cigarAtIndex:(NSUInteger)i error:(NSError **)error
{
    if (_decodedCigars != nil) {
        if (i >= _decodedCigars.count) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2060
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"cigars index %lu out of range "
                                @"[0, %lu)",
                                (unsigned long)i,
                                (unsigned long)_decodedCigars.count]}];
            return nil;
        }
        return _decodedCigars[i];
    }

    id<TTIOStorageDataset> ds = [self signalDatasetNamed:@"cigars"
                                                   error:error];
    if (!ds) return nil;

    // Shape dispatch: precision == UInt8 is a flat uint8 dataset and
    // therefore the codec path; anything else (compound) falls through
    // to the M82 path. Mirrors -readNameAtIndex:'s shape check.
    if ([ds precision] == TTIOPrecisionUInt8) {
        uint8_t codec_id = 0;
        id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:NULL];
        if ([sig respondsToSelector:@selector(unwrap)]) {
            TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
            TTIOHDF5Dataset *hds = [hg openDatasetNamed:@"cigars"
                                                  error:NULL];
            if (hds) {
                codec_id = _ttio_m86_read_compression_attr([hds datasetId]);
            }
        } else {
            codec_id = _ttio_m86_read_compression_attr_protocol(ds);
        }

        id allRaw = [ds readAll:error];
        if (![allRaw isKindOfClass:[NSData class]]) return nil;
        NSData *encoded = (NSData *)allRaw;

        if (codec_id == (uint8_t)4 /* RANS_ORDER0 */
            || codec_id == (uint8_t)5 /* RANS_ORDER1 */) {
            NSError *decErr = nil;
            NSData *decoded = TTIORansDecode(encoded, &decErr);
            if (decoded == nil) {
                if (error) *error = decErr ?: [NSError
                    errorWithDomain:@"TTIOGenomicRun" code:2061
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"signal_channel 'cigars' rANS decode "
                               @"failed"}];
                return nil;
            }
            // Walk length-prefix-concat: varint(len) + len bytes per
            // CIGAR, repeated until the decoded buffer is exhausted.
            const uint8_t *buf = (const uint8_t *)decoded.bytes;
            const size_t   n   = decoded.length;
            size_t off = 0;
            NSMutableArray<NSString *> *out = [NSMutableArray array];
            while (off < n) {
                uint64_t len = 0;
                if (!_ttio_m86_cigars_varint_read(buf, n, &off, &len)) {
                    if (error) *error = [NSError
                        errorWithDomain:@"TTIOGenomicRun" code:2062
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"signal_channel 'cigars' rANS "
                                   @"length-prefix-concat: truncated "
                                   @"varint length prefix"}];
                    return nil;
                }
                if (off + (size_t)len > n) {
                    if (error) *error = [NSError
                        errorWithDomain:@"TTIOGenomicRun" code:2063
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                        @"signal_channel 'cigars' rANS "
                                        @"length-prefix-concat: entry "
                                        @"runs off end of decoded buffer "
                                        @"(offset=%zu, length=%llu, "
                                        @"buffer_size=%zu)",
                                        off,
                                        (unsigned long long)len, n]}];
                    return nil;
                }
                NSString *cig = [[NSString alloc]
                    initWithBytes:buf + off
                           length:(NSUInteger)len
                         encoding:NSASCIIStringEncoding];
                if (cig == nil) {
                    if (error) *error = [NSError
                        errorWithDomain:@"TTIOGenomicRun" code:2064
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"signal_channel 'cigars' rANS "
                                   @"length-prefix-concat: entry "
                                   @"contains non-ASCII bytes"}];
                    return nil;
                }
                [out addObject:cig];
                off += (size_t)len;
            }
            _decodedCigars = [out copy];
        } else if (codec_id == (uint8_t)8 /* NAME_TOKENIZED v1 */) {
            // v1.0 reset Phase 2c: NAME_TOKENIZED v1 reader removed.
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2065
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"NAME_TOKENIZED v1 (codec id 8) is no "
                           @"longer supported in v1.0; cigars dataset "
                           @"was written with an older TTI-O version. "
                           @"Re-encode with v1.0+ which uses RANS "
                           @"on the cigars channel."}];
            return nil;
        } else {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2066
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel 'cigars': "
                                @"@compression=%u is not a supported "
                                @"TTIO codec id for the cigars channel "
                                @"(only RANS_ORDER0 = 4 and "
                                @"RANS_ORDER1 = 5 are recognised "
                                @"under v1.0)",
                                (unsigned)codec_id]}];
            return nil;
        }

        if (i >= _decodedCigars.count) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2067
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"cigars index %lu out of range "
                                @"[0, %lu) after codec decode",
                                (unsigned long)i,
                                (unsigned long)_decodedCigars.count]}];
            return nil;
        }
        return _decodedCigars[i];
    }

    // Compound path (M82, no override).
    TTIOCompoundField *vlValue =
        [TTIOCompoundField fieldWithName:@"value"
                                    kind:TTIOCompoundFieldKindVLString];
    NSArray *cigars = [self compoundRowsNamed:@"cigars"
                                         field:vlValue
                                         error:error];
    if (!cigars) return nil;
    if (i >= cigars.count) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2068
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"cigars index %lu out of range [0, %lu)",
                            (unsigned long)i,
                            (unsigned long)cigars.count]}];
        return nil;
    }
    id cigarV = cigars[i][@"value"];
    if ([cigarV isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:cigarV
                                      encoding:NSUTF8StringEncoding];
    }
    return (NSString *)cigarV;
}

// M86 Phase B: integer-channel array reader.
//
// Returns the full integer signal-channel array (positions, flags,
// or mapping_qualities) as an NSData carrying the LE byte
// representation of the dtype implied by channel-name lookup
// (Binding Decision §115). Two paths:
//
//   - **Uncompressed (no @compression or @compression == 0):** read
//     the typed dataset directly via the storage protocol; bytes are
//     already in LE order (HDF5 stores native little-endian on
//     x86/ARM). Cache and return.
//
//   - **rANS (@compression == 4 or 5):** read the dataset whole as
//     uint8 bytes, decode through TTIORansDecode, cache and return.
//
// Per Binding Decision §119 the per-read access path
// (-readAtIndex:) does NOT consume this helper; it continues to use
// self.index.{positions,mappingQualities,flags}. This helper is
// wired for round-trip conformance and for any future reader that
// prefers signal_channels/ over genomic_index/ (Phase B is primarily
// a write-side file-size optimisation).
// v1.6 (L4): -intChannelArrayNamed:error: removed. The helper read
// positions/flags/mapping_qualities from signal_channels/ via codec
// dispatch — but those datasets no longer exist in v1.6 files. See
// docs/format-spec.md §10.7.

// M86 Phase F: HDF5 link-type query for signal_channels/mate_info.
// Per Binding Decision §128 / Gotcha §141, dispatch is on HDF5 link
// type (dataset = M82 compound; group = Phase F subgroup), NOT on
// @compression attribute presence on the bare link (the attribute
// lives on per-field child datasets within the subgroup, not on the
// bare link). Probed once on first access and cached on the run.
//
// HDF5 backend: H5Oget_info_by_name returns a struct whose `type`
// field is H5O_TYPE_GROUP or H5O_TYPE_DATASET — the cleanest signal
// for the dispatch. For non-HDF5 backends we fall back to the
// storage protocol's openGroupNamed/openDatasetNamed combination
// (one returns nil where the other doesn't).
- (BOOL)_mateInfoIsSubgroup
{
    if (_mateInfoLinkType >= 0) {
        // linkType 0 = compound, 1 = Phase-F subgroup, 2 = inline_v2 subgroup.
        return _mateInfoLinkType >= 1;
    }
    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:NULL];
    if (!sig) {
        // Defensive: if signal_channels is unavailable, assume M82.
        _mateInfoLinkType = 0;
        return NO;
    }
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        if (hg) {
            H5O_info_t info;
            herr_t s = H5Oget_info_by_name([hg groupId], "mate_info",
                                           &info, H5P_DEFAULT);
            if (s >= 0 && info.type == H5O_TYPE_GROUP) {
                // It is a group. Probe further for inline_v2 dataset.
                TTIOHDF5Group *mateGrp = [hg openGroupNamed:@"mate_info" error:NULL];
                if (mateGrp) {
                    H5O_info_t dsInfo;
                    herr_t s2 = H5Oget_info_by_name([mateGrp groupId],
                                                    "inline_v2", &dsInfo,
                                                    H5P_DEFAULT);
                    if (s2 >= 0 && dsInfo.type == H5O_TYPE_DATASET) {
                        _mateInfoLinkType = 2;  // v1.7 inline_v2
                        return YES;
                    }
                }
                _mateInfoLinkType = 1;  // Phase-F per-field subgroup
                return YES;
            }
            if (s >= 0) {
                _mateInfoLinkType = 0;  // dataset = M82 compound
                return NO;
            }
        }
        // H5Oget_info_by_name failed — assume compound (legacy default).
        _mateInfoLinkType = 0;
        return NO;
    }
    // Storage-protocol path: try openGroupNamed first.
    NSError *gErr = nil;
    id<TTIOStorageGroup> sub = [sig openGroupNamed:@"mate_info" error:&gErr];
    if (sub != nil) {
        // Probe for inline_v2 child dataset.
        NSError *dsErr = nil;
        id<TTIOStorageDataset> inlineDs =
            [sub openDatasetNamed:@"inline_v2" error:&dsErr];
        if (inlineDs != nil) {
            _mateInfoLinkType = 2;
        } else {
            _mateInfoLinkType = 1;
        }
        return YES;
    }
    _mateInfoLinkType = 0;
    return NO;
}

/** v1.7 #11: YES when signal_channels/mate_info/inline_v2 exists. */
- (BOOL)_mateInfoIsInlineV2
{
    // Force probe if not yet done.
    (void)[self _mateInfoIsSubgroup];
    return _mateInfoLinkType == 2;
}

// ── v1.8 #11: sequences GROUP probe + refdiff_v2 decoder ─────────────────────

/** v1.8 #11: probe whether signal_channels/sequences is a GROUP (refdiff_v2
 *  layout) or a flat dataset (all v1 layouts). Cached on first call. */
- (BOOL)_sequencesIsRefDiffV2
{
    if (_sequencesLinkType >= 0) return _sequencesLinkType == 1;

    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:NULL];
    if (!sig) {
        _sequencesLinkType = 0;
        return NO;
    }
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        H5O_info_t info;
        memset(&info, 0, sizeof(info));
        herr_t s = H5Oget_info_by_name([hg groupId], "sequences",
                                       &info, H5P_DEFAULT);
        if (s >= 0 && info.type == H5O_TYPE_GROUP) {
            _sequencesLinkType = 1;
            return YES;
        }
        _sequencesLinkType = 0;
        return NO;
    }
    // Storage-protocol path: try openGroupNamed first.
    NSError *gErr = nil;
    id<TTIOStorageGroup> sub = [sig openGroupNamed:@"sequences" error:&gErr];
    if (sub != nil) {
        _sequencesLinkType = 1;
        return YES;
    }
    _sequencesLinkType = 0;
    return NO;
}

/** v1.8 #11: decode the refdiff_v2 blob into flat sequence bytes; cache
 *  the result in _decodedRefDiffV2Sequences. Returns nil + error on
 *  failure. Resolves the reference via TTIOReferenceResolver.
 *
 *  Blob header layout (from Python spec):
 *    [0:4]    magic "RDF2"
 *    [12:20]  n_reads (LE uint64)
 *    [20:36]  reference_md5 (16 bytes)
 *    [36:38]  uri_len (LE uint16)
 *    [38:38+uri_len] reference_uri (UTF-8)
 */
- (NSData *)_decodeRefDiffV2Sequences:(NSError **)error
{
    if (_decodedRefDiffV2Sequences) return _decodedRefDiffV2Sequences;

    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
    if (!sig) return nil;

    // Open the sequences GROUP and the refdiff_v2 dataset inside it.
    NSData *blob = nil;
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        TTIOHDF5Group *seqGrp = [hg openGroupNamed:@"sequences" error:error];
        if (!seqGrp) return nil;
        TTIOHDF5Dataset *ds = [seqGrp openDatasetNamed:@"refdiff_v2" error:error];
        if (!ds) return nil;
        id raw = [ds readDataWithError:error];
        if (![raw isKindOfClass:[NSData class]]) return nil;
        blob = (NSData *)raw;
    } else {
        id<TTIOStorageGroup> seqGrp = [sig openGroupNamed:@"sequences" error:error];
        if (!seqGrp) return nil;
        id<TTIOStorageDataset> ds = [seqGrp openDatasetNamed:@"refdiff_v2" error:error];
        if (!ds) return nil;
        id raw = [ds readAll:error];
        if (![raw isKindOfClass:[NSData class]]) return nil;
        blob = (NSData *)raw;
    }

    // Parse the blob header to extract reference_uri and reference_md5.
    // Header layout: [0:4] "RDF2" magic, [20:36] md5, [36:38] uri_len LE,
    // [38:38+uri_len] uri UTF-8.
    const uint8_t *blobBytes = (const uint8_t *)blob.bytes;
    NSUInteger blobLen = blob.length;
    if (blobLen < 38) {
        if (error) *error = [NSError errorWithDomain:@"TTIOGenomicRun" code:2094
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               @"refdiff_v2 blob too short to parse header"}];
        return nil;
    }
    if (memcmp(blobBytes, "RDF2", 4) != 0) {
        if (error) *error = [NSError errorWithDomain:@"TTIOGenomicRun" code:2094
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               @"refdiff_v2 blob magic mismatch (expected 'RDF2')"}];
        return nil;
    }
    NSData *blobMD5 = [NSData dataWithBytes:blobBytes + 20 length:16];
    uint16_t uriLen = 0;
    memcpy(&uriLen, blobBytes + 36, 2);
    // uriLen is LE uint16
    if (blobLen < (NSUInteger)(38 + uriLen)) {
        if (error) *error = [NSError errorWithDomain:@"TTIOGenomicRun" code:2094
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               @"refdiff_v2 blob truncated (uri)"}];
        return nil;
    }
    NSString *blobURI = [[NSString alloc] initWithBytes:blobBytes + 38
                                                  length:uriLen
                                               encoding:NSUTF8StringEncoding]
                        ?: @"";

    // Resolve reference sequence via embedded /study/references/ or external path.
    TTIOHDF5Group *rootHDF5 = nil;
    if ([_group respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *runG = [(id)_group performSelector:@selector(unwrap)];
        hid_t fid = H5Iget_file_id([runG groupId]);
        if (fid >= 0) {
            hid_t rootId = H5Gopen2(fid, "/", H5P_DEFAULT);
            if (rootId >= 0) {
                rootHDF5 = [[TTIOHDF5Group alloc] initWithGroupId:rootId
                                                          retainer:nil];
            }
            H5Idec_ref(fid);
        }
    }
    TTIOReferenceResolver *resolver = [[TTIOReferenceResolver alloc]
        initWithRootGroup:rootHDF5
    externalReferencePath:nil];

    // Single-chromosome constraint (same as v1).
    NSMutableSet<NSString *> *unique = [NSMutableSet set];
    for (NSUInteger i = 0; i < _index.count; i++) {
        NSString *c = [_index chromosomeAt:i];
        if (c.length) [unique addObject:c];
    }
    if (unique.count != 1) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2095
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"refdiff_v2 decode: expected single-chromosome "
                            @"run, got %lu chromosomes",
                            (unsigned long)unique.count]}];
        return nil;
    }
    NSString *chrom = [unique anyObject];
    NSError *resolveErr = nil;
    NSData *ref = [resolver resolveURI:blobURI
                           expectedMD5:blobMD5
                            chromosome:chrom
                                 error:&resolveErr];
    if (!ref) {
        if (error) *error = resolveErr;
        return nil;
    }

    NSUInteger n = _index.count;
    NSUInteger totalBases = 0;
    for (NSUInteger i = 0; i < n; i++) totalBases += [_index lengthAt:i];

    // Build positions array from the index.
    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *posPtr = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) posPtr[i] = [_index positionAt:i];

    // Build cigars list — trigger cigarAtIndex:0 to populate _decodedCigars
    // when the cigars channel uses the codec path (same as v1 path).
    NSMutableArray<NSString *> *cigars = nil;
    if (n > 0) {
        NSError *cigErr = nil;
        (void)[self cigarAtIndex:0 error:&cigErr];
    }
    if (_decodedCigars != nil) {
        cigars = [NSMutableArray arrayWithArray:_decodedCigars];
    } else {
        cigars = [NSMutableArray arrayWithCapacity:n];
        for (NSUInteger i = 0; i < n; i++) {
            NSError *cigErr = nil;
            NSString *cig = [self cigarAtIndex:i error:&cigErr];
            if (!cig) {
                if (error) *error = cigErr;
                return nil;
            }
            [cigars addObject:cig];
        }
    }

    NSData *outSeq = nil;
    NSData *outOff = nil;
    BOOL ok = [TTIORefDiffV2 decodeData:blob
                              positions:positions
                           cigarStrings:cigars
                              reference:ref
                                 nReads:n
                             totalBases:totalBases
                           outSequences:&outSeq
                             outOffsets:&outOff
                                  error:error];
    if (!ok) return nil;

    _decodedRefDiffV2Sequences = outSeq;
    return _decodedRefDiffV2Sequences;
}

/** v1.7 #11: decode the inline_v2 blob; populate _decodedMateInfo with
 *  "chrom" (NSArray<NSString *>), "pos" (NSData int64), "tlen" (NSData int32).
 *  Returns NO + error on failure. Caches on success. */
- (BOOL)_decodeMateInfoInlineV2:(NSError **)error
{
    // Already cached?
    if (_decodedMateInfo[@"chrom"]) return YES;

    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
    if (!sig) return NO;

    // Open the mate_info group.
    TTIOHDF5Group *mateH5 = nil;
    id<TTIOStorageGroup> mateProt = nil;
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        mateH5 = [hg openGroupNamed:@"mate_info" error:error];
        if (!mateH5) return NO;
    } else {
        mateProt = [sig openGroupNamed:@"mate_info" error:error];
        if (!mateProt) return NO;
    }

    // Read the inline_v2 blob.
    NSData *blob = nil;
    if (mateH5) {
        TTIOHDF5Dataset *ds = [mateH5 openDatasetNamed:@"inline_v2" error:error];
        if (!ds) return NO;
        id raw = [ds readDataWithError:error];
        if (![raw isKindOfClass:[NSData class]]) return NO;
        blob = (NSData *)raw;
    } else {
        id<TTIOStorageDataset> ds = [mateProt openDatasetNamed:@"inline_v2" error:error];
        if (!ds) return NO;
        id raw = [ds readAll:error];
        if (![raw isKindOfClass:[NSData class]]) return NO;
        blob = (NSData *)raw;
    }

    NSUInteger n = _index.count;

    // Build own_chrom_ids using encounter-order (must match writer).
    NSMutableData *ownChromIds =
        [NSMutableData dataWithLength:n * sizeof(uint16_t)];
    uint16_t *ownIdsPtr = (uint16_t *)ownChromIds.mutableBytes;
    NSMutableDictionary<NSString *, NSNumber *> *nameToId =
        [NSMutableDictionary dictionaryWithCapacity:32];
    for (NSUInteger i = 0; i < n; i++) {
        NSString *name = [_index chromosomeAt:i];
        NSNumber *existingId = nameToId[name];
        if (existingId == nil) {
            NSUInteger newId = nameToId.count;
            nameToId[name] = @(newId);
            ownIdsPtr[i] = (uint16_t)newId;
        } else {
            ownIdsPtr[i] = (uint16_t)[existingId unsignedIntegerValue];
        }
    }

    // Build own_positions from index.
    NSMutableData *ownPositions =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *posPtr = (int64_t *)ownPositions.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        posPtr[i] = [_index positionAt:i];
    }

    // Decode via TTIOMateInfoV2.
    NSData *outMc = nil, *outMp = nil, *outTs = nil;
    NSError *decErr = nil;
    BOOL ok = [TTIOMateInfoV2 decodeData:blob
                             ownChromIds:ownChromIds
                            ownPositions:ownPositions
                               nRecords:n
                        outMateChromIds:&outMc
                       outMatePositions:&outMp
                     outTemplateLengths:&outTs
                                  error:&decErr];
    if (!ok) {
        if (error) *error = decErr ?: [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2090
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"v1.7 inline_v2 decode failed"}];
        return NO;
    }

    // Read the chrom_names sidecar compound to resolve mate chrom ids → names.
    NSArray *chromNameRows = nil;
    TTIOCompoundField *nameField =
        [TTIOCompoundField fieldWithName:@"name"
                                    kind:TTIOCompoundFieldKindVLString];
    if (mateH5) {
        chromNameRows = [TTIOCompoundIO readGenericFromGroup:mateH5
                                                datasetNamed:@"chrom_names"
                                                      fields:@[nameField]
                                                       error:error];
    } else {
        id<TTIOStorageDataset> namesDs =
            [mateProt openDatasetNamed:@"chrom_names" error:error];
        if (namesDs) chromNameRows = [namesDs readAll:error];
    }
    if (!chromNameRows) return NO;

    // Build chrom_id → name table (row index = chrom_id).
    NSMutableArray<NSString *> *chromNamesById =
        [NSMutableArray arrayWithCapacity:chromNameRows.count];
    for (NSDictionary *row in chromNameRows) {
        id v = row[@"name"];
        NSString *s = [v isKindOfClass:[NSData class]]
            ? [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding]
            : (NSString *)v;
        [chromNamesById addObject:s ?: @""];
    }

    // Convert mate_chrom_ids (int32, -1=unmapped) back to chromosome name strings.
    const int32_t *mcPtr = (const int32_t *)outMc.bytes;
    NSMutableArray<NSString *> *mateChroms =
        [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        int32_t iv = mcPtr[i];
        if (iv == -1) {
            [mateChroms addObject:@"*"];
        } else if (iv >= 0 && (NSUInteger)iv < chromNamesById.count) {
            [mateChroms addObject:chromNamesById[iv]];
        } else {
            [mateChroms addObject:
                [NSString stringWithFormat:@"chr_id_%d", iv]];
        }
    }

    _decodedMateInfo[@"chrom"] = [mateChroms copy];
    _decodedMateInfo[@"pos"]   = outMp;
    _decodedMateInfo[@"tlen"]  = outTs;
    return YES;
}

// v1.0 reset Phase 2c: per-read mate-field accessors recognise only
// the inline_v2 layout (v1.7 codec id 13). The Phase F per-field
// subgroup (linkType 1) and M82 compound (linkType 0) layouts are
// rejected with a clear NSError directing callers at the v2 codec.
static void _ttio_v17_reject_legacy_mate_layout(NSError **error)
{
    if (error) *error = [NSError
        errorWithDomain:@"TTIOGenomicRun" code:2080
               userInfo:@{NSLocalizedDescriptionKey:
                   @"signal_channels/mate_info layout is not the "
                   @"inline_v2 codec (id 13). The Phase F per-field "
                   @"subgroup and M82 compound layouts are no longer "
                   @"supported in v1.0; file was written with an "
                   @"older TTI-O version. Re-encode with v1.0+."}];
}

- (NSString *)_mateChromAtIndex:(NSUInteger)i error:(NSError **)error
{
    if ([self _mateInfoIsInlineV2]) {
        if (![self _decodeMateInfoInlineV2:error]) return nil;
        NSArray<NSString *> *chroms = _decodedMateInfo[@"chrom"];
        if (!chroms || i >= chroms.count) return nil;
        return chroms[i];
    }
    _ttio_v17_reject_legacy_mate_layout(error);
    return nil;
}

- (int64_t)_matePosAtIndex:(NSUInteger)i error:(NSError **)error
{
    if ([self _mateInfoIsInlineV2]) {
        if (![self _decodeMateInfoInlineV2:error]) return 0;
        NSData *bytes = _decodedMateInfo[@"pos"];
        if (!bytes) return 0;
        NSUInteger n = bytes.length / sizeof(int64_t);
        if (i >= n) return 0;
        int64_t v; memcpy(&v, (const int64_t *)bytes.bytes + i, sizeof(int64_t));
        return v;
    }
    _ttio_v17_reject_legacy_mate_layout(error);
    return 0;
}

- (int32_t)_mateTlenAtIndex:(NSUInteger)i error:(NSError **)error
{
    if ([self _mateInfoIsInlineV2]) {
        if (![self _decodeMateInfoInlineV2:error]) return 0;
        NSData *bytes = _decodedMateInfo[@"tlen"];
        if (!bytes) return 0;
        NSUInteger n = bytes.length / sizeof(int32_t);
        if (i >= n) return 0;
        int32_t v; memcpy(&v, (const int32_t *)bytes.bytes + i, sizeof(int32_t));
        return v;
    }
    _ttio_v17_reject_legacy_mate_layout(error);
    return 0;
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

    // M86 Phase C: route cigars through the shape-dispatching helper
    // so the schema-lifted (flat uint8 + RANS or NAME_TOKENIZED)
    // layout is decoded transparently. The compound (M82) layout
    // continues to use the existing -compoundRowsNamed: cache via
    // the helper's compound fall-through.
    NSString *cigar = [self cigarAtIndex:i error:error];
    if (!cigar && error && *error) return nil;

    // M86 Phase E: route read_names through the shape-dispatching
    // helper so the schema-lifted (flat uint8 + NAME_TOKENIZED)
    // layout is decoded transparently. The compound (M82) layout
    // continues to use the existing -compoundRowsNamed: cache.
    NSString *readName = [self readNameAtIndex:i error:error];
    if (!readName && error && *error) return nil;

    // M86 Phase F: route mate-field reads through the per-field
    // dispatch helpers. The link-type query (group vs dataset) for
    // signal_channels/mate_info is cached on the run, so the three
    // accessors are essentially free after the first call. The
    // existing M82 compound path is preserved inside the helpers
    // (see -_mateChromAtIndex: et al.).
    NSError *mErr = nil;
    NSString *mateChromosome = [self _mateChromAtIndex:i error:&mErr];
    if (!mateChromosome && mErr) {
        if (error) *error = mErr;
        return nil;
    }
    int64_t matePosition = [self _matePosAtIndex:i error:&mErr];
    int32_t templateLength = [self _mateTlenAtIndex:i error:&mErr];

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

#pragma mark - TTIOIndexable / TTIORun (Phase 1)

- (NSUInteger)count
{
    return _index ? _index.count : 0;
}

- (id)objectAtIndex:(NSUInteger)index
{
    return [self readAtIndex:index error:NULL];
}

- (NSArray<TTIOProvenanceRecord *> *)provenanceChain
{
    // Mirrors Python GenomicRun.provenance_chain() — closes the M91
    // read-side gap. Reads from <run>/provenance/steps using the same
    // compound layout as TTIOAcquisitionRun. Returns @[] for runs with
    // no provenance attached.
    if (![_group respondsToSelector:@selector(unwrap)]) return @[];
    TTIOHDF5Group *runH5 = [(id)_group performSelector:@selector(unwrap)];
    if (!runH5) return @[];
    if (![runH5 hasChildNamed:@"provenance"]) return @[];
    TTIOHDF5Group *provGroup =
        [runH5 openGroupNamed:@"provenance" error:NULL];
    if (!provGroup || ![provGroup hasChildNamed:@"steps"]) return @[];
    NSArray *records =
        [TTIOCompoundIO readProvenanceFromGroup:provGroup
                                   datasetNamed:@"steps"
                                          error:NULL];
    return records ? [records copy] : @[];
}

@end
