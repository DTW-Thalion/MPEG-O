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
#import "Codecs/TTIONameTokenizer.h"   // M86 Phase E
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
    NSMutableDictionary<NSString *, NSData *> *_decodedIntChannels;
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
        _decodedIntChannels  = [NSMutableDictionary dictionary];
        _decodedMateInfo     = [NSMutableDictionary dictionary];
        _mateInfoLinkType    = -1;  // not yet probed
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
        if (codec_id != (uint8_t)8 /* NAME_TOKENIZED */) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2041
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel 'read_names': "
                                @"@compression=%u is not a supported "
                                @"TTIO codec id for the read_names "
                                @"channel (only NAME_TOKENIZED = 8 is "
                                @"recognised)",
                                (unsigned)codec_id]}];
            return nil;
        }
        id allRaw = [ds readAll:error];
        if (![allRaw isKindOfClass:[NSData class]]) return nil;
        NSData *encoded = (NSData *)allRaw;
        NSError *decErr = nil;
        NSArray<NSString *> *decoded = TTIONameTokenizerDecode(encoded, &decErr);
        if (decoded == nil) {
            if (error) *error = decErr ?: [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2042
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"signal_channel 'read_names' "
                           @"NAME_TOKENIZED decode failed"}];
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

    // Compound path (M82, no override).
    TTIOCompoundField *vlValue =
        [TTIOCompoundField fieldWithName:@"value"
                                    kind:TTIOCompoundFieldKindVLString];
    NSArray *names = [self compoundRowsNamed:@"read_names"
                                       field:vlValue
                                       error:error];
    if (!names) return nil;
    if (i >= names.count) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2044
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"read_names index %lu out of range [0, %lu)",
                            (unsigned long)i,
                            (unsigned long)names.count]}];
        return nil;
    }
    id nameV = names[i][@"value"];
    if ([nameV isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:nameV
                                      encoding:NSUTF8StringEncoding];
    }
    return (NSString *)nameV;
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
        } else if (codec_id == (uint8_t)8 /* NAME_TOKENIZED */) {
            NSError *decErr = nil;
            NSArray<NSString *> *decoded =
                TTIONameTokenizerDecode(encoded, &decErr);
            if (decoded == nil) {
                if (error) *error = decErr ?: [NSError
                    errorWithDomain:@"TTIOGenomicRun" code:2065
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"signal_channel 'cigars' "
                               @"NAME_TOKENIZED decode failed"}];
                return nil;
            }
            _decodedCigars = [decoded copy];
        } else {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2066
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel 'cigars': "
                                @"@compression=%u is not a supported "
                                @"TTIO codec id for the cigars channel "
                                @"(only RANS_ORDER0 = 4, RANS_ORDER1 = "
                                @"5, and NAME_TOKENIZED = 8 are "
                                @"recognised)",
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
- (NSData *)intChannelArrayNamed:(NSString *)name error:(NSError **)error
{
    if (![name isEqualToString:@"positions"]
        && ![name isEqualToString:@"flags"]
        && ![name isEqualToString:@"mapping_qualities"]) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2050
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"intChannelArrayNamed: '%@' is not a "
                            @"recognised integer signal channel "
                            @"(only positions, flags, "
                            @"mapping_qualities)", name]}];
        return nil;
    }
    NSData *cached = _decodedIntChannels[name];
    if (cached) return cached;

    id<TTIOStorageDataset> ds = [self signalDatasetNamed:name error:error];
    if (!ds) return nil;

    // Detect codec via @compression on the dataset. HDF5 backend
    // exposes the underlying TTIOHDF5Dataset; non-HDF5 backends
    // route through the storage protocol's attributeValueForName:.
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
        // Uncompressed: read the typed dataset whole. The storage
        // protocol returns NSData carrying the native (host LE on
        // x86/ARM) byte representation; that matches the documented
        // LE serialisation contract for the cached output.
        id allRaw = [ds readAll:error];
        if (![allRaw isKindOfClass:[NSData class]]) return nil;
        _decodedIntChannels[name] = (NSData *)allRaw;
        return _decodedIntChannels[name];
    }

    if (codec_id != 4 /* RansOrder0 */ && codec_id != 5 /* RansOrder1 */) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2051
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"signal_channel '%@': @compression=%u "
                            @"is not a supported TTIO codec id for an "
                            @"integer channel (only RANS_ORDER0 = 4 "
                            @"and RANS_ORDER1 = 5 are recognised)",
                            name, (unsigned)codec_id]}];
        return nil;
    }

    id allRaw = [ds readAll:error];
    if (![allRaw isKindOfClass:[NSData class]]) return nil;
    NSError *decErr = nil;
    NSData *decoded = TTIORansDecode((NSData *)allRaw, &decErr);
    if (!decoded) {
        if (error) *error = decErr ?: [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2052
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"signal_channel '%@' rANS decode failed",
                            name]}];
        return nil;
    }
    _decodedIntChannels[name] = decoded;
    return decoded;
}

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
        return _mateInfoLinkType == 1;
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
            if (s >= 0) {
                _mateInfoLinkType =
                    (info.type == H5O_TYPE_GROUP) ? 1 : 0;
                return _mateInfoLinkType == 1;
            }
        }
        // H5Oget_info_by_name failed — assume compound (legacy default).
        _mateInfoLinkType = 0;
        return NO;
    }
    // Storage-protocol path: try openGroupNamed first; if it succeeds
    // and the link is a dataset the protocol's adapter typically
    // returns nil for openGroupNamed. Different providers behave
    // slightly differently here; for robustness probe openGroupNamed
    // first and treat success as Phase F. (The cross-language
    // conformance fixture only covers HDF5; provider-path Phase F
    // round-trips through the same mate_info dispatch but byte-exact
    // parity isn't asserted.)
    NSError *gErr = nil;
    id<TTIOStorageGroup> sub = [sig openGroupNamed:@"mate_info" error:&gErr];
    if (sub != nil) {
        _mateInfoLinkType = 1;
        return YES;
    }
    _mateInfoLinkType = 0;
    return NO;
}

// M86 Phase F: lazily decode the mate_info chrom field from the Phase F
// subgroup. Caches in _decodedMateInfo[@"chrom"] and returns
// NSArray<NSString *>. Routes through Phase C cigars helpers for the
// rANS path (length-prefix-concat) and TTIONameTokenizerDecode for
// the NAME_TOKENIZED path. For un-overridden chrom fields the dataset
// is a compound with VL_STRING value field — read whole and extract.
- (NSArray<NSString *> *)_decodeMateChromOrError:(NSError **)error
{
    NSArray<NSString *> *cached = _decodedMateInfo[@"chrom"];
    if (cached) return cached;

    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
    if (!sig) return nil;

    // Open the Phase F subgroup. HDF5 fast path uses the underlying
    // H5 group; non-HDF5 falls back to the storage protocol.
    TTIOHDF5Group *mateH5 = nil;
    id<TTIOStorageGroup> mateProt = nil;
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        mateH5 = [hg openGroupNamed:@"mate_info" error:error];
        if (!mateH5) return nil;
    } else {
        mateProt = [sig openGroupNamed:@"mate_info" error:error];
        if (!mateProt) return nil;
    }

    // Determine layout: a flat uint8 child dataset is the codec path;
    // a compound child dataset is the natural-dtype path.
    TTIOHDF5Dataset *chromH5 = nil;
    id<TTIOStorageDataset> chromProt = nil;
    if (mateH5) {
        chromH5 = [mateH5 openDatasetNamed:@"chrom" error:error];
        if (!chromH5) return nil;
    } else {
        chromProt = [mateProt openDatasetNamed:@"chrom" error:error];
        if (!chromProt) return nil;
    }

    TTIOPrecision prec = chromH5 ? [chromH5 precision] : [chromProt precision];
    if (prec == TTIOPrecisionUInt8) {
        uint8_t codec_id = 0;
        if (chromH5) {
            codec_id = _ttio_m86_read_compression_attr([chromH5 datasetId]);
        } else {
            codec_id = _ttio_m86_read_compression_attr_protocol(chromProt);
        }
        NSData *encoded = nil;
        if (chromH5) {
            id raw = [chromH5 readDataWithError:error];
            if (![raw isKindOfClass:[NSData class]]) return nil;
            encoded = (NSData *)raw;
        } else {
            id raw = [chromProt readAll:error];
            if (![raw isKindOfClass:[NSData class]]) return nil;
            encoded = (NSData *)raw;
        }

        if (codec_id == (uint8_t)4 /* RANS_ORDER0 */
            || codec_id == (uint8_t)5 /* RANS_ORDER1 */) {
            NSError *decErr = nil;
            NSData *decoded = TTIORansDecode(encoded, &decErr);
            if (decoded == nil) {
                if (error) *error = decErr ?: [NSError
                    errorWithDomain:@"TTIOGenomicRun" code:2070
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"signal_channel 'mate_info/chrom' rANS "
                               @"decode failed"}];
                return nil;
            }
            const uint8_t *buf = (const uint8_t *)decoded.bytes;
            const size_t   n   = decoded.length;
            size_t off = 0;
            NSMutableArray<NSString *> *out = [NSMutableArray array];
            while (off < n) {
                uint64_t len = 0;
                if (!_ttio_m86_cigars_varint_read(buf, n, &off, &len)) {
                    if (error) *error = [NSError
                        errorWithDomain:@"TTIOGenomicRun" code:2071
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"signal_channel 'mate_info/chrom' "
                                   @"rANS length-prefix-concat: "
                                   @"truncated varint length prefix"}];
                    return nil;
                }
                if (off + (size_t)len > n) {
                    if (error) *error = [NSError
                        errorWithDomain:@"TTIOGenomicRun" code:2072
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                        @"signal_channel 'mate_info/chrom' "
                                        @"rANS length-prefix-concat: entry "
                                        @"runs off end of decoded buffer "
                                        @"(offset=%zu, length=%llu, "
                                        @"buffer_size=%zu)",
                                        off,
                                        (unsigned long long)len, n]}];
                    return nil;
                }
                NSString *cstr = [[NSString alloc]
                    initWithBytes:buf + off
                           length:(NSUInteger)len
                         encoding:NSASCIIStringEncoding];
                if (cstr == nil) {
                    if (error) *error = [NSError
                        errorWithDomain:@"TTIOGenomicRun" code:2073
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"signal_channel 'mate_info/chrom' "
                                   @"rANS length-prefix-concat: entry "
                                   @"contains non-ASCII bytes"}];
                    return nil;
                }
                [out addObject:cstr];
                off += (size_t)len;
            }
            _decodedMateInfo[@"chrom"] = [out copy];
            return _decodedMateInfo[@"chrom"];
        }
        if (codec_id == (uint8_t)8 /* NAME_TOKENIZED */) {
            NSError *decErr = nil;
            NSArray<NSString *> *decoded =
                TTIONameTokenizerDecode(encoded, &decErr);
            if (decoded == nil) {
                if (error) *error = decErr ?: [NSError
                    errorWithDomain:@"TTIOGenomicRun" code:2074
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"signal_channel 'mate_info/chrom' "
                               @"NAME_TOKENIZED decode failed"}];
                return nil;
            }
            _decodedMateInfo[@"chrom"] = [decoded copy];
            return _decodedMateInfo[@"chrom"];
        }
        if (error) *error = [NSError
            errorWithDomain:@"TTIOGenomicRun" code:2075
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"signal_channel 'mate_info/chrom': "
                            @"@compression=%u is not a supported TTIO "
                            @"codec id (only RANS_ORDER0 = 4, "
                            @"RANS_ORDER1 = 5, and NAME_TOKENIZED = 8 "
                            @"are recognised for this channel)",
                            (unsigned)codec_id]}];
        return nil;
    }

    // Natural-dtype (un-overridden) path: compound VL_STRING child
    // dataset inside the subgroup. Read whole and extract values.
    NSArray *rows = nil;
    if (mateH5) {
        TTIOCompoundField *vlValue =
            [TTIOCompoundField fieldWithName:@"value"
                                        kind:TTIOCompoundFieldKindVLString];
        rows = [TTIOCompoundIO readGenericFromGroup:mateH5
                                         datasetNamed:@"chrom"
                                               fields:@[vlValue]
                                                error:error];
    } else {
        rows = [chromProt readAll:error];
    }
    if (!rows) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        id v = r[@"value"];
        NSString *s = [v isKindOfClass:[NSData class]]
            ? [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding]
            : (NSString *)v;
        [out addObject:s ?: @""];
    }
    _decodedMateInfo[@"chrom"] = [out copy];
    return _decodedMateInfo[@"chrom"];
}

// M86 Phase F: lazily decode an integer mate field (pos = int64 LE,
// tlen = int32 LE) from the Phase F subgroup. Caches in
// _decodedMateInfo[name] and returns the cached NSData (LE byte
// representation). For un-overridden fields reads the typed dataset
// directly (HDF5 already returns LE bytes on x86/ARM hosts; on
// big-endian hosts the caller must byte-swap, mirroring the write
// contract per Binding Decision §118).
- (NSData *)_decodeMateIntField:(NSString *)name
                       elemSize:(NSUInteger)elemSize
                          error:(NSError **)error
{
    NSData *cached = _decodedMateInfo[name];
    if (cached) return cached;

    id<TTIOStorageGroup> sig = [self signalChannelsGroupWithError:error];
    if (!sig) return nil;

    TTIOHDF5Group *mateH5 = nil;
    id<TTIOStorageGroup> mateProt = nil;
    if ([sig respondsToSelector:@selector(unwrap)]) {
        TTIOHDF5Group *hg = [(id)sig performSelector:@selector(unwrap)];
        mateH5 = [hg openGroupNamed:@"mate_info" error:error];
        if (!mateH5) return nil;
    } else {
        mateProt = [sig openGroupNamed:@"mate_info" error:error];
        if (!mateProt) return nil;
    }

    TTIOHDF5Dataset *fieldH5 = nil;
    id<TTIOStorageDataset> fieldProt = nil;
    if (mateH5) {
        fieldH5 = [mateH5 openDatasetNamed:name error:error];
        if (!fieldH5) return nil;
    } else {
        fieldProt = [mateProt openDatasetNamed:name error:error];
        if (!fieldProt) return nil;
    }

    TTIOPrecision prec = fieldH5 ? [fieldH5 precision] : [fieldProt precision];
    if (prec == TTIOPrecisionUInt8) {
        uint8_t codec_id = 0;
        if (fieldH5) {
            codec_id = _ttio_m86_read_compression_attr([fieldH5 datasetId]);
        } else {
            codec_id = _ttio_m86_read_compression_attr_protocol(fieldProt);
        }
        if (codec_id != 4 /* RansOrder0 */ && codec_id != 5 /* RansOrder1 */) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2076
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel 'mate_info/%@': "
                                @"@compression=%u is not a supported "
                                @"TTIO codec id for an integer mate field "
                                @"(only RANS_ORDER0 = 4 and RANS_ORDER1 = "
                                @"5 are recognised)",
                                name, (unsigned)codec_id]}];
            return nil;
        }
        NSData *encoded = nil;
        if (fieldH5) {
            id raw = [fieldH5 readDataWithError:error];
            if (![raw isKindOfClass:[NSData class]]) return nil;
            encoded = (NSData *)raw;
        } else {
            id raw = [fieldProt readAll:error];
            if (![raw isKindOfClass:[NSData class]]) return nil;
            encoded = (NSData *)raw;
        }
        NSError *decErr = nil;
        NSData *decoded = TTIORansDecode(encoded, &decErr);
        if (!decoded) {
            if (error) *error = decErr ?: [NSError
                errorWithDomain:@"TTIOGenomicRun" code:2077
                       userInfo:@{NSLocalizedDescriptionKey:
                           [NSString stringWithFormat:
                                @"signal_channel 'mate_info/%@' rANS "
                                @"decode failed", name]}];
            return nil;
        }
        _decodedMateInfo[name] = decoded;
        return decoded;
    }

    // Natural-dtype (un-overridden) path: read the typed dataset whole.
    // The bytes are already LE on x86/ARM hosts (HDF5 native LE storage).
    id allRaw = nil;
    if (fieldH5) {
        allRaw = [fieldH5 readDataWithError:error];
    } else {
        allRaw = [fieldProt readAll:error];
    }
    if (![allRaw isKindOfClass:[NSData class]]) return nil;
    _decodedMateInfo[name] = (NSData *)allRaw;
    (void)elemSize;  // currently informational; element-size kept for
                    // future shape validation.
    return _decodedMateInfo[name];
}

// M86 Phase F: per-read accessors for the three mate fields. Each
// dispatches on the link-type query (group = Phase F subgroup vs
// dataset = M82 compound) and routes through either the per-field
// decode helper (Phase F) or the existing _compoundCache[@"mate_info"]
// path (M82). Used by -readAtIndex: in place of the M82 mate-block.
- (NSString *)_mateChromAtIndex:(NSUInteger)i error:(NSError **)error
{
    if ([self _mateInfoIsSubgroup]) {
        NSArray<NSString *> *chroms = [self _decodeMateChromOrError:error];
        if (!chroms) return nil;
        if (i >= chroms.count) return nil;
        return chroms[i];
    }
    // M82 compound path — read whole-and-cache via _compoundCache,
    // mirroring the original -readAtIndex: block.
    NSArray *mates = _compoundCache[@"mate_info"];
    if (!mates) {
        NSArray *mateFields = @[
            [TTIOCompoundField fieldWithName:@"chrom" kind:TTIOCompoundFieldKindVLString],
            [TTIOCompoundField fieldWithName:@"pos"   kind:TTIOCompoundFieldKindInt64],
            [TTIOCompoundField fieldWithName:@"tlen"  kind:TTIOCompoundFieldKindInt64],
        ];
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
    if (i >= mates.count) return nil;
    id mcv = mates[i][@"chrom"];
    return [mcv isKindOfClass:[NSData class]]
        ? [[NSString alloc] initWithData:mcv encoding:NSUTF8StringEncoding]
        : (NSString *)(mcv ?: @"");
}

- (int64_t)_matePosAtIndex:(NSUInteger)i error:(NSError **)error
{
    if ([self _mateInfoIsSubgroup]) {
        NSData *bytes = [self _decodeMateIntField:@"pos"
                                          elemSize:sizeof(int64_t)
                                             error:error];
        if (!bytes) return 0;
        NSUInteger n = bytes.length / sizeof(int64_t);
        if (i >= n) return 0;
        const int64_t *src = (const int64_t *)bytes.bytes;
        // Bytes are LE; on x86/ARM (LE host) memcpy gives the right value.
        int64_t v;
        memcpy(&v, &src[i], sizeof(int64_t));
        return v;
    }
    // M82 compound path.
    NSArray *mates = _compoundCache[@"mate_info"];
    if (!mates) {
        // Force population via -_mateChromAtIndex: side-effect; reuses
        // the same compound-cache fill. (Discarded return; we just
        // need the cache populated.)
        NSError *gErr = nil;
        (void)[self _mateChromAtIndex:0 error:&gErr];
        mates = _compoundCache[@"mate_info"];
    }
    if (!mates || i >= mates.count) return 0;
    return [mates[i][@"pos"] longLongValue];
}

- (int32_t)_mateTlenAtIndex:(NSUInteger)i error:(NSError **)error
{
    if ([self _mateInfoIsSubgroup]) {
        NSData *bytes = [self _decodeMateIntField:@"tlen"
                                          elemSize:sizeof(int32_t)
                                             error:error];
        if (!bytes) return 0;
        NSUInteger n = bytes.length / sizeof(int32_t);
        if (i >= n) return 0;
        const int32_t *src = (const int32_t *)bytes.bytes;
        int32_t v;
        memcpy(&v, &src[i], sizeof(int32_t));
        return v;
    }
    NSArray *mates = _compoundCache[@"mate_info"];
    if (!mates) {
        NSError *gErr = nil;
        (void)[self _mateChromAtIndex:0 error:&gErr];
        mates = _compoundCache[@"mate_info"];
    }
    if (!mates || i >= mates.count) return 0;
    return (int32_t)[mates[i][@"tlen"] integerValue];
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
