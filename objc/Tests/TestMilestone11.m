// Milestone 11 tests — native HDF5 compound types + file-level encryption.
// Intentionally exercises the deprecated file-path encryption manager API
// via the dataset-level protocol path, so suppress deprecations.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Dataset/TTIOCompoundIO.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "HDF5/TTIOHDF5CompoundType.h"
#import "Protection/TTIOAccessPolicy.h"
#import "Protection/TTIOEncryptionManager.h"
#import <unistd.h>

static NSString *m11path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m11_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOSignalArray *f64ForCount(NSUInteger k, NSUInteger n)
{
    double *buf = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) buf[i] = 100.0 + (double)(k * 8 + i);
    NSData *d = [NSData dataWithBytes:buf length:n * sizeof(double)];
    free(buf);
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:d
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static TTIOAcquisitionRun *m11MakeRun(NSUInteger specCount)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < specCount; k++) {
        TTIOSignalArray *mz = f64ForCount(k, 8);
        TTIOSignalArray *in = f64ForCount(k + 1000, 8);
        [spectra addObject:
            [[TTIOMassSpectrum alloc] initWithMzArray:mz
                                       intensityArray:in
                                              msLevel:(k % 2 == 0 ? 1 : 2)
                                             polarity:TTIOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.5
                                          precursorMz:0
                                      precursorCharge:0
                                                error:NULL]];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    return [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:TTIOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

void testMilestone11(void)
{
    // ---- 1. 100 identifications as compound type ----
    {
        NSMutableArray *idents = [NSMutableArray array];
        for (NSUInteger i = 0; i < 100; i++) {
            TTIOIdentification *id_ =
                [[TTIOIdentification alloc] initWithRunName:@"run_0001"
                                              spectrumIndex:i
                                             chemicalEntity:[NSString stringWithFormat:@"CHEBI:%lu",
                                                             (unsigned long)(15000 + i)]
                                            confidenceScore:0.5 + (double)i * 0.005
                                              evidenceChain:@[@"MS:1002217", @"PRIDE:0000033"]];
            [idents addObject:id_];
        }

        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_idents"
                                    isaInvestigationId:@"I-42"
                                                msRuns:@{@"run_0001": m11MakeRun(5)}
                                               nmrRuns:@{}
                                       identifications:idents
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"idents");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err], "dataset with 100 idents writes");

        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, "dataset with 100 idents reads");
        PASS(back.identifications.count == 100, "100 idents round-trip");
        TTIOIdentification *id42 = back.identifications[42];
        PASS([id42.runName isEqualToString:@"run_0001"], "ident[42].runName");
        PASS(id42.spectrumIndex == 42, "ident[42].spectrumIndex");
        PASS([id42.chemicalEntity isEqualToString:@"CHEBI:15042"], "ident[42].chemicalEntity");
        PASS(fabs(id42.confidenceScore - (0.5 + 42 * 0.005)) < 1e-12, "ident[42].confidenceScore");
        PASS(id42.evidenceChain.count == 2, "ident[42].evidenceChain length");
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 2. 50 quantifications as compound type ----
    {
        NSMutableArray *quants = [NSMutableArray array];
        for (NSUInteger i = 0; i < 50; i++) {
            [quants addObject:
                [[TTIOQuantification alloc]
                    initWithChemicalEntity:[NSString stringWithFormat:@"CHEBI:%lu",
                                            (unsigned long)(15000 + i)]
                                 sampleRef:[NSString stringWithFormat:@"sample_%lu",
                                            (unsigned long)i]
                                 abundance:1000.0 + (double)i * 25.0
                       normalizationMethod:(i % 3 == 0 ? @"median" : nil)]];
        }

        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_quants"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m11MakeRun(5)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:quants
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"quants");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err], "dataset with 50 quants writes");

        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, "dataset with 50 quants reads");
        PASS(back.quantifications.count == 50, "50 quants round-trip");
        TTIOQuantification *q17 = back.quantifications[17];
        PASS([q17.chemicalEntity isEqualToString:@"CHEBI:15017"], "q[17].chemicalEntity");
        PASS([q17.sampleRef isEqualToString:@"sample_17"], "q[17].sampleRef");
        PASS(fabs(q17.abundance - (1000.0 + 17 * 25.0)) < 1e-12, "q[17].abundance");
        TTIOQuantification *q15 = back.quantifications[15];
        PASS([q15.normalizationMethod isEqualToString:@"median"],
             "q[15].normalizationMethod retained for i%3==0");
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 3. Dataset-level provenance as compound ----
    {
        NSMutableArray *prov = [NSMutableArray array];
        for (NSUInteger i = 0; i < 5; i++) {
            [prov addObject:
                [[TTIOProvenanceRecord alloc]
                    initWithInputRefs:@[[NSString stringWithFormat:@"in:%lu", (unsigned long)i]]
                             software:[NSString stringWithFormat:@"tool_%lu", (unsigned long)i]
                           parameters:@{@"param": @(i)}
                           outputRefs:@[[NSString stringWithFormat:@"out:%lu", (unsigned long)i]]
                        timestampUnix:1700000000 + (int64_t)i]];
        }

        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_prov"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m11MakeRun(5)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:prov
                                           transitions:nil];
        NSString *path = m11path(@"prov");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err], "dataset with provenance writes");

        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(back.provenanceRecords.count == 5, "5 prov records round-trip");
        TTIOProvenanceRecord *r2 = back.provenanceRecords[2];
        PASS([r2.software isEqualToString:@"tool_2"], "prov[2].software");
        PASS(r2.timestampUnix == 1700000002, "prov[2].timestamp");
        PASS([r2.parameters[@"param"] integerValue] == 2, "prov[2].parameters");
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 4. Feature flags written and readable ----
    {
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_flags"
                                    isaInvestigationId:@""
                                                msRuns:@{@"r": m11MakeRun(3)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"flags");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        [ds writeToFilePath:path error:&err];

        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        NSString *fv = [TTIOFeatureFlags formatVersionForRoot:root];
        NSArray *features = [TTIOFeatureFlags featuresForRoot:root];
        PASS([fv isEqualToString:@"1.0"], "format version is 1.0");
        PASS([features containsObject:@"base_v1"], "features: base_v1");
        PASS([features containsObject:@"compound_identifications"],
             "features: compound_identifications");
        PASS([TTIOFeatureFlags root:root
                    supportsFeature:@"compound_quantifications"],
             "supportsFeature: compound_quantifications");
        PASS(![TTIOFeatureFlags isLegacyV1File:root], "not a legacy v0.1 file");
        [f close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 5. v0.1 backward compatibility: legacy file with JSON attributes ----
    {
        // Synthesize a v0.1 layout: @ttio_version = "1.0.0", no
        // @ttio_features, identifications_json / quantifications_json /
        // provenance_json as string attributes on /study.
        NSString *path = m11path(@"v01");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        [root setStringAttribute:@"ttio_version" value:@"1.0.0" error:&err];

        TTIOHDF5Group *study = [root createGroupNamed:@"study" error:&err];
        [study setStringAttribute:@"title" value:@"legacy" error:&err];
        [study setStringAttribute:@"isa_investigation_id" value:@"" error:&err];
        // Empty ms_runs group to satisfy the reader
        TTIOHDF5Group *msg = [study createGroupNamed:@"ms_runs" error:&err];
        [msg setStringAttribute:@"_run_names" value:@"" error:&err];

        NSArray *idPlist = @[ @{
            @"run_name": @"run_0001",
            @"spectrum_index": @5,
            @"chemical_entity": @"CHEBI:99999",
            @"confidence_score": @0.75,
            @"evidence_chain": @[@"legacy_source"]
        } ];
        NSData *idJsonData = [NSJSONSerialization dataWithJSONObject:idPlist options:0 error:&err];
        NSString *idJson = [[NSString alloc] initWithData:idJsonData encoding:NSUTF8StringEncoding];
        [study setStringAttribute:@"identifications_json" value:idJson error:&err];
        [f close];

        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, "legacy v0.1 file reads via fallback");
        PASS(back.identifications.count == 1, "legacy ident count via JSON fallback");
        TTIOIdentification *id_ = back.identifications[0];
        PASS([id_.chemicalEntity isEqualToString:@"CHEBI:99999"],
             "legacy ident entity from JSON");
        PASS(id_.spectrumIndex == 5, "legacy ident spectrumIndex");
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 6. Compound headers queryable via hyperslab ----
    {
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_headers"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m11MakeRun(8)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"headers");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        [ds writeToFilePath:path error:&err];

        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
        TTIOHDF5Group *msg = [study openGroupNamed:@"ms_runs" error:&err];
        TTIOHDF5Group *runG = [msg openGroupNamed:@"run_0001" error:&err];
        TTIOHDF5Group *idxG = [runG openGroupNamed:@"spectrum_index" error:&err];
        PASS([idxG hasChildNamed:@"headers"],
             "compound headers dataset written alongside parallel arrays");

        NSDictionary *row3 = [TTIOCompoundIO readCompoundHeaderRow:3
                                                          fromGroup:idxG
                                                              error:&err];
        PASS(row3 != nil, "compound header row 3 readable via hyperslab");
        PASS([row3[@"length"] unsignedIntValue] == 8, "row[3].length");
        PASS([row3[@"ms_level"] unsignedCharValue] == 2, "row[3].ms_level (k=3 is ms2)");
        PASS(fabs([row3[@"retention_time"] doubleValue] - 1.5) < 1e-9,
             "row[3].retention_time");
        [f close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 7. Perf: 10,000 identifications write/read < 50ms each ----
    {
        NSMutableArray *idents = [NSMutableArray array];
        for (NSUInteger i = 0; i < 10000; i++) {
            [idents addObject:
                [[TTIOIdentification alloc]
                    initWithRunName:@"run_0001"
                      spectrumIndex:i
                     chemicalEntity:[NSString stringWithFormat:@"CHEBI:%lu", (unsigned long)i]
                    confidenceScore:0.5
                      evidenceChain:@[@"MS:1002217"]]];
        }
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_perf"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m11MakeRun(2)}
                                               nmrRuns:@{}
                                       identifications:idents
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"perf");
        unlink([path fileSystemRepresentation]);

        NSDate *tw = [NSDate date];
        NSError *err = nil;
        [ds writeToFilePath:path error:&err];
        NSTimeInterval dw = -[tw timeIntervalSinceNow];

        NSDate *tr = [NSDate date];
        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        NSTimeInterval dr = -[tr timeIntervalSinceNow];

        PASS(back.identifications.count == 10000, "10k idents round-trip");
        printf("    [bench] 10k identifications write %.2f ms, read %.2f ms\n",
               dw * 1000.0, dr * 1000.0);
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 8. closeFile releases handle and lets the encryption path work ----
    {
        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_close"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m11MakeRun(4)}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"close");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        [ds writeToFilePath:path error:&err];

        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(back.filePath != nil, "filePath populated after read");
        PASS([back closeFile], "closeFile succeeds");
        PASS([back closeFile], "closeFile is idempotent");
        unlink([path fileSystemRepresentation]);
    }

    // ---- 9. Dataset-level encrypt + decrypt round-trip ----
    {
        NSMutableArray *idents = [NSMutableArray array];
        for (NSUInteger i = 0; i < 20; i++) {
            [idents addObject:
                [[TTIOIdentification alloc]
                    initWithRunName:@"run_0001"
                      spectrumIndex:i
                     chemicalEntity:[NSString stringWithFormat:@"CHEBI:sec%lu", (unsigned long)i]
                    confidenceScore:0.9
                      evidenceChain:@[@"confidential"]]];
        }
        NSMutableArray *quants = [NSMutableArray array];
        for (NSUInteger i = 0; i < 10; i++) {
            [quants addObject:
                [[TTIOQuantification alloc]
                    initWithChemicalEntity:[NSString stringWithFormat:@"CHEBI:sec%lu", (unsigned long)i]
                                 sampleRef:@"patient_001"
                                 abundance:1.234e6 + (double)i
                       normalizationMethod:@"TIC"]];
        }

        TTIOSpectralDataset *ds =
            [[TTIOSpectralDataset alloc] initWithTitle:@"m11_enc"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": m11MakeRun(6)}
                                               nmrRuns:@{}
                                       identifications:idents
                                       quantifications:quants
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m11path(@"enc");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err], "sensitive dataset writes");

        uint8_t rawKey[32];
        for (int i = 0; i < 32; i++) rawKey[i] = (uint8_t)(i * 7 + 3);
        NSData *key = [NSData dataWithBytes:rawKey length:32];

        ds.accessPolicy = [[TTIOAccessPolicy alloc]
                            initWithPolicy:@{ @"key_id": @"kms-42",
                                              @"subjects": @[@"clinician:alice"] }];
        err = nil;
        BOOL enc = [ds encryptWithKey:key
                                level:TTIOEncryptionLevelDataset
                                error:&err];
        PASS(enc, "dataset-level encrypt succeeds");
        PASS(err == nil, "dataset encrypt no error");

        // Root marker + access policy should be on disk. Wrap the
        // inspection in an autoreleasepool so the HDF5 handles are
        // released before the next RW reopen (MRC test harness).
        @autoreleasepool {
            TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
            TTIOHDF5Group *root = [f rootGroup];
            NSString *marker = [root stringAttributeNamed:@"encrypted" error:&err];
            PASS([marker isEqualToString:@"aes-256-gcm"],
                 "@encrypted marker appears on root");
            NSString *apJson = [root stringAttributeNamed:@"access_policy_json" error:&err];
            PASS(apJson.length > 0, "@access_policy_json persisted");

            // Intensity channel is gone (replaced by *_encrypted).
            TTIOHDF5Group *study = [root openGroupNamed:@"study" error:&err];
            TTIOHDF5Group *msg   = [study openGroupNamed:@"ms_runs" error:&err];
            TTIOHDF5Group *runG  = [msg openGroupNamed:@"run_0001" error:&err];
            TTIOHDF5Group *chans = [runG openGroupNamed:@"signal_channels" error:&err];
            PASS(![chans hasChildNamed:@"intensity_values"],
                 "intensity_values replaced by encrypted variant");
            PASS([chans hasChildNamed:@"intensity_values_encrypted"],
                 "intensity_values_encrypted present");
            PASS([chans hasChildNamed:@"mz_values"],
                 "mz_values still readable without key");

            // Compound idents/quants replaced by sealed blobs.
            PASS(![study hasChildNamed:@"identifications"],
                 "identifications compound removed after encrypt");
            PASS([study hasChildNamed:@"identifications_sealed"],
                 "identifications_sealed blob present");
            PASS(![study hasChildNamed:@"quantifications"],
                 "quantifications compound removed after encrypt");
            PASS([study hasChildNamed:@"quantifications_sealed"],
                 "quantifications_sealed blob present");
            [f close];
        }

        // Decrypt round-trip: reload, decrypt, reload, compare.
        TTIOSpectralDataset *sealed =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(sealed.identifications.count == 0,
             "sealed dataset reads with empty idents before decrypt");
        PASS([sealed decryptWithKey:key error:&err], "decryptWithKey succeeds");

        TTIOSpectralDataset *restored =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(restored.identifications.count == 20,
             "identifications restored after decrypt");
        PASS(restored.quantifications.count == 10,
             "quantifications restored after decrypt");
        TTIOIdentification *i0 = restored.identifications[0];
        PASS([i0.chemicalEntity isEqualToString:@"CHEBI:sec0"],
             "restored ident content");
        [sealed closeFile];
        [restored closeFile];
        unlink([path fileSystemRepresentation]);
    }
}
