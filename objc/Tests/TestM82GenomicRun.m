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

void testM82GenomicRun(void)
{
    testAlignedReadBasicFields();
    testAlignedReadFlagAccessors();
    testAlignedReadEquality();
    // Subsequent tasks append more test functions called from here.
}
