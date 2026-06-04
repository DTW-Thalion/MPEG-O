/*
 * TestFormatWriters.m — OT6 per-format TTIOWriter adapters.
 *
 * Mirrors the merged Java exporters.writers.*Adapter classes + the Python
 * ttio.exporters.writers behaviour. Each of the 8 adapters conforms to
 * TTIOWriter and reproduces the Java writer adapter call + Python error text.
 *
 * The BAM round-trip case is the fence for OT3's +writtenFromGenomicRun:
 * (the genomic -> written conversion). It builds a genomic .tio, reopens it
 * to obtain a read-side TTIOGenomicRun, runs the BAM adapter end-to-end (which
 * internally calls +writtenFromGenomicRun:), and asserts a non-empty BAM is
 * produced. When samtools is not on PATH the BAM-output assertion is skipped
 * cleanly, but +writtenFromGenomicRun: is still exercised up to the writer.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <objc/runtime.h>

#import "Export/TTIOWriter.h"
#import "Export/TTIOWriterAdapters.h"
#import "Export/TTIORunSelection.h"

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "ValueClasses/TTIOEnums.h"


static NSString *fwTmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_fmtwriters_%d_%@",
            (int)getpid(), suffix];
}

// ── samtools availability gate (mirrors TestM87BamImporter) ──────────
static BOOL fwSamtoolsAvailable(void)
{
    NSString *path = [[NSProcessInfo processInfo] environment][@"PATH"];
    if (path.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [path componentsSeparatedByString:@":"]) {
        if (dir.length == 0) continue;
        NSString *full = [dir stringByAppendingPathComponent:@"samtools"];
        if ([fm isExecutableFileAtPath:full]) return YES;
    }
    return NO;
}

// ── MS run + .tio for the real mzML-export case ──────────────────────
static TTIOWrittenRun *fwMakeMSRun(void)
{
    NSUInteger n = 2, peaks = 3, total = n * peaks;
    NSMutableData *mzBuf  = [NSMutableData dataWithLength:total * sizeof(double)];
    NSMutableData *intBuf = [NSMutableData dataWithLength:total * sizeof(double)];
    double *mz  = (double *)mzBuf.mutableBytes;
    double *inn = (double *)intBuf.mutableBytes;
    for (NSUInteger i = 0; i < total; i++) { mz[i] = 100.0 + (double)i; inn[i] = 1000.0; }

    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *rts     = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *mls     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pols    = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pmzs    = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *pcs     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *bps     = [NSMutableData dataWithLength:n * sizeof(double)];
    int64_t  *offsetsPtr = (int64_t *)offsets.mutableBytes;
    uint32_t *lengthsPtr = (uint32_t *)lengths.mutableBytes;
    double   *rtPtr  = (double *)rts.mutableBytes;
    int32_t  *mlPtr  = (int32_t *)mls.mutableBytes;
    int32_t  *polPtr = (int32_t *)pols.mutableBytes;
    double   *pmzPtr = (double *)pmzs.mutableBytes;
    int32_t  *pcPtr  = (int32_t *)pcs.mutableBytes;
    double   *bpPtr  = (double *)bps.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        offsetsPtr[i] = (int64_t)i * (int64_t)peaks;
        lengthsPtr[i] = (uint32_t)peaks;
        rtPtr[i]  = (double)i * 0.06;
        mlPtr[i]  = 1; polPtr[i] = 1; pmzPtr[i] = 0.0; pcPtr[i] = 0; bpPtr[i] = 1000.0;
    }
    NSDictionary *channels = @{@"mz": mzBuf, @"intensity": intBuf};
    return [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:channels
                          offsets:offsets
                          lengths:lengths
                   retentionTimes:rts
                         msLevels:mls
                       polarities:pols
                     precursorMzs:pmzs
                 precursorCharges:pcs
              basePeakIntensities:bps];
}

// ── Genomic written run for the BAM round-trip case ──────────────────
static TTIOWrittenGenomicRun *fwMakeGenomicRun(NSUInteger nReads)
{
    NSUInteger readLength = 50;
    NSArray<NSString *> *chromsPool = @[@"chr1", @"chr2", @"chrX"];
    NSMutableArray<NSString *> *chroms = [NSMutableArray array];
    NSMutableData *positionsData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    int64_t *positions = (int64_t *)positionsData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) {
        [chroms addObject:chromsPool[i % 3]];
        positions[i] = 10000 + (int64_t)((i / 3) * 100);
    }

    NSMutableData *flagsData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];

    NSMutableData *mapqsData = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
    memset(mapqsData.mutableBytes, 60, nReads);

    NSMutableData *sequencesData = [NSMutableData dataWithLength:nReads * readLength];
    uint8_t *seqBytes = (uint8_t *)sequencesData.mutableBytes;
    const char bases[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < nReads * readLength; i++) {
        seqBytes[i] = (uint8_t)bases[i % 4];
    }

    // QUAL stored as ASCII Phred+33 bytes ('I' == Phred 40), per BamWriter.
    NSMutableData *qualitiesData = [NSMutableData dataWithLength:nReads * readLength];
    memset(qualitiesData.mutableBytes, 'I', nReads * readLength);

    NSMutableData *offsetsData = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    uint64_t *offsets = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) offsets[i] = i * readLength;

    NSMutableData *lengthsData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    uint32_t *lengths = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) lengths[i] = (uint32_t)readLength;

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names  = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < nReads; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)readLength]];
        [names  addObject:[NSString stringWithFormat:@"read_%06lu", (unsigned long)i]];
        [mateChroms addObject:@"*"];
    }

    NSMutableData *matePosData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    int64_t *matePos = (int64_t *)matePosData.mutableBytes;
    NSMutableData *tlensData = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
    for (NSUInteger i = 0; i < nReads; i++) matePos[i] = -1;

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"NA12878"
                      positions:positionsData
               mappingQualities:mapqsData
                          flags:flagsData
                      sequences:sequencesData
                      qualities:qualitiesData
                        offsets:offsetsData
                        lengths:lengthsData
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePosData
                templateLengths:tlensData
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
}


void testFormatWriters(void)
{
    @autoreleasepool {
        // ---- 1. All 8 adapters conform to TTIOWriter ------------------
        NSArray *adapters = @[
            [TTIOMzMLWriterAdapter new],
            [TTIOMzTabWriterAdapter new],
            [TTIONmrMLWriterAdapter new],
            [TTIOImzMLWriterAdapter new],
            [TTIOJcampDxWriterAdapter new],
            [TTIOIsaWriterAdapter new],
            [TTIOBamWriterAdapter new],
            [TTIOCramWriterAdapter new],
        ];
        for (id a in adapters) {
            PASS([a conformsToProtocol:@protocol(TTIOWriter)],
                 "OT6: %s conforms to TTIOWriter",
                 class_getName([a class]));
        }

        // ---- 2. Real mzML export through the adapter ------------------
        NSString *msTio = fwTmpPath(@"ms.tio");
        [[NSFileManager defaultManager] removeItemAtPath:msTio error:NULL];
        NSError *err = nil;
        BOOL wrote = [TTIOSpectralDataset writeMinimalToPath:msTio
                                                       title:@"ms"
                                          isaInvestigationId:@"inv"
                                                      msRuns:@{@"run_a": fwMakeMSRun()}
                                             identifications:nil
                                             quantifications:nil
                                           provenanceRecords:nil
                                                       error:&err];
        PASS(wrote, "OT6: mzML fixture .tio written (err=%s)",
             err.localizedDescription.UTF8String ?: "(none)");
        TTIOSpectralDataset *msDs =
            [TTIOSpectralDataset readFromFilePath:msTio error:&err];
        PASS(msDs != nil, "OT6: mzML fixture .tio reopens");

        NSString *mzmlOut = fwTmpPath(@"out.mzML");
        [[NSFileManager defaultManager] removeItemAtPath:mzmlOut error:NULL];
        id<TTIOWriter> mzmlAdapter = [TTIOMzMLWriterAdapter new];
        err = nil;
        BOOL mzmlOk = [mzmlAdapter writeDataset:msDs
                                          layer:nil
                                       toOutput:mzmlOut
                                        options:@{}
                                          error:&err];
        PASS(mzmlOk, "OT6: mzML adapter writeDataset succeeds (err=%s)",
             err.localizedDescription.UTF8String ?: "(none)");
        NSDictionary *mzmlAttrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:mzmlOut error:NULL];
        PASS(mzmlAttrs != nil && [mzmlAttrs fileSize] > 0,
             "OT6: mzML output exists and is non-empty (%llu bytes)",
             (unsigned long long)[mzmlAttrs fileSize]);

        // ---- 3. BAM round-trip — exercises +writtenFromGenomicRun: ----
        NSString *gTio = fwTmpPath(@"genomic.tio");
        [[NSFileManager defaultManager] removeItemAtPath:gTio error:NULL];
        err = nil;
        BOOL gWrote = [TTIOSpectralDataset writeMinimalToPath:gTio
                                                        title:@"g"
                                           isaInvestigationId:@"inv"
                                                       msRuns:@{}
                                                  genomicRuns:@{@"genomic_0001":
                                                                    fwMakeGenomicRun(8)}
                                              identifications:nil
                                              quantifications:nil
                                            provenanceRecords:nil
                                                        error:&err];
        PASS(gWrote, "OT6: genomic fixture .tio written (err=%s)",
             err.localizedDescription.UTF8String ?: "(none)");
        TTIOSpectralDataset *gDs =
            [TTIOSpectralDataset readFromFilePath:gTio error:&err];
        PASS(gDs != nil, "OT6: genomic fixture .tio reopens");
        PASS(gDs.genomicRuns[@"genomic_0001"] != nil,
             "OT6: read-side genomic run present");

        // Exercise the OT3 conversion fence directly (independent of
        // samtools): read-side run -> written run, with offsets/lengths
        // re-derived from per-read sequence bytes. A desync here would
        // surface as a wrong read count / sequence-length mismatch.
        TTIOGenomicRun *readSide = gDs.genomicRuns[@"genomic_0001"];
        TTIOWrittenGenomicRun *written =
            [TTIORunSelection writtenFromGenomicRun:readSide];
        PASS(written != nil, "OT6: +writtenFromGenomicRun: returns a run");
        PASS(written.readNames.count == readSide.readCount,
             "OT6: written read count == read-side read count (%lu)",
             (unsigned long)readSide.readCount);

        NSString *bamOut = fwTmpPath(@"out.bam");
        [[NSFileManager defaultManager] removeItemAtPath:bamOut error:NULL];
        id<TTIOWriter> bamAdapter = [TTIOBamWriterAdapter new];
        err = nil;
        BOOL bamOk = [bamAdapter writeDataset:gDs
                                        layer:nil
                                     toOutput:bamOut
                                      options:@{}
                                        error:&err];
        if (fwSamtoolsAvailable()) {
            PASS(bamOk, "OT6: BAM adapter writeDataset succeeds (err=%s)",
                 err.localizedDescription.UTF8String ?: "(none)");
            NSDictionary *bamAttrs =
                [[NSFileManager defaultManager] attributesOfItemAtPath:bamOut error:NULL];
            PASS(bamAttrs != nil && [bamAttrs fileSize] > 0,
                 "OT6: BAM output exists and is non-empty (%llu bytes)",
                 (unsigned long long)[bamAttrs fileSize]);
        } else {
            PASS(YES, "OT6: samtools not on PATH — skipping BAM-output "
                 "assertion (writtenFromGenomicRun: still exercised above)");
        }

        // ---- 4. CRAM adapter: missing reference -> Python error text --
        id<TTIOWriter> cramAdapter = [TTIOCramWriterAdapter new];
        NSString *cramOut = fwTmpPath(@"out.cram");
        err = nil;
        BOOL cramOk = [cramAdapter writeDataset:gDs
                                          layer:nil
                                       toOutput:cramOut
                                        options:@{}
                                          error:&err];
        PASS(!cramOk && err != nil &&
             [err.localizedDescription isEqualToString:
              @"CRAM export is reference-compressed; pass the reference FASTA "
              @"via --extra --reference <path>"],
             "OT6: CRAM adapter without reference raises Python error text");

        // ---- 5. imzML adapter: no image -> Python error text ----------
        id<TTIOWriter> imzmlAdapter = [TTIOImzMLWriterAdapter new];
        NSString *imzmlOut = fwTmpPath(@"out.imzML");
        err = nil;
        BOOL imzmlOk = [imzmlAdapter writeDataset:msDs
                                            layer:nil
                                         toOutput:imzmlOut
                                          options:@{}
                                            error:&err];
        PASS(!imzmlOk && err != nil &&
             [err.localizedDescription isEqualToString:
              @"dataset has no MS image to export as imzML"],
             "OT6: imzML adapter without image raises Python error text");
    }
}
