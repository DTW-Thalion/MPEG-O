#import "TTIOSpectralDataset.h"
#import "TTIOWrittenRun.h"
#import "TTIOIdentification.h"
#import "TTIOQuantification.h"
#import "TTIOProvenanceRecord.h"
#import "TTIOTransitionList.h"
#import "TTIOCompoundIO.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIONMRSpectrum.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "HDF5/TTIOHDF5Types.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "Protection/TTIOEncryptionManager.h"
#import "Protection/TTIOAccessPolicy.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOCompoundField.h"
#import "Providers/TTIOHDF5Provider.h"
#import "Genomics/TTIOGenomicRun.h"            // M82
#import "Genomics/TTIOGenomicIndex.h"          // M82
#import "Genomics/TTIOWrittenGenomicRun.h"     // M82
#import "Codecs/TTIORans.h"                    // M86
#import "Codecs/TTIOBasePack.h"                // M86
#import "Codecs/TTIOQuality.h"                 // M86 Phase D
#import "Codecs/TTIONameTokenizer.h"            // M86 Phase E
#import <hdf5.h>

// Internal SPI surfaced by TTIOAcquisitionRun for the dataset-level
// decrypt lifecycle. Not part of the public header.
@interface TTIOAcquisitionRun (TTIOSpectralDatasetInternal)
- (NSData *)decryptedChannelNamed:(NSString *)chName;
- (BOOL)reattachSignalHandlesFromGroup:(TTIOHDF5Group *)channels error:(NSError **)error;
@end

// v0.2 format version emitted by this writer.
static NSString *const kTTIOFormatVersion = @"1.1";

// v0.12 M74: version bumped when the file carries
// opt_ms2_activation_detail (i.e. any run's spectrum_index has the
// four optional activation/isolation columns).
static NSString *const kTTIOFormatVersionM74 = @"1.3";
static NSString *const kTTIOFormatVersionM82 = @"1.4";

/** v0.12 M74 Slice E: scan the ms_runs dict for any run whose
 *  spectrum_index carries the four optional activation/isolation
 *  columns. When present, the writer upgrades the feature flag list
 *  with opt_ms2_activation_detail and bumps the on-disk format version
 *  to 1.3. Returns NO when every run has the legacy layout. */
static BOOL datasetRunsHaveActivationDetail(NSDictionary *msRuns)
{
    for (TTIOAcquisitionRun *run in [msRuns objectEnumerator]) {
        if (run.spectrumIndex.hasActivationDetail) return YES;
    }
    return NO;
}

// ── M86: signal-channel codec wiring ────────────────────────────────
//
// Validation, codec dispatch (rANS / BASE_PACK), and the uint8
// @compression attribute write that the read path keys on. See
// HANDOFF.md M86 §2 + Binding Decisions §86–§89.

static NSSet *_TTIO_M86_AllowedOverrideChannels(void)
{
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // M86 Phase E: read_names joins sequences/qualities as an
        // override-eligible channel, but its only valid codec is
        // NAME_TOKENIZED (Binding Decision §113).
        s = [NSSet setWithArray:@[@"sequences", @"qualities", @"read_names"]];
    });
    return s;
}

/** Per-channel allowed-codec map (M86 Phase D §119, Phase E §113).
 *  Sequences accepts the three byte-stream codecs from Phase A
 *  (rANS-0/1, BASE_PACK). Qualities additionally accepts
 *  QUALITY_BINNED (M85 Phase A codec id 7), wired here in Phase D.
 *  read_names accepts only NAME_TOKENIZED (id 8) — the codec
 *  tokenises UTF-8 strings (digit-runs vs string-runs) and is not
 *  meaningful on the byte-stream channels (Binding Decision §113);
 *  conversely the byte-stream codecs are not valid on read_names
 *  because the source data is NSArray<NSString *>, not NSData. */
static NSDictionary<NSString *, NSSet<NSNumber *> *> *_TTIO_M86_AllowedOverrideCodecsByChannel(void)
{
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSSet *seqAllowed = [NSSet setWithArray:@[
            @(TTIOCompressionRansOrder0),
            @(TTIOCompressionRansOrder1),
            @(TTIOCompressionBasePack),
        ]];
        NSSet *qualAllowed = [NSSet setWithArray:@[
            @(TTIOCompressionRansOrder0),
            @(TTIOCompressionRansOrder1),
            @(TTIOCompressionBasePack),
            @(TTIOCompressionQualityBinned),
        ]];
        NSSet *nameAllowed = [NSSet setWithArray:@[
            @(TTIOCompressionNameTokenized),
        ]];
        d = @{
            @"sequences":  seqAllowed,
            @"qualities":  qualAllowed,
            @"read_names": nameAllowed,
        };
    });
    return d;
}

/** Validate the per-channel codec overrides BEFORE any HDF5 mutation.
 *  Raises NSInvalidArgumentException on programmer error so the file
 *  is left untouched (Binding Decision §88, HANDOFF.md M86 §3). */
static void _TTIO_M86_ValidateOverrides(NSDictionary<NSString *, NSNumber *> *overrides)
{
    if (overrides.count == 0) return;
    NSSet *allowedChans = _TTIO_M86_AllowedOverrideChannels();
    NSDictionary<NSString *, NSSet<NSNumber *> *> *allowedByChan =
        _TTIO_M86_AllowedOverrideCodecsByChannel();
    for (NSString *chName in overrides) {
        if (![allowedChans containsObject:chName]) {
            [NSException raise:NSInvalidArgumentException
                        format:@"signalCodecOverrides: channel '%@' not "
                               @"supported (only sequences, qualities, and "
                               @"read_names can use TTIO codecs)", chName];
        }
        NSNumber *codecBox = overrides[chName];
        if (![codecBox isKindOfClass:[NSNumber class]]) {
            [NSException raise:NSInvalidArgumentException
                        format:@"signalCodecOverrides['%@']: codec value "
                               @"must be an NSNumber-boxed TTIOCompression",
                               chName];
        }
        NSSet<NSNumber *> *allowed = allowedByChan[chName];
        if (![allowed containsObject:codecBox]) {
            // Phase D Binding Decision §110: explicit message for the
            // (sequences, QUALITY_BINNED) category error — names the
            // codec, the channel, and the lossy-quantisation rationale.
            TTIOCompression codec =
                (TTIOCompression)[codecBox unsignedIntegerValue];
            if (codec == TTIOCompressionQualityBinned
                && [chName isEqualToString:@"sequences"]) {
                [NSException raise:NSInvalidArgumentException
                            format:@"signalCodecOverrides['%@']: codec "
                                   @"QUALITY_BINNED is not valid on the "
                                   @"'%@' channel — quality binning is "
                                   @"lossy and only applies to Phred "
                                   @"quality scores. Applying it to ACGT "
                                   @"sequence bytes would silently destroy "
                                   @"the sequence via Phred-bin "
                                   @"quantisation. Use the 'qualities' "
                                   @"channel for QUALITY_BINNED, or "
                                   @"RansOrder0/RansOrder1/BasePack on "
                                   @"sequences.", chName, chName];
            }
            // M86 Phase E Binding Decision §113: explicit message for
            // (sequences|qualities, NAME_TOKENIZED) — names the codec,
            // the channel, points at the read_names channel, and
            // explains the wrong-input-type rationale.
            if (codec == TTIOCompressionNameTokenized
                && ([chName isEqualToString:@"sequences"]
                    || [chName isEqualToString:@"qualities"])) {
                [NSException raise:NSInvalidArgumentException
                            format:@"signalCodecOverrides['%@']: codec "
                                   @"NAME_TOKENIZED is not valid on the "
                                   @"'%@' channel — NAME_TOKENIZED "
                                   @"tokenises UTF-8 read name strings "
                                   @"(digit runs vs string runs), not "
                                   @"binary byte streams like ACGT "
                                   @"sequence bytes or Phred quality "
                                   @"scores. Applying it to '%@' would "
                                   @"mis-tokenise the data and fall back "
                                   @"to verbatim, producing nonsensical "
                                   @"compression. Use the read_names "
                                   @"channel for NAME_TOKENIZED, or "
                                   @"RansOrder0/RansOrder1/BasePack on "
                                   @"'%@'.",
                                   chName, chName, chName, chName];
            }
            if ([chName isEqualToString:@"read_names"]) {
                [NSException raise:NSInvalidArgumentException
                            format:@"signalCodecOverrides['%@']: codec %@ "
                                   @"not supported on the '%@' channel "
                                   @"(allowed: NameTokenized)",
                                   chName, codecBox, chName];
            }
            NSString *allowedTail =
                [chName isEqualToString:@"qualities"] ? @", QualityBinned" : @"";
            [NSException raise:NSInvalidArgumentException
                        format:@"signalCodecOverrides['%@']: codec %@ "
                               @"not supported on the '%@' channel "
                               @"(allowed: RansOrder0, RansOrder1, "
                               @"BasePack%@)",
                               chName, codecBox, chName, allowedTail];
        }
    }
}

/** Encode raw bytes through the selected M86 codec. */
static NSData *_TTIO_M86_EncodeWithCodec(NSData *raw, TTIOCompression codec)
{
    switch (codec) {
        case TTIOCompressionRansOrder0:
            return TTIORansEncode(raw, 0);
        case TTIOCompressionRansOrder1:
            return TTIORansEncode(raw, 1);
        case TTIOCompressionBasePack:
            return TTIOBasePackEncode(raw);
        case TTIOCompressionQualityBinned:           // M86 Phase D
            return TTIOQualityEncode(raw);
        default:
            [NSException raise:NSInvalidArgumentException
                        format:@"_TTIO_M86_EncodeWithCodec: codec %lu not "
                               @"a TTIO byte-stream codec",
                               (unsigned long)codec];
            return nil;
    }
}

/** Set @compression as a uint8 attribute on an HDF5 dataset. Matches
 *  Python's ``write_int_attr(ds, "compression", n, dtype="<u1")``
 *  byte-for-byte (Binding Decision §86, HANDOFF.md M86 §5.1). */
static BOOL _TTIO_M86_WriteUInt8Attribute(hid_t did, const char *name,
                                          uint8_t value, NSError **error)
{
    hid_t space = H5Screate(H5S_SCALAR);
    if (space < 0) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2001
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"H5Screate(SCALAR) failed for @compression"}];
        return NO;
    }
    if (H5Aexists(did, name) > 0) {
        H5Adelete(did, name);
    }
    hid_t aid = H5Acreate2(did, name, H5T_NATIVE_UINT8, space,
                            H5P_DEFAULT, H5P_DEFAULT);
    if (aid < 0) {
        H5Sclose(space);
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2002
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"H5Acreate2(@%s) failed", name]}];
        return NO;
    }
    herr_t s = H5Awrite(aid, H5T_NATIVE_UINT8, &value);
    H5Aclose(aid); H5Sclose(space);
    if (s < 0) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2003
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"H5Awrite(@%s) failed", name]}];
        return NO;
    }
    return YES;
}

/** Read @compression as a uint8 from an HDF5 dataset. Returns 0 when
 *  the attribute is absent (matches Python's read_int_attr default).
 *  ``*outExists`` (if non-NULL) signals whether the attribute was
 *  found, so callers can distinguish "absent" from "explicitly 0". */
static uint8_t _TTIO_M86_ReadUInt8Attribute(hid_t did, const char *name,
                                            BOOL *outExists)
{
    if (H5Aexists(did, name) <= 0) {
        if (outExists) *outExists = NO;
        return 0;
    }
    if (outExists) *outExists = YES;
    hid_t aid = H5Aopen(did, name, H5P_DEFAULT);
    if (aid < 0) return 0;
    uint8_t value = 0;
    H5Aread(aid, H5T_NATIVE_UINT8, &value);
    H5Aclose(aid);
    return value;
}

/** Write a uint8 byte channel either through the existing HDF5 filter
 *  (when no override) or through a TTIO codec (when overridden). For
 *  the codec path we skip the HDF5 filter entirely (Binding Decision
 *  §87 — no double-compression). The @compression attribute is set on
 *  the dataset for the read-side dispatcher. */
static BOOL _TTIO_M86_WriteByteChannel(TTIOHDF5Group *group,
                                       NSString *name,
                                       NSData *data,
                                       TTIOCompression defaultCompression,
                                       NSNumber *codecOverride,
                                       NSError **error)
{
    if (codecOverride == nil) {
        // Plain path — same behaviour as the M82 byte-channel write.
        TTIOHDF5Dataset *ds = [group createDatasetNamed:name
                                              precision:TTIOPrecisionUInt8
                                                 length:data.length
                                              chunkSize:65536
                                            compression:defaultCompression
                                       compressionLevel:6
                                                  error:error];
        if (!ds) return NO;
        return [ds writeData:data error:error];
    }

    TTIOCompression codec = (TTIOCompression)[codecOverride unsignedIntegerValue];
    NSData *encoded = _TTIO_M86_EncodeWithCodec(data, codec);
    if (!encoded) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2010
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"M86 codec %lu encode failed for channel '%@'",
                            (unsigned long)codec, name]}];
        return NO;
    }
    // Codec-compressed datasets carry NO HDF5 filter.
    TTIOHDF5Dataset *ds = [group createDatasetNamed:name
                                          precision:TTIOPrecisionUInt8
                                             length:encoded.length
                                          chunkSize:65536
                                        compression:TTIOCompressionNone
                                   compressionLevel:0
                                              error:error];
    if (!ds) return NO;
    if (![ds writeData:encoded error:error]) return NO;
    return _TTIO_M86_WriteUInt8Attribute([ds datasetId], "compression",
                                         (uint8_t)codec, error);
}

/** Provider-path twin of _TTIO_M86_WriteByteChannel for non-HDF5
 *  backends (memory://, sqlite://). The @compression attribute uses
 *  the storage protocol's setAttributeValue:forName: which boxes as
 *  NSNumber → int64 in the HDF5 backend; non-HDF5 backends simply
 *  store the integer. The cross-language fixture matrix only covers
 *  HDF5, so the protocol path doesn't need byte-exact parity. */
static BOOL _TTIO_M86_WriteByteChannelStorage(id<TTIOStorageGroup> group,
                                              NSString *name,
                                              NSData *data,
                                              TTIOCompression defaultCompression,
                                              NSNumber *codecOverride,
                                              NSError **error)
{
    if (codecOverride == nil) {
        id<TTIOStorageDataset> ds = [group createDatasetNamed:name
                                                    precision:TTIOPrecisionUInt8
                                                       length:data.length
                                                    chunkSize:65536
                                                  compression:defaultCompression
                                             compressionLevel:6
                                                        error:error];
        if (!ds) return NO;
        return [ds writeAll:data error:error];
    }

    TTIOCompression codec = (TTIOCompression)[codecOverride unsignedIntegerValue];
    NSData *encoded = _TTIO_M86_EncodeWithCodec(data, codec);
    if (!encoded) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2011
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"M86 codec %lu encode failed for channel '%@'",
                            (unsigned long)codec, name]}];
        return NO;
    }
    id<TTIOStorageDataset> ds = [group createDatasetNamed:name
                                                precision:TTIOPrecisionUInt8
                                                   length:encoded.length
                                                chunkSize:65536
                                              compression:TTIOCompressionNone
                                         compressionLevel:0
                                                    error:error];
    if (!ds) return NO;
    if (![ds writeAll:encoded error:error]) return NO;
    return [ds setAttributeValue:@((uint8_t)codec)
                          forName:@"compression"
                            error:error];
}

@implementation TTIOSpectralDataset
{
    TTIOHDF5File     *_file;       // retained while alive for lazy reads
    NSString         *_filePath;
    TTIOAccessPolicy *_accessPolicy;
    NSString         *_encryptedAlgorithm;  // empty string when not encrypted
    id<TTIOStorageProvider> _provider;  // M39: owns _file
}

@synthesize filePath = _filePath;
@synthesize provider = _provider;
@synthesize encryptedAlgorithm = _encryptedAlgorithm;
@synthesize genomicRuns = _genomicRuns;  // M82

- (BOOL)isEncrypted
{
    return _encryptedAlgorithm.length > 0;
}

- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
                       msRuns:(NSDictionary *)msRuns
                      nmrRuns:(NSDictionary *)nmrRuns
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                  transitions:(TTIOTransitionList *)transitions
{
    self = [super init];
    if (self) {
        _title              = [title copy];
        _isaInvestigationId = [isaId copy];
        _msRuns             = [msRuns copy] ?: @{};
        _nmrRuns            = [nmrRuns copy] ?: @{};
        _genomicRuns        = @{};   // M82: populated by +readFromFilePath: when present
        _identifications    = [identifications copy] ?: @[];
        _quantifications    = [quantifications copy] ?: @[];
        _provenanceRecords  = [provenance copy] ?: @[];
        _transitions        = transitions;
        _encryptedAlgorithm = @"";
    }
    return self;
}

- (void)dealloc
{
    [self closeFile];
}

#pragma mark - Access policy JSON helpers

static NSString *encodeAccessPolicy(TTIOAccessPolicy *p)
{
    if (!p || !p.policy) return nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:p.policy options:0 error:NULL];
    if (!d) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static TTIOAccessPolicy *decodeAccessPolicy(NSString *json)
{
    if (json.length == 0) return nil;
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    return [[TTIOAccessPolicy alloc] initWithPolicy:parsed];
}

#pragma mark - JSON-plist helpers (v0.1 fallback only)

static NSArray *decodePlistArray(NSString *json, Class cls, NSError **error)
{
    if (!json) return @[];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *plists = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!plists) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:plists.count];
    for (NSDictionary *p in plists) [out addObject:[cls fromPlist:p]];
    return out;
}

#pragma mark - URL scheme routing (v0.9 M64.5)

static BOOL isNonHdf5ProviderURL(NSString *url) {
    if (url.length == 0) return NO;
    return [url hasPrefix:@"memory://"]
        || [url hasPrefix:@"sqlite://"]
        || [url hasPrefix:@"zarr://"];
}

static NSError *makeProviderWriteNotImplementedError(NSString *url) {
    NSString *msg = [NSString stringWithFormat:
        @"ObjC SpectralDataset *write* via URL '%@' not implemented "
        @"in v0.9 (read is supported via +readViaProviderURL:). "
        @"Produce non-HDF5 .tio files through Python / Java which "
        @"have the full write-side caller refactor.",
        url];
    return [NSError errorWithDomain:@"TTIOSpectralDatasetErrorDomain"
                                code:999
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - HDF5 write

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error
{
    if (isNonHdf5ProviderURL(path)) {
        if (error) *error = makeProviderWriteNotImplementedError(path);
        return NO;
    }
    // M39: route through TTIOHDF5Provider. writeToFilePath: is a
    // transactional create-write-close (handle isn't retained) so we
    // close the provider at the tail of the method.
    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeCreate error:error]) return NO;
    TTIOHDF5File *f = (TTIOHDF5File *)[p nativeHandle];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];

    // Emit v0.2 format + feature flags. The per-run compound provenance
    // flag (M17) is emitted unconditionally: every v0.3 writer produces
    // compound-form per-run provenance when any run carries records, and
    // the flag advertises that capability to future readers even when the
    // current in-memory dataset happens to have no provenance to persist.
    NSMutableArray *features = [@[
        [TTIOFeatureFlags featureBaseV1],
        [TTIOFeatureFlags featureCompoundIdentifications],
        [TTIOFeatureFlags featureCompoundQuantifications],
        [TTIOFeatureFlags featureCompoundProvenance],
        [TTIOFeatureFlags featureCompoundPerRunProvenance],
        [TTIOFeatureFlags featureCompoundHeaders],
        [TTIOFeatureFlags featureNative2DNMR],
        [TTIOFeatureFlags featureNativeMSImageCube],
    ] mutableCopy];
    BOOL anyM74 = datasetRunsHaveActivationDetail(_msRuns);
    if (anyM74) {
        [features addObject:[TTIOFeatureFlags featureMS2ActivationDetail]];
    }
    NSString *formatVersion = anyM74 ? kTTIOFormatVersionM74 : kTTIOFormatVersion;
    if (![TTIOFeatureFlags writeFormatVersion:formatVersion
                                      features:features
                                        toRoot:root
                                         error:error]) return NO;

    // Access policy, if set.
    NSString *apJson = encodeAccessPolicy(_accessPolicy);
    if (apJson) {
        if (![root setStringAttribute:@"access_policy_json"
                                value:apJson error:error]) return NO;
    }

    TTIOHDF5Group *study = [root createGroupNamed:@"study" error:error];
    if (!study) return NO;
    if (![study setStringAttribute:@"title" value:(_title ?: @"") error:error]) return NO;
    if (![study setStringAttribute:@"isa_investigation_id"
                              value:(_isaInvestigationId ?: @"")
                              error:error]) return NO;

    // MS runs
    TTIOHDF5Group *msRunsGroup = [study createGroupNamed:@"ms_runs" error:error];
    if (!msRunsGroup) return NO;
    NSArray *msNames = [[_msRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![msRunsGroup setStringAttribute:@"_run_names"
                                    value:[msNames componentsJoinedByString:@","]
                                    error:error]) return NO;
    for (NSString *runName in msNames) {
        TTIOAcquisitionRun *run = _msRuns[runName];
        if (![run writeToGroup:msRunsGroup name:runName error:error]) return NO;

        // Write compound headers alongside the parallel index datasets.
        TTIOHDF5Group *runG = [msRunsGroup openGroupNamed:runName error:NULL];
        TTIOHDF5Group *idxG = [runG openGroupNamed:@"spectrum_index" error:NULL];
        if (idxG) {
            [TTIOCompoundIO writeCompoundHeadersForIndex:run.spectrumIndex
                                                intoGroup:idxG
                                                    error:NULL];
        }
    }

    // NMR runs (legacy nmrRuns dict, kept for backward compat)
    TTIOHDF5Group *nmrRunsGroup = [study createGroupNamed:@"nmr_runs" error:error];
    if (!nmrRunsGroup) return NO;
    NSArray *nmrNames = [[_nmrRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![nmrRunsGroup setStringAttribute:@"_run_names"
                                     value:[nmrNames componentsJoinedByString:@","]
                                     error:error]) return NO;
    for (NSString *runName in nmrNames) {
        TTIOHDF5Group *nmrRun = [nmrRunsGroup createGroupNamed:runName error:error];
        if (!nmrRun) return NO;
        NSArray<TTIONMRSpectrum *> *spectra = _nmrRuns[runName];
        if (![nmrRun setIntegerAttribute:@"count" value:(int64_t)spectra.count
                                   error:error]) return NO;
        for (NSUInteger i = 0; i < spectra.count; i++) {
            NSString *name = [NSString stringWithFormat:@"spec_%06lu", (unsigned long)i];
            if (![spectra[i] writeToGroup:nmrRun name:name error:error]) return NO;
        }
    }

    // Compound identifications / quantifications / provenance
    if (_identifications.count > 0) {
        if (![TTIOCompoundIO writeIdentifications:_identifications
                                         intoGroup:study
                                      datasetNamed:@"identifications"
                                             error:error]) return NO;
    }
    if (_quantifications.count > 0) {
        if (![TTIOCompoundIO writeQuantifications:_quantifications
                                         intoGroup:study
                                      datasetNamed:@"quantifications"
                                             error:error]) return NO;
    }
    if (_provenanceRecords.count > 0) {
        if (![TTIOCompoundIO writeProvenance:_provenanceRecords
                                    intoGroup:study
                                 datasetNamed:@"provenance"
                                        error:error]) return NO;
    }

    // Subclass hook: adds its own datasets under /study/ before close.
    if (![self writeAdditionalStudyContent:study error:error]) return NO;

    if (_transitions) {
        NSData *tdata = [NSJSONSerialization dataWithJSONObject:[_transitions asPlist]
                                                        options:0
                                                          error:error];
        if (!tdata) return NO;
        NSString *tjson = [[NSString alloc] initWithData:tdata encoding:NSUTF8StringEncoding];
        if (![study setStringAttribute:@"transitions_json" value:tjson error:error]) return NO;
    }

    _filePath = [path copy];
    return [f close];
}

#pragma mark - HDF5 write (flat-buffer fast path)

/* Write an index array as a 1-D HDF5 dataset matching what
 * TTIOSpectrumIndex -writeToGroup:error: emits (same precision,
 * chunkSize=1024, compression level 6). The format is load-bearing:
 * readers — including Java and Python — depend on exactly this
 * layout. */
static BOOL writeIndexArrayDS(TTIOHDF5Group *g, NSString *name,
                               TTIOPrecision p, NSData *data,
                               NSError **error)
{
    if (!data) return YES;
    NSUInteger n = data.length / TTIOPrecisionElementSize(p);
    TTIOHDF5Dataset *ds = [g createDatasetNamed:name
                                       precision:p
                                          length:n
                                       chunkSize:4096
                                compressionLevel:6
                                           error:error];
    if (!ds) return NO;
    return [ds writeData:data error:error];
}

// M82: provider-agnostic write of one /study/genomic_runs/<name>/
// subtree via the StorageGroup protocol. Used by the memory:// /
// sqlite:// / zarr:// write path. The HDF5 fast path uses
// +writeGenomicRun:toGroup:name:error: instead which goes
// HDF5-direct for byte parity.
+ (BOOL)writeGenomicRunStorage:(TTIOWrittenGenomicRun *)run
                         toGroup:(id<TTIOStorageGroup>)parent
                            name:(NSString *)name
                           error:(NSError **)error
{
    // M86: validate signal-channel codec overrides before any
    // mutation. Same fail-fast contract as the HDF5 fast path.
    _TTIO_M86_ValidateOverrides(run.signalCodecOverrides);

    id<TTIOStorageGroup> rg = [parent createGroupNamed:name error:error];
    if (!rg) return NO;

    // Run-level attributes via the storage protocol.
    if (![rg setAttributeValue:@(run.acquisitionMode)
                         forName:@"acquisition_mode" error:error]) return NO;
    if (![rg setAttributeValue:@"genomic_sequencing"
                         forName:@"modality" error:error]) return NO;
    if (![rg setAttributeValue:@(5)
                         forName:@"spectrum_class" error:error]) return NO;
    if (![rg setAttributeValue:run.referenceUri ?: @""
                         forName:@"reference_uri" error:error]) return NO;
    if (![rg setAttributeValue:run.platform ?: @""
                         forName:@"platform" error:error]) return NO;
    if (![rg setAttributeValue:run.sampleName ?: @""
                         forName:@"sample_name" error:error]) return NO;
    if (![rg setAttributeValue:@((int64_t)run.readCount)
                         forName:@"read_count" error:error]) return NO;

    // genomic_index subgroup (already provider-agnostic).
    TTIOGenomicIndex *idx = [[TTIOGenomicIndex alloc]
        initWithOffsets:run.offsetsData
                lengths:run.lengthsData
            chromosomes:run.chromosomes
              positions:run.positionsData
       mappingQualities:run.mappingQualitiesData
                  flags:run.flagsData];
    id<TTIOStorageGroup> idxG = [rg createGroupNamed:@"genomic_index" error:error];
    if (!idxG) return NO;
    if (![idx writeToGroup:idxG error:error]) return NO;

    // signal_channels subgroup.
    id<TTIOStorageGroup> sc = [rg createGroupNamed:@"signal_channels" error:error];
    if (!sc) return NO;
    TTIOCompression codec = run.signalCompression;

    NSDictionary *intChannels = @{
        @"positions"         : @[ @(TTIOPrecisionInt64),  run.positionsData ],
        @"flags"             : @[ @(TTIOPrecisionUInt32), run.flagsData ],
        @"mapping_qualities" : @[ @(TTIOPrecisionUInt8),  run.mappingQualitiesData ],
    };
    for (NSString *chName in @[@"positions", @"flags", @"mapping_qualities"]) {
        NSArray *spec = intChannels[chName];
        TTIOPrecision prec = (TTIOPrecision)[spec[0] integerValue];
        NSData *data = spec[1];
        NSUInteger n = data.length / TTIOPrecisionElementSize(prec);
        id<TTIOStorageDataset> ds = [sc createDatasetNamed:chName
                                                   precision:prec
                                                      length:n
                                                   chunkSize:65536
                                                 compression:codec
                                            compressionLevel:6
                                                       error:error];
        if (!ds) return NO;
        if (![ds writeAll:data error:error]) return NO;
    }
    // M86: sequences/qualities through codec-aware byte-channel writer.
    if (!_TTIO_M86_WriteByteChannelStorage(sc, @"sequences",
                                           run.sequencesData, codec,
                                           run.signalCodecOverrides[@"sequences"],
                                           error)) return NO;
    if (!_TTIO_M86_WriteByteChannelStorage(sc, @"qualities",
                                           run.qualitiesData, codec,
                                           run.signalCodecOverrides[@"qualities"],
                                           error)) return NO;

    // 3 compound datasets via the storage-protocol's compound API.
    NSArray *vlValueField = @[
        [TTIOCompoundField fieldWithName:@"value" kind:TTIOCompoundFieldKindVLString]
    ];

    NSMutableArray *cigarRows = [NSMutableArray arrayWithCapacity:run.cigars.count];
    for (NSString *c in run.cigars) [cigarRows addObject:@{@"value": c}];
    id<TTIOStorageDataset> cigarDs = [sc createCompoundDatasetNamed:@"cigars"
                                                                fields:vlValueField
                                                                 count:run.cigars.count
                                                                 error:error];
    if (!cigarDs || ![cigarDs writeAll:cigarRows error:error]) return NO;

    // M86 Phase E: schema lift for read_names on the provider/storage
    // path (memory:// / sqlite:// / zarr://). Same dispatch as the
    // HDF5 fast path above. The protocol's setAttributeValue:forName:
    // boxes the @compression attribute as NSNumber → int64 in the
    // HDF5 backend; non-HDF5 backends store the integer directly.
    NSNumber *readNamesOverride = run.signalCodecOverrides[@"read_names"];
    if (readNamesOverride != nil) {
        NSData *encoded = TTIONameTokenizerEncode(run.readNames);
        if (!encoded) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2031
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"M86 Phase E: NAME_TOKENIZED encode of "
                           @"read_names returned nil"}];
            return NO;
        }
        id<TTIOStorageDataset> nameDs = [sc createDatasetNamed:@"read_names"
                                                     precision:TTIOPrecisionUInt8
                                                        length:encoded.length
                                                     chunkSize:65536
                                                   compression:TTIOCompressionNone
                                              compressionLevel:0
                                                         error:error];
        if (!nameDs) return NO;
        if (![nameDs writeAll:encoded error:error]) return NO;
        if (![nameDs setAttributeValue:@((uint8_t)TTIOCompressionNameTokenized)
                               forName:@"compression"
                                 error:error]) return NO;
    } else {
        NSMutableArray *nameRows = [NSMutableArray arrayWithCapacity:run.readNames.count];
        for (NSString *rn in run.readNames) [nameRows addObject:@{@"value": rn}];
        id<TTIOStorageDataset> nameDs = [sc createCompoundDatasetNamed:@"read_names"
                                                                   fields:vlValueField
                                                                    count:run.readNames.count
                                                                    error:error];
        if (!nameDs || ![nameDs writeAll:nameRows error:error]) return NO;
    }

    NSArray *mateFields = @[
        [TTIOCompoundField fieldWithName:@"chrom" kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"pos"   kind:TTIOCompoundFieldKindInt64],
        [TTIOCompoundField fieldWithName:@"tlen"  kind:TTIOCompoundFieldKindInt64],
    ];
    NSMutableArray *mateRows = [NSMutableArray arrayWithCapacity:run.readCount];
    const int64_t *matePos = (const int64_t *)run.matePositionsData.bytes;
    const int32_t *tlens   = (const int32_t *)run.templateLengthsData.bytes;
    for (NSUInteger i = 0; i < run.readCount; i++) {
        [mateRows addObject:@{
            @"chrom": run.mateChromosomes[i],
            @"pos":   @(matePos[i]),
            @"tlen":  @((int64_t)tlens[i]),
        }];
    }
    id<TTIOStorageDataset> mateDs = [sc createCompoundDatasetNamed:@"mate_info"
                                                               fields:mateFields
                                                                count:run.readCount
                                                                error:error];
    if (!mateDs || ![mateDs writeAll:mateRows error:error]) return NO;

    return YES;
}

// M82: provider-agnostic minimal write — supports memory:// /
// sqlite:// / zarr:// URLs. Currently genomic-only (no MS runs);
// MS run support via non-HDF5 providers requires the larger writer
// refactor to use the StorageGroup protocol throughout (M64.5 read
// side already does this; write side is HDF5-fast-path-only today).
+ (BOOL)writeMinimalGenomicViaProviderURL:(NSString *)url
                                       title:(NSString *)title
                          isaInvestigationId:(NSString *)isaId
                                  msRuns:(NSDictionary *)msRuns
                                 genomicRuns:(NSDictionary *)genomicRuns
                                       error:(NSError **)error
{
    if (msRuns.count > 0) {
        if (error) *error = [NSError
            errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:1000
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                            @"writeMinimal via provider URL '%@' does not yet "
                            @"support MS runs (genomic_runs only). Use the "
                            @"HDF5 fast path or wait for the writer refactor.",
                            url]}];
        return NO;
    }

    id<TTIOStorageProvider> prov =
        [[TTIOProviderRegistry sharedRegistry] openURL:url
                                                  mode:TTIOStorageOpenModeCreate
                                              provider:nil
                                                 error:error];
    if (!prov) return NO;

    @try {
        id<TTIOStorageGroup> root = [prov rootGroupWithError:error];
        if (!root) return NO;

        // Feature flags (mirror what TTIOFeatureFlags writeFormatVersion
        // does for HDF5: ttio_format_version + ttio_features attrs on
        // the root, JSON-encoded array for features). Memory provider
        // accepts NSString attribute values directly.
        NSMutableArray *features = [@[
            [TTIOFeatureFlags featureBaseV1],
            [TTIOFeatureFlags featureCompoundIdentifications],
            [TTIOFeatureFlags featureCompoundQuantifications],
            [TTIOFeatureFlags featureCompoundProvenance],
            [TTIOFeatureFlags featureCompoundPerRunProvenance],
            [TTIOFeatureFlags featureCompoundHeaders],
            [TTIOFeatureFlags featureNative2DNMR],
            [TTIOFeatureFlags featureNativeMSImageCube],
        ] mutableCopy];
        BOOL hasGenomic = genomicRuns.count > 0;
        NSString *formatVersion = kTTIOFormatVersion;
        if (hasGenomic) {
            if (![features containsObject:[TTIOFeatureFlags featureOptGenomic]]) {
                [features addObject:[TTIOFeatureFlags featureOptGenomic]];
            }
            formatVersion = kTTIOFormatVersionM82;
        }
        if (![root setAttributeValue:formatVersion
                              forName:@"ttio_format_version" error:error]) return NO;
        NSData *featJSON = [NSJSONSerialization dataWithJSONObject:features options:0 error:NULL];
        NSString *featStr = [[NSString alloc] initWithData:featJSON encoding:NSUTF8StringEncoding];
        if (![root setAttributeValue:featStr
                              forName:@"ttio_features" error:error]) return NO;

        id<TTIOStorageGroup> study = [root createGroupNamed:@"study" error:error];
        if (!study) return NO;
        if (![study setAttributeValue:title ?: @""
                               forName:@"title" error:error]) return NO;
        if (![study setAttributeValue:isaId ?: @""
                               forName:@"isa_investigation_id" error:error]) return NO;

        // Empty ms_runs/nmr_runs for parity (readers expect them).
        id<TTIOStorageGroup> msG = [study createGroupNamed:@"ms_runs" error:error];
        if (!msG) return NO;
        if (![msG setAttributeValue:@""
                            forName:@"_run_names" error:error]) return NO;
        id<TTIOStorageGroup> nmrG = [study createGroupNamed:@"nmr_runs" error:error];
        if (!nmrG) return NO;
        if (![nmrG setAttributeValue:@""
                             forName:@"_run_names" error:error]) return NO;

        if (hasGenomic) {
            id<TTIOStorageGroup> gG = [study createGroupNamed:@"genomic_runs" error:error];
            if (!gG) return NO;
            NSArray *gNames = [[genomicRuns allKeys]
                sortedArrayUsingSelector:@selector(compare:)];
            if (![gG setAttributeValue:[gNames componentsJoinedByString:@","]
                               forName:@"_run_names" error:error]) return NO;
            for (NSString *gName in gNames) {
                if (![self writeGenomicRunStorage:genomicRuns[gName]
                                           toGroup:gG
                                              name:gName
                                             error:error]) return NO;
            }
        }
    }
    @finally {
        [prov close];
    }
    return YES;
}

// M82: write one /study/genomic_runs/<name>/ subtree. Mirrors the
// per-MS-run writer but for the genomic data model. Uses TTIOGenomicIndex
// for the index subgroup + TTIOCompoundIO for the 3 VL compound
// datasets (cigars, read_names, mate_info) under signal_channels/.
+ (BOOL)writeGenomicRun:(TTIOWrittenGenomicRun *)run
                 toGroup:(TTIOHDF5Group *)parent
                    name:(NSString *)name
                   error:(NSError **)error
{
    // M86: validate signal-channel codec overrides before any HDF5
    // mutation. Raises NSInvalidArgumentException on programmer
    // error; the file is left untouched.
    _TTIO_M86_ValidateOverrides(run.signalCodecOverrides);

    TTIOHDF5Group *rg = [parent createGroupNamed:name error:error];
    if (!rg) return NO;

    // Run-level attributes.
    if (![rg setIntegerAttribute:@"acquisition_mode"
                            value:run.acquisitionMode error:error]) return NO;
    if (![rg setStringAttribute:@"modality"
                           value:@"genomic_sequencing" error:error]) return NO;
    if (![rg setIntegerAttribute:@"spectrum_class" value:5 error:error]) return NO;
    if (![rg setStringAttribute:@"reference_uri"
                           value:run.referenceUri error:error]) return NO;
    if (![rg setStringAttribute:@"platform"
                           value:run.platform error:error]) return NO;
    if (![rg setStringAttribute:@"sample_name"
                           value:run.sampleName error:error]) return NO;
    if (![rg setIntegerAttribute:@"read_count"
                            value:(int64_t)run.readCount error:error]) return NO;

    // genomic_index subgroup (delegates to TTIOGenomicIndex).
    TTIOGenomicIndex *idx = [[TTIOGenomicIndex alloc]
        initWithOffsets:run.offsetsData
                lengths:run.lengthsData
            chromosomes:run.chromosomes
              positions:run.positionsData
       mappingQualities:run.mappingQualitiesData
                  flags:run.flagsData];
    TTIOHDF5Group *idxG = [rg createGroupNamed:@"genomic_index" error:error];
    if (!idxG) return NO;
    // GenomicIndex.writeToGroup takes id<TTIOStorageGroup>; wrap via the
    // HDF5 provider's adapter. Use the same trick: TTIOHDF5GroupAdapter
    // is created by openProviderURL but we can construct it via
    // TTIOHDF5Provider's escape hatch. Simpler: pass the raw HDF5Group
    // via `id`-cast since GenomicIndex.writeToGroup checks
    // respondsToSelector:@selector(unwrap) and falls through to direct
    // TTIOCompoundIO + the storage protocol calls also work on
    // TTIOHDF5Group via category methods. Easiest: just reuse the
    // helper directly — TTIOGenomicIndex's internal writes use
    // createDatasetNamed:precision:length:chunkSize:compression:
    // compressionLevel:error: which TTIOHDF5Group implements with a
    // slightly different signature (no `compression` arg). Wrap via
    // adapter to bridge.
    id<TTIOStorageGroup> idxGAdapter =
        (id<TTIOStorageGroup>)[[NSClassFromString(@"TTIOHDF5GroupAdapter") alloc]
            performSelector:@selector(initWithGroup:) withObject:idxG];
    if (!idxGAdapter) return NO;
    if (![idx writeToGroup:idxGAdapter error:error]) return NO;

    // signal_channels subgroup.
    TTIOHDF5Group *sc = [rg createGroupNamed:@"signal_channels" error:error];
    if (!sc) return NO;
    id<TTIOStorageGroup> scAdapter =
        (id<TTIOStorageGroup>)[[NSClassFromString(@"TTIOHDF5GroupAdapter") alloc]
            performSelector:@selector(initWithGroup:) withObject:sc];
    if (!scAdapter) return NO;

    // 5 typed channels (use TTIOGenomicIndex's static writeTypedChannel
    // helper isn't accessible — inline the same pattern via the
    // adapter). These match the precision choices in the spec:
    // positions=int64, sequences=uint8, qualities=uint8, flags=uint32,
    // mapping_qualities=uint8.
    //
    // M86: sequences and qualities go through the byte-channel codec
    // dispatcher so an override (rANS / BASE_PACK) is honoured.
    TTIOCompression codec = run.signalCompression;
    NSDictionary *intChannels = @{
        @"positions"         : @[ @(TTIOPrecisionInt64),  run.positionsData ],
        @"flags"             : @[ @(TTIOPrecisionUInt32), run.flagsData ],
        @"mapping_qualities" : @[ @(TTIOPrecisionUInt8),  run.mappingQualitiesData ],
    };
    for (NSString *chName in @[@"positions", @"flags", @"mapping_qualities"]) {
        NSArray *spec = intChannels[chName];
        TTIOPrecision prec = (TTIOPrecision)[spec[0] integerValue];
        NSData *data = spec[1];
        NSUInteger n = data.length / TTIOPrecisionElementSize(prec);
        id<TTIOStorageDataset> ds = [scAdapter createDatasetNamed:chName
                                                          precision:prec
                                                             length:n
                                                          chunkSize:65536
                                                        compression:codec
                                                   compressionLevel:6
                                                              error:error];
        if (!ds) return NO;
        if (![ds writeAll:data error:error]) return NO;
    }
    // sequences (uint8) — codec-aware
    if (!_TTIO_M86_WriteByteChannel(sc, @"sequences", run.sequencesData,
                                    codec,
                                    run.signalCodecOverrides[@"sequences"],
                                    error)) return NO;
    // qualities (uint8) — codec-aware
    if (!_TTIO_M86_WriteByteChannel(sc, @"qualities", run.qualitiesData,
                                    codec,
                                    run.signalCodecOverrides[@"qualities"],
                                    error)) return NO;

    // 3 compound datasets via TTIOCompoundIO (HDF5-direct).
    NSArray *vlValueField = @[
        [TTIOCompoundField fieldWithName:@"value" kind:TTIOCompoundFieldKindVLString]
    ];

    NSMutableArray *cigarRows = [NSMutableArray arrayWithCapacity:run.cigars.count];
    for (NSString *c in run.cigars) [cigarRows addObject:@{@"value": c}];
    if (![TTIOCompoundIO writeGeneric:cigarRows
                              intoGroup:sc datasetNamed:@"cigars"
                                  fields:vlValueField error:error]) return NO;

    // M86 Phase E: schema lift for read_names. When the
    // NAME_TOKENIZED override is set, replace the M82 compound
    // dataset with a flat 1-D uint8 dataset of the same name
    // carrying the codec output, plus an @compression == 8
    // attribute (Binding Decisions §111, §113). The two layouts
    // are mutually exclusive within a single run; readers
    // dispatch on dataset shape (compound vs uint8). No HDF5
    // filter is applied — codec output is high-entropy
    // (Binding Decision §87).
    NSNumber *readNamesOverride = run.signalCodecOverrides[@"read_names"];
    if (readNamesOverride != nil) {
        NSData *encoded = TTIONameTokenizerEncode(run.readNames);
        if (!encoded) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:2030
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"M86 Phase E: NAME_TOKENIZED encode of "
                           @"read_names returned nil"}];
            return NO;
        }
        TTIOHDF5Dataset *nameDs = [sc createDatasetNamed:@"read_names"
                                               precision:TTIOPrecisionUInt8
                                                  length:encoded.length
                                               chunkSize:65536
                                             compression:TTIOCompressionNone
                                        compressionLevel:0
                                                   error:error];
        if (!nameDs) return NO;
        if (![nameDs writeData:encoded error:error]) return NO;
        if (!_TTIO_M86_WriteUInt8Attribute([nameDs datasetId], "compression",
                                           (uint8_t)TTIOCompressionNameTokenized,
                                           error)) return NO;
    } else {
        NSMutableArray *nameRows = [NSMutableArray arrayWithCapacity:run.readNames.count];
        for (NSString *rn in run.readNames) [nameRows addObject:@{@"value": rn}];
        if (![TTIOCompoundIO writeGeneric:nameRows
                                  intoGroup:sc datasetNamed:@"read_names"
                                      fields:vlValueField error:error]) return NO;
    }

    // mate_info compound: chrom (VL str) + pos (int64) + tlen (int32 → boxed as int64 via VLString-or-int64 schema).
    NSArray *mateFields = @[
        [TTIOCompoundField fieldWithName:@"chrom" kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"pos"   kind:TTIOCompoundFieldKindInt64],
        [TTIOCompoundField fieldWithName:@"tlen"  kind:TTIOCompoundFieldKindInt64],
    ];
    NSMutableArray *mateRows = [NSMutableArray arrayWithCapacity:run.readCount];
    const int64_t *matePos = (const int64_t *)run.matePositionsData.bytes;
    const int32_t *tlens   = (const int32_t *)run.templateLengthsData.bytes;
    for (NSUInteger i = 0; i < run.readCount; i++) {
        [mateRows addObject:@{
            @"chrom": run.mateChromosomes[i],
            @"pos":   @(matePos[i]),
            @"tlen":  @((int64_t)tlens[i]),
        }];
    }
    if (![TTIOCompoundIO writeGeneric:mateRows
                              intoGroup:sc datasetNamed:@"mate_info"
                                  fields:mateFields error:error]) return NO;

    return YES;
}

+ (BOOL)writeMinimalToPath:(NSString *)path
                      title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                    msRuns:(NSDictionary<NSString *, TTIOWrittenRun *> *)runs
            identifications:(NSArray *)identifications
            quantifications:(NSArray *)quantifications
          provenanceRecords:(NSArray *)provenance
                      error:(NSError **)error
{
    return [self writeMinimalToPath:path
                              title:title
                 isaInvestigationId:isaId
                             msRuns:runs
                         genomicRuns:nil
                     identifications:identifications
                     quantifications:quantifications
                  provenanceRecords:provenance
                              error:error];
}

+ (BOOL)writeMinimalToPath:(NSString *)path
                      title:(NSString *)title
        isaInvestigationId:(NSString *)isaId
                    msRuns:(NSDictionary<NSString *, TTIOWrittenRun *> *)runs
                genomicRuns:(NSDictionary<NSString *, TTIOWrittenGenomicRun *> *)genomicRuns
            identifications:(NSArray *)identifications
            quantifications:(NSArray *)quantifications
          provenanceRecords:(NSArray *)provenance
                      error:(NSError **)error
{
    // M82.2: provider-agnostic write path for non-HDF5 URLs.
    // Currently genomic-only (no MS runs); MS via memory needs the
    // full writer refactor (HDF5-direct → StorageGroup protocol).
    // The HDF5 fast path below preserves byte parity with pre-M82.2
    // file output for ms_runs.
    if (isNonHdf5ProviderURL(path)) {
        if (identifications.count > 0 || quantifications.count > 0 ||
            provenance.count > 0) {
            if (error) *error = [NSError
                errorWithDomain:@"TTIOSpectralDatasetErrorDomain" code:1001
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"writeMinimal via provider URL does not yet "
                           @"support identifications/quantifications/provenance "
                           @"(genomic_runs only)."}];
            return NO;
        }
        return [self writeMinimalGenomicViaProviderURL:path
                                                  title:title
                                     isaInvestigationId:isaId
                                                 msRuns:runs
                                            genomicRuns:genomicRuns
                                                  error:error];
    }

    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeCreate error:error]) return NO;
    TTIOHDF5File *f = (TTIOHDF5File *)[p nativeHandle];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];

    // Same feature-flag set as -writeToFilePath: so readers can't tell
    // the two paths apart.
    NSMutableArray *features = [@[
        [TTIOFeatureFlags featureBaseV1],
        [TTIOFeatureFlags featureCompoundIdentifications],
        [TTIOFeatureFlags featureCompoundQuantifications],
        [TTIOFeatureFlags featureCompoundProvenance],
        [TTIOFeatureFlags featureCompoundPerRunProvenance],
        [TTIOFeatureFlags featureCompoundHeaders],
        [TTIOFeatureFlags featureNative2DNMR],
        [TTIOFeatureFlags featureNativeMSImageCube],
    ] mutableCopy];

    // M82: opt_genomic is the canonical advertisement of genomic
    // content. Add it whenever genomicRuns is non-empty, idempotent
    // if a future caller pre-populates it. Bump format_version to 1.4
    // (which implies 1.3 + 1.1 — readers gate features by flag, not
    // by version equality).
    BOOL hasGenomic = genomicRuns.count > 0;
    NSString *formatVersion = kTTIOFormatVersion;
    if (hasGenomic) {
        if (![features containsObject:[TTIOFeatureFlags featureOptGenomic]]) {
            [features addObject:[TTIOFeatureFlags featureOptGenomic]];
        }
        formatVersion = kTTIOFormatVersionM82;
    }

    if (![TTIOFeatureFlags writeFormatVersion:formatVersion
                                      features:features
                                        toRoot:root
                                         error:error]) return NO;

    TTIOHDF5Group *study = [root createGroupNamed:@"study" error:error];
    if (!study) return NO;
    if (![study setStringAttribute:@"title" value:(title ?: @"") error:error]) return NO;
    if (![study setStringAttribute:@"isa_investigation_id"
                              value:(isaId ?: @"") error:error]) return NO;

    TTIOHDF5Group *msRunsGroup = [study createGroupNamed:@"ms_runs" error:error];
    if (!msRunsGroup) return NO;
    NSArray *msNames = [[runs allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![msRunsGroup setStringAttribute:@"_run_names"
                                    value:[msNames componentsJoinedByString:@","]
                                    error:error]) return NO;

    for (NSString *runName in msNames) {
        TTIOWrittenRun *run = runs[runName];

        TTIOHDF5Group *runGroup = [msRunsGroup createGroupNamed:runName error:error];
        if (!runGroup) return NO;

        NSUInteger spectrumCount = run.offsets.length / sizeof(int64_t);
        if (![runGroup setIntegerAttribute:@"acquisition_mode"
                                     value:run.acquisitionMode error:error]) return NO;
        if (![runGroup setIntegerAttribute:@"spectrum_count"
                                     value:(int64_t)spectrumCount error:error]) return NO;
        if (![runGroup setStringAttribute:@"spectrum_class"
                                    value:run.spectrumClassName error:error]) return NO;
        if (run.nucleusType.length > 0) {
            if (![runGroup setStringAttribute:@"nucleus_type"
                                        value:run.nucleusType error:error]) return NO;
        }

        // instrument_config subgroup — writeMinimal callers don't ship
        // instrument metadata; emit the same empty-string skeleton that
        // Python's write_minimal does so readers don't distinguish
        // writer.
        TTIOHDF5Group *cfg =
            [runGroup createGroupNamed:@"instrument_config" error:error];
        if (!cfg) return NO;
        for (NSString *fieldName in @[@"manufacturer", @"model", @"serial_number",
                                       @"source_type", @"analyzer_type",
                                       @"detector_type"]) {
            if (![cfg setStringAttribute:fieldName value:@"" error:error]) return NO;
        }

        // spectrum_index — same layout as TTIOSpectrumIndex -writeToGroup:.
        TTIOHDF5Group *idxG = [runGroup createGroupNamed:@"spectrum_index" error:error];
        if (!idxG) return NO;
        if (![idxG setIntegerAttribute:@"count"
                                 value:(int64_t)spectrumCount error:error]) return NO;
        if (!writeIndexArrayDS(idxG, @"offsets",
                                TTIOPrecisionInt64, run.offsets, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"lengths",
                                TTIOPrecisionUInt32, run.lengths, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"retention_times",
                                TTIOPrecisionFloat64, run.retentionTimes, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"ms_levels",
                                TTIOPrecisionInt32, run.msLevels, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"polarities",
                                TTIOPrecisionInt32, run.polarities, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"precursor_mzs",
                                TTIOPrecisionFloat64, run.precursorMzs, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"precursor_charges",
                                TTIOPrecisionInt32, run.precursorCharges, error)) return NO;
        if (!writeIndexArrayDS(idxG, @"base_peak_intensities",
                                TTIOPrecisionFloat64, run.basePeakIntensities, error)) return NO;

        // v1.1 writeMinimal intentionally SKIPS the "opt_compound_headers"
        // duplicate spectrum_index/headers compound dataset. That feature
        // (added by TTIOCompoundIO writeCompoundHeadersForIndex:) writes
        // the parallel index arrays again as a 56-byte-per-row compound,
        // uncompressed + unchunked — ~5.6 MB on 100 K spectra. The parallel
        // arrays are authoritative; the compound copy exists only for
        // h5dump readability. Python's write_minimal doesn't emit it, and
        // its absence is the single biggest file-size difference between
        // the ObjC and Python minimal paths. Callers that need h5dump-
        // friendly compound headers should use the object-mode writer.

        // signal_channels — pre-flattened NSData buffers, written
        // straight through with no per-spectrum concat.
        TTIOHDF5Group *channels =
            [runGroup createGroupNamed:@"signal_channels" error:error];
        if (!channels) return NO;
        NSArray *channelNames = run.channelData.allKeys;
        NSString *namesJoined = [channelNames componentsJoinedByString:@","];
        if (![channels setStringAttribute:@"channel_names"
                                    value:namesJoined error:error]) return NO;

        for (NSString *chName in channelNames) {
            NSData *buf = run.channelData[chName];
            NSUInteger total = buf.length / sizeof(double);
            NSString *dsName = [chName stringByAppendingString:@"_values"];
            TTIOHDF5Dataset *ds =
                [channels createDatasetNamed:dsName
                                   precision:TTIOPrecisionFloat64
                                      length:total
                                   chunkSize:65536
                                 compression:TTIOCompressionZlib
                            compressionLevel:6
                                       error:error];
            if (!ds) return NO;
            if (![ds writeData:buf error:error]) return NO;
        }
    }

    // Empty nmr_runs group for byte-parity with -writeToFilePath:.
    TTIOHDF5Group *nmrRunsGroup = [study createGroupNamed:@"nmr_runs" error:error];
    if (!nmrRunsGroup) return NO;
    if (![nmrRunsGroup setStringAttribute:@"_run_names" value:@"" error:error]) return NO;

    // M82: genomic_runs subtree (only when non-empty — pre-M82 byte
    // parity for ms-only files).
    if (hasGenomic) {
        TTIOHDF5Group *gRunsGroup = [study createGroupNamed:@"genomic_runs" error:error];
        if (!gRunsGroup) return NO;
        NSArray *gNames = [[genomicRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];
        if (![gRunsGroup setStringAttribute:@"_run_names"
                                      value:[gNames componentsJoinedByString:@","]
                                      error:error]) return NO;
        for (NSString *gName in gNames) {
            TTIOWrittenGenomicRun *gRun = genomicRuns[gName];
            if (![self writeGenomicRun:gRun
                                toGroup:gRunsGroup
                                   name:gName
                                  error:error]) return NO;
        }
    }

    if (identifications.count > 0) {
        if (![TTIOCompoundIO writeIdentifications:identifications
                                         intoGroup:study
                                      datasetNamed:@"identifications"
                                             error:error]) return NO;
    }
    if (quantifications.count > 0) {
        if (![TTIOCompoundIO writeQuantifications:quantifications
                                         intoGroup:study
                                      datasetNamed:@"quantifications"
                                             error:error]) return NO;
    }
    if (provenance.count > 0) {
        if (![TTIOCompoundIO writeProvenance:provenance
                                    intoGroup:study
                                 datasetNamed:@"provenance"
                                        error:error]) return NO;
    }

    return [f close];
}

#pragma mark - HDF5 read

+ (instancetype)readViaProviderURL:(NSString *)url error:(NSError **)error
{
    // v0.9 M64.5-objc-java: read a non-HDF5 .tio by routing through
    // the provider registry. Metadata (idents/quants/prov) comes from
    // the JSON mirror attributes; runs are reconstructed via
    // +[TTIOAcquisitionRun readFromStorageGroup:].
    id<TTIOStorageProvider> prov = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeRead provider:nil error:error];
    if (!prov) return nil;
    id<TTIOStorageGroup> root = [prov rootGroupWithError:error];
    if (!root) return nil;

    NSString *title = @"", *isaId = @"";
    NSMutableDictionary *msRuns = [NSMutableDictionary dictionary];
    NSMutableDictionary *genomicRunsMap = [NSMutableDictionary dictionary];  // M82.2
    NSArray *idents = @[], *quants = @[], *provRecs = @[];

    if ([root hasChildNamed:@"study"]) {
        id<TTIOStorageGroup> study = [root openGroupNamed:@"study" error:error];
        if (!study) return nil;

        id titleObj = [study attributeValueForName:@"title" error:NULL];
        if ([titleObj isKindOfClass:[NSString class]]) title = titleObj;
        id isaObj = [study attributeValueForName:@"isa_investigation_id" error:NULL];
        if ([isaObj isKindOfClass:[NSString class]]) isaId = isaObj;

        if ([study hasChildNamed:@"ms_runs"]) {
            id<TTIOStorageGroup> ms = [study openGroupNamed:@"ms_runs" error:NULL];
            id namesObj = [ms attributeValueForName:@"_run_names" error:NULL];
            if ([namesObj isKindOfClass:[NSString class]]) {
                for (NSString *rn in [(NSString *)namesObj componentsSeparatedByString:@","]) {
                    if (rn.length == 0) continue;
                    TTIOAcquisitionRun *run = [TTIOAcquisitionRun readFromStorageGroup:ms
                                                                                   name:rn
                                                                                  error:NULL];
                    if (run) msRuns[rn] = run;
                }
            }
        }

        // M82.2: provider-agnostic genomic_runs read.
        if ([study hasChildNamed:@"genomic_runs"]) {
            id<TTIOStorageGroup> gG = [study openGroupNamed:@"genomic_runs" error:NULL];
            id namesObj = [gG attributeValueForName:@"_run_names" error:NULL];
            if ([namesObj isKindOfClass:[NSString class]]) {
                for (NSString *rn in [(NSString *)namesObj componentsSeparatedByString:@","]) {
                    NSString *trimmed = [rn stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length == 0 || ![gG hasChildNamed:trimmed]) continue;
                    id<TTIOStorageGroup> runG = [gG openGroupNamed:trimmed error:NULL];
                    TTIOGenomicRun *gr = [TTIOGenomicRun openFromGroup:runG
                                                                    name:trimmed
                                                                   error:NULL];
                    if (gr) genomicRunsMap[trimmed] = gr;
                }
            }
        }

        id iObj = [study attributeValueForName:@"identifications_json" error:NULL];
        if ([iObj isKindOfClass:[NSString class]]) {
            NSArray *plists = [NSJSONSerialization
                JSONObjectWithData:[(NSString *)iObj dataUsingEncoding:NSUTF8StringEncoding]
                           options:0 error:NULL];
            NSMutableArray *arr = [NSMutableArray array];
            for (NSDictionary *d in plists) {
                id rec = [TTIOIdentification fromPlist:d];
                if (rec) [arr addObject:rec];
            }
            idents = arr;
        }
        id qObj = [study attributeValueForName:@"quantifications_json" error:NULL];
        if ([qObj isKindOfClass:[NSString class]]) {
            NSArray *plists = [NSJSONSerialization
                JSONObjectWithData:[(NSString *)qObj dataUsingEncoding:NSUTF8StringEncoding]
                           options:0 error:NULL];
            NSMutableArray *arr = [NSMutableArray array];
            for (NSDictionary *d in plists) {
                id rec = [TTIOQuantification fromPlist:d];
                if (rec) [arr addObject:rec];
            }
            quants = arr;
        }
        id pObj = [study attributeValueForName:@"provenance_json" error:NULL];
        if ([pObj isKindOfClass:[NSString class]]) {
            NSArray *plists = [NSJSONSerialization
                JSONObjectWithData:[(NSString *)pObj dataUsingEncoding:NSUTF8StringEncoding]
                           options:0 error:NULL];
            NSMutableArray *arr = [NSMutableArray array];
            for (NSDictionary *d in plists) {
                id rec = [TTIOProvenanceRecord fromPlist:d];
                if (rec) [arr addObject:rec];
            }
            provRecs = arr;
        }
    }

    TTIOSpectralDataset *ds = [[self alloc] initWithTitle:title
                                        isaInvestigationId:isaId
                                                    msRuns:msRuns
                                                   nmrRuns:@{}
                                           identifications:idents
                                           quantifications:quants
                                         provenanceRecords:provRecs
                                               transitions:nil];
    ds->_filePath    = [url copy];
    ds->_genomicRuns = [genomicRunsMap copy];  // M82.2
    // Surface the root `encrypted` attr for provider-backed reads too.
    id encObj = [root attributeValueForName:@"encrypted" error:NULL];
    if ([encObj isKindOfClass:[NSString class]]) {
        ds->_encryptedAlgorithm = [(NSString *)encObj copy];
    } else {
        ds->_encryptedAlgorithm = @"";
    }
    // _file / _provider stay nil — the provider instance was transient;
    // close() is a no-op for provider-backed datasets in v0.9.
    return ds;
}

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    if (isNonHdf5ProviderURL(path)) {
        return [self readViaProviderURL:path error:error];
    }
    // M39: route through TTIOHDF5Provider; the native handle is the
    // TTIOHDF5File previously obtained directly.
    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeRead error:error]) return nil;
    TTIOHDF5File *f = (TTIOHDF5File *)[p nativeHandle];
    if (!f) return nil;
    TTIOHDF5Group *root = [f rootGroup];

    BOOL isV1 = [TTIOFeatureFlags isLegacyV1File:root];

    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) return nil;

    NSString *title  = [study stringAttributeNamed:@"title" error:error];
    NSString *isaId  = [study stringAttributeNamed:@"isa_investigation_id" error:error];

    // MS runs (v0.2: any TTIOSpectrum subclass)
    NSMutableDictionary *msRuns = [NSMutableDictionary dictionary];
    if ([study hasChildNamed:@"ms_runs"]) {
        TTIOHDF5Group *msg = [study openGroupNamed:@"ms_runs" error:error];
        NSString *namesStr = [msg stringAttributeNamed:@"_run_names" error:error];
        for (NSString *rname in [namesStr componentsSeparatedByString:@","]) {
            if (rname.length == 0) continue;
            TTIOAcquisitionRun *run = [TTIOAcquisitionRun readFromGroup:msg name:rname error:error];
            if (!run) return nil;
            [run setPersistenceFilePath:path runName:rname];
            msRuns[rname] = run;
        }
    }

    // M82: genomic_runs subtree (absent on pre-M82 files → empty dict).
    NSMutableDictionary *genomicRuns = [NSMutableDictionary dictionary];
    if ([study hasChildNamed:@"genomic_runs"]) {
        TTIOHDF5Group *gg = [study openGroupNamed:@"genomic_runs" error:error];
        NSString *gNames = [gg stringAttributeNamed:@"_run_names" error:NULL] ?: @"";
        for (NSString *rname in [gNames componentsSeparatedByString:@","]) {
            NSString *trimmed =
                [rname stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length == 0 || ![gg hasChildNamed:trimmed]) continue;
            TTIOHDF5Group *runG = [gg openGroupNamed:trimmed error:error];
            if (!runG) return nil;
            id<TTIOStorageGroup> runAdapter =
                (id<TTIOStorageGroup>)[[NSClassFromString(@"TTIOHDF5GroupAdapter") alloc]
                    performSelector:@selector(initWithGroup:) withObject:runG];
            TTIOGenomicRun *gr =
                [TTIOGenomicRun openFromGroup:runAdapter name:trimmed error:error];
            if (!gr) return nil;
            genomicRuns[trimmed] = gr;
        }
    }

    // NMR runs (legacy)
    NSMutableDictionary *nmrRuns = [NSMutableDictionary dictionary];
    if ([study hasChildNamed:@"nmr_runs"]) {
        TTIOHDF5Group *ng = [study openGroupNamed:@"nmr_runs" error:error];
        NSString *namesStr = [ng stringAttributeNamed:@"_run_names" error:error];
        for (NSString *rname in [namesStr componentsSeparatedByString:@","]) {
            if (rname.length == 0) continue;
            TTIOHDF5Group *runG = [ng openGroupNamed:rname error:error];
            BOOL exists = NO;
            NSUInteger n = (NSUInteger)[runG integerAttributeNamed:@"count"
                                                            exists:&exists error:error];
            NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:n];
            for (NSUInteger i = 0; i < n; i++) {
                NSString *sname = [NSString stringWithFormat:@"spec_%06lu", (unsigned long)i];
                TTIONMRSpectrum *s = [TTIONMRSpectrum readFromGroup:runG name:sname error:error];
                if (!s) return nil;
                [spectra addObject:s];
            }
            nmrRuns[rname] = spectra;
        }
    }

    // Identifications, quantifications, provenance: compound if present
    // (v0.2 feature flags), JSON fallback otherwise (v0.1).
    NSArray *idents = @[];
    NSArray *quants = @[];
    NSArray *prov   = @[];

    if (!isV1 &&
        [TTIOFeatureFlags root:root supportsFeature:[TTIOFeatureFlags featureCompoundIdentifications]] &&
        [study hasChildNamed:@"identifications"]) {
        idents = [TTIOCompoundIO readIdentificationsFromGroup:study
                                                 datasetNamed:@"identifications"
                                                        error:NULL] ?: @[];
    } else if ([study hasAttributeNamed:@"identifications_json"]) {
        idents = decodePlistArray([study stringAttributeNamed:@"identifications_json" error:NULL],
                                  [TTIOIdentification class], NULL) ?: @[];
    }

    if (!isV1 &&
        [TTIOFeatureFlags root:root supportsFeature:[TTIOFeatureFlags featureCompoundQuantifications]] &&
        [study hasChildNamed:@"quantifications"]) {
        quants = [TTIOCompoundIO readQuantificationsFromGroup:study
                                                 datasetNamed:@"quantifications"
                                                        error:NULL] ?: @[];
    } else if ([study hasAttributeNamed:@"quantifications_json"]) {
        quants = decodePlistArray([study stringAttributeNamed:@"quantifications_json" error:NULL],
                                  [TTIOQuantification class], NULL) ?: @[];
    }

    if (!isV1 &&
        [TTIOFeatureFlags root:root supportsFeature:[TTIOFeatureFlags featureCompoundProvenance]] &&
        [study hasChildNamed:@"provenance"]) {
        prov = [TTIOCompoundIO readProvenanceFromGroup:study
                                          datasetNamed:@"provenance"
                                                 error:NULL] ?: @[];
    } else if ([study hasAttributeNamed:@"provenance_json"]) {
        prov = decodePlistArray([study stringAttributeNamed:@"provenance_json" error:NULL],
                                [TTIOProvenanceRecord class], NULL) ?: @[];
    }

    TTIOTransitionList *trans = nil;
    if ([study hasAttributeNamed:@"transitions_json"]) {
        NSString *tjson = [study stringAttributeNamed:@"transitions_json" error:error];
        NSData *tdata = [tjson dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *plist = [NSJSONSerialization JSONObjectWithData:tdata options:0 error:error];
        if (plist) trans = [TTIOTransitionList fromPlist:plist];
    }

    TTIOSpectralDataset *ds = [[self alloc] initWithTitle:title
                                        isaInvestigationId:isaId
                                                    msRuns:msRuns
                                                   nmrRuns:nmrRuns
                                           identifications:idents
                                           quantifications:quants
                                         provenanceRecords:prov
                                               transitions:trans];
    ds->_file        = f;
    ds->_provider    = p;
    ds->_filePath    = [path copy];
    ds->_genomicRuns = [genomicRuns copy];  // M82

    // Subclass hook: read additional /study/ content while file is open.
    (void)[ds readAdditionalStudyContent:study error:NULL];

    if ([root hasAttributeNamed:@"access_policy_json"]) {
        ds->_accessPolicy = decodeAccessPolicy(
            [root stringAttributeNamed:@"access_policy_json" error:NULL]);
    }

    // Surface the root `encrypted` attribute (written by
    // -markRootEncryptedWithError:) so -isEncrypted / -encryptedAlgorithm
    // round-trip across close/reopen. Absent → empty string.
    if ([root hasAttributeNamed:@"encrypted"]) {
        NSString *alg = [root stringAttributeNamed:@"encrypted" error:NULL];
        ds->_encryptedAlgorithm = [(alg ?: @"") copy];
    } else {
        ds->_encryptedAlgorithm = @"";
    }

    return ds;
}

- (BOOL)closeFile
{
    // Cascade: runs hold open HDF5 group/dataset handles that would
    // otherwise keep the file alive even after [_file close].
    for (NSString *runName in _msRuns) {
        [[_msRuns objectForKey:runName] releaseHDF5Handles];
    }
    if (_file) {
        BOOL ok = [_file close];
        _file = nil;
        [_provider close];
        _provider = nil;
        return ok;
    }
    return YES;
}

- (NSArray<TTIOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref
{
    NSMutableArray *out = [NSMutableArray array];
    for (TTIOProvenanceRecord *r in _provenanceRecords) {
        if ([r containsInputRef:ref]) [out addObject:r];
    }
    return out;
}

#pragma mark - TTIOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(TTIOEncryptionLevel)level
                 error:(NSError **)error
{
    if (!_filePath) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOSpectralDataset: cannot encrypt before the dataset has been persisted");
        return NO;
    }

    // Release our handle so the encryption manager can reopen rw.
    [self closeFile];

    // 1. Encrypt each MS run's intensity channel by delegating to the
    //    run's own protocol method (persistence context was set during
    //    the load or by the caller after initial write).
    for (NSString *runName in _msRuns) {
        TTIOAcquisitionRun *run = _msRuns[runName];
        // Use the full HDF5 path since runs live under /study/ms_runs/
        // when persisted by TTIOSpectralDataset. H5Gopen2 accepts slash-
        // separated paths, so the encryption manager can locate the run.
        NSString *fullPath = [NSString stringWithFormat:@"/study/ms_runs/%@", runName];
        [run setPersistenceFilePath:_filePath runName:fullPath];
        if (![run encryptWithKey:key level:level error:error]) return NO;
    }

    // 2. Seal compound identifications + quantifications into encrypted
    //    byte blobs under /study/, dropping the plaintext compound
    //    datasets.
    if (![self sealCompoundDatasetsWithKey:key error:error]) return NO;

    // 3. Mark the root + persist access policy.
    if (![self markRootEncryptedWithError:error]) return NO;

    // 4. Mirror the on-disk attr in memory so -isEncrypted /
    //    -encryptedAlgorithm return the new state without a reopen.
    _encryptedAlgorithm = @"aes-256-gcm";

    return YES;
}

- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error
{
    if (!_filePath) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOSpectralDataset: no file path to decrypt against");
        return NO;
    }
    [self closeFile];

    for (NSString *runName in _msRuns) {
        TTIOAcquisitionRun *run = _msRuns[runName];
        NSString *fullPath = [NSString stringWithFormat:@"/study/ms_runs/%@", runName];
        [run setPersistenceFilePath:_filePath runName:fullPath];
        if (![run decryptWithKey:key error:error]) return NO;
    }

    if (![self unsealCompoundDatasetsWithKey:key error:error]) return NO;

    // M5-handoff: reopen the file read-only and reattach each run's
    // signal-channel handles so -spectrumAtIndex: can serve both the
    // decrypted intensity channel (from the run's in-memory cache) and
    // any unencrypted channels (mz, chemical_shift) from disk. The
    // on-disk file still carries the `encrypted` attribute and the
    // ciphertext datasets — decryption does not modify the file.
    return [self reopenAfterDecryptWithError:error];
}

- (BOOL)reopenAfterDecryptWithError:(NSError **)error
{
    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:_filePath mode:TTIOStorageOpenModeRead error:error]) return NO;
    TTIOHDF5File *f = (TTIOHDF5File *)[p nativeHandle];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    if (!root) { [p close]; return NO; }
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) { [p close]; return NO; }
    TTIOHDF5Group *msRunsG = nil;
    if ([study hasChildNamed:@"ms_runs"]) {
        msRunsG = [study openGroupNamed:@"ms_runs" error:error];
        if (!msRunsG) { [p close]; return NO; }
    }
    for (NSString *runName in _msRuns) {
        if (!msRunsG) break;
        TTIOHDF5Group *runG = [msRunsG openGroupNamed:runName error:NULL];
        if (!runG) continue;
        TTIOHDF5Group *channels = [runG openGroupNamed:@"signal_channels" error:NULL];
        if (!channels) continue;
        TTIOAcquisitionRun *run = _msRuns[runName];
        (void)[run reattachSignalHandlesFromGroup:channels error:NULL];
    }
    _file     = f;
    _provider = p;
    return YES;
}

- (TTIOAccessPolicy *)accessPolicy { return _accessPolicy; }
- (void)setAccessPolicy:(TTIOAccessPolicy *)policy { _accessPolicy = policy; }

#pragma mark - Subclass hooks (default no-ops)

- (BOOL)writeAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                              error:(NSError **)error
{
    (void)studyGroup; (void)error;
    return YES;
}

- (BOOL)readAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                             error:(NSError **)error
{
    (void)studyGroup; (void)error;
    return YES;
}

#pragma mark - Compound dataset sealing (encryption of /study compound datasets)

- (BOOL)sealCompoundDatasetsWithKey:(NSData *)key error:(NSError **)error
{
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:_filePath error:error];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) { [f close]; return NO; }

    if ([study hasChildNamed:@"identifications"]) {
        NSArray *idents = [TTIOCompoundIO readIdentificationsFromGroup:study
                                                          datasetNamed:@"identifications"
                                                                 error:error];
        if (!idents) { [f close]; return NO; }
        NSMutableArray *plists = [NSMutableArray array];
        for (TTIOIdentification *i in idents) [plists addObject:[i asPlist]];
        NSData *json = [NSJSONSerialization dataWithJSONObject:plists options:0 error:error];
        if (!json) { [f close]; return NO; }
        H5Ldelete(study.groupId, "identifications", H5P_DEFAULT);
        // M37: also strip the JSON attribute mirror so sealed files are
        // not readable without decryption.
        if ([study hasAttributeNamed:@"identifications_json"])
            H5Adelete(study.groupId, "identifications_json");
        if (![self writeSealedBlob:json name:@"identifications_sealed"
                           inGroup:study key:key error:error]) { [f close]; return NO; }
    }

    if ([study hasChildNamed:@"quantifications"]) {
        NSArray *quants = [TTIOCompoundIO readQuantificationsFromGroup:study
                                                          datasetNamed:@"quantifications"
                                                                 error:error];
        if (!quants) { [f close]; return NO; }
        NSMutableArray *plists = [NSMutableArray array];
        for (TTIOQuantification *q in quants) [plists addObject:[q asPlist]];
        NSData *json = [NSJSONSerialization dataWithJSONObject:plists options:0 error:error];
        if (!json) { [f close]; return NO; }
        H5Ldelete(study.groupId, "quantifications", H5P_DEFAULT);
        if ([study hasAttributeNamed:@"quantifications_json"])
            H5Adelete(study.groupId, "quantifications_json");
        if (![self writeSealedBlob:json name:@"quantifications_sealed"
                           inGroup:study key:key error:error]) { [f close]; return NO; }
    }

    return [f close];
}

- (BOOL)unsealCompoundDatasetsWithKey:(NSData *)key error:(NSError **)error
{
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:_filePath error:error];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) { [f close]; return NO; }

    if ([study hasChildNamed:@"identifications_sealed"]) {
        NSData *json = [self readSealedBlob:@"identifications_sealed"
                                    inGroup:study key:key error:error];
        if (!json) { [f close]; return NO; }
        NSArray *plists = [NSJSONSerialization JSONObjectWithData:json options:0 error:error];
        NSMutableArray *idents = [NSMutableArray array];
        for (NSDictionary *p in plists) [idents addObject:[TTIOIdentification fromPlist:p]];
        H5Ldelete(study.groupId, "identifications_sealed", H5P_DEFAULT);
        H5Ldelete(study.groupId, "identifications_sealed_iv", H5P_DEFAULT);
        H5Ldelete(study.groupId, "identifications_sealed_tag", H5P_DEFAULT);
        H5Ldelete(study.groupId, "identifications_sealed_bytes", H5P_DEFAULT);
        if (![TTIOCompoundIO writeIdentifications:idents
                                        intoGroup:study
                                     datasetNamed:@"identifications"
                                            error:error]) { [f close]; return NO; }
        _identifications = [idents copy];
    }

    if ([study hasChildNamed:@"quantifications_sealed"]) {
        NSData *json = [self readSealedBlob:@"quantifications_sealed"
                                    inGroup:study key:key error:error];
        if (!json) { [f close]; return NO; }
        NSArray *plists = [NSJSONSerialization JSONObjectWithData:json options:0 error:error];
        NSMutableArray *quants = [NSMutableArray array];
        for (NSDictionary *p in plists) [quants addObject:[TTIOQuantification fromPlist:p]];
        H5Ldelete(study.groupId, "quantifications_sealed", H5P_DEFAULT);
        H5Ldelete(study.groupId, "quantifications_sealed_iv", H5P_DEFAULT);
        H5Ldelete(study.groupId, "quantifications_sealed_tag", H5P_DEFAULT);
        H5Ldelete(study.groupId, "quantifications_sealed_bytes", H5P_DEFAULT);
        if (![TTIOCompoundIO writeQuantifications:quants
                                        intoGroup:study
                                     datasetNamed:@"quantifications"
                                            error:error]) { [f close]; return NO; }
        _quantifications = [quants copy];
    }

    return [f close];
}

- (BOOL)writeSealedBlob:(NSData *)plaintext
                   name:(NSString *)name
                inGroup:(TTIOHDF5Group *)group
                    key:(NSData *)key
                  error:(NSError **)error
{
    NSData *iv = nil, *tag = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *cipher = [TTIOEncryptionManager encryptData:plaintext
                                                withKey:key
                                                     iv:&iv
                                                authTag:&tag
                                                  error:error];
#pragma clang diagnostic pop
    if (!cipher) return NO;

    NSMutableData *padded = [NSMutableData dataWithData:cipher];
    while (padded.length % 4 != 0) {
        uint8_t zero = 0;
        [padded appendBytes:&zero length:1];
    }
    TTIOHDF5Dataset *ds = [group createDatasetNamed:name
                                           precision:TTIOPrecisionInt32
                                              length:padded.length / 4
                                           chunkSize:0
                                    compressionLevel:0
                                               error:error];
    if (!ds) return NO;
    if (![ds writeData:padded error:error]) return NO;

    NSString *ivName  = [name stringByAppendingString:@"_iv"];
    NSString *tagName = [name stringByAppendingString:@"_tag"];
    NSString *lenName = [name stringByAppendingString:@"_bytes"];

    TTIOHDF5Dataset *ivDs = [group createDatasetNamed:ivName
                                             precision:TTIOPrecisionInt32
                                                length:3   // 12 bytes
                                             chunkSize:0
                                      compressionLevel:0
                                                 error:error];
    if (![ivDs writeData:iv error:error]) return NO;

    TTIOHDF5Dataset *tagDs = [group createDatasetNamed:tagName
                                              precision:TTIOPrecisionInt32
                                                 length:4   // 16 bytes
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
    if (![tagDs writeData:tag error:error]) return NO;

    // Store original cipher length (before padding) as 1-element dataset
    uint32_t lenBytes = (uint32_t)cipher.length;
    TTIOHDF5Dataset *lenDs = [group createDatasetNamed:lenName
                                              precision:TTIOPrecisionUInt32
                                                 length:1
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
    return [lenDs writeData:[NSData dataWithBytes:&lenBytes length:sizeof(lenBytes)] error:error];
}

- (NSData *)readSealedBlob:(NSString *)name
                   inGroup:(TTIOHDF5Group *)group
                       key:(NSData *)key
                     error:(NSError **)error
{
    TTIOHDF5Dataset *ds = [group openDatasetNamed:name error:error];
    if (!ds) return nil;
    NSData *padded = [ds readDataWithError:error];
    if (!padded) return nil;

    NSString *lenName = [name stringByAppendingString:@"_bytes"];
    TTIOHDF5Dataset *lenDs = [group openDatasetNamed:lenName error:error];
    NSData *lenData = [lenDs readDataWithError:error];
    uint32_t cipherLen = ((const uint32_t *)lenData.bytes)[0];

    NSData *cipher = [padded subdataWithRange:NSMakeRange(0, cipherLen)];

    NSString *ivName  = [name stringByAppendingString:@"_iv"];
    NSString *tagName = [name stringByAppendingString:@"_tag"];
    NSData *iv  = [[group openDatasetNamed:ivName  error:error] readDataWithError:error];
    NSData *tag = [[group openDatasetNamed:tagName error:error] readDataWithError:error];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [TTIOEncryptionManager decryptData:cipher
                                      withKey:key
                                           iv:iv
                                      authTag:tag
                                        error:error];
#pragma clang diagnostic pop
}

- (BOOL)markRootEncryptedWithError:(NSError **)error
{
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:_filePath error:error];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    if (![root setStringAttribute:@"encrypted"
                             value:@"aes-256-gcm"
                             error:error]) { [f close]; return NO; }

    NSString *ap = encodeAccessPolicy(_accessPolicy);
    if (ap) {
        if (![root setStringAttribute:@"access_policy_json"
                                value:ap
                                error:error]) { [f close]; return NO; }
    }
    return [f close];
}

#pragma mark - v1.1.1: persist-to-disk decrypt

+ (BOOL)decryptInPlaceAtPath:(NSString *)path
                     withKey:(NSData *)key
                       error:(NSError **)error
{
    if (key.length != 32) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"AES-256-GCM requires a 32-byte key, got %lu",
            (unsigned long)key.length);
        return NO;
    }

    // 1. Enumerate MS run names while the file is closed to readers.
    NSMutableArray<NSString *> *runNames = [NSMutableArray array];
    {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:error];
        if (!f) return NO;
        TTIOHDF5Group *root = [f rootGroup];
        if ([root hasChildNamed:@"study"]) {
            TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
            if (!study) { [f close]; return NO; }
            if ([study hasChildNamed:@"ms_runs"]) {
                TTIOHDF5Group *msRunsG =
                    [study openGroupNamed:@"ms_runs" error:error];
                if (!msRunsG) { [f close]; return NO; }
                for (NSString *name in [msRunsG childNames]) {
                    [runNames addObject:name];
                }
            }
        }
        if (![f close]) return NO;
    }

    // 2. Decrypt each run's intensity channel in place. The encryption
    //    manager opens/closes the file for each call, mirroring the
    //    encrypt side's per-run lifecycle.
    for (NSString *name in runNames) {
        NSString *fullPath =
            [NSString stringWithFormat:@"/study/ms_runs/%@", name];
        if (![TTIOEncryptionManager
                decryptIntensityChannelInRunInPlace:fullPath
                                         atFilePath:path
                                            withKey:key
                                              error:error]) {
            return NO;
        }
    }

    // 3. Clear the root @encrypted attribute so a reopen sees the
    //    file as unprotected.
    TTIOHDF5File *fw = [TTIOHDF5File openAtPath:path error:error];
    if (!fw) return NO;
    TTIOHDF5Group *root = [fw rootGroup];
    if ([root hasAttributeNamed:@"encrypted"]) {
        if (![root deleteAttributeNamed:@"encrypted" error:error]) {
            [fw close];
            return NO;
        }
    }
    return [fw close];
}

@end
