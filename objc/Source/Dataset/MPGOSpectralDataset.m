#import "MPGOSpectralDataset.h"
#import "MPGOIdentification.h"
#import "MPGOQuantification.h"
#import "MPGOProvenanceRecord.h"
#import "MPGOTransitionList.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOSpectralDataset

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

#pragma mark - Helpers (JSON encode/decode of plist-like structures)

static NSString *encodePlistArray(NSArray *items, NSError **error)
{
    NSMutableArray *plists = [NSMutableArray arrayWithCapacity:items.count];
    for (id obj in items) [plists addObject:[obj asPlist]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:plists options:0 error:error];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

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

    if (![root setStringAttribute:@"mpeg_o_version" value:@"1.0.0" error:error]) return NO;

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
        if (![_msRuns[runName] writeToGroup:msRunsGroup name:runName error:error]) return NO;
    }

    // NMR runs (each is an array of MPGONMRSpectrum written with MPGOSpectrum API)
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

    // Identifications / Quantifications / Provenance
    NSString *idJson = encodePlistArray(_identifications, error);
    if (!idJson) return NO;
    if (![study setStringAttribute:@"identifications_json" value:idJson error:error]) return NO;

    NSString *qJson = encodePlistArray(_quantifications, error);
    if (!qJson) return NO;
    if (![study setStringAttribute:@"quantifications_json" value:qJson error:error]) return NO;

    NSString *pJson = encodePlistArray(_provenanceRecords, error);
    if (!pJson) return NO;
    if (![study setStringAttribute:@"provenance_json" value:pJson error:error]) return NO;

    if (_transitions) {
        NSData *tdata = [NSJSONSerialization dataWithJSONObject:[_transitions asPlist]
                                                        options:0
                                                          error:error];
        if (!tdata) return NO;
        NSString *tjson = [[NSString alloc] initWithData:tdata encoding:NSUTF8StringEncoding];
        if (![study setStringAttribute:@"transitions_json" value:tjson error:error]) return NO;
    }

    return [f close];
}

#pragma mark - HDF5 read

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    MPGOHDF5File *f = [MPGOHDF5File openReadOnlyAtPath:path error:error];
    if (!f) return nil;
    MPGOHDF5Group *root = [f rootGroup];

    MPGOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (!study) return nil;

    NSString *title  = [study stringAttributeNamed:@"title" error:error];
    NSString *isaId  = [study stringAttributeNamed:@"isa_investigation_id" error:error];

    // MS runs (v0.2: any MPGOSpectrum subclass, not just mass spectra)
    NSMutableDictionary *msRuns = [NSMutableDictionary dictionary];
    if ([study hasChildNamed:@"ms_runs"]) {
        MPGOHDF5Group *msg = [study openGroupNamed:@"ms_runs" error:error];
        NSString *namesStr = [msg stringAttributeNamed:@"_run_names" error:error];
        for (NSString *rname in [namesStr componentsSeparatedByString:@","]) {
            if (rname.length == 0) continue;
            MPGOAcquisitionRun *run = [MPGOAcquisitionRun readFromGroup:msg name:rname error:error];
            if (!run) return nil;
            // Thread persistence context so protocol encryption methods work.
            [run setPersistenceFilePath:path runName:rname];
            msRuns[rname] = run;
        }
    }

    // NMR runs
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

    NSArray *idents = decodePlistArray([study stringAttributeNamed:@"identifications_json" error:NULL],
                                       [MPGOIdentification class], error);
    NSArray *quants = decodePlistArray([study stringAttributeNamed:@"quantifications_json" error:NULL],
                                       [MPGOQuantification class], error);
    NSArray *prov   = decodePlistArray([study stringAttributeNamed:@"provenance_json" error:NULL],
                                       [MPGOProvenanceRecord class], error);

    MPGOTransitionList *trans = nil;
    if ([study hasAttributeNamed:@"transitions_json"]) {
        NSString *tjson = [study stringAttributeNamed:@"transitions_json" error:error];
        NSData *tdata = [tjson dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *plist = [NSJSONSerialization JSONObjectWithData:tdata options:0 error:error];
        if (plist) trans = [MPGOTransitionList fromPlist:plist];
    }

    return [[self alloc] initWithTitle:title
                    isaInvestigationId:isaId
                                msRuns:msRuns
                               nmrRuns:nmrRuns
                       identifications:idents
                       quantifications:quants
                     provenanceRecords:prov
                           transitions:trans];
}

- (NSArray<MPGOProvenanceRecord *> *)provenanceRecordsForInputRef:(NSString *)ref
{
    NSMutableArray *out = [NSMutableArray array];
    for (MPGOProvenanceRecord *r in _provenanceRecords) {
        if ([r containsInputRef:ref]) [out addObject:r];
    }
    return out;
}

@end
