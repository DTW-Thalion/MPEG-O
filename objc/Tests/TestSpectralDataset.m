#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "Dataset/MPGOTransitionList.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>

static NSString *dsPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_ds_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *f64Array(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static MPGOMassSpectrum *miniSpectrum(NSUInteger k, double rt)
{
    double mz[5] = { 100 + k, 200 + k, 300 + k, 400 + k, 500 + k };
    double in[5] = { 1, 2, 3, 4, 5 };
    NSError *err = nil;
    return [[MPGOMassSpectrum alloc] initWithMzArray:f64Array(mz, 5)
                                      intensityArray:f64Array(in, 5)
                                             msLevel:1
                                            polarity:MPGOPolarityPositive
                                          scanWindow:nil
                                       indexPosition:k
                                     scanTimeSeconds:rt
                                         precursorMz:0
                                     precursorCharge:0
                                               error:&err];
}

static MPGOAcquisitionRun *miniMSRun(NSUInteger n, NSString *modelLabel)
{
    NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger k = 0; k < n; k++) {
        [spectra addObject:miniSpectrum(k, (double)k * 0.5)];
    }
    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@"Thermo"
                                                     model:modelLabel
                                              serialNumber:@"SN"
                                                sourceType:@"ESI"
                                              analyzerType:@"Orbitrap"
                                              detectorType:@"em"];
    return [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:MPGOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

static MPGONMRSpectrum *miniNMRSpectrum(NSString *nucleus, NSUInteger n)
{
    double *cs = malloc(n * sizeof(double));
    double *in = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) { cs[i] = (double)i * 0.01; in[i] = (double)i; }
    MPGOSignalArray *csA = f64Array(cs, n);
    MPGOSignalArray *inA = f64Array(in, n);
    free(cs); free(in);
    NSError *err = nil;
    return [[MPGONMRSpectrum alloc] initWithChemicalShiftArray:csA
                                                 intensityArray:inA
                                                    nucleusType:nucleus
                                       spectrometerFrequencyMHz:600.13
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:&err];
}

void testSpectralDataset(void)
{
    // ---- build a dataset: 2 MS runs + 1 NMR run, 10 idents, 5 quants, multi-step provenance ----
    MPGOAcquisitionRun *runA = miniMSRun(10, @"Q Exactive HF");
    MPGOAcquisitionRun *runB = miniMSRun(8,  @"Orbitrap Exploris");

    NSArray *nmrRunSpectra = @[
        miniNMRSpectrum(@"1H",  256),
        miniNMRSpectrum(@"13C", 512)
    ];

    NSMutableArray *idents = [NSMutableArray arrayWithCapacity:10];
    for (int i = 0; i < 10; i++) {
        [idents addObject:
            [[MPGOIdentification alloc] initWithRunName:(i % 2 == 0 ? @"run_A" : @"run_B")
                                          spectrumIndex:(NSUInteger)(i % 5)
                                         chemicalEntity:[NSString stringWithFormat:@"CHEBI:%d", 10000 + i]
                                        confidenceScore:0.95 - (double)i * 0.01
                                          evidenceChain:@[ @"MS:1002217", @"manual_review" ]]];
    }

    NSMutableArray *quants = [NSMutableArray arrayWithCapacity:5];
    for (int i = 0; i < 5; i++) {
        [quants addObject:
            [[MPGOQuantification alloc] initWithChemicalEntity:[NSString stringWithFormat:@"CHEBI:%d", 10000 + i]
                                                     sampleRef:@"sample_001"
                                                     abundance:1.0e6 + (double)i * 1.0e5
                                           normalizationMethod:@"median"]];
    }

    NSArray *provenance = @[
        [[MPGOProvenanceRecord alloc] initWithInputRefs:@[ @"raw://instrument-001/scan_2026.raw" ]
                                                software:@"ProteoWizard msconvert 3.0.21"
                                              parameters:@{ @"format": @"mzml" }
                                              outputRefs:@[ @"derived://run_A.mzml" ]
                                           timestampUnix:1700000000],
        [[MPGOProvenanceRecord alloc] initWithInputRefs:@[ @"derived://run_A.mzml" ]
                                                software:@"OpenMS FeatureFinderCentroided 3.1"
                                              parameters:@{ @"mass_tolerance_ppm": @5 }
                                              outputRefs:@[ @"derived://run_A.featureXML" ]
                                           timestampUnix:1700000100],
        [[MPGOProvenanceRecord alloc] initWithInputRefs:@[ @"derived://run_A.featureXML",
                                                            @"db://chebi_2026" ]
                                                software:@"MetFrag 2.5"
                                              parameters:@{ @"score_threshold": @0.7 }
                                              outputRefs:@[ @"ident://run_A.csv" ]
                                           timestampUnix:1700000200]
    ];

    MPGOValueRange *rtWin = [MPGOValueRange rangeWithMinimum:30 maximum:60];
    MPGOTransition *t1 =
        [[MPGOTransition alloc] initWithPrecursorMz:524.30
                                          productMz:396.20
                                    collisionEnergy:25.0
                                retentionTimeWindow:rtWin];
    MPGOTransition *t2 =
        [[MPGOTransition alloc] initWithPrecursorMz:524.30
                                          productMz:255.10
                                    collisionEnergy:35.0
                                retentionTimeWindow:rtWin];
    MPGOTransitionList *tl = [[MPGOTransitionList alloc] initWithTransitions:@[ t1, t2 ]];

    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"Smoke study"
                                isaInvestigationId:@"ISA-001"
                                            msRuns:@{ @"run_A": runA, @"run_B": runB }
                                           nmrRuns:@{ @"nmr_run_1": nmrRunSpectra }
                                   identifications:idents
                                   quantifications:quants
                                 provenanceRecords:provenance
                                       transitions:tl];

    // ---- write ----
    NSString *path = dsPath(@"multi");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([ds writeToFilePath:path error:&err], "multi-run dataset writes");
    PASS(err == nil, "no error on write");

    // ---- reopen ----
    MPGOSpectralDataset *back =
        [MPGOSpectralDataset readFromFilePath:path error:&err];
    PASS(back != nil, "multi-run dataset reads back");
    PASS([back.title isEqualToString:@"Smoke study"], "title round-trips");
    PASS([back.isaInvestigationId isEqualToString:@"ISA-001"], "isa id round-trips");

    // MS runs
    PASS(back.msRuns.count == 2, "2 MS runs round-trip");
    PASS([back.msRuns[@"run_A"] count] == 10, "run_A spectrum count preserved");
    PASS([back.msRuns[@"run_B"] count] == 8,  "run_B spectrum count preserved");
    MPGOMassSpectrum *spec5 = [back.msRuns[@"run_A"] spectrumAtIndex:5 error:&err];
    PASS(spec5 != nil, "spectrum 5 of run_A reads via random access");
    PASS(spec5.mzArray.length == 5, "spectrum 5 length matches");
    PASS([back.msRuns[@"run_A"].instrumentConfig.model isEqualToString:@"Q Exactive HF"],
         "run_A instrument model preserved");
    PASS([back.msRuns[@"run_B"].instrumentConfig.model isEqualToString:@"Orbitrap Exploris"],
         "run_B instrument model preserved");

    // NMR run
    PASS(back.nmrRuns.count == 1, "1 NMR run round-trips");
    NSArray *nmrBack = back.nmrRuns[@"nmr_run_1"];
    PASS(nmrBack.count == 2, "NMR run has 2 spectra");
    PASS([[nmrBack[0] nucleusType] isEqualToString:@"1H"], "first NMR spectrum nucleus preserved");
    PASS([[nmrBack[1] nucleusType] isEqualToString:@"13C"], "second NMR spectrum nucleus preserved");

    // Identifications
    PASS(back.identifications.count == 10, "10 identifications round-trip");
    MPGOIdentification *ident0 = back.identifications[0];
    PASS([ident0.chemicalEntity isEqualToString:@"CHEBI:10000"], "first ident entity");
    PASS(fabs(ident0.confidenceScore - 0.95) < 1e-12, "first ident score preserved");
    PASS([ident0.evidenceChain.firstObject isEqualToString:@"MS:1002217"],
         "evidence chain preserved");

    // Quantifications
    PASS(back.quantifications.count == 5, "5 quantifications round-trip");
    PASS([back.quantifications[2].normalizationMethod isEqualToString:@"median"],
         "quantification normalization method preserved");

    // Provenance
    PASS(back.provenanceRecords.count == 3, "3 provenance records round-trip");
    PASS([back.provenanceRecords[1].software hasPrefix:@"OpenMS"], "provenance software preserved");
    PASS([[back.provenanceRecords[2].parameters objectForKey:@"score_threshold"] doubleValue] == 0.7,
         "provenance parameters preserved");

    // ---- provenance query by input ref ----
    NSArray *byRaw =
        [back provenanceRecordsForInputRef:@"raw://instrument-001/scan_2026.raw"];
    PASS(byRaw.count == 1, "1 record references the raw scan");
    NSArray *byMzml = [back provenanceRecordsForInputRef:@"derived://run_A.mzml"];
    PASS(byMzml.count == 1, "1 record references the converted mzML");
    NSArray *byChebi = [back provenanceRecordsForInputRef:@"db://chebi_2026"];
    PASS(byChebi.count == 1, "1 record references the chebi database");
    PASS([[byChebi.firstObject software] hasPrefix:@"MetFrag"], "chebi-input record is MetFrag");
    NSArray *missing = [back provenanceRecordsForInputRef:@"raw://does-not-exist"];
    PASS(missing.count == 0, "absent input ref returns empty");

    // ---- transitions ----
    PASS(back.transitions != nil, "transition list round-trips");
    PASS(back.transitions.count == 2, "2 transitions round-trip");
    MPGOTransition *bt1 = [back.transitions transitionAtIndex:0];
    PASS(bt1.precursorMz == 524.30, "transition precursor mz preserved");
    PASS(bt1.productMz   == 396.20, "transition product mz preserved");
    PASS(bt1.collisionEnergy == 25.0, "collision energy preserved");
    PASS(bt1.retentionTimeWindow.minimum == 30 &&
         bt1.retentionTimeWindow.maximum == 60,
         "RT window preserved");

    unlink([path fileSystemRepresentation]);
}
