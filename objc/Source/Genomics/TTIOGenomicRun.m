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
