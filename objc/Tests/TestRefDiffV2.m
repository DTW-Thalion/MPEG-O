// TestRefDiffV2.m -- round-trip + invalid-input tests for ref_diff v2.
//
// Mirrors:
//   python/tests/test_ref_diff_v2_native.py
//   java/src/test/java/.../RefDiffV2Test.java
//
// SPDX-License-Identifier: LGPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIORefDiffV2.h"

static void testRoundTripPerfectMatch(void) {
    NSUInteger n = 100;
    NSUInteger readLen = 100;
    /* Reference large enough to cover all read positions (r*50 + readLen) */
    NSMutableData *reference = [NSMutableData dataWithLength:n * 50 + 200];
    uint8_t *refBytes = [reference mutableBytes];
    for (NSUInteger i = 0; i < [reference length]; i++)
        refBytes[i] = "ACGT"[i % 4];

    NSMutableData *sequences = [NSMutableData dataWithLength:n * readLen];
    NSMutableData *offsets   = [NSMutableData dataWithLength:(n + 1) * sizeof(uint64_t)];
    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableArray *cigars   = [NSMutableArray arrayWithCapacity:n];

    uint8_t  *seqBytes = [sequences mutableBytes];
    uint64_t *offBytes = [offsets mutableBytes];
    int64_t  *posBytes = [positions mutableBytes];

    srand(42);
    offBytes[0] = 0;
    for (NSUInteger r = 0; r < n; r++) {
        NSUInteger refPos = r * 50;
        for (NSUInteger i = 0; i < readLen; i++) {
            uint8_t b = refBytes[refPos + i];
            /* Introduce ~1% mismatches */
            if (rand() % 100 == 0) {
                b = (b == 'A') ? 'C' : 'A';
            }
            seqBytes[r * readLen + i] = b;
        }
        offBytes[r + 1] = (uint64_t)((r + 1) * readLen);
        posBytes[r]     = (int64_t)(refPos + 1); /* 1-based */
        [cigars addObject:@"100M"];
    }

    /* 16-byte placeholder MD5 -- decode side does not validate it */
    NSMutableData *md5 = [NSMutableData dataWithLength:16];

    NSError *error = nil;
    NSData *encoded = [TTIORefDiffV2 encodeSequences:sequences
                                              offsets:offsets
                                            positions:positions
                                         cigarStrings:cigars
                                            reference:reference
                                         referenceMd5:md5
                                         referenceUri:@"test"
                                       readsPerSlice:10000
                                                error:&error];
    PASS(encoded != nil, "encode succeeded");
    if (!encoded) return;
    PASS([encoded length] > 38, "encoded > header size");

    const uint8_t *eb = (const uint8_t *)[encoded bytes];
    PASS(eb[0] == 'R' && eb[1] == 'D' && eb[2] == 'F' && eb[3] == '2',
         "magic bytes RDF2");

    NSData *outSeq = nil, *outOff = nil;
    BOOL ok = [TTIORefDiffV2 decodeData:encoded
                              positions:positions
                           cigarStrings:cigars
                              reference:reference
                                nReads:n
                            totalBases:n * readLen
                          outSequences:&outSeq
                            outOffsets:&outOff
                                  error:&error];
    PASS(ok, "decode succeeded");
    if (!ok) return;

    PASS(memcmp([sequences bytes], [outSeq bytes], n * readLen) == 0,
         "sequences round-trip exact");
    PASS(memcmp([offsets bytes], [outOff bytes], (n + 1) * sizeof(uint64_t)) == 0,
         "offsets round-trip exact");
}

static void testInvalidMd5Length(void) {
    NSMutableData *seq    = [NSMutableData dataWithLength:100];
    NSMutableData *off    = [NSMutableData dataWithLength:2 * sizeof(uint64_t)];
    NSMutableData *pos    = [NSMutableData dataWithLength:1 * sizeof(int64_t)];
    NSMutableData *ref    = [NSMutableData dataWithLength:200];
    NSMutableData *badMd5 = [NSMutableData dataWithLength:8]; /* wrong: must be 16 */

    /* Set offsets so (n+1) entries match n=1 read */
    uint64_t *offP = (uint64_t *)[off mutableBytes];
    offP[0] = 0; offP[1] = 100;
    int64_t *posP = (int64_t *)[pos mutableBytes];
    posP[0] = 1;

    NSError *error = nil;
    NSData *encoded = [TTIORefDiffV2 encodeSequences:seq
                                              offsets:off
                                            positions:pos
                                         cigarStrings:@[@"100M"]
                                            reference:ref
                                         referenceMd5:badMd5
                                         referenceUri:@"test"
                                       readsPerSlice:10000
                                                error:&error];
    PASS(encoded == nil, "encode rejected bad MD5 length");
    PASS(error != nil, "error set on rejection");
}

/* M97: the slice_bytes byte budget produces non-uniform slice
 * boundaries the fixed-count writer cannot, and the unmodified
 * decoder round-trips them. Mirrors
 * native/tests/test_ref_diff_v2_invariants.c test_m97_slice_bytes_policy. */
static void testM97SliceBytesBudget(void) {
    NSUInteger n = 40;
    /* Alternating 20- and 100-base reads so a byte budget cuts
     * mid-pattern and slice read-counts differ. */
    NSMutableData *reference = [NSMutableData dataWithLength:4096];
    uint8_t *refBytes = [reference mutableBytes];
    for (NSUInteger i = 0; i < [reference length]; i++)
        refBytes[i] = "ACGT"[i % 4];

    NSMutableData *sequences = [NSMutableData data];
    NSMutableData *offsets   = [NSMutableData dataWithLength:(n + 1) * sizeof(uint64_t)];
    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableArray *cigars   = [NSMutableArray arrayWithCapacity:n];
    uint64_t *offBytes = [offsets mutableBytes];
    int64_t  *posBytes = [positions mutableBytes];
    uint64_t total = 0;
    for (NSUInteger r = 0; r < n; r++) {
        NSUInteger len = (r % 2 == 0) ? 20 : 100;
        NSUInteger refPos = r * 60;
        offBytes[r] = total;
        posBytes[r] = (int64_t)(refPos + 1); /* 1-based */
        NSMutableData *read = [NSMutableData dataWithBytes:refBytes + refPos
                                                    length:len];
        uint8_t *rb = read.mutableBytes;                 /* 1 substitution */
        rb[3] = (rb[3] == 'A') ? 'C' : 'A';
        [sequences appendData:read];
        [cigars addObject:(len == 20 ? @"20M" : @"100M")];
        total += len;
    }
    offBytes[n] = total;
    NSMutableData *md5 = [NSMutableData dataWithLength:16];

    NSError *error = nil;
    NSData *base = [TTIORefDiffV2 encodeSequences:sequences
                                           offsets:offsets
                                         positions:positions
                                      cigarStrings:cigars
                                         reference:reference
                                      referenceMd5:md5
                                      referenceUri:@"m97"
                                    readsPerSlice:10000
                                             error:&error];
    PASS(base != nil, "default encode succeeded");

    /* A budget covering every base reproduces the default byte for byte. */
    NSData *full = [TTIORefDiffV2 encodeSequences:sequences
                                           offsets:offsets
                                         positions:positions
                                      cigarStrings:cigars
                                         reference:reference
                                      referenceMd5:md5
                                      referenceUri:@"m97"
                                    readsPerSlice:10000
                                       sliceBytes:total
                                            error:&error];
    PASS(full != nil && [full isEqualToData:base],
         "full-budget encode byte-identical to default");

    /* A 200-base budget engages the walk: > 1 slice in the outer
     * header (u32 LE at offset 8), boundaries the fixed-count writer
     * cannot produce. */
    NSData *budgeted = [TTIORefDiffV2 encodeSequences:sequences
                                               offsets:offsets
                                             positions:positions
                                          cigarStrings:cigars
                                             reference:reference
                                          referenceMd5:md5
                                          referenceUri:@"m97"
                                        readsPerSlice:10000
                                           sliceBytes:200
                                                error:&error];
    PASS(budgeted != nil, "byte-budget encode succeeded");
    if (!budgeted) return;
    const uint8_t *bb = (const uint8_t *)[budgeted bytes];
    uint32_t nSlices = (uint32_t)bb[8] | ((uint32_t)bb[9] << 8)
                     | ((uint32_t)bb[10] << 16) | ((uint32_t)bb[11] << 24);
    PASS(nSlices > 1, "byte budget produced multiple slices");
    PASS(![budgeted isEqualToData:base], "byte-budget blob differs from default");

    NSData *outSeq = nil, *outOff = nil;
    BOOL ok = [TTIORefDiffV2 decodeData:budgeted
                              positions:positions
                           cigarStrings:cigars
                              reference:reference
                                nReads:n
                            totalBases:(NSUInteger)total
                          outSequences:&outSeq
                            outOffsets:&outOff
                                  error:&error];
    PASS(ok, "unmodified decoder accepts non-uniform slices");
    if (!ok) return;
    PASS([outSeq isEqualToData:sequences],
         "byte-budget sequences round-trip exact");
}

void testRefDiffV2(void);
void testRefDiffV2(void) {
    testRoundTripPerfectMatch();
    testInvalidMd5Length();
    testM97SliceBytesBudget();
}
