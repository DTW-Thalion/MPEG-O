// TestM82GenomicRun.m — v0.11 M82.2.
//
// Objective-C normative implementation of GenomicRun + AlignedRead +
// genomic signal channel layout. Mirrors the Python reference impl
// shipped in M82.1.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOWrittenGenomicRun.h"

// ── AlignedRead value class ────────────────────────────────────────

static TTIOAlignedRead *makeAlignedRead(uint32_t flags)
{
    return [[TTIOAlignedRead alloc]
        initWithReadName:@"r"
              chromosome:@"chr1"
                position:0
          mappingQuality:0
                   cigar:@"0M"
                sequence:@""
               qualities:[NSData data]
                   flags:flags
          mateChromosome:@""
            matePosition:-1
          templateLength:0];
}

static void testAlignedReadBasicFields(void)
{
    NSData *quals = [@"IIIIIIIIIIIIII" dataUsingEncoding:NSASCIIStringEncoding];
    TTIOAlignedRead *r =
        [[TTIOAlignedRead alloc]
            initWithReadName:@"read_001"
                  chromosome:@"chr1"
                    position:12345
              mappingQuality:60
                       cigar:@"150M"
                    sequence:@"AAAAAAAAAAAAAA"
                   qualities:quals
                       flags:0
              mateChromosome:@""
                matePosition:-1
              templateLength:0];
    PASS(r != nil, "M82: AlignedRead constructible");
    PASS([r.readName isEqualToString:@"read_001"], "M82: readName preserved");
    PASS([r.chromosome isEqualToString:@"chr1"], "M82: chromosome preserved");
    PASS(r.position == 12345, "M82: position preserved");
    PASS(r.mappingQuality == 60, "M82: mappingQuality preserved");
    PASS([r.cigar isEqualToString:@"150M"], "M82: cigar preserved");
    PASS(r.flags == 0, "M82: flags preserved");
    PASS([r.qualities isEqualToData:quals], "M82: qualities preserved");
    PASS(r.matePosition == -1, "M82: matePosition sentinel preserved");
    PASS(r.templateLength == 0, "M82: templateLength sentinel preserved");
    PASS(r.readLength == 14, "M82: readLength derived from sequence length");
}

static void testAlignedReadFlagAccessors(void)
{
    PASS(makeAlignedRead(0).isMapped == YES,        "M82: isMapped true when 0x4 unset");
    PASS(makeAlignedRead(0x4).isMapped == NO,       "M82: isMapped false when 0x4 set");
    PASS(makeAlignedRead(0).isPaired == NO,         "M82: isPaired false when 0x1 unset");
    PASS(makeAlignedRead(0x1).isPaired == YES,      "M82: isPaired true when 0x1 set");
    PASS(makeAlignedRead(0).isReverse == NO,        "M82: isReverse false when 0x10 unset");
    PASS(makeAlignedRead(0x10).isReverse == YES,    "M82: isReverse true when 0x10 set");
    PASS(makeAlignedRead(0).isSecondary == NO,      "M82: isSecondary false when 0x100 unset");
    PASS(makeAlignedRead(0x100).isSecondary == YES, "M82: isSecondary true when 0x100 set");
    PASS(makeAlignedRead(0).isSupplementary == NO,  "M82: isSupplementary false when 0x800 unset");
    PASS(makeAlignedRead(0x800).isSupplementary == YES, "M82: isSupplementary true when 0x800 set");
}

static void testAlignedReadEquality(void)
{
    TTIOAlignedRead *a = makeAlignedRead(0);
    TTIOAlignedRead *b = makeAlignedRead(0);
    TTIOAlignedRead *c = makeAlignedRead(0x1);
    PASS([a isEqual:b], "M82: equal AlignedReads compare equal");
    PASS(![a isEqual:c], "M82: different flags → unequal AlignedReads");
    PASS(a.hash == b.hash, "M82: equal AlignedReads have equal hash");
}

// ── GenomicIndex (in-memory) ───────────────────────────────────────

static TTIOGenomicIndex *makeIndex6(void)
{
    uint64_t offsets[6]    = {0, 150, 300, 450, 600, 750};
    uint32_t lengths[6]    = {150, 150, 150, 150, 150, 150};
    int64_t  positions[6]  = {100, 15000, 100, 200, 100, 25000};
    uint8_t  mapqs[6]      = {60, 60, 0, 60, 60, 60};
    uint32_t flags[6]      = {0, 0, 0x4, 0x10, 0x1, 0};
    NSArray *chroms = @[@"chr1", @"chr1", @"chr2", @"chr2", @"chrX", @"chr1"];

    return [[TTIOGenomicIndex alloc]
        initWithOffsets:[NSData dataWithBytes:offsets length:sizeof(offsets)]
                lengths:[NSData dataWithBytes:lengths length:sizeof(lengths)]
            chromosomes:chroms
              positions:[NSData dataWithBytes:positions length:sizeof(positions)]
       mappingQualities:[NSData dataWithBytes:mapqs length:sizeof(mapqs)]
                  flags:[NSData dataWithBytes:flags length:sizeof(flags)]];
}

static void testGenomicIndexInMemory(void)
{
    TTIOGenomicIndex *idx = makeIndex6();
    PASS(idx.count == 6, "M82: GenomicIndex count");
    PASS([idx offsetAt:0] == 0, "M82: offsetAt[0]");
    PASS([idx lengthAt:5] == 150, "M82: lengthAt[5]");
    PASS([idx positionAt:1] == 15000, "M82: positionAt[1]");
    PASS([idx mappingQualityAt:2] == 0, "M82: mappingQualityAt[2]");
    PASS([idx flagsAt:3] == 0x10, "M82: flagsAt[3]");
    PASS([[idx chromosomeAt:4] isEqualToString:@"chrX"], "M82: chromosomeAt[4]");

    NSIndexSet *region = [idx indicesForRegion:@"chr1" start:10000 end:20000];
    PASS([region containsIndex:1] && region.count == 1,
         "M82: indicesForRegion narrows correctly");

    NSIndexSet *empty = [idx indicesForRegion:@"chrY" start:0 end:1000000];
    PASS(empty.count == 0, "M82: indicesForRegion empty when no match");

    NSIndexSet *unmapped = [idx indicesForUnmapped];
    PASS([unmapped containsIndex:2] && unmapped.count == 1,
         "M82: indicesForUnmapped");

    NSIndexSet *reverse = [idx indicesForFlag:0x10];
    PASS([reverse containsIndex:3] && reverse.count == 1,
         "M82: indicesForFlag(reverse)");

    NSIndexSet *paired = [idx indicesForFlag:0x1];
    PASS([paired containsIndex:4] && paired.count == 1,
         "M82: indicesForFlag(paired)");
}

// ── WrittenGenomicRun container ────────────────────────────────────

static void testWrittenGenomicRunConstruction(void)
{
    uint64_t offsets[2]   = {0, 150};
    uint32_t lengths[2]   = {150, 150};
    int64_t  positions[2] = {1000, 2000};
    uint8_t  mapqs[2]     = {60, 60};
    uint32_t flags[2]     = {0, 0};
    int64_t  matePos[2]   = {-1, -1};
    int32_t  tlens[2]     = {0, 0};

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"NA12878"
                           positions:[NSData dataWithBytes:positions length:sizeof(positions)]
                    mappingQualities:[NSData dataWithBytes:mapqs length:sizeof(mapqs)]
                               flags:[NSData dataWithBytes:flags length:sizeof(flags)]
                           sequences:[NSMutableData dataWithLength:300]
                           qualities:[NSMutableData dataWithLength:300]
                             offsets:[NSData dataWithBytes:offsets length:sizeof(offsets)]
                             lengths:[NSData dataWithBytes:lengths length:sizeof(lengths)]
                              cigars:@[@"150M", @"150M"]
                           readNames:@[@"r1", @"r2"]
                     mateChromosomes:@[@"", @""]
                       matePositions:[NSData dataWithBytes:matePos length:sizeof(matePos)]
                     templateLengths:[NSData dataWithBytes:tlens length:sizeof(tlens)]
                         chromosomes:@[@"chr1", @"chr1"]
                  signalCompression:TTIOCompressionZlib];

    PASS(run != nil, "M82: WrittenGenomicRun constructible");
    PASS(run.acquisitionMode == TTIOAcquisitionModeGenomicWGS,
         "M82: acquisitionMode preserved");
    PASS([run.referenceUri isEqualToString:@"GRCh38.p14"],
         "M82: referenceUri preserved");
    PASS(run.cigars.count == 2, "M82: cigars count preserved");
    PASS(run.readCount == 2, "M82: readCount derived from offsets");
    PASS(run.signalCompression == TTIOCompressionZlib,
         "M82: signalCompression preserved");
}

void testM82GenomicRun(void)
{
    testAlignedReadBasicFields();
    testAlignedReadFlagAccessors();
    testAlignedReadEquality();
    testGenomicIndexInMemory();
    testWrittenGenomicRunConstruction();
    // Subsequent tasks append more test functions called from here.
}
