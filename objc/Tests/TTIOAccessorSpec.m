/*
 * TTIOAccessorSpec.m — Task 3.10 of transport-spec v0.11.
 *
 * Per-accessor content-equality comparators for the v0.11 conformance
 * matrix. Each block mirrors the Java + Python equivalent so the three
 * SDKs reject the same silent-drop classes of regression.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOAccessorSpec.h"
#import "TTIOV011FixtureBuilder.h"

#include <math.h>
#include <pthread.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Image/TTIOMSImage.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Spectra/TTIOSpectrum.h"
#import "Core/TTIOSignalArray.h"

// ────────────────────────── TTIOAccessorSpec ───────────────────────

@implementation TTIOAccessorSpec
- (instancetype)initWithName:(NSString *)name
                        build:(TTIOAccessorBuildBlock)build
                  assertEqual:(TTIOAccessorAssertBlock)assertEqual
{
    if ((self = [super init])) {
        _name = [name copy];
        _build = [build copy];
        _assertEqual = [assertEqual copy];
    }
    return self;
}
@end

// ────────────────────────── comparators ─────────────────────────────

static NSString *spec_referencesEqual(TTIOSpectralDataset *a,
                                        TTIOSpectralDataset *b)
{
    NSDictionary<NSString *, TTIOReferenceImport *> *ra = a.references;
    NSDictionary<NSString *, TTIOReferenceImport *> *rb = b.references;
    if (ra.count != rb.count) {
        return [NSString stringWithFormat:
            @"reference count mismatch: %lu vs %lu",
            (unsigned long)ra.count, (unsigned long)rb.count];
    }
    for (NSString *uri in ra) {
        TTIOReferenceImport *refA = ra[uri];
        TTIOReferenceImport *refB = rb[uri];
        if (refB == nil) {
            return [NSString stringWithFormat:
                @"missing reference %@ in round-trip output", uri];
        }
        if (refA.chromosomes.count != refB.chromosomes.count) {
            return [NSString stringWithFormat:
                @"chromosome count mismatch for %@: %lu vs %lu",
                uri,
                (unsigned long)refA.chromosomes.count,
                (unsigned long)refB.chromosomes.count];
        }
        // Look up each sequence by name (order-agnostic — matches the
        // MD5 contract; Java preserves FASTA order, Python+ObjC sort
        // alphabetically).
        NSArray<NSString *> *namesA =
            [refA.chromosomes sortedArrayUsingSelector:@selector(compare:)];
        NSArray<NSString *> *namesB =
            [refB.chromosomes sortedArrayUsingSelector:@selector(compare:)];
        if (![namesA isEqualToArray:namesB]) {
            return [NSString stringWithFormat:
                @"chromosome name set mismatch for %@: %@ vs %@",
                uri, namesA, namesB];
        }
        for (NSString *name in namesA) {
            NSData *seqA = [refA chromosomeNamed:name];
            NSData *seqB = [refB chromosomeNamed:name];
            if (![seqA isEqualToData:seqB]) {
                return [NSString stringWithFormat:
                    @"chromosome sequence mismatch at %@[%@] "
                    @"(lens %lu vs %lu)",
                    uri, name,
                    (unsigned long)seqA.length, (unsigned long)seqB.length];
            }
        }
    }
    return nil;
}

static NSString *spec_msRunsEqual(TTIOSpectralDataset *a,
                                    TTIOSpectralDataset *b)
{
    NSDictionary<NSString *, TTIOAcquisitionRun *> *ma = a.msRuns;
    NSDictionary<NSString *, TTIOAcquisitionRun *> *mb = b.msRuns;
    NSSet<NSString *> *ka = [NSSet setWithArray:ma.allKeys];
    NSSet<NSString *> *kb = [NSSet setWithArray:mb.allKeys];
    if (![ka isEqualToSet:kb]) {
        return [NSString stringWithFormat:
            @"ms-run name set mismatch: %@ vs %@", ka, kb];
    }
    for (NSString *name in ma) {
        TTIOAcquisitionRun *ra = ma[name];
        TTIOAcquisitionRun *rb = mb[name];
        if ([ra count] != [rb count]) {
            return [NSString stringWithFormat:
                @"spectrum count mismatch for run %@: %lu vs %lu",
                name, (unsigned long)[ra count], (unsigned long)[rb count]];
        }
        for (NSUInteger i = 0; i < [ra count]; i++) {
            TTIOSpectrum *sa = [ra objectAtIndex:i];
            TTIOSpectrum *sb = [rb objectAtIndex:i];
            if (fabs(sa.scanTimeSeconds - sb.scanTimeSeconds) > 1e-9) {
                return [NSString stringWithFormat:
                    @"scanTime mismatch at %@/%lu: %f vs %f",
                    name, (unsigned long)i,
                    sa.scanTimeSeconds, sb.scanTimeSeconds];
            }
            if (fabs(sa.precursorMz - sb.precursorMz) > 1e-9) {
                return [NSString stringWithFormat:
                    @"precursorMz mismatch at %@/%lu: %f vs %f",
                    name, (unsigned long)i,
                    sa.precursorMz, sb.precursorMz];
            }
            NSData *mzA = sa.signalArrays[@"mz"].buffer;
            NSData *mzB = sb.signalArrays[@"mz"].buffer;
            if (![mzA isEqualToData:mzB]) {
                return [NSString stringWithFormat:
                    @"mz signal mismatch at %@/%lu (lens %lu vs %lu)",
                    name, (unsigned long)i,
                    (unsigned long)mzA.length, (unsigned long)mzB.length];
            }
            NSData *iA = sa.signalArrays[@"intensity"].buffer;
            NSData *iB = sb.signalArrays[@"intensity"].buffer;
            if (![iA isEqualToData:iB]) {
                return [NSString stringWithFormat:
                    @"intensity signal mismatch at %@/%lu",
                    name, (unsigned long)i];
            }
        }
    }
    return nil;
}

static NSString *spec_genomicRunsEqual(TTIOSpectralDataset *a,
                                         TTIOSpectralDataset *b)
{
    NSDictionary<NSString *, TTIOGenomicRun *> *ga = a.genomicRuns;
    NSDictionary<NSString *, TTIOGenomicRun *> *gb = b.genomicRuns;
    NSSet<NSString *> *ka = [NSSet setWithArray:ga.allKeys];
    NSSet<NSString *> *kb = [NSSet setWithArray:gb.allKeys];
    if (![ka isEqualToSet:kb]) {
        return [NSString stringWithFormat:
            @"genomic-run name set mismatch: %@ vs %@", ka, kb];
    }
    for (NSString *name in ga) {
        TTIOGenomicRun *ra = ga[name];
        TTIOGenomicRun *rb = gb[name];
        if ([ra readCount] != [rb readCount]) {
            return [NSString stringWithFormat:
                @"read count mismatch for run %@: %lu vs %lu",
                name,
                (unsigned long)[ra readCount],
                (unsigned long)[rb readCount]];
        }
        if (![ra.referenceUri isEqualToString:rb.referenceUri]) {
            return [NSString stringWithFormat:
                @"referenceUri mismatch for run %@: '%@' vs '%@'",
                name, ra.referenceUri, rb.referenceUri];
        }
        if (![ra.platform isEqualToString:rb.platform]) {
            return [NSString stringWithFormat:
                @"platform mismatch for run %@: '%@' vs '%@'",
                name, ra.platform, rb.platform];
        }
        if (![ra.sampleName isEqualToString:rb.sampleName]) {
            return [NSString stringWithFormat:
                @"sampleName mismatch for run %@: '%@' vs '%@'",
                name, ra.sampleName, rb.sampleName];
        }
        if (ra.acquisitionMode != rb.acquisitionMode) {
            return [NSString stringWithFormat:
                @"acquisitionMode mismatch for run %@: %d vs %d",
                name, (int)ra.acquisitionMode, (int)rb.acquisitionMode];
        }
    }
    return nil;
}

static NSString *spec_imageEqual(TTIOSpectralDataset *a,
                                   TTIOSpectralDataset *b)
{
    TTIOMSImage *ia = a.msImage;
    TTIOMSImage *ib = b.msImage;
    if (ia == nil || ib == nil) {
        return [NSString stringWithFormat:
            @"MSImage missing on at least one side: a=%p, b=%p",
            (void *)ia, (void *)ib];
    }
    if (ia.width != ib.width
        || ia.height != ib.height
        || ia.spectralPoints != ib.spectralPoints) {
        return [NSString stringWithFormat:
            @"image shape mismatch: %lux%lux%lu vs %lux%lux%lu",
            (unsigned long)ia.width, (unsigned long)ia.height,
            (unsigned long)ia.spectralPoints,
            (unsigned long)ib.width, (unsigned long)ib.height,
            (unsigned long)ib.spectralPoints];
    }
    // Float64 → float64 round-trip with no precision loss: byte-equal.
    if (![ia.mzAxis isEqualToData:ib.mzAxis]) {
        return [NSString stringWithFormat:
            @"mz-axis byte mismatch (lens %lu vs %lu)",
            (unsigned long)ia.mzAxis.length,
            (unsigned long)ib.mzAxis.length];
    }
    if (![ia.cube isEqualToData:ib.cube]) {
        return [NSString stringWithFormat:
            @"intensity-cube byte mismatch (lens %lu vs %lu)",
            (unsigned long)ia.cube.length,
            (unsigned long)ib.cube.length];
    }
    return nil;
}

static NSString *spec_identificationsEqual(TTIOSpectralDataset *a,
                                             TTIOSpectralDataset *b)
{
    NSArray<TTIOIdentification *> *la = a.identifications;
    NSArray<TTIOIdentification *> *lb = b.identifications;
    if (la.count != lb.count) {
        return [NSString stringWithFormat:
            @"identification count mismatch: %lu vs %lu",
            (unsigned long)la.count, (unsigned long)lb.count];
    }
    for (NSUInteger i = 0; i < la.count; i++) {
        TTIOIdentification *ia = la[i];
        TTIOIdentification *ib = lb[i];
        if (![ia.runName isEqualToString:ib.runName]) {
            return [NSString stringWithFormat:
                @"identification[%lu].runName: '%@' vs '%@'",
                (unsigned long)i, ia.runName, ib.runName];
        }
        if (ia.spectrumIndex != ib.spectrumIndex) {
            return [NSString stringWithFormat:
                @"identification[%lu].spectrumIndex: %lu vs %lu",
                (unsigned long)i,
                (unsigned long)ia.spectrumIndex,
                (unsigned long)ib.spectrumIndex];
        }
        if (![ia.chemicalEntity isEqualToString:ib.chemicalEntity]) {
            return [NSString stringWithFormat:
                @"identification[%lu].chemicalEntity: '%@' vs '%@'",
                (unsigned long)i, ia.chemicalEntity, ib.chemicalEntity];
        }
        if (fabs(ia.confidenceScore - ib.confidenceScore) > 1e-9) {
            return [NSString stringWithFormat:
                @"identification[%lu].confidenceScore: %f vs %f",
                (unsigned long)i, ia.confidenceScore, ib.confidenceScore];
        }
        if (![ia.evidenceChain isEqualToArray:ib.evidenceChain]) {
            return [NSString stringWithFormat:
                @"identification[%lu].evidenceChain: %@ vs %@",
                (unsigned long)i, ia.evidenceChain, ib.evidenceChain];
        }
    }
    return nil;
}

static NSString *spec_quantificationsEqual(TTIOSpectralDataset *a,
                                             TTIOSpectralDataset *b)
{
    NSArray<TTIOQuantification *> *la = a.quantifications;
    NSArray<TTIOQuantification *> *lb = b.quantifications;
    if (la.count != lb.count) {
        return [NSString stringWithFormat:
            @"quantification count mismatch: %lu vs %lu",
            (unsigned long)la.count, (unsigned long)lb.count];
    }
    for (NSUInteger i = 0; i < la.count; i++) {
        TTIOQuantification *qa = la[i];
        TTIOQuantification *qb = lb[i];
        if (![qa.chemicalEntity isEqualToString:qb.chemicalEntity]) {
            return [NSString stringWithFormat:
                @"quantification[%lu].chemicalEntity: '%@' vs '%@'",
                (unsigned long)i, qa.chemicalEntity, qb.chemicalEntity];
        }
        if (![qa.sampleRef isEqualToString:qb.sampleRef]) {
            return [NSString stringWithFormat:
                @"quantification[%lu].sampleRef: '%@' vs '%@'",
                (unsigned long)i, qa.sampleRef, qb.sampleRef];
        }
        if (fabs(qa.abundance - qb.abundance) > 1e-9) {
            return [NSString stringWithFormat:
                @"quantification[%lu].abundance: %f vs %f",
                (unsigned long)i, qa.abundance, qb.abundance];
        }
        if (qa.normalizationMethod != nil
            && ![qa.normalizationMethod isEqualToString:qb.normalizationMethod]) {
            return [NSString stringWithFormat:
                @"quantification[%lu].normalizationMethod: '%@' vs '%@'",
                (unsigned long)i,
                qa.normalizationMethod, qb.normalizationMethod];
        }
        if (qa.unit != nil
            && ![qa.unit isEqualToString:qb.unit]) {
            return [NSString stringWithFormat:
                @"quantification[%lu].unit: '%@' vs '%@'",
                (unsigned long)i, qa.unit, qb.unit];
        }
    }
    return nil;
}

static NSString *spec_provenanceEqual(TTIOSpectralDataset *a,
                                        TTIOSpectralDataset *b)
{
    NSArray<TTIOProvenanceRecord *> *la = a.provenanceRecords;
    NSArray<TTIOProvenanceRecord *> *lb = b.provenanceRecords;
    if (la.count != lb.count) {
        return [NSString stringWithFormat:
            @"provenance count mismatch: %lu vs %lu",
            (unsigned long)la.count, (unsigned long)lb.count];
    }
    for (NSUInteger i = 0; i < la.count; i++) {
        TTIOProvenanceRecord *pa = la[i];
        TTIOProvenanceRecord *pb = lb[i];
        if (pa.timestampUnix != pb.timestampUnix) {
            return [NSString stringWithFormat:
                @"provenance[%lu].timestampUnix: %lld vs %lld",
                (unsigned long)i,
                (long long)pa.timestampUnix, (long long)pb.timestampUnix];
        }
        if (![pa.software isEqualToString:pb.software]) {
            return [NSString stringWithFormat:
                @"provenance[%lu].software: '%@' vs '%@'",
                (unsigned long)i, pa.software, pb.software];
        }
        if (![pa.parameters isEqual:pb.parameters]) {
            return [NSString stringWithFormat:
                @"provenance[%lu].parameters: %@ vs %@",
                (unsigned long)i, pa.parameters, pb.parameters];
        }
        if (![pa.inputRefs isEqualToArray:pb.inputRefs]) {
            return [NSString stringWithFormat:
                @"provenance[%lu].inputRefs: %@ vs %@",
                (unsigned long)i, pa.inputRefs, pb.inputRefs];
        }
        if (![pa.outputRefs isEqualToArray:pb.outputRefs]) {
            return [NSString stringWithFormat:
                @"provenance[%lu].outputRefs: %@ vs %@",
                (unsigned long)i, pa.outputRefs, pb.outputRefs];
        }
    }
    return nil;
}

static NSString *spec_encryptionEqual(TTIOSpectralDataset *a,
                                        TTIOSpectralDataset *b)
{
    if (a.isEncrypted != b.isEncrypted) {
        return [NSString stringWithFormat:
            @"isEncrypted mismatch: %d vs %d",
            (int)a.isEncrypted, (int)b.isEncrypted];
    }
    NSString *algA = a.encryptedAlgorithm ?: @"";
    NSString *algB = b.encryptedAlgorithm ?: @"";
    if (![algA isEqualToString:algB]) {
        return [NSString stringWithFormat:
            @"encryptedAlgorithm mismatch: '%@' vs '%@'", algA, algB];
    }
    return nil;
}

// ────────────────────────── spec list ───────────────────────────────

static NSArray<TTIOAccessorSpec *> *_ttioAccessorSpecsList = nil;

static void _ttioAccessorSpecsInit(void)
{
    // MRC: explicitly retain so the array survives autorelease-pool
    // drains between START_SET blocks. The init blocks themselves use
    // -[NSString copy] / -[Block copy] which already retain their
    // captured strings, but the top-level array literal otherwise
    // returns autoreleased and would dangle after this function exits.
    _ttioAccessorSpecsList = [@[
            [[TTIOAccessorSpec alloc]
                initWithName:@"REFERENCES"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildReferenceOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_referencesEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"MS_RUNS"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildMsRunsOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_msRunsEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"GENOMIC_RUNS"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildGenomicRunsOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_genomicRunsEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"IMAGE"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildImageMsContinuousAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_imageEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"IDENTIFICATIONS"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildIdentificationsOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_identificationsEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"QUANTIFICATIONS"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildQuantificationsOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_quantificationsEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"DATASET_PROVENANCE"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildDatasetProvenanceOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_provenanceEqual(a, b);
                 }],
            [[TTIOAccessorSpec alloc]
                initWithName:@"ENCRYPTION_ALGORITHM"
                       build:^BOOL(NSString *path, NSError **error) {
                           return [TTIOV011FixtureBuilder
                               buildEncryptionAlgorithmOnlyAtPath:path error:error];
                       }
                 assertEqual:^NSString *(TTIOSpectralDataset *a,
                                          TTIOSpectralDataset *b) {
                     return spec_encryptionEqual(a, b);
                 }],
    ] retain];
}

NSArray<TTIOAccessorSpec *> *TTIOAccessorSpecsAll(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, _ttioAccessorSpecsInit);
    return _ttioAccessorSpecsList;
}
