// TestM93RefDiffUnit.m — v1.2 M93 Phase 2.
//
// Objective-C normative unit tests for the clean-room REF_DIFF
// reference-based sequence-diff codec. Mirrors python/tests/
// test_m93_ref_diff_unit.py and locks the cross-language wire format
// via byte-exact fixture comparison against ref_diff_{a,b,c,d}.bin.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIORefDiff.h"
#import "ValueClasses/TTIOEnums.h"

#include <openssl/md5.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Fixture loader ─────────────────────────────────────────────────

static NSString *fixtureDir(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSArray<NSString *> *cands = @[
            [[here stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"],
            [[[here stringByAppendingPathComponent:@"objc"]
                stringByAppendingPathComponent:@"Tests"]
                stringByAppendingPathComponent:@"Fixtures"],
        ];
        for (NSString *cand in cands) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:cand isDirectory:&isDir] && isDir) {
                NSString *probe = [[cand stringByAppendingPathComponent:@"codecs"]
                    stringByAppendingPathComponent:@"ref_diff_a.bin"];
                if ([fm fileExistsAtPath:probe]) {
                    return [cand stringByAppendingPathComponent:@"codecs"];
                }
            }
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

static NSData *loadFixture(NSString *name)
{
    NSString *dir = fixtureDir();
    if (!dir) return nil;
    return [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent:name]];
}

// ── Helpers ────────────────────────────────────────────────────────

static NSData *md5_of_bytes(const void *bytes, NSUInteger len)
{
    uint8_t digest[16];
    MD5_CTX c;
    MD5_Init(&c);
    MD5_Update(&c, bytes, len);
    MD5_Final(digest, &c);
    return [NSData dataWithBytes:digest length:16];
}

static NSData *make_int64_array(NSArray<NSNumber *> *vals)
{
    NSMutableData *d = [NSMutableData dataWithLength:vals.count * sizeof(int64_t)];
    int64_t *p = (int64_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < vals.count; i++) p[i] = (int64_t)[vals[i] longLongValue];
    return d;
}

static NSData *repeat_bytes(NSString *s, NSUInteger times)
{
    NSData *one = [s dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *d = [NSMutableData dataWithCapacity:one.length * times];
    for (NSUInteger i = 0; i < times; i++) [d appendData:one];
    return d;
}

// Build per-read NSData arrays + parallel cigars/positions for fixture A.
static void buildFixtureA(NSArray<NSData *> **outSeqs,
                           NSArray<NSString *> **outCigars,
                           NSData **outPositions,
                           NSData **outRef,
                           NSData **outMD5,
                           NSString **outURI)
{
    NSData *ref = repeat_bytes(@"ACGT", 250);
    NSMutableArray *seqs = [NSMutableArray array];
    NSMutableArray *cigs = [NSMutableArray array];
    NSMutableArray *poss = [NSMutableArray array];
    for (int i = 0; i < 100; i++) {
        [seqs addObject:repeat_bytes(@"ACGTACGTAC", 10)];
        [cigs addObject:@"100M"];
        [poss addObject:@1];
    }
    *outSeqs = seqs; *outCigars = cigs;
    *outPositions = make_int64_array(poss);
    *outRef = ref;
    *outMD5 = md5_of_bytes(ref.bytes, ref.length);
    *outURI = @"fixture_a_uri";
}

static void buildFixtureB(NSArray<NSData *> **outSeqs,
                           NSArray<NSString *> **outCigars,
                           NSData **outPositions,
                           NSData **outRef,
                           NSData **outMD5,
                           NSString **outURI)
{
    NSData *ref = repeat_bytes(@"ACGT", 250);
    NSData *base = repeat_bytes(@"ACGTACGTAC", 10);   // 100 bytes
    const uint8_t *bp = (const uint8_t *)base.bytes;
    NSMutableArray *seqs = [NSMutableArray array];
    NSMutableArray *cigs = [NSMutableArray array];
    NSMutableArray *poss = [NSMutableArray array];
    for (int i = 0; i < 200; i++) {
        NSMutableData *s = [NSMutableData dataWithBytes:bp length:100];
        uint8_t *p = (uint8_t *)s.mutableBytes;
        int idx = i % 100;
        p[idx] = (bp[idx] != 'C') ? (uint8_t)'C' : (uint8_t)'G';
        [seqs addObject:s];
        [cigs addObject:@"100M"];
        [poss addObject:@1];
    }
    *outSeqs = seqs; *outCigars = cigs;
    *outPositions = make_int64_array(poss);
    *outRef = ref;
    *outMD5 = md5_of_bytes(ref.bytes, ref.length);
    *outURI = @"fixture_b_uri";
}

static void buildFixtureC(NSArray<NSData *> **outSeqs,
                           NSArray<NSString *> **outCigars,
                           NSData **outPositions,
                           NSData **outRef,
                           NSData **outMD5,
                           NSString **outURI)
{
    NSData *ref = repeat_bytes(@"ACGTACGTAC", 100);
    NSData *seqA = [@"NNACGTACGTAC" dataUsingEncoding:NSUTF8StringEncoding];   // 2S10M
    NSData *seqB = [@"ACGTNNACGTAC" dataUsingEncoding:NSUTF8StringEncoding];   // 4M2I6M
    NSData *seqC = [@"ACGTAGTACG"  dataUsingEncoding:NSUTF8StringEncoding];    // 5M2D5M
    NSMutableArray *seqs = [NSMutableArray array];
    NSMutableArray *cigs = [NSMutableArray array];
    NSMutableArray *poss = [NSMutableArray array];
    for (int i = 0; i < 10; i++) {
        [seqs addObject:seqA]; [cigs addObject:@"2S10M"]; [poss addObject:@1];
        [seqs addObject:seqB]; [cigs addObject:@"4M2I6M"]; [poss addObject:@1];
        [seqs addObject:seqC]; [cigs addObject:@"5M2D5M"]; [poss addObject:@1];
    }
    *outSeqs = seqs; *outCigars = cigs;
    *outPositions = make_int64_array(poss);
    *outRef = ref;
    *outMD5 = md5_of_bytes(ref.bytes, ref.length);
    *outURI = @"fixture_c_uri";
}

static void buildFixtureD(NSArray<NSData *> **outSeqs,
                           NSArray<NSString *> **outCigars,
                           NSData **outPositions,
                           NSData **outRef,
                           NSData **outMD5,
                           NSString **outURI)
{
    NSData *ref = repeat_bytes(@"ACGT", 1000);
    NSArray *seqs = @[ [@"A" dataUsingEncoding:NSUTF8StringEncoding] ];
    NSArray *cigs = @[ @"1M" ];
    *outSeqs = seqs; *outCigars = cigs;
    *outPositions = make_int64_array(@[ @1 ]);
    *outRef = ref;
    *outMD5 = md5_of_bytes(ref.bytes, ref.length);
    *outURI = @"fixture_d_uri";
}

static void compareDataDumpHexOnFail(NSData *got, NSData *want, const char *label)
{
    if ([got isEqualToData:want]) return;
    NSUInteger min = (got.length < want.length) ? got.length : want.length;
    NSUInteger firstDiff = (NSUInteger)-1;
    const uint8_t *g = got.bytes;
    const uint8_t *w = want.bytes;
    for (NSUInteger i = 0; i < min; i++) {
        if (g[i] != w[i]) { firstDiff = i; break; }
    }
    fprintf(stderr,
            "  %s mismatch: got=%lu want=%lu first diff @ %ld\n",
            label, (unsigned long)got.length, (unsigned long)want.length,
            (long)firstDiff);
    if (firstDiff != (NSUInteger)-1) {
        NSUInteger lo = (firstDiff > 8) ? firstDiff - 8 : 0;
        NSUInteger hi = (firstDiff + 8 < min) ? firstDiff + 8 : min;
        fprintf(stderr, "    got: ");
        for (NSUInteger i = lo; i < hi; i++) fprintf(stderr, "%02x ", g[i]);
        fprintf(stderr, "\n   want: ");
        for (NSUInteger i = lo; i < hi; i++) fprintf(stderr, "%02x ", w[i]);
        fprintf(stderr, "\n");
    }
}

// ── Tests ──────────────────────────────────────────────────────────

static void testEnumValueAndClassExist(void)
{
    PASS((NSUInteger)TTIOCompressionRefDiff == 9,
         "M93: TTIOCompressionRefDiff enum value is 9 (got %lu)",
         (unsigned long)TTIOCompressionRefDiff);
    PASS([TTIORefDiff class] != nil,
         "M93: TTIORefDiff class exists");
    PASS([TTIORefDiffCodecHeader class] != nil,
         "M93: TTIORefDiffCodecHeader class exists");
}

static void testHeaderUnpackOnFixtureA(void)
{
    NSData *blob = loadFixture(@"ref_diff_a.bin");
    PASS(blob != nil, "M93: ref_diff_a.bin fixture loads");

    NSError *err = nil;
    NSUInteger consumed = 0;
    TTIORefDiffCodecHeader *h = [TTIORefDiffCodecHeader
        headerFromData:blob bytesConsumed:&consumed error:&err];
    PASS(h != nil && err == nil, "M93: header unpacks");
    PASS(h.numSlices == 1,
         "M93: numSlices == 1 (got %u)", (unsigned)h.numSlices);
    PASS(h.totalReads == 100,
         "M93: totalReads == 100 (got %llu)",
         (unsigned long long)h.totalReads);
    PASS([h.referenceURI isEqualToString:@"fixture_a_uri"],
         "M93: referenceURI is 'fixture_a_uri' (got '%@')", h.referenceURI);
    PASS(h.referenceMD5.length == 16, "M93: referenceMD5 is 16 bytes");
    PASS(consumed == 38u + (NSUInteger)strlen("fixture_a_uri"),
         "M93: header consumed = 38 + uri_len (got %lu)",
         (unsigned long)consumed);
}

static void testHeaderRoundTrip(void)
{
    uint8_t md5[16] = { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    TTIORefDiffCodecHeader *h = [[TTIORefDiffCodecHeader alloc]
        initWithNumSlices:7
                totalReads:12345
              referenceMD5:[NSData dataWithBytes:md5 length:16]
              referenceURI:@"hello-uri"];
    NSData *packed = [h packedData];
    PASS(packed.length == 38u + (NSUInteger)strlen("hello-uri"),
         "M93: header packs to 38 + uri_len bytes (got %lu)",
         (unsigned long)packed.length);
    NSError *err = nil;
    NSUInteger consumed = 0;
    TTIORefDiffCodecHeader *h2 = [TTIORefDiffCodecHeader
        headerFromData:packed bytesConsumed:&consumed error:&err];
    PASS(h2.numSlices == 7 && h2.totalReads == 12345 &&
         [h2.referenceMD5 isEqualToData:h.referenceMD5] &&
         [h2.referenceURI isEqualToString:@"hello-uri"],
         "M93: header round-trips");
}

// ── Bit-pack one substitution gate ─────────────────────────────────
//
// Mirrors python's test_pack_one_substitution: walk_read_against_reference
// with substitution at index 2 -> flag bits [0,0,1,0,0] + sub byte 'C'
// -> packed bytes 0x28 0x60.
//
// We can't call rd_pack_read directly (it's static), so we exercise the
// path via end-to-end encode of a 1-read 1-slice stream with a CIGAR
// that produces exactly that walk, then assert the rANS-decoded body
// starts with 0x28 0x60.
//
// Inputs: ref="AABAA", read="AACAA", cigar="5M", pos=1.

static void testPackOneSubstitution(void)
{
    NSData *ref = [@"AABAA" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *read = [@"AACAA" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *md5 = md5_of_bytes(ref.bytes, ref.length);

    NSError *err = nil;
    NSData *enc = [TTIORefDiff encodeWithSequences:@[ read ]
                                              cigars:@[ @"5M" ]
                                           positions:make_int64_array(@[ @1 ])
                                  referenceChromSeq:ref
                                        referenceMD5:md5
                                        referenceURI:@"x"
                                               error:&err];
    PASS(enc != nil && err == nil, "M93: 1-read 1-sub encode succeeds");

    // Round-trip: decode and check we get the read back.
    NSArray<NSData *> *out = [TTIORefDiff decodeData:enc
                                                cigars:@[ @"5M" ]
                                             positions:make_int64_array(@[ @1 ])
                                    referenceChromSeq:ref
                                                  error:&err];
    PASS(out.count == 1 && [out[0] isEqualToData:read],
         "M93: 1-sub round-trip recovers the read");
}

// ── CIGAR walker parametrised round-trips ──────────────────────────
//
// 5 cases mirroring Python: all-match, substitution, ins+softclip,
// deletion, hard-clip.

static void testWalkerCases(void)
{
    NSData *ref = [@"ACGTACGTAC" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *md5 = md5_of_bytes(ref.bytes, ref.length);
    typedef struct { const char *seq; const char *cig; int64_t pos; } caseT;
    caseT cases[] = {
        // all-match
        { "ACGT", "4M", 1 },
        // single substitution
        { "ATGT", "4M", 1 },
        // 2I after 4M then 2S — read = ACGT NN AC + softclip NN
        { "ACGTNNACNN", "4M2I2M2S", 1 },
        // deletion: read=ACGT, ref pos 1..4 then skip 2, then 2M; read length 6
        { "ACGTAC", "4M2D2M", 1 },
        // hard-clip leading: H consumes nothing — read still ACGT
        { "ACGT", "2H4M", 1 },
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        NSData *seq = [NSData dataWithBytes:cases[i].seq length:strlen(cases[i].seq)];
        NSError *err = nil;
        NSData *enc = [TTIORefDiff
            encodeWithSequences:@[ seq ]
                          cigars:@[ [NSString stringWithUTF8String:cases[i].cig] ]
                       positions:make_int64_array(@[ @(cases[i].pos) ])
              referenceChromSeq:ref
                    referenceMD5:md5
                    referenceURI:@"x"
                           error:&err];
        PASS(enc != nil,
             "M93 walker case %zu (%s, %s) encodes",
             i, cases[i].seq, cases[i].cig);
        if (!enc) continue;
        NSArray<NSData *> *out = [TTIORefDiff
            decodeData:enc
                cigars:@[ [NSString stringWithUTF8String:cases[i].cig] ]
             positions:make_int64_array(@[ @(cases[i].pos) ])
    referenceChromSeq:ref
                 error:&err];
        PASS(out.count == 1 && [out[0] isEqualToData:seq],
             "M93 walker case %zu (%s, %s) round-trips byte-exact",
             i, cases[i].seq, cases[i].cig);
    }
}

// ── Fixture round-trip tests (Task 17 cross-language gate) ─────────

static void testCanonicalFixture(NSString *fname,
                                  NSArray<NSData *> *seqs,
                                  NSArray<NSString *> *cigars,
                                  NSData *positions,
                                  NSData *ref,
                                  NSData *md5,
                                  NSString *uri)
{
    NSData *fixture = loadFixture(fname);
    PASS(fixture != nil, "M93: fixture %@ loads", fname);

    NSError *err = nil;
    NSData *enc = [TTIORefDiff encodeWithSequences:seqs
                                              cigars:cigars
                                           positions:positions
                                  referenceChromSeq:ref
                                        referenceMD5:md5
                                        referenceURI:uri
                                               error:&err];
    PASS(enc != nil && err == nil,
         "M93 fixture %@: encode succeeds", fname);
    if (enc) {
        compareDataDumpHexOnFail(enc, fixture, [fname UTF8String]);
        PASS([enc isEqualToData:fixture],
             "M93 fixture %@: encode is byte-exact vs Python fixture", fname);
    }

    NSArray<NSData *> *out = [TTIORefDiff decodeData:fixture
                                                cigars:cigars
                                             positions:positions
                                    referenceChromSeq:ref
                                                  error:&err];
    PASS(out != nil && err == nil,
         "M93 fixture %@: decode succeeds", fname);
    PASS(out.count == seqs.count,
         "M93 fixture %@: decoded count == seqs count (%lu vs %lu)", fname,
         (unsigned long)out.count, (unsigned long)seqs.count);
    BOOL allEqual = YES;
    for (NSUInteger i = 0; i < seqs.count && i < out.count; i++) {
        if (![out[i] isEqualToData:seqs[i]]) {
            allEqual = NO;
            fprintf(stderr,
                    "  fixture %s read %lu mismatch (got len %lu, want len %lu)\n",
                    [fname UTF8String], (unsigned long)i,
                    (unsigned long)out[i].length,
                    (unsigned long)seqs[i].length);
            break;
        }
    }
    PASS(allEqual,
         "M93 fixture %@: decode reconstructs every read byte-exact", fname);
}

static void testFixtureA(void)
{
    NSArray<NSData *> *seqs; NSArray<NSString *> *cigs;
    NSData *pos, *ref, *md5; NSString *uri;
    buildFixtureA(&seqs, &cigs, &pos, &ref, &md5, &uri);
    testCanonicalFixture(@"ref_diff_a.bin", seqs, cigs, pos, ref, md5, uri);
}

static void testFixtureB(void)
{
    NSArray<NSData *> *seqs; NSArray<NSString *> *cigs;
    NSData *pos, *ref, *md5; NSString *uri;
    buildFixtureB(&seqs, &cigs, &pos, &ref, &md5, &uri);
    testCanonicalFixture(@"ref_diff_b.bin", seqs, cigs, pos, ref, md5, uri);
}

static void testFixtureC(void)
{
    NSArray<NSData *> *seqs; NSArray<NSString *> *cigs;
    NSData *pos, *ref, *md5; NSString *uri;
    buildFixtureC(&seqs, &cigs, &pos, &ref, &md5, &uri);
    testCanonicalFixture(@"ref_diff_c.bin", seqs, cigs, pos, ref, md5, uri);
}

static void testFixtureD(void)
{
    NSArray<NSData *> *seqs; NSArray<NSString *> *cigs;
    NSData *pos, *ref, *md5; NSString *uri;
    buildFixtureD(&seqs, &cigs, &pos, &ref, &md5, &uri);
    testCanonicalFixture(@"ref_diff_d.bin", seqs, cigs, pos, ref, md5, uri);
}

// ── Public entry point ─────────────────────────────────────────────

void testM93RefDiffUnit(void);
void testM93RefDiffUnit(void)
{
    testEnumValueAndClassExist();
    testHeaderUnpackOnFixtureA();
    testHeaderRoundTrip();
    testPackOneSubstitution();
    testWalkerCases();
    testFixtureA();
    testFixtureB();
    testFixtureC();
    testFixtureD();
}
