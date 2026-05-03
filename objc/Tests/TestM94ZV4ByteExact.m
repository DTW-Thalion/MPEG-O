// TestM94ZV4ByteExact.m — Stage 3 Task 9: ObjC V4 cross-corpus byte-exact.
//
// Mirrors:
//   java/.../FqzcompNx16ZV4ByteExactTest.java
//   python/tests/integration/test_m94z_v4_byte_exact.py
//
// For each of 4 corpora (chr22, WES, HG002 Illumina, HG002 PacBio HiFi):
//   1. Read /tmp/{name}_v4_qual.bin / _lens.bin / _flags.bin
//      (populated by tools/perf/htscodecs_compare.sh).
//   2. Read /tmp/py_{name}_v4.fqz (full M94Z V4 stream produced by
//      Python — populated by tools.perf.m94z_v4_prototype.run_v4_python_references).
//   3. Encode via +encodeV4WithQualities:... and assert byte-identical
//      to the Python output.
//
// Skips cleanly when /tmp inputs are missing (Phase-5 prep not done) or
// when the native backend is not linked.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"

typedef struct {
    const char *name;
    size_t expectedQualBytes;
    size_t expectedNReads;
} CorpusSpec;

static const CorpusSpec kCorpora[] = {
    {"chr22",          178409733, 1766433},
    {"wes",             95035281,  992974},
    {"hg002_illumina", 248184765,  997415},
    {"hg002_pacbio",   264190341,   14284},
};
static const size_t kNumCorpora = sizeof(kCorpora) / sizeof(kCorpora[0]);

static void runOneCorpus(const CorpusSpec *spec)
{
    NSString *base = [NSString stringWithFormat:@"/tmp/%s_v4", spec->name];
    NSString *qualPath  = [base stringByAppendingString:@"_qual.bin"];
    NSString *lensPath  = [base stringByAppendingString:@"_lens.bin"];
    NSString *flagsPath = [base stringByAppendingString:@"_flags.bin"];
    NSString *pyOut     = [NSString stringWithFormat:@"/tmp/py_%s_v4.fqz",
                                                     spec->name];

    NSData *qualities = [NSData dataWithContentsOfFile:qualPath];
    NSData *lensBlob  = [NSData dataWithContentsOfFile:lensPath];
    NSData *flagsBlob = [NSData dataWithContentsOfFile:flagsPath];
    NSData *pyResult  = [NSData dataWithContentsOfFile:pyOut];
    if (!qualities || !lensBlob || !flagsBlob || !pyResult) {
        fprintf(stderr,
            "  %s: skipping — Phase 5 /tmp inputs not present "
            "(run tools/perf/htscodecs_compare.sh + run_v4_python_references)\n",
            spec->name);
        return;
    }

    PASS(qualities.length == spec->expectedQualBytes,
         "%s: qualities byte count matches fixture", spec->name);
    size_t nReads = lensBlob.length / 4;
    PASS(nReads == spec->expectedNReads,
         "%s: read count matches fixture", spec->name);

    const uint32_t *lensArr  = (const uint32_t *)lensBlob.bytes;
    const uint32_t *flagsArr = (const uint32_t *)flagsBlob.bytes;
    NSMutableArray<NSNumber *> *lens = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray<NSNumber *> *rev  = [NSMutableArray arrayWithCapacity:nReads];
    for (size_t i = 0; i < nReads; i++) {
        [lens addObject:@(lensArr[i])];
        // SAM_REVERSE bit is bit 4; encodeV4Internal converts to 0/16.
        [rev  addObject:@((flagsArr[i] & 16) != 0 ? 1 : 0)];
    }

    // pad_count = (-num_qualities) & 3, matching the Python and Java
    // top-level dispatch logic (TTIOFqzcompNx16Z.m around line 1783).
    uint8_t padCount = (uint8_t)((-(NSInteger)qualities.length) & 0x3);
    NSError *err = nil;
    NSData *objcV4 = [TTIOFqzcompNx16Z encodeV4WithQualities:qualities
                                                  readLengths:lens
                                                 revcompFlags:rev
                                                 strategyHint:-1
                                                     padCount:padCount
                                                        error:&err];
    PASS(objcV4 != nil, "%s: ObjC V4 encode succeeds", spec->name);
    if (!objcV4) {
        if (err) fprintf(stderr, "    error: %s\n",
                         [[err localizedDescription] UTF8String]);
        return;
    }

    BOOL equal = [objcV4 isEqualToData:pyResult];
    PASS(equal, "%s: ObjC V4 == Python V4 byte-exact (ObjC=%zu Python=%zu)",
         spec->name, (size_t)objcV4.length, (size_t)pyResult.length);
    if (!equal) {
        size_t minLen = MIN(objcV4.length, pyResult.length);
        const uint8_t *o = objcV4.bytes;
        const uint8_t *p = pyResult.bytes;
        size_t firstDiff = minLen;
        for (size_t i = 0; i < minLen; i++) {
            if (o[i] != p[i]) { firstDiff = i; break; }
        }
        fprintf(stderr,
            "    %s: first diff at offset %zu of %zu (ObjC=%zu Python=%zu)\n",
            spec->name, firstDiff, minLen,
            (size_t)objcV4.length, (size_t)pyResult.length);
    }
}

void testM94ZV4ByteExact(void);
void testM94ZV4ByteExact(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    if (![backend hasPrefix:@"native-"]) {
        fprintf(stderr,
            "  testM94ZV4ByteExact: skipping — native backend unavailable "
            "(backendName=%s)\n", [backend UTF8String]);
        return;
    }
    for (size_t i = 0; i < kNumCorpora; i++) {
        runOneCorpus(&kCorpora[i]);
    }
}
