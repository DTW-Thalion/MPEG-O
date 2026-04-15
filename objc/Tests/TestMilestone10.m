#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "Query/MPGOQuery.h"
#import "Query/MPGOStreamReader.h"
#import "Query/MPGOStreamWriter.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "HDF5/MPGOHDF5Types.h"
#import "Protection/MPGOEncryptionManager.h"
#import <math.h>
#import <unistd.h>

static NSString *m10path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m10_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *f64(const double *src, NSUInteger n)
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

static MPGOInstrumentConfig *emptyConfig(void)
{
    return [[MPGOInstrumentConfig alloc] initWithManufacturer:@""
                                                        model:@""
                                                 serialNumber:@""
                                                   sourceType:@""
                                                 analyzerType:@""
                                                 detectorType:@""];
}

static MPGOMassSpectrum *makeMS(NSUInteger k, NSUInteger n)
{
    double *mz = malloc(n * sizeof(double));
    double *in = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        mz[i] = 100.0 + (double)i * 0.5;
        in[i] = 1000.0 + (double)(k * 10 + i);
    }
    MPGOSignalArray *mzA = f64(mz, n);
    MPGOSignalArray *inA = f64(in, n);
    free(mz); free(in);
    return [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                      intensityArray:inA
                                             msLevel:(k % 3 == 0 ? 1 : 2)
                                            polarity:MPGOPolarityPositive
                                          scanWindow:nil
                                       indexPosition:k
                                     scanTimeSeconds:(double)k * 0.1
                                         precursorMz:0
                                     precursorCharge:0
                                               error:NULL];
}

static MPGONMRSpectrum *makeNMR(NSUInteger k, NSUInteger n)
{
    double *cs = malloc(n * sizeof(double));
    double *in = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        cs[i] = -1.0 + (double)i * 0.01;
        in[i] = sin((double)(k * 10 + i) * 0.1) * 1000.0;
    }
    MPGOSignalArray *csA = f64(cs, n);
    MPGOSignalArray *inA = f64(in, n);
    free(cs); free(in);
    return [[MPGONMRSpectrum alloc] initWithChemicalShiftArray:csA
                                                intensityArray:inA
                                                   nucleusType:@"1H"
                                      spectrometerFrequencyMHz:600.13
                                                 indexPosition:k
                                               scanTimeSeconds:(double)k * 0.25
                                                         error:NULL];
}

void testMilestone10(void)
{
    // ---- 1. MS 100-spectrum run still round-trips (preserves v0.1 layout) ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 100; k++) [spectra addObject:makeMS(k, 20)];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionModeMS1DDA
                                       instrumentConfig:emptyConfig()];
        PASS([run.spectrumClassName isEqualToString:@"MPGOMassSpectrum"],
             "MS run stores spectrumClassName");
        PASS(run.count == 100, "100 MS spectra indexed");

        NSString *path = m10path(@"ms100");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS(f != nil, "MS round-trip: file created");
        PASS([run writeToGroup:[f rootGroup] name:@"r" error:&err], "MS run writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOAcquisitionRun *back =
            [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"r" error:&err];
        PASS(back != nil, "MS run reads back");
        PASS(back.count == 100, "MS read-back count matches");
        PASS([back.spectrumClassName isEqualToString:@"MPGOMassSpectrum"],
             "MS class round-trips");

        MPGOMassSpectrum *s50 = [back spectrumAtIndex:50 error:&err];
        PASS([s50 isKindOfClass:[MPGOMassSpectrum class]],
             "MS spec50 is MPGOMassSpectrum");
        PASS(s50.mzArray.length == 20, "MS spec50 mz length correct");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 2. NMR 50-spectrum run: write → read → verify arrays ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 50; k++) [spectra addObject:makeNMR(k, 32)];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionMode1DNMR
                                       instrumentConfig:emptyConfig()];
        PASS([run.spectrumClassName isEqualToString:@"MPGONMRSpectrum"],
             "NMR run stores spectrumClassName");
        PASS([run.nucleusType isEqualToString:@"1H"], "NMR nucleus propagated");
        PASS(run.spectrometerFrequencyMHz == 600.13, "NMR frequency propagated");

        NSString *path = m10path(@"nmr50");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([run writeToGroup:[f rootGroup] name:@"r" error:&err], "NMR run writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOAcquisitionRun *back =
            [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"r" error:&err];
        PASS(back != nil, "NMR run reads back");
        PASS(back.count == 50, "NMR read-back count matches");
        PASS([back.spectrumClassName isEqualToString:@"MPGONMRSpectrum"],
             "NMR class round-trips");
        PASS([back.nucleusType isEqualToString:@"1H"], "NMR nucleus round-trips");
        PASS(back.spectrometerFrequencyMHz == 600.13, "NMR frequency round-trips");

        MPGONMRSpectrum *s10 = [back spectrumAtIndex:10 error:&err];
        PASS([s10 isKindOfClass:[MPGONMRSpectrum class]],
             "NMR spec10 is MPGONMRSpectrum");
        PASS(s10.chemicalShiftArray.length == 32, "NMR cs array length");
        PASS(s10.intensityArray.length == 32, "NMR intensity array length");
        PASS([s10.nucleusType isEqualToString:@"1H"], "NMR per-spectrum nucleus");

        // Sample-check a value: spectrum 10, element 5, intensity
        double expected = sin((double)(10 * 10 + 5) * 0.1) * 1000.0;
        double got = ((const double *)s10.intensityArray.buffer.bytes)[5];
        PASS(fabs(got - expected) < 1e-9, "NMR intensity sample-exact");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 3. Per-run provenance: add 3 steps, round-trip ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 20; k++) [spectra addObject:makeMS(k, 10)];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionModeMS1DDA
                                       instrumentConfig:emptyConfig()];
        MPGOProvenanceRecord *r1 =
            [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"raw:001"]
                                                    software:@"vendor_convert"
                                                  parameters:@{@"mode": @"centroid"}
                                                  outputRefs:@[@"mzml:001"]
                                               timestampUnix:1700000000];
        MPGOProvenanceRecord *r2 =
            [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"mzml:001"]
                                                    software:@"MPGO_import"
                                                  parameters:@{}
                                                  outputRefs:@[@"mpgo:001"]
                                               timestampUnix:1700000100];
        MPGOProvenanceRecord *r3 =
            [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"mpgo:001"]
                                                    software:@"MPGO_peak_pick"
                                                  parameters:@{@"snr": @5}
                                                  outputRefs:@[@"mpgo:001:peaks"]
                                               timestampUnix:1700000200];
        [run addProcessingStep:r1];
        [run addProcessingStep:r2];
        [run addProcessingStep:r3];
        PASS(run.provenanceChain.count == 3, "3 provenance steps appended");

        NSString *path = m10path(@"prov");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([run writeToGroup:[f rootGroup] name:@"r" error:&err],
             "run with provenance writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOAcquisitionRun *back =
            [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"r" error:&err];
        PASS(back.provenanceChain.count == 3, "3 provenance steps round-trip");
        MPGOProvenanceRecord *rb1 = back.provenanceChain[0];
        PASS([rb1.software isEqualToString:@"vendor_convert"],
             "first step software preserved");
        PASS([back.inputEntities count] == 3, "inputEntities aggregated");
        PASS([back.outputEntities count] == 3, "outputEntities aggregated");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 4. Encryption via run's protocol method (requires persistence) ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 10; k++) [spectra addObject:makeMS(k, 15)];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionModeMS1DDA
                                       instrumentConfig:emptyConfig()];

        // In-memory encrypt should fail with a clear error.
        NSError *err = nil;
        uint8_t rawKey[32];
        for (int i = 0; i < 32; i++) rawKey[i] = (uint8_t)i;
        NSData *key = [NSData dataWithBytes:rawKey length:32];
        PASS(![run encryptWithKey:key
                            level:MPGOEncryptionLevelDataset
                            error:&err],
             "in-memory encrypt rejected");
        PASS(err != nil, "in-memory encrypt populates error");

        // Persist the run at the HDF5 root (the encryption manager's
        // deprecated API expects a top-level run). The protocol test
        // exercises the wiring: run -> persistence context -> manager.
        NSString *path = m10path(@"enc");
        unlink([path fileSystemRepresentation]);
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([run writeToGroup:[f rootGroup] name:@"run_0001" error:&err],
             "run written at root for enc test");
        [f close];

        MPGOAcquisitionRun *ctx =
            [[MPGOAcquisitionRun alloc] initWithSpectra:@[]
                                        acquisitionMode:MPGOAcquisitionModeMS1DDA
                                       instrumentConfig:emptyConfig()];
        [ctx setPersistenceFilePath:path runName:@"run_0001"];

        err = nil;
        BOOL enc = [ctx encryptWithKey:key
                                 level:MPGOEncryptionLevelDataset
                                 error:&err];
        PASS(enc, "protocol encrypt succeeds with persistence context");
        PASS(err == nil, "protocol encrypt no error");

        // And the decrypt side of the protocol.
        err = nil;
        PASS([ctx decryptWithKey:key error:&err],
             "protocol decrypt succeeds with persistence context");
        unlink([path fileSystemRepresentation]);
    }

    // ---- 5. Query on NMR runs: RT range predicate ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 40; k++) [spectra addObject:makeNMR(k, 16)];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionMode1DNMR
                                       instrumentConfig:emptyConfig()];
        // scanTime = k * 0.25 → RT in [5.0, 7.5] selects k ∈ [20, 30]
        MPGOValueRange *r = [MPGOValueRange rangeWithMinimum:5.0 maximum:7.5];
        NSIndexSet *hits =
            [[[MPGOQuery queryOnIndex:run.spectrumIndex]
                withRetentionTimeRange:r]
                matchingIndices];
        PASS(hits.count == 11, "NMR RT range yields expected count");
    }

    // ---- 6. Streaming NMR run via MPGOStreamReader ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 25; k++) [spectra addObject:makeNMR(k, 8)];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionMode1DNMR
                                       instrumentConfig:emptyConfig()];
        NSString *path = m10path(@"nmrstream");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        [run writeToGroup:[f rootGroup] name:@"r" error:&err];
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOAcquisitionRun *back =
            [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"r" error:&err];

        NSUInteger seen = 0;
        [back reset];
        while ([back hasMore]) {
            id s = [back nextObject];
            PASS([s isKindOfClass:[MPGONMRSpectrum class]],
                 "streamed element is NMR spectrum");
            seen++;
            if (seen >= 25) break;
        }
        PASS(seen == 25, "NMR streaming visits all 25 spectra");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 7. v0.1 backward compatibility: synthesize legacy layout inline ----
    {
        NSString *path = m10path(@"v01compat");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        MPGOHDF5Group *root = [f rootGroup];

        // Build a v0.1-style layout: no @spectrum_class, no @channel_names,
        // hardcoded mz_values + intensity_values. Five spectra of 4 peaks each.
        MPGOHDF5Group *runG = [root createGroupNamed:@"r" error:&err];
        PASS([runG setIntegerAttribute:@"acquisition_mode" value:0 error:&err],
             "legacy run: acquisition_mode written");
        PASS([runG setIntegerAttribute:@"spectrum_count" value:5 error:&err],
             "legacy run: spectrum_count written");

        // Instrument config: empty strings under instrument_config/
        MPGOInstrumentConfig *cfg = emptyConfig();
        PASS([cfg writeToGroup:runG error:&err],
             "legacy run: instrument_config written");

        // Spectrum index: parallel datasets
        const NSUInteger N = 5;
        const NSUInteger peaksPerSpec = 4;
        const NSUInteger totalPeaks = N * peaksPerSpec;

        uint64_t offsets[5]; for (NSUInteger i = 0; i < N; i++) offsets[i] = i * peaksPerSpec;
        uint32_t lengths[5]; for (NSUInteger i = 0; i < N; i++) lengths[i] = peaksPerSpec;
        double   rts[5];     for (NSUInteger i = 0; i < N; i++) rts[i] = (double)i;
        int32_t  mls[5];     for (NSUInteger i = 0; i < N; i++) mls[i] = 1;
        int32_t  pols[5];    for (NSUInteger i = 0; i < N; i++) pols[i] = 1;
        double   pmzs[5];    for (NSUInteger i = 0; i < N; i++) pmzs[i] = 0;
        int32_t  pcs[5];     for (NSUInteger i = 0; i < N; i++) pcs[i] = 0;
        double   bps[5];     for (NSUInteger i = 0; i < N; i++) bps[i] = 100.0 + (double)i;

        NSData *offD  = [NSData dataWithBytes:offsets length:sizeof(offsets)];
        NSData *lenD  = [NSData dataWithBytes:lengths length:sizeof(lengths)];
        NSData *rtD   = [NSData dataWithBytes:rts     length:sizeof(rts)];
        NSData *mlD   = [NSData dataWithBytes:mls     length:sizeof(mls)];
        NSData *polD  = [NSData dataWithBytes:pols    length:sizeof(pols)];
        NSData *pmzD  = [NSData dataWithBytes:pmzs    length:sizeof(pmzs)];
        NSData *pcD   = [NSData dataWithBytes:pcs     length:sizeof(pcs)];
        NSData *bpD   = [NSData dataWithBytes:bps     length:sizeof(bps)];

        MPGOSpectrumIndex *idx =
            [[MPGOSpectrumIndex alloc] initWithOffsets:offD
                                               lengths:lenD
                                        retentionTimes:rtD
                                              msLevels:mlD
                                            polarities:polD
                                          precursorMzs:pmzD
                                      precursorCharges:pcD
                                   basePeakIntensities:bpD];
        PASS([idx writeToGroup:runG error:&err],
             "legacy run: spectrum_index written");

        // Legacy signal channels: hardcoded mz_values + intensity_values,
        // no @channel_names attribute.
        MPGOHDF5Group *channels = [runG createGroupNamed:@"signal_channels" error:&err];
        double mzAll[20], inAll[20];
        for (NSUInteger s = 0; s < N; s++) {
            for (NSUInteger k = 0; k < peaksPerSpec; k++) {
                mzAll[s * peaksPerSpec + k] = 100.0 + (double)(s * peaksPerSpec + k);
                inAll[s * peaksPerSpec + k] = (double)(s + 1) * 10.0 + (double)k;
            }
        }
        MPGOHDF5Dataset *mzDS = [channels createDatasetNamed:@"mz_values"
                                                    precision:MPGOPrecisionFloat64
                                                       length:totalPeaks
                                                    chunkSize:16384
                                             compressionLevel:6
                                                        error:&err];
        PASS([mzDS writeData:[NSData dataWithBytes:mzAll length:sizeof(mzAll)] error:&err],
             "legacy mz_values written");
        MPGOHDF5Dataset *inDS = [channels createDatasetNamed:@"intensity_values"
                                                    precision:MPGOPrecisionFloat64
                                                       length:totalPeaks
                                                    chunkSize:16384
                                             compressionLevel:6
                                                        error:&err];
        PASS([inDS writeData:[NSData dataWithBytes:inAll length:sizeof(inAll)] error:&err],
             "legacy intensity_values written");
        [f close];

        // Now read via the v0.2 MPGOAcquisitionRun reader
        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOAcquisitionRun *back =
            [MPGOAcquisitionRun readFromGroup:[g rootGroup] name:@"r" error:&err];
        PASS(back != nil, "legacy v0.1 layout loads via v0.2 reader");
        PASS([back.spectrumClassName isEqualToString:@"MPGOMassSpectrum"],
             "legacy run defaults to MPGOMassSpectrum");
        PASS(back.count == 5, "legacy run reports 5 spectra");

        MPGOMassSpectrum *s2 = [back spectrumAtIndex:2 error:&err];
        PASS([s2 isKindOfClass:[MPGOMassSpectrum class]],
             "legacy spectrum materializes as MPGOMassSpectrum");
        PASS(s2.mzArray.length == 4, "legacy spectrum 2 length = 4");
        const double *mz = s2.mzArray.buffer.bytes;
        PASS(fabs(mz[0] - 108.0) < 1e-9, "legacy spectrum 2 mz[0] matches");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 8. MPGOSpectralDataset NMR run via msRuns (generalized) ----
    {
        NSMutableArray *spectra = [NSMutableArray array];
        for (NSUInteger k = 0; k < 15; k++) [spectra addObject:makeNMR(k, 16)];
        MPGOAcquisitionRun *nmrRun =
            [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                        acquisitionMode:MPGOAcquisitionMode1DNMR
                                       instrumentConfig:emptyConfig()];
        MPGOSpectralDataset *ds =
            [[MPGOSpectralDataset alloc] initWithTitle:@"m10_unified"
                                    isaInvestigationId:@""
                                                msRuns:@{@"nmr_run": nmrRun}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m10path(@"unified");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([ds writeToFilePath:path error:&err], "unified dataset writes");
        MPGOSpectralDataset *back =
            [MPGOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, "unified dataset reads back");
        MPGOAcquisitionRun *r = back.msRuns[@"nmr_run"];
        PASS(r != nil, "NMR run lives in msRuns dict");
        PASS([r.spectrumClassName isEqualToString:@"MPGONMRSpectrum"],
             "unified: run holds NMR spectra");
        MPGONMRSpectrum *s = [r spectrumAtIndex:7 error:&err];
        PASS([s isKindOfClass:[MPGONMRSpectrum class]],
             "unified: reconstructed as NMR");
        unlink([path fileSystemRepresentation]);
    }
}
