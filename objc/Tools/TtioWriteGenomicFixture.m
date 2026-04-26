/*
 * TtioWriteGenomicFixture — one-shot fixture writer used by the M82.4
 * cross-language conformance matrix. Writes a deterministic 100-read
 * genomic-only .tio file to the path given on the command line, then
 * exits.
 *
 * The shape mirrors python/tests/fixtures/genomic/generate.py and
 * java/.../tools/TtioWriteGenomicFixture.java: same title, ISA id, run
 * name, 100 reads × 150 bases, ACGT cycled, qualities = 30,
 * chromosomes round-robin over {chr1,chr2,chrX}, positions
 * 10_000 + (i/3)*100. Sequence bases are intentionally generated with a
 * portable cycle (not platform RNG) so all three writers produce
 * identical bytes.
 *
 * Usage: TtioWriteGenomicFixture <out-path>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "ValueClasses/TTIOEnums.h"

static TTIOWrittenGenomicRun *MakeRun(void)
{
    NSUInteger nReads = 100;
    NSUInteger readLength = 150;
    NSArray<NSString *> *chromsPool = @[@"chr1", @"chr2", @"chrX"];
    const char bases[4] = {'A', 'C', 'G', 'T'};

    NSMutableArray<NSString *> *chroms     = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray<NSString *> *cigars     = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray<NSString *> *readNames  = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray<NSString *> *mateChroms = [NSMutableArray arrayWithCapacity:nReads];

    NSMutableData *positionsData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *mapqsData     = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
    NSMutableData *flagsData     = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *offsetsData   = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    NSMutableData *lengthsData   = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *matePosData   = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *tlensData     = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];

    int64_t  *positions = positionsData.mutableBytes;
    uint8_t  *mapqs     = mapqsData.mutableBytes;
    uint32_t *flags     = flagsData.mutableBytes;
    uint64_t *offsets   = offsetsData.mutableBytes;
    uint32_t *lengths   = lengthsData.mutableBytes;
    int64_t  *matePos   = matePosData.mutableBytes;
    int32_t  *tlens     = tlensData.mutableBytes;

    for (NSUInteger i = 0; i < nReads; i++) {
        [chroms     addObject:chromsPool[i % 3]];
        [cigars     addObject:[NSString stringWithFormat:@"%luM",
                               (unsigned long)readLength]];
        [readNames  addObject:[NSString stringWithFormat:@"read_%06lu",
                               (unsigned long)i]];
        [mateChroms addObject:@""];
        positions[i] = 10000 + (int64_t)((i / 3) * 100);
        mapqs[i]     = 60;
        flags[i]     = 0;
        offsets[i]   = (uint64_t)(i * readLength);
        lengths[i]   = (uint32_t)readLength;
        matePos[i]   = -1;
        tlens[i]     = 0;
    }

    NSMutableData *sequencesData = [NSMutableData dataWithLength:nReads * readLength];
    uint8_t *seqBytes = sequencesData.mutableBytes;
    for (NSUInteger i = 0; i < nReads * readLength; i++) {
        seqBytes[i] = (uint8_t)bases[i % 4];
    }
    NSMutableData *qualitiesData = [NSMutableData dataWithLength:nReads * readLength];
    memset(qualitiesData.mutableBytes, 30, nReads * readLength);

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
                      readNames:readNames
                mateChromosomes:mateChroms
                  matePositions:matePosData
                templateLengths:tlensData
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: TtioWriteGenomicFixture <out-path>\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];

        TTIOWrittenGenomicRun *run = MakeRun();
        NSError *err = nil;
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                    title:@"m82-cross-lang-fixture"
                                       isaInvestigationId:@"ISA-M82-100"
                                                   msRuns:@{}
                                              genomicRuns:@{@"genomic_0001": run}
                                          identifications:nil
                                          quantifications:nil
                                        provenanceRecords:nil
                                                    error:&err];
        if (!ok) {
            fprintf(stderr, "TtioWriteGenomicFixture: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        return 0;
    }
}
