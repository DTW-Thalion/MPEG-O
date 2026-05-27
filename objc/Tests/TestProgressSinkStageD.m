/*
 * TestProgressSinkStageD.m
 * TTI-O Objective-C tests
 *
 * Stage D writer progress hooks + writeMinimalToPath:progress: per-
 * section progress. Mirrors Java's Stage D writer tests (PR #176) and
 * Python's PR #179 commit 6b13f6cb.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOProgressSink.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOEnums.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Spectra/TTIOUVVisSpectrum.h"
#import "Import/TTIOFastaReader.h"
#import "Import/TTIOFastqReader.h"
#import "Export/TTIOFastaWriter.h"
#import "Export/TTIOFastqWriter.h"
#import "Export/TTIOJcampDxWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOWrittenRun.h"
#import <unistd.h>


static NSString *psStageDTempDir(void)
{
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return dir;
}

// --- FASTA writer -------------------------------------------------------

static void testFastaWriterProgress(void)
{
    NSString *tmp = psStageDTempDir();
    NSError *err = nil;

    // Build a small unaligned FASTA in memory and write it back out
    // with progress.
    NSString *inPath = [tmp stringByAppendingPathComponent:@"in.fa"];
    [@">r1\nACGT\n>r2\nGGGG\n>r3\nTTTT\n"
        writeToFile:inPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    TTIOWrittenGenomicRun *run = [TTIOFastaReader
        readUnalignedFromPath:inPath
                   sampleName:@"S"
                     platform:@""
                 referenceUri:@""
              acquisitionMode:TTIOAcquisitionModeGenomicWGS
                        error:&err];
    PASS(run != nil, "FASTA setup parses");

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    NSString *outPath = [tmp stringByAppendingPathComponent:@"out.fa"];
    BOOL ok = [TTIOFastaWriter writeRun:run
                                 toPath:outPath
                              lineWidth:60
                             gzipOutput:-1
                               writeFai:NO
                               progress:cb
                                  error:&err];
    PASS(ok, "FASTA writeRun:progress: succeeds");
    PASS(doneVals.count >= 1, "at least one FASTA-write progress fire");
    PASS([[doneVals lastObject] longLongValue] == 3,
         "FASTA write final fire reports 3 records");
    PASS([[totalVals lastObject] longLongValue] == 3,
         "FASTA write final fire stamps total");

    // Legacy overload (no progress arg) still works.
    NSError *err2 = nil;
    BOOL ok2 = [TTIOFastaWriter writeRun:run
                                  toPath:outPath
                               lineWidth:60
                              gzipOutput:-1
                                writeFai:NO
                                   error:&err2];
    PASS(ok2, "legacy FASTA writeRun (no progress) still succeeds");
}

// --- FASTQ writer -------------------------------------------------------

static void testFastqWriterProgress(void)
{
    NSString *tmp = psStageDTempDir();
    NSError *err = nil;

    NSMutableString *fq = [NSMutableString string];
    for (NSUInteger i = 0; i < 5; i++) {
        [fq appendFormat:@"@read_%lu\nACGTACGT\n+\nIIIIIIII\n",
            (unsigned long)i];
    }
    NSString *inPath = [tmp stringByAppendingPathComponent:@"in.fq"];
    [fq writeToFile:inPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    TTIOWrittenGenomicRun *run = [TTIOFastqReader
        readFromPath:inPath
         forcedPhred:33
          sampleName:@"S"
            platform:@""
        referenceUri:@""
     acquisitionMode:TTIOAcquisitionModeGenomicWGS
         outDetected:NULL
               error:&err];
    PASS(run != nil, "FASTQ setup parses");

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    NSString *outPath = [tmp stringByAppendingPathComponent:@"out.fq"];
    BOOL ok = [TTIOFastqWriter writeRun:run
                                 toPath:outPath
                             gzipOutput:-1
                            phredOffset:33
                               progress:cb
                                  error:&err];
    PASS(ok, "FASTQ writeRun:progress: succeeds");
    PASS([[doneVals lastObject] longLongValue] == 5,
         "FASTQ write final fire reports 5 records");
    PASS([[totalVals lastObject] longLongValue] == 5,
         "FASTQ write final fire stamps total");

    // Legacy overload (no progress arg) still works.
    NSError *err2 = nil;
    BOOL ok2 = [TTIOFastqWriter writeRun:run
                                  toPath:outPath
                              gzipOutput:-1
                             phredOffset:33
                                   error:&err2];
    PASS(ok2, "legacy FASTQ writeRun (no progress) still succeeds");
}

// --- JCAMP-DX writer (single-spectrum) ----------------------------------

static void testJcampDxWriterProgress(void)
{
    NSString *tmp = psStageDTempDir();
    NSError *err = nil;

    // Build a small Raman spectrum in memory.
    NSUInteger n = 3;
    double xs[] = {100.0, 101.0, 102.0};
    double ys[] = {10.0, 20.0, 30.0};
    NSData *xData = [NSData dataWithBytes:xs length:n * sizeof(double)];
    NSData *yData = [NSData dataWithBytes:ys length:n * sizeof(double)];
    TTIOValueRange *xRange = [TTIOValueRange rangeWithMinimum:100.0 maximum:102.0];
    TTIOValueRange *yRange = [TTIOValueRange rangeWithMinimum:10.0 maximum:30.0];
    TTIOAxisDescriptor *xAxis = [TTIOAxisDescriptor descriptorWithName:@"wavenumber"
                                                                  unit:@"1/cm"
                                                            valueRange:xRange
                                                          samplingMode:TTIOSamplingModeUniform];
    TTIOAxisDescriptor *yAxis = [TTIOAxisDescriptor descriptorWithName:@"intensity"
                                                                  unit:@"counts"
                                                            valueRange:yRange
                                                          samplingMode:TTIOSamplingModeUniform];
    TTIOEncodingSpec *spec64 = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                                              compressionAlgorithm:TTIOCompressionNone
                                                         byteOrder:TTIOByteOrderLittleEndian];
    TTIOSignalArray *xArr = [[TTIOSignalArray alloc] initWithBuffer:xData
                                                             length:n
                                                           encoding:spec64
                                                               axis:xAxis];
    TTIOSignalArray *yArr = [[TTIOSignalArray alloc] initWithBuffer:yData
                                                             length:n
                                                           encoding:spec64
                                                               axis:yAxis];
    TTIORamanSpectrum *raman = [[TTIORamanSpectrum alloc]
        initWithWavenumberArray:xArr
                 intensityArray:yArr
         excitationWavelengthNm:532.0
                   laserPowerMw:10.0
             integrationTimeSec:1.0
                  indexPosition:0
                scanTimeSeconds:0
                          error:&err];
    PASS(raman != nil, "Raman spectrum constructed");

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    NSString *outPath = [tmp stringByAppendingPathComponent:@"r.jdx"];
    BOOL ok = [TTIOJcampDxWriter writeRamanSpectrum:raman
                                              toPath:outPath
                                               title:@"t"
                                            encoding:TTIOJcampDxEncodingAFFN
                                            progress:cb
                                               error:&err];
    PASS(ok, "JCAMP-DX Raman writer:progress: succeeds");
    // JCAMP-DX is single-spectrum: exactly one (1, 1) fire.
    PASS(doneVals.count == 1, "JCAMP-DX Raman writer fires exactly once");
    if (doneVals.count == 1) {
        PASS([doneVals[0] longLongValue] == 1 &&
             [totalVals[0] longLongValue] == 1,
             "JCAMP-DX Raman writer fire is (1, 1)");
    }
}

// --- SpectralDataset writeMinimalToPath:progress: ------------------------

static void testWriteMinimalProgress(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_test_minimal_%d.tio",
                       (int)getpid()];
    unlink([path fileSystemRepresentation]);

    // Make a minimal mixed write with: provenance + identifications +
    // quantifications + runs (genomic). Should give 4 section fires +
    // 1 baseline = 5 total fires.
    TTIOIdentification *ident = [[TTIOIdentification alloc]
        initWithRunName:@"r1"
          spectrumIndex:0
         chemicalEntity:@"P1"
        confidenceScore:0.95
          evidenceChain:@[@"Mascot"]];
    TTIOQuantification *quant = [[TTIOQuantification alloc]
        initWithChemicalEntity:@"P1"
                     sampleRef:@"S1"
                     abundance:1.0
           normalizationMethod:@""];
    // Build a tiny unaligned genomic run via the FASTA helper used
    // elsewhere.
    NSString *tmp = psStageDTempDir();
    NSString *faPath = [tmp stringByAppendingPathComponent:@"r.fa"];
    [@">r1\nACGT\n" writeToFile:faPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSError *err = nil;
    TTIOWrittenGenomicRun *gr = [TTIOFastaReader
        readUnalignedFromPath:faPath
                   sampleName:@"S1"
                     platform:@""
                 referenceUri:@""
              acquisitionMode:TTIOAcquisitionModeGenomicWGS
                        error:&err];
    PASS(gr != nil, "writeMinimal setup: genomic run constructed");

    NSMutableArray<NSNumber *> *doneVals = [NSMutableArray array];
    NSMutableArray<NSNumber *> *totalVals = [NSMutableArray array];
    TTIOProgressBlock cb = ^(int64_t done, int64_t total) {
        [doneVals addObject:@(done)];
        [totalVals addObject:@(total)];
    };
    BOOL ok = [TTIOSpectralDataset
        writeMinimalToPath:path
                     title:@"t"
        isaInvestigationId:@""
                 mixedRuns:@{}
               genomicRuns:@{@"r1": gr}
           identifications:@[ident]
           quantifications:@[quant]
         provenanceRecords:@[]
                  progress:cb
                     error:&err];
    PASS(ok, "writeMinimalToPath:progress: succeeds");

    // Expected section flags:
    //   provenance      0 (empty)
    //   subjects        0 (not supported)
    //   samples         0 (not supported)
    //   references      1 (genomic_runs non-empty)
    //   image           0 (not supported)
    //   identifications 1
    //   quantifications 1
    //   runs            1
    // Total = 4. Plus baseline (0, 4) = 5 fires.
    PASS(doneVals.count == 5,
         "writeMinimal fires baseline + 4 section markers");
    if (doneVals.count == 5) {
        PASS([doneVals[0] longLongValue] == 0 &&
             [totalVals[0] longLongValue] == 4,
             "writeMinimal baseline fire is (0, 4)");
        PASS([doneVals[4] longLongValue] == 4 &&
             [totalVals[4] longLongValue] == 4,
             "writeMinimal final fire is (4, 4)");
    }

    // Legacy overload (no progress arg) still works.
    unlink([path fileSystemRepresentation]);
    NSError *err2 = nil;
    BOOL ok2 = [TTIOSpectralDataset
        writeMinimalToPath:path
                     title:@"t"
        isaInvestigationId:@""
                 mixedRuns:@{}
               genomicRuns:@{@"r1": gr}
           identifications:@[ident]
           quantifications:@[quant]
         provenanceRecords:@[]
                     error:&err2];
    PASS(ok2, "legacy writeMinimalToPath (no progress arg) still succeeds");
    unlink([path fileSystemRepresentation]);
}

// Public entry point.
void testProgressSinkStageD(void)
{
    testFastaWriterProgress();
    testFastqWriterProgress();
    testJcampDxWriterProgress();
    testWriteMinimalProgress();
}
