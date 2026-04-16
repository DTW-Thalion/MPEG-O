#import "MPGOSpectralDataset.h"
#import "MPGOIdentification.h"
#import "MPGOQuantification.h"
#import "MPGOProvenanceRecord.h"
#import "MPGOTransitionList.h"
#import "MPGOCompoundIO.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOFeatureFlags.h"
#import "Protection/MPGOEncryptionManager.h"
#import "Protection/MPGOAccessPolicy.h"
#import <hdf5.h>

// v0.2 format version emitted by this writer.
static NSString *const kMPGOFormatVersion = @"1.1";

@implementation MPGOSpectralDataset
{
    MPGOHDF5File     *_file;   // retained while alive for lazy reads
    NSString         *_filePath;
    MPGOAccessPolicy *_accessPolicy;
}

@synthesize filePath = _filePath;

- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
                       msRuns:(NSDictionary *)msRuns
                      nmrRuns:(NSDictionary *)nmrRuns
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                  transitions:(MPGOTransitionList *)transitions
{
    self = [super init];
    if (self) {
        _title              = [title copy];
        _isaInvestigationId = [isaId copy];
        _msRuns             = [msRuns copy] ?: @{};
        _nmrRuns            = [nmrRuns copy] ?: @{};
        _identifications    = [identifications copy] ?: @[];
        _quantifications    = [quantifications copy] ?: @[];
        _provenanceRecords  = [provenance copy] ?: @[];
        _transitions        = transitions;
    }
    return self;
}

- (void)dealloc
{
    [self closeFile];
}

#pragma mark - Access policy JSON helpers

static NSString *encodeAccessPolicy(MPGOAccessPolicy *p)
{
    if (!p || !p.policy) return nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:p.policy options:0 error:NULL];
    if (!d) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static MPGOAccessPolicy *decodeAccessPolicy(NSString *json)
{
    if (json.length == 0) return nil;
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    return [[MPGOAccessPolicy alloc] initWithPolicy:parsed];
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

#pragma mark - HDF5 write

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error
{
    MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:error];
    if (!f) return NO;
    MPGOHDF5Group *root = [f rootGroup];

    // Emit v0.2 format + feature flags. The per-run compound provenance
    // flag (M17) is emitted unconditionally: every v0.3 writer produces
    // compound-form per-run provenance when any run carries records, and
    // the flag advertises that capability to future readers even when the
    // current in-memory dataset happens to have no provenance to persist.
    NSArray *features = @[
        [MPGOFeatureFlags featureBaseV1],
        [MPGOFeatureFlags featureCompoundIdentifications],
        [MPGOFeatureFlags featureCompoundQuantifications],
        [MPGOFeatureFlags featureCompoundProvenance],
        [MPGOFeatureFlags featureCompoundPerRunProvenance],
        [MPGOFeatureFlags featureCompoundHeaders],
        [MPGOFeatureFlags featureNative2DNMR],
        [MPGOFeatureFlags featureNativeMSImageCube],
    ];
    if (![MPGOFeatureFlags writeFormatVersion:kMPGOFormatVersion
                                      features:features
                                        toRoot:root
                                         error:error]) return NO;

    // Access policy, if set.
    NSString *apJson = encodeAccessPolicy(_accessPolicy);
    if (apJson) {
        if (![root setStringAttribute:@"access_policy_json"
                                value:apJson error:error]) return NO;
    }

    MPGOHDF5Group *study = [root createGroupNamed:@"study" error:error];
    if (!study) return NO;
    if (![study setStringAttribute:@"title" value:(_title ?: @"") error:error]) return NO;
    if (![study setStringAttribute:@"isa_investigation_id"
                              value:(_isaInvestigationId ?: @"")
                              error:error]) return NO;

    // MS runs
    MPGOHDF5Group *msRunsGroup = [study createGroupNamed:@"ms_runs" error:error];
    if (!msRunsGroup) return NO;
    NSArray *msNames = [[_msRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![msRunsGroup setStringAttribute:@"_run_names"
                                    value:[msNames componentsJoinedByString:@","]
                                    error:error]) return NO;
    for (NSString *runName in msNames) {
        MPGOAcquisitionRun *run = _msRuns[runName];
        if (![run writeToGroup:msRunsGroup name:runName error:error]) return NO;

        // Write compound headers alongside the parallel index datasets.
        MPGOHDF5Group *runG = [msRunsGroup openGroupNamed:runName error:NULL];
        MPGOHDF5Group *idxG = [runG openGroupNamed:@"spectrum_index" error:NULL];
        if (idxG) {
            [MPGOCompoundIO writeCompoundHeadersForIndex:run.spectrumIndex
                                                intoGroup:idxG
                                                    error:NULL];
        }
    }

    // NMR runs (legacy nmrRuns dict, kept for backward compat)
    MPGOHDF5Group *nmrRunsGroup = [study createGroupNamed:@"nmr_runs" error:error];
    if (!nmrRunsGroup) return NO;
    NSArray *nmrNames = [[_nmrRuns allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (![nmrRunsGroup setStringAttribute:@"_run_names"
                                     value:[nmrNames componentsJoinedByString:@","]
                                     error:error]) return NO;
    for (NSString *runName in nmrNames) {
        MPGOHDF5Group *nmrRun = [nmrRunsGroup createGroupNamed:runName error:error];
        if (!nmrRun) return NO;
        NSArray<MPGONMRSpectrum *> *spectra = _nmrRuns[runName];
        if (![nmrRun setIntegerAttribute:@"count" value:(int64_t)spectra.count
                                   error:error]) return NO;
        for (NSUInteger i = 0; i < spectra.count; i++) {
            NSString *name = [NSString stringWithFormat:@"spec_%06lu", (unsigned long)i];
            if (![spectra[i] writeToGroup:nmrRun name:name error:error]) return NO;
        }
    }

    // Compound identifications / quantifications / provenance
    if (_identifications.count > 0) {
        if (![MPGOCompoundIO writeIdentifications:_identifications
                                         intoGroup:study
                                      datasetNamed:@"identifications"
                                             error:error]) return NO;
    }
    if (_quantifications.count > 0) {
        if (![MPGOCompoundIO writeQuantifications:_quantifications
                                         intoGroup:study
                                      datasetNamed:@"quantifications"
                                             error:error]) return NO;
    }
    if (_provenanceRecords.count > 0) {
        if (![MPGOCompoundIO writeProvenance:_provenanceRecords
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

#pragma mark - HDF5 read

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    MPGOHDF5File *f = [MPGOHDF5File openReadOnlyAtPath:path error:error];
    if (!f) return nil;
    MPGOHDF5Group *root = [f rootGroup];

    BOOL isV1 = [MPGOFeatureFlags isLegacyV1File:root];

    MPGOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) return nil;

    NSString *title  = [study stringAttributeNamed:@"title" error:error];
    NSString *isaId  = [study stringAttributeNamed:@"isa_investigation_id" error:error];

    // MS runs (v0.2: any MPGOSpectrum subclass)
    NSMutableDictionary *msRuns = [NSMutableDictionary dictionary];
    if ([study hasChildNamed:@"ms_runs"]) {
        MPGOHDF5Group *msg = [study openGroupNamed:@"ms_runs" error:error];
        NSString *namesStr = [msg stringAttributeNamed:@"_run_names" error:error];
        for (NSString *rname in [namesStr componentsSeparatedByString:@","]) {
            if (rname.length == 0) continue;
            MPGOAcquisitionRun *run = [MPGOAcquisitionRun readFromGroup:msg name:rname error:error];
            if (!run) return nil;
            [run setPersistenceFilePath:path runName:rname];
            msRuns[rname] = run;
        }
    }

    // NMR runs (legacy)
    NSMutableDictionary *nmrRuns = [NSMutableDictionary dictionary];
    if ([study hasChildNamed:@"nmr_runs"]) {
        MPGOHDF5Group *ng = [study openGroupNamed:@"nmr_runs" error:error];
        NSString *namesStr = [ng stringAttributeNamed:@"_run_names" error:error];
        for (NSString *rname in [namesStr componentsSeparatedByString:@","]) {
            if (rname.length == 0) continue;
            MPGOHDF5Group *runG = [ng openGroupNamed:rname error:error];
            BOOL exists = NO;
            NSUInteger n = (NSUInteger)[runG integerAttributeNamed:@"count"
                                                            exists:&exists error:error];
            NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:n];
            for (NSUInteger i = 0; i < n; i++) {
                NSString *sname = [NSString stringWithFormat:@"spec_%06lu", (unsigned long)i];
                MPGONMRSpectrum *s = [MPGONMRSpectrum readFromGroup:runG name:sname error:error];
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
        [MPGOFeatureFlags root:root supportsFeature:[MPGOFeatureFlags featureCompoundIdentifications]] &&
        [study hasChildNamed:@"identifications"]) {
        idents = [MPGOCompoundIO readIdentificationsFromGroup:study
                                                 datasetNamed:@"identifications"
                                                        error:NULL] ?: @[];
    } else if ([study hasAttributeNamed:@"identifications_json"]) {
        idents = decodePlistArray([study stringAttributeNamed:@"identifications_json" error:NULL],
                                  [MPGOIdentification class], NULL) ?: @[];
    }

    if (!isV1 &&
        [MPGOFeatureFlags root:root supportsFeature:[MPGOFeatureFlags featureCompoundQuantifications]] &&
        [study hasChildNamed:@"quantifications"]) {
        quants = [MPGOCompoundIO readQuantificationsFromGroup:study
                                                 datasetNamed:@"quantifications"
                                                        error:NULL] ?: @[];
    } else if ([study hasAttributeNamed:@"quantifications_json"]) {
        quants = decodePlistArray([study stringAttributeNamed:@"quantifications_json" error:NULL],
                                  [MPGOQuantification class], NULL) ?: @[];
    }

    if (!isV1 &&
        [MPGOFeatureFlags root:root supportsFeature:[MPGOFeatureFlags featureCompoundProvenance]] &&
        [study hasChildNamed:@"provenance"]) {
        prov = [MPGOCompoundIO readProvenanceFromGroup:study
                                          datasetNamed:@"provenance"
                                                 error:NULL] ?: @[];
    } else if ([study hasAttributeNamed:@"provenance_json"]) {
        prov = decodePlistArray([study stringAttributeNamed:@"provenance_json" error:NULL],
                                [MPGOProvenanceRecord class], NULL) ?: @[];
    }

    MPGOTransitionList *trans = nil;
    if ([study hasAttributeNamed:@"transitions_json"]) {
        NSString *tjson = [study stringAttributeNamed:@"transitions_json" error:error];
        NSData *tdata = [tjson dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *plist = [NSJSONSerialization JSONObjectWithData:tdata options:0 error:error];
        if (plist) trans = [MPGOTransitionList fromPlist:plist];
    }

    MPGOSpectralDataset *ds = [[self alloc] initWithTitle:title
                                        isaInvestigationId:isaId
                                                    msRuns:msRuns
                                                   nmrRuns:nmrRuns
                                           identifications:idents
                                           quantifications:quants
                                         provenanceRecords:prov
                                               transitions:trans];
    ds->_file     = f;
    ds->_filePath = [path copy];

    // Subclass hook: read additional /study/ content while file is open.
    (void)[ds readAdditionalStudyContent:study error:NULL];

    if ([root hasAttributeNamed:@"access_policy_json"]) {
        ds->_accessPolicy = decodeAccessPolicy(
            [root stringAttributeNamed:@"access_policy_json" error:NULL]);
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
        return ok;
    }
    return YES;
}

- (NSArray<MPGOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref
{
    NSMutableArray *out = [NSMutableArray array];
    for (MPGOProvenanceRecord *r in _provenanceRecords) {
        if ([r containsInputRef:ref]) [out addObject:r];
    }
    return out;
}

#pragma mark - MPGOEncryptable

- (BOOL)encryptWithKey:(NSData *)key
                 level:(MPGOEncryptionLevel)level
                 error:(NSError **)error
{
    if (!_filePath) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOSpectralDataset: cannot encrypt before the dataset has been persisted");
        return NO;
    }

    // Release our handle so the encryption manager can reopen rw.
    [self closeFile];

    // 1. Encrypt each MS run's intensity channel by delegating to the
    //    run's own protocol method (persistence context was set during
    //    the load or by the caller after initial write).
    for (NSString *runName in _msRuns) {
        MPGOAcquisitionRun *run = _msRuns[runName];
        // Use the full HDF5 path since runs live under /study/ms_runs/
        // when persisted by MPGOSpectralDataset. H5Gopen2 accepts slash-
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

    return YES;
}

- (BOOL)decryptWithKey:(NSData *)key error:(NSError **)error
{
    if (!_filePath) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOSpectralDataset: no file path to decrypt against");
        return NO;
    }
    [self closeFile];

    for (NSString *runName in _msRuns) {
        MPGOAcquisitionRun *run = _msRuns[runName];
        NSString *fullPath = [NSString stringWithFormat:@"/study/ms_runs/%@", runName];
        [run setPersistenceFilePath:_filePath runName:fullPath];
        if (![run decryptWithKey:key error:error]) return NO;
    }

    if (![self unsealCompoundDatasetsWithKey:key error:error]) return NO;
    return YES;
}

- (MPGOAccessPolicy *)accessPolicy { return _accessPolicy; }
- (void)setAccessPolicy:(MPGOAccessPolicy *)policy { _accessPolicy = policy; }

#pragma mark - Subclass hooks (default no-ops)

- (BOOL)writeAdditionalStudyContent:(MPGOHDF5Group *)studyGroup
                              error:(NSError **)error
{
    (void)studyGroup; (void)error;
    return YES;
}

- (BOOL)readAdditionalStudyContent:(MPGOHDF5Group *)studyGroup
                             error:(NSError **)error
{
    (void)studyGroup; (void)error;
    return YES;
}

#pragma mark - Compound dataset sealing (encryption of /study compound datasets)

- (BOOL)sealCompoundDatasetsWithKey:(NSData *)key error:(NSError **)error
{
    MPGOHDF5File *f = [MPGOHDF5File openAtPath:_filePath error:error];
    if (!f) return NO;
    MPGOHDF5Group *root = [f rootGroup];
    MPGOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) { [f close]; return NO; }

    if ([study hasChildNamed:@"identifications"]) {
        NSArray *idents = [MPGOCompoundIO readIdentificationsFromGroup:study
                                                          datasetNamed:@"identifications"
                                                                 error:error];
        if (!idents) { [f close]; return NO; }
        NSMutableArray *plists = [NSMutableArray array];
        for (MPGOIdentification *i in idents) [plists addObject:[i asPlist]];
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
        NSArray *quants = [MPGOCompoundIO readQuantificationsFromGroup:study
                                                          datasetNamed:@"quantifications"
                                                                 error:error];
        if (!quants) { [f close]; return NO; }
        NSMutableArray *plists = [NSMutableArray array];
        for (MPGOQuantification *q in quants) [plists addObject:[q asPlist]];
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
    MPGOHDF5File *f = [MPGOHDF5File openAtPath:_filePath error:error];
    if (!f) return NO;
    MPGOHDF5Group *root = [f rootGroup];
    MPGOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) { [f close]; return NO; }

    if ([study hasChildNamed:@"identifications_sealed"]) {
        NSData *json = [self readSealedBlob:@"identifications_sealed"
                                    inGroup:study key:key error:error];
        if (!json) { [f close]; return NO; }
        NSArray *plists = [NSJSONSerialization JSONObjectWithData:json options:0 error:error];
        NSMutableArray *idents = [NSMutableArray array];
        for (NSDictionary *p in plists) [idents addObject:[MPGOIdentification fromPlist:p]];
        H5Ldelete(study.groupId, "identifications_sealed", H5P_DEFAULT);
        H5Ldelete(study.groupId, "identifications_sealed_iv", H5P_DEFAULT);
        H5Ldelete(study.groupId, "identifications_sealed_tag", H5P_DEFAULT);
        H5Ldelete(study.groupId, "identifications_sealed_bytes", H5P_DEFAULT);
        if (![MPGOCompoundIO writeIdentifications:idents
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
        for (NSDictionary *p in plists) [quants addObject:[MPGOQuantification fromPlist:p]];
        H5Ldelete(study.groupId, "quantifications_sealed", H5P_DEFAULT);
        H5Ldelete(study.groupId, "quantifications_sealed_iv", H5P_DEFAULT);
        H5Ldelete(study.groupId, "quantifications_sealed_tag", H5P_DEFAULT);
        H5Ldelete(study.groupId, "quantifications_sealed_bytes", H5P_DEFAULT);
        if (![MPGOCompoundIO writeQuantifications:quants
                                        intoGroup:study
                                     datasetNamed:@"quantifications"
                                            error:error]) { [f close]; return NO; }
        _quantifications = [quants copy];
    }

    return [f close];
}

- (BOOL)writeSealedBlob:(NSData *)plaintext
                   name:(NSString *)name
                inGroup:(MPGOHDF5Group *)group
                    key:(NSData *)key
                  error:(NSError **)error
{
    NSData *iv = nil, *tag = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *cipher = [MPGOEncryptionManager encryptData:plaintext
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
    MPGOHDF5Dataset *ds = [group createDatasetNamed:name
                                           precision:MPGOPrecisionInt32
                                              length:padded.length / 4
                                           chunkSize:0
                                    compressionLevel:0
                                               error:error];
    if (!ds) return NO;
    if (![ds writeData:padded error:error]) return NO;

    NSString *ivName  = [name stringByAppendingString:@"_iv"];
    NSString *tagName = [name stringByAppendingString:@"_tag"];
    NSString *lenName = [name stringByAppendingString:@"_bytes"];

    MPGOHDF5Dataset *ivDs = [group createDatasetNamed:ivName
                                             precision:MPGOPrecisionInt32
                                                length:3   // 12 bytes
                                             chunkSize:0
                                      compressionLevel:0
                                                 error:error];
    if (![ivDs writeData:iv error:error]) return NO;

    MPGOHDF5Dataset *tagDs = [group createDatasetNamed:tagName
                                              precision:MPGOPrecisionInt32
                                                 length:4   // 16 bytes
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
    if (![tagDs writeData:tag error:error]) return NO;

    // Store original cipher length (before padding) as 1-element dataset
    uint32_t lenBytes = (uint32_t)cipher.length;
    MPGOHDF5Dataset *lenDs = [group createDatasetNamed:lenName
                                              precision:MPGOPrecisionUInt32
                                                 length:1
                                              chunkSize:0
                                       compressionLevel:0
                                                  error:error];
    return [lenDs writeData:[NSData dataWithBytes:&lenBytes length:sizeof(lenBytes)] error:error];
}

- (NSData *)readSealedBlob:(NSString *)name
                   inGroup:(MPGOHDF5Group *)group
                       key:(NSData *)key
                     error:(NSError **)error
{
    MPGOHDF5Dataset *ds = [group openDatasetNamed:name error:error];
    if (!ds) return nil;
    NSData *padded = [ds readDataWithError:error];
    if (!padded) return nil;

    NSString *lenName = [name stringByAppendingString:@"_bytes"];
    MPGOHDF5Dataset *lenDs = [group openDatasetNamed:lenName error:error];
    NSData *lenData = [lenDs readDataWithError:error];
    uint32_t cipherLen = ((const uint32_t *)lenData.bytes)[0];

    NSData *cipher = [padded subdataWithRange:NSMakeRange(0, cipherLen)];

    NSString *ivName  = [name stringByAppendingString:@"_iv"];
    NSString *tagName = [name stringByAppendingString:@"_tag"];
    NSData *iv  = [[group openDatasetNamed:ivName  error:error] readDataWithError:error];
    NSData *tag = [[group openDatasetNamed:tagName error:error] readDataWithError:error];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [MPGOEncryptionManager decryptData:cipher
                                      withKey:key
                                           iv:iv
                                      authTag:tag
                                        error:error];
#pragma clang diagnostic pop
}

- (BOOL)markRootEncryptedWithError:(NSError **)error
{
    MPGOHDF5File *f = [MPGOHDF5File openAtPath:_filePath error:error];
    if (!f) return NO;
    MPGOHDF5Group *root = [f rootGroup];
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

@end
