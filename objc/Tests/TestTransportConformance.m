/*
 * TestTransportConformance — v0.10 M70.
 *
 * In-language .mpgo → .mots → .mpgo round-trip with signal values
 * preserved bit-for-bit.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#include <math.h>

#import "Transport/MPGOTransportWriter.h"
#import "Transport/MPGOTransportReader.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOWrittenRun.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Spectra/MPGOSpectrum.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *tmp(NSString *n) {
    return [NSString stringWithFormat:@"/tmp/mpgo_m70_%d_%@", (int)getpid(), n];
}
static void rm(NSString *p) { [[NSFileManager defaultManager] removeItemAtPath:p error:NULL]; }

static NSData *f64le(const double *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}
static NSData *i32arr(const int32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u32arr(const uint32_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:4];
    return d;
}
static NSData *u64arr(const uint64_t *v, NSUInteger n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (NSUInteger i = 0; i < n; i++) [d appendBytes:&v[i] length:8];
    return d;
}

static BOOL buildDataset(NSString *path, NSUInteger nRuns,
                           NSUInteger nSpectra, NSUInteger pointsPerSpectrum,
                           NSError **error)
{
    NSMutableDictionary<NSString *, MPGOWrittenRun *> *runMap = [NSMutableDictionary dictionary];
    for (NSUInteger r = 0; r < nRuns; r++) {
        NSUInteger total = nSpectra * pointsPerSpectrum;
        double *mz = calloc(total, sizeof(double));
        double *intensity = calloc(total, sizeof(double));
        for (NSUInteger i = 0; i < total; i++) {
            mz[i] = 100.0 * (r + 1) + (double)i;
            intensity[i] = 100.0 * (r + 1) * (double)(i + 1);
        }
        uint64_t *offsets = calloc(nSpectra, sizeof(uint64_t));
        uint32_t *lengths = calloc(nSpectra, sizeof(uint32_t));
        for (NSUInteger i = 0; i < nSpectra; i++) {
            offsets[i] = (uint64_t)(i * pointsPerSpectrum);
            lengths[i] = (uint32_t)pointsPerSpectrum;
        }
        double *rts = calloc(nSpectra, sizeof(double));
        int32_t *msLevels = calloc(nSpectra, sizeof(int32_t));
        int32_t *pols = calloc(nSpectra, sizeof(int32_t));
        double *pmzs = calloc(nSpectra, sizeof(double));
        int32_t *pcs = calloc(nSpectra, sizeof(int32_t));
        double *bpis = calloc(nSpectra, sizeof(double));
        for (NSUInteger i = 0; i < nSpectra; i++) {
            rts[i] = 1.0 + (double)i;
            msLevels[i] = (i % 2 == 0) ? 1 : 2;
            pols[i] = 1;
            pmzs[i] = msLevels[i] == 1 ? 0.0 : 500.0 + (double)i;
            pcs[i] = msLevels[i] == 1 ? 0 : 2;
            double best = 0.0;
            for (NSUInteger k = 0; k < pointsPerSpectrum; k++) {
                double v = intensity[i * pointsPerSpectrum + k];
                if (v > best) best = v;
            }
            bpis[i] = best;
        }
        MPGOWrittenRun *run =
            [[MPGOWrittenRun alloc]
                initWithSpectrumClassName:@"MPGOMassSpectrum"
                          acquisitionMode:(int64_t)MPGOAcquisitionModeMS1DDA
                              channelData:@{@"mz": f64le(mz, total),
                                            @"intensity": f64le(intensity, total)}
                                  offsets:u64arr(offsets, nSpectra)
                                  lengths:u32arr(lengths, nSpectra)
                           retentionTimes:f64le(rts, nSpectra)
                                 msLevels:i32arr(msLevels, nSpectra)
                               polarities:i32arr(pols, nSpectra)
                             precursorMzs:f64le(pmzs, nSpectra)
                         precursorCharges:i32arr(pcs, nSpectra)
                      basePeakIntensities:f64le(bpis, nSpectra)];
        runMap[[NSString stringWithFormat:@"run_%04lu", (unsigned long)r]] = run;
        free(mz); free(intensity);
        free(offsets); free(lengths); free(rts);
        free(msLevels); free(pols); free(pmzs); free(pcs); free(bpis);
    }
    return [MPGOSpectralDataset writeMinimalToPath:path
                                              title:@"M70 ObjC conformance"
                                 isaInvestigationId:@"ISA-M70-OBJC"
                                             msRuns:runMap
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

static BOOL signalBytesEqual(NSData *a, NSData *b)
{
    if (a.length != b.length) return NO;
    return memcmp(a.bytes, b.bytes, a.length) == 0;
}

static BOOL datasetsSignalEqual(MPGOSpectralDataset *a, MPGOSpectralDataset *b)
{
    if (![[NSSet setWithArray:a.msRuns.allKeys]
            isEqualToSet:[NSSet setWithArray:b.msRuns.allKeys]]) return NO;
    for (NSString *name in a.msRuns) {
        MPGOAcquisitionRun *ra = a.msRuns[name];
        MPGOAcquisitionRun *rb = b.msRuns[name];
        if ([ra count] != [rb count]) return NO;
        for (NSUInteger i = 0; i < [ra count]; i++) {
            MPGOSpectrum *sa = [ra objectAtIndex:i];
            MPGOSpectrum *sb = [rb objectAtIndex:i];
            if (fabs(sa.scanTimeSeconds - sb.scanTimeSeconds) > 1e-12) return NO;
            if (fabs(sa.precursorMz - sb.precursorMz) > 1e-12) return NO;
            if (!signalBytesEqual(sa.signalArrays[@"mz"].buffer,
                                   sb.signalArrays[@"mz"].buffer)) return NO;
            if (!signalBytesEqual(sa.signalArrays[@"intensity"].buffer,
                                   sb.signalArrays[@"intensity"].buffer)) return NO;
        }
    }
    return YES;
}

static BOOL roundTrip(NSUInteger nRuns, NSUInteger nSpectra,
                        NSUInteger pointsPerSpectrum, BOOL withChecksum)
{
    NSString *src = tmp(@"src.mpgo");
    NSString *mots = tmp(@"stream.mots");
    NSString *rt = tmp(@"rt.mpgo");
    rm(src); rm(mots); rm(rt);

    NSError *err = nil;
    if (!buildDataset(src, nRuns, nSpectra, pointsPerSpectrum, &err)) return NO;

    MPGOSpectralDataset *source = [MPGOSpectralDataset readFromFilePath:src error:&err];
    MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithOutputPath:mots];
    tw.useChecksum = withChecksum;
    if (![tw writeDataset:source error:&err]) { [tw close]; return NO; }
    [tw close];

    MPGOTransportReader *tr = [[MPGOTransportReader alloc] initWithInputPath:mots];
    if (![tr writeMpgoToPath:rt error:&err]) return NO;

    MPGOSpectralDataset *rtDs = [MPGOSpectralDataset readFromFilePath:rt error:&err];
    BOOL eq = datasetsSignalEqual(source, rtDs);
    rm(src); rm(mots); rm(rt);
    return eq;
}

void testTransportConformance(void)
{
    PASS(roundTrip(1, 5, 4, NO), "single run, 5 spectra × 4 pts: round-trip bit-equal");
    PASS(roundTrip(3, 4, 5, NO), "3 runs, 4 spectra × 5 pts: round-trip bit-equal");
    PASS(roundTrip(1, 20, 128, NO), "1 run × 20 spectra × 128 pts: round-trip bit-equal");
    PASS(roundTrip(1, 5, 4, YES), "round-trip with CRC-32C checksum: bit-equal");
}
