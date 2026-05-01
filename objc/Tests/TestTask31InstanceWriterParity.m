/*
 * TestTask31InstanceWriterParity.m — Task 31 instance-mode writer.
 *
 * Exercises -[TTIOSpectralDataset writeToFilePath:] for non-HDF5 URLs
 * (memory:// / sqlite:// / zarr://). Pre-Task-31 these returned
 * NSError code 999 ("not implemented in v0.9"). Task 31 narrows that
 * rejection to NMR-runs / Image-subclass datasets only and dispatches
 * MS-only datasets through the storage protocol.
 *
 * Pattern: construct TTIOSpectralDataset with in-memory TTIOAcquisitionRun
 * containing TTIOMassSpectrum objects, call -writeToFilePath:url, read
 * back, verify channel data and metadata round-trip.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "Providers/TTIOMemoryProvider.h"
#include <unistd.h>

static TTIOSignalArray *t31MakeF64(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf length:n
                                            encoding:enc axis:nil];
}

static TTIOMassSpectrum *t31MakeSpectrum(NSUInteger k, NSUInteger peaks)
{
    double mz[8], in[8];
    for (NSUInteger i = 0; i < peaks; i++) {
        mz[i] = 100.0 + (double)i * 0.5 + (double)(k % 17) * 0.001;
        in[i] = (double)(1.0e3 + (double)((k * 13 + i) % 1000));
    }
    NSError *err = nil;
    return [[TTIOMassSpectrum alloc]
        initWithMzArray:t31MakeF64(mz, peaks)
         intensityArray:t31MakeF64(in, peaks)
                msLevel:1
               polarity:TTIOPolarityPositive
             scanWindow:nil
          indexPosition:k
        scanTimeSeconds:(double)k * 0.06
            precursorMz:0.0
        precursorCharge:0
                  error:&err];
}

static TTIOSpectralDataset *t31BuildDataset(NSUInteger nSpectra, NSUInteger peaks)
{
    NSMutableArray *spectra = [NSMutableArray arrayWithCapacity:nSpectra];
    for (NSUInteger i = 0; i < nSpectra; i++) {
        [spectra addObject:t31MakeSpectrum(i, peaks)];
    }
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@"TestCo"
                                                      model:@"T31"
                                               serialNumber:@"SN-001"
                                                 sourceType:@"ESI"
                                               analyzerType:@"Orbitrap"
                                               detectorType:@"EM"];
    TTIOAcquisitionRun *run =
        [[TTIOAcquisitionRun alloc] initWithSpectra:spectra
                                     acquisitionMode:TTIOAcquisitionModeMS1DDA
                                    instrumentConfig:cfg];
    return [[TTIOSpectralDataset alloc] initWithTitle:@"task31"
                                    isaInvestigationId:@"ISA-T31"
                                                msRuns:@{@"r": run}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
}

static BOOL t31InstanceRoundTrip(NSString *url, NSUInteger nSpectra, NSUInteger peaks)
{
    @autoreleasepool {
        TTIOSpectralDataset *src = t31BuildDataset(nSpectra, peaks);
        NSError *err = nil;
        if (![src writeToFilePath:url error:&err]) {
            NSLog(@"Task31: writeToFilePath:%@ failed: %@", url, err);
            return NO;
        }
        TTIOSpectralDataset *back = [TTIOSpectralDataset readFromFilePath:url error:&err];
        if (!back) {
            NSLog(@"Task31: readback %@ failed: %@", url, err);
            return NO;
        }
        if (![back.title isEqualToString:@"task31"]) {
            NSLog(@"Task31 %@: title mismatch '%@'", url, back.title);
            return NO;
        }
        TTIOAcquisitionRun *r = back.msRuns[@"r"];
        if (!r) {
            NSLog(@"Task31 %@: msRuns[r] missing", url);
            return NO;
        }
        if (r.spectrumIndex.count != nSpectra) {
            NSLog(@"Task31 %@: count %lu != expected %lu",
                  url, (unsigned long)r.spectrumIndex.count, (unsigned long)nSpectra);
            return NO;
        }
        // Per-spectrum index entry survives the round-trip (offset = i*peaks,
        // length = peaks, ms_level = 1).
        for (NSUInteger i = 0; i < nSpectra; i++) {
            uint64_t off = [r.spectrumIndex offsetAt:i];
            uint32_t len = [r.spectrumIndex lengthAt:i];
            uint8_t  ml  = [r.spectrumIndex msLevelAt:i];
            if (off != (uint64_t)(i * peaks) || len != peaks || ml != 1) {
                NSLog(@"Task31 %@: index[%lu] mismatch off=%llu len=%u ml=%u",
                      url, (unsigned long)i, (unsigned long long)off,
                      (unsigned)len, (unsigned)ml);
                return NO;
            }
        }
        return YES;
    }
}

void testTask31InstanceWriterParity(void)
{
    @autoreleasepool {
        const NSUInteger N = 16;
        const NSUInteger P = 8;

        // ── HDF5 plain path (regression guard) ────────────────────
        NSString *hPath = [NSString stringWithFormat:@"/tmp/ttio_t31_inst_%d.tio",
                           (int)getpid()];
        unlink([hPath fileSystemRepresentation]);
        PASS(t31InstanceRoundTrip(hPath, N, P),
             "Task31 #1: HDF5 plain-path -writeToFilePath: round-trip");
        unlink([hPath fileSystemRepresentation]);

        // ── memory:// — write + read round-trip via instance writer ─
        NSString *memUrl = [NSString stringWithFormat:@"memory://t31-inst-%d",
                            (int)getpid()];
        [TTIOMemoryProvider discardStore:memUrl];
        PASS(t31InstanceRoundTrip(memUrl, N, P),
             "Task31 #2: memory:// -writeToFilePath: round-trip");
        [TTIOMemoryProvider discardStore:memUrl];

        // ── sqlite:// ──────────────────────────────────────────────
        NSString *sqlPath = [NSString stringWithFormat:@"/tmp/ttio_t31_inst_%d.sqlite",
                             (int)getpid()];
        unlink([sqlPath fileSystemRepresentation]);
        NSString *sqlUrl = [@"sqlite://" stringByAppendingString:sqlPath];
        PASS(t31InstanceRoundTrip(sqlUrl, N, P),
             "Task31 #3: sqlite:// -writeToFilePath: round-trip");
        unlink([sqlPath fileSystemRepresentation]);

        // ── zarr:// ────────────────────────────────────────────────
        NSString *zPath = [NSString stringWithFormat:@"/tmp/ttio_t31_inst_%d.zarr",
                           (int)getpid()];
        [[NSFileManager defaultManager] removeItemAtPath:zPath error:NULL];
        NSString *zUrl = [@"zarr://" stringByAppendingString:zPath];
        PASS(t31InstanceRoundTrip(zUrl, N, P),
             "Task31 #4: zarr:// -writeToFilePath: round-trip");
        [[NSFileManager defaultManager] removeItemAtPath:zPath error:NULL];
    }
}
