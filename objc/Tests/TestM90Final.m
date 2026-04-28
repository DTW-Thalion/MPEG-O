/*
 * TestM90Final.m — M90.11 + M90.12 + M90.13 + M90.14 + M90.15 ObjC parity.
 *
 * Mirrors the Python tests:
 *   python/tests/test_m90_11_encrypted_genomic_headers.py
 *   python/tests/test_m90_12_mpad_uint8.py    (subset: format-level only)
 *   python/tests/test_m90_13_mask_overlap.py
 *   python/tests/test_m90_14_seeded_qualities.py
 *   python/tests/test_m90_15_chromosomes_sign.py
 *
 *   M90.11 — encrypt genomic_index columns under reserved "_headers" key
 *   M90.12 — uint8-aware MPAD wire bump (magic "MPA1" + per-entry dtype)
 *   M90.13 — mask_regions uses SAM-overlap (CIGAR-walked end coord)
 *   M90.14 — randomise_qualities seeded RNG (deterministic Phred bytes)
 *   M90.15 — sign genomic_index/chromosomes compound
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <string.h>

#import "Protection/TTIOPerAUFile.h"
#import "Protection/TTIOPerAUEncryption.h"
#import "Protection/TTIOSignatureManager.h"
#import "Protection/TTIOAnonymizer.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOFeatureFlags.h"


// ── Helpers ────────────────────────────────────────────────────────

static NSString *m90fTmp(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m90final_%d_%@",
            (int)getpid(), suffix];
}

static void m90fRm(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSData *m90fKey(uint8_t b)
{
    uint8_t buf[32]; memset(buf, b, 32);
    return [NSData dataWithBytes:buf length:32];
}

// Build the M90.11 fixture: 4 reads on chr1/chr1/chr6/chr6 with
// distinct sequences AAA.../TTT.../GGG.../CCC...
static BOOL m90fBuildHeadersFixture(NSString *path, NSError **error)
{
    NSUInteger n = 4;
    NSUInteger L = 8;
    NSArray<NSString *> *chromosomes =
        @[@"chr1", @"chr1", @"chr6", @"chr6"];

    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    [seqData appendBytes:"AAAAAAAA" length:L];
    [seqData appendBytes:"TTTTTTTT" length:L];
    [seqData appendBytes:"GGGGGGGG" length:L];
    [seqData appendBytes:"CCCCCCCC" length:L];
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    memset(qualData.mutableBytes, 20, n * L);

    NSMutableData *posData =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pos = (int64_t *)posData.mutableBytes;
    pos[0] = 100; pos[1] = 200; pos[2] = 1000; pos[3] = 1100;

    NSMutableData *mapqData = [NSMutableData dataWithLength:n];
    uint8_t *mq = (uint8_t *)mapqData.mutableBytes;
    mq[0] = 60; mq[1] = 55; mq[2] = 40; mq[3] = 50;

    NSMutableData *flagsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *flags = (uint32_t *)flagsData.mutableBytes;
    flags[0] = 0x0003; flags[1] = 0x0083; flags[2] = 0x0003; flags[3] = 0x0083;

    NSMutableData *offsetsData =
        [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *off = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) off[i] = i * L;
    NSMutableData *lengthsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *len = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) len[i] = (uint32_t)L;

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)L]];
        [names  addObject:[NSString stringWithFormat:@"r%03lu", (unsigned long)i]];
        [mateChroms addObject:@""];
    }
    NSMutableData *matePosData =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *mp = (int64_t *)matePosData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) mp[i] = -1;
    NSMutableData *tlensData =
        [NSMutableData dataWithLength:n * sizeof(int32_t)];

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"NA12878"
                          positions:posData
                   mappingQualities:mapqData
                              flags:flagsData
                          sequences:seqData
                          qualities:qualData
                            offsets:offsetsData
                            lengths:lengthsData
                             cigars:cigars
                          readNames:names
                    mateChromosomes:mateChroms
                      matePositions:matePosData
                    templateLengths:tlensData
                        chromosomes:chromosomes
                  signalCompression:TTIOCompressionZlib];

    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"M90.11 headers fixture"
                                 isaInvestigationId:@"ISA-M90-11"
                                             msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}


// ── M90.11: encrypted genomic AU headers ─────────────────────────

static void testM90_11HeadersStripsPlaintext(void)
{
    NSString *path = m90fTmp(@"m11_strip.tio");
    m90fRm(path);
    NSError *err = nil;
    PASS(m90fBuildHeadersFixture(path, &err),
         "M90.11: build headers fixture");

    NSData *kHeaders = m90fKey(0x11);
    BOOL ok = [TTIOPerAUFile encryptFilePathByRegion:path
                                                keyMap:@{@"_headers": kHeaders}
                                          providerName:nil
                                                 error:&err];
    PASS(ok, "M90.11: encryptFilePathByRegion with _headers succeeds");

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    TTIOHDF5Group *idx =
        [[[[f.rootGroup openGroupNamed:@"study" error:NULL]
            openGroupNamed:@"genomic_runs" error:NULL]
                openGroupNamed:@"genomic_0001" error:NULL]
                    openGroupNamed:@"genomic_index" error:NULL];
    PASS(![idx hasChildNamed:@"positions"],
         "M90.11: positions plaintext stripped");
    PASS(![idx hasChildNamed:@"mapping_qualities"],
         "M90.11: mapping_qualities plaintext stripped");
    PASS(![idx hasChildNamed:@"flags"],
         "M90.11: flags plaintext stripped");
    PASS(![idx hasChildNamed:@"chromosomes"],
         "M90.11: chromosomes plaintext stripped");
    PASS([idx hasChildNamed:@"positions_encrypted"],
         "M90.11: positions_encrypted blob present");
    PASS([idx hasChildNamed:@"mapping_qualities_encrypted"],
         "M90.11: mapping_qualities_encrypted blob present");
    PASS([idx hasChildNamed:@"flags_encrypted"],
         "M90.11: flags_encrypted blob present");
    PASS([idx hasChildNamed:@"chromosomes_encrypted"],
         "M90.11: chromosomes_encrypted blob present");
    // offsets/lengths stay plaintext (structural framing).
    PASS([idx hasChildNamed:@"offsets"],
         "M90.11: offsets stays plaintext");
    PASS([idx hasChildNamed:@"lengths"],
         "M90.11: lengths stays plaintext");

    NSArray *features = [TTIOFeatureFlags featuresForRoot:f.rootGroup] ?: @[];
    PASS([features containsObject:@"opt_encrypted_au_headers"],
         "M90.11: opt_encrypted_au_headers feature flag set");
    [f close];
    m90fRm(path);
}

static void testM90_11HeadersRoundTrip(void)
{
    NSString *path = m90fTmp(@"m11_rt.tio");
    m90fRm(path);
    NSError *err = nil;
    m90fBuildHeadersFixture(path, &err);

    NSData *kHeaders = m90fKey(0x11);
    [TTIOPerAUFile encryptFilePathByRegion:path
                                      keyMap:@{@"_headers": kHeaders}
                                providerName:nil
                                       error:&err];

    NSDictionary *plain = [TTIOPerAUFile
        decryptFilePathByRegion:path
                          keyMap:@{@"_headers": kHeaders}
                    providerName:nil
                           error:&err];
    PASS(plain != nil, "M90.11: decrypt with _headers key");
    NSDictionary *runOut = plain[@"genomic_0001"];
    PASS(runOut != nil, "M90.11: genomic_0001 in result");
    NSDictionary *index = runOut[@"__index__"];
    PASS(index != nil, "M90.11: __index__ entry present in run output");

    NSArray<NSString *> *chroms = index[@"chromosomes"];
    PASS(chroms.count == 4
         && [chroms[0] isEqualToString:@"chr1"]
         && [chroms[2] isEqualToString:@"chr6"],
         "M90.11: chromosomes round-trip");

    NSData *posBytes = index[@"positions"];
    PASS(posBytes.length == 4 * sizeof(int64_t),
         "M90.11: positions length 32B");
    const int64_t *pos = (const int64_t *)posBytes.bytes;
    PASS(pos[0] == 100 && pos[1] == 200 && pos[2] == 1000 && pos[3] == 1100,
         "M90.11: positions byte-exact");

    NSData *mqBytes = index[@"mapping_qualities"];
    const uint8_t *mq = (const uint8_t *)mqBytes.bytes;
    PASS(mqBytes.length == 4
         && mq[0] == 60 && mq[1] == 55 && mq[2] == 40 && mq[3] == 50,
         "M90.11: mapping_qualities byte-exact");

    NSData *flBytes = index[@"flags"];
    const uint32_t *fl = (const uint32_t *)flBytes.bytes;
    PASS(flBytes.length == 4 * sizeof(uint32_t)
         && fl[0] == 0x0003 && fl[1] == 0x0083,
         "M90.11: flags byte-exact");

    m90fRm(path);
}

static void testM90_11DecryptWithoutHeadersKeyFails(void)
{
    NSString *path = m90fTmp(@"m11_nokey.tio");
    m90fRm(path);
    NSError *err = nil;
    m90fBuildHeadersFixture(path, &err);

    [TTIOPerAUFile encryptFilePathByRegion:path
                                      keyMap:@{@"_headers": m90fKey(0x11)}
                                providerName:nil
                                       error:&err];
    err = nil;
    NSDictionary *plain =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{}
                                    providerName:nil
                                           error:&err];
    PASS(plain == nil && err != nil,
         "M90.11: decrypt without _headers key rejected");
    m90fRm(path);
}

static void testM90_11ComposedHeadersAndRegion(void)
{
    NSString *path = m90fTmp(@"m11_combo.tio");
    m90fRm(path);
    NSError *err = nil;
    m90fBuildHeadersFixture(path, &err);

    NSData *kHeaders = m90fKey(0x11);
    NSData *kHla = m90fKey(0x42);
    BOOL ok = [TTIOPerAUFile
        encryptFilePathByRegion:path
                          keyMap:@{@"_headers": kHeaders, @"chr6": kHla}
                    providerName:nil
                           error:&err];
    PASS(ok, "M90.11+M90.4: combined encrypt with both keys");

    NSDictionary *plain = [TTIOPerAUFile
        decryptFilePathByRegion:path
                          keyMap:@{@"_headers": kHeaders, @"chr6": kHla}
                    providerName:nil
                           error:&err];
    PASS(plain != nil, "M90.11+M90.4: combined decrypt");
    NSDictionary *runOut = plain[@"genomic_0001"];
    NSData *seq = runOut[@"sequences"];
    PASS(seq.length == 32, "M90.11+M90.4: sequences = 32B (4×8)");
    NSData *aaaa = [NSData dataWithBytes:"AAAAAAAA" length:8];
    NSData *gggg = [NSData dataWithBytes:"GGGGGGGG" length:8];
    PASS([[seq subdataWithRange:NSMakeRange(0, 8)] isEqualToData:aaaa],
         "M90.11+M90.4: chr1 (clear) sequence preserved");
    PASS([[seq subdataWithRange:NSMakeRange(16, 8)] isEqualToData:gggg],
         "M90.11+M90.4: chr6 (encrypted) sequence decrypts");
    m90fRm(path);
}

static void testM90_11RegionOnlyNoHeadersFlag(void)
{
    NSString *path = m90fTmp(@"m11_regonly.tio");
    m90fRm(path);
    NSError *err = nil;
    m90fBuildHeadersFixture(path, &err);

    [TTIOPerAUFile encryptFilePathByRegion:path
                                      keyMap:@{@"chr6": m90fKey(0x42)}
                                providerName:nil
                                       error:&err];

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    TTIOHDF5Group *idx =
        [[[[f.rootGroup openGroupNamed:@"study" error:NULL]
            openGroupNamed:@"genomic_runs" error:NULL]
                openGroupNamed:@"genomic_0001" error:NULL]
                    openGroupNamed:@"genomic_index" error:NULL];
    PASS([idx hasChildNamed:@"positions"],
         "M90.11 regonly: positions stays plaintext");
    PASS([idx hasChildNamed:@"chromosomes"],
         "M90.11 regonly: chromosomes stays plaintext");
    PASS(![idx hasChildNamed:@"positions_encrypted"],
         "M90.11 regonly: no positions_encrypted blob");
    NSArray *features = [TTIOFeatureFlags featuresForRoot:f.rootGroup] ?: @[];
    PASS(![features containsObject:@"opt_encrypted_au_headers"],
         "M90.11 regonly: opt_encrypted_au_headers NOT set");
    [f close];
    m90fRm(path);
}


// ── M90.12: uint8-aware MPAD wire format ────────────────────────
//
// The M90.12 wire bump (MPAD → MPA1 + per-entry dtype byte) lives
// in ``TtioPerAU.m`` (a CLI binary), so this test spawns the CLI
// via ``NSTask`` to exercise the on-the-wire byte layout end-to-end.
// MS channels (mz / intensity) round-trip with dtype byte == 1
// (FLOAT64); genomic channels (sequences / qualities) round-trip
// with dtype byte == 6 (UINT8).
//
// Mirrors python/tests/test_m90_12_mpad_uint8.py. The cross-
// language subprocess harness still asserts byte-for-byte
// equivalence between Python/Java/ObjC outputs; this in-process
// ObjC test only asserts that the ObjC CLI honours the M90.12
// invariants on its own.

// MS fixture for M90.12: two spectra, four peaks each. Mirrors the
// shape used by TestPerAUFile.m's buildPlaintextFixture and
// TestM90_12 in the Python tree.
static BOOL m90fBuildMSFixture(NSString *path, NSError **error)
{
    NSUInteger n = 2, p = 4, total = n * p;
    double mz[8], intensity[8];
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + (double)i;
        intensity[i] = (double)(i + 1) * 10.0;
    }
    int64_t offsets[2] = {0, 4};
    uint32_t lengths[2] = {4, 4};
    double rts[2] = {1.5, 3.0};
    int32_t msLevels[2] = {1, 1};
    int32_t pols[2] = {1, 1};
    double pmzs[2] = {0.0, 0.0};
    int32_t pcs[2] = {0, 0};
    double bpis[2] = {40.0, 80.0};

    TTIOWrittenRun *run = [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz":        [NSData dataWithBytes:mz length:total * sizeof(double)],
                                    @"intensity": [NSData dataWithBytes:intensity length:total * sizeof(double)]}
                          offsets:[NSData dataWithBytes:offsets length:n * sizeof(int64_t)]
                          lengths:[NSData dataWithBytes:lengths length:n * sizeof(uint32_t)]
                   retentionTimes:[NSData dataWithBytes:rts length:n * sizeof(double)]
                         msLevels:[NSData dataWithBytes:msLevels length:n * sizeof(int32_t)]
                       polarities:[NSData dataWithBytes:pols length:n * sizeof(int32_t)]
                     precursorMzs:[NSData dataWithBytes:pmzs length:n * sizeof(double)]
                 precursorCharges:[NSData dataWithBytes:pcs length:n * sizeof(int32_t)]
              basePeakIntensities:[NSData dataWithBytes:bpis length:n * sizeof(double)]];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"M90.12 MS fixture"
                                 isaInvestigationId:@"ISA-M90-12"
                                             msRuns:@{@"run_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

// Spawn TtioPerAU with argv. Sets LD_LIBRARY_PATH so the binary
// can resolve libTTIO.so out of objc/Source/obj. Returns the
// termination status; -1 means the binary isn't built (caller
// should skip the assertion).
static int m90fSpawnPerAU(NSArray<NSString *> *args)
{
    NSString *toolPath = @"/home/toddw/TTI-O/objc/Tools/obj/TtioPerAU";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        return -1;
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = toolPath;
    task.arguments = args;
    NSMutableDictionary *env =
        [[NSProcessInfo processInfo].environment mutableCopy];
    NSString *libDir = @"/home/toddw/TTI-O/objc/Source/obj";
    NSString *prev = env[@"LD_LIBRARY_PATH"] ?: @"";
    env[@"LD_LIBRARY_PATH"] =
        prev.length > 0
            ? [NSString stringWithFormat:@"%@:%@", libDir, prev]
            : libDir;
    task.environment = env;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    @try {
        [task launch];
    } @catch (NSException *exc) {
        NSLog(@"M90.12: TtioPerAU launch failed: %@", exc.reason);
        return -2;
    }
    [task waitUntilExit];
    // Drain pipes so the child doesn't block on full buffers.
    (void)[[outPipe fileHandleForReading] readDataToEndOfFile];
    (void)[[errPipe fileHandleForReading] readDataToEndOfFile];
    return task.terminationStatus;
}

// Read a length-prefixed key from the MPA1 buffer at offset *cur,
// then the dtype byte + value-length-prefixed value bytes. Mutates
// *cur. Returns YES on success, NO if the buffer runs short.
static BOOL m90fParseMPA1Entry(NSData *buf, NSUInteger *cur,
                                NSString **outKey, uint8_t *outDtype,
                                NSUInteger *outValueLength)
{
    const uint8_t *bytes = (const uint8_t *)buf.bytes;
    NSUInteger remaining = buf.length - *cur;
    if (remaining < 2) return NO;
    uint16_t keyLen = (uint16_t)bytes[*cur] | ((uint16_t)bytes[*cur + 1] << 8);
    *cur += 2;
    if (buf.length - *cur < keyLen + 5u) return NO;
    NSString *key =
        [[NSString alloc] initWithBytes:bytes + *cur
                                  length:keyLen
                                encoding:NSUTF8StringEncoding];
    *cur += keyLen;
    uint8_t dtype = bytes[*cur];
    *cur += 1;
    uint32_t vLen = (uint32_t)bytes[*cur]
                  | ((uint32_t)bytes[*cur + 1] << 8)
                  | ((uint32_t)bytes[*cur + 2] << 16)
                  | ((uint32_t)bytes[*cur + 3] << 24);
    *cur += 4;
    if (buf.length - *cur < vLen) return NO;
    *cur += vLen;
    if (outKey) *outKey = key;
    if (outDtype) *outDtype = dtype;
    if (outValueLength) *outValueLength = vLen;
    return YES;
}

static void testM90_12MPA1MSFixture(void)
{
    NSString *toolPath = @"/home/toddw/TTI-O/objc/Tools/obj/TtioPerAU";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        NSLog(@"M90.12: TtioPerAU not built; skipping MS fixture test");
        PASS(YES, "M90.12 MS: TtioPerAU not built (skipped)");
        return;
    }

    NSString *fxPath = m90fTmp(@"m12_ms.tio");
    NSString *encPath = m90fTmp(@"m12_ms_enc.tio");
    NSString *mpadPath = m90fTmp(@"m12_ms.mpad");
    NSString *keyPath = m90fTmp(@"m12_ms.key");
    m90fRm(fxPath); m90fRm(encPath); m90fRm(mpadPath); m90fRm(keyPath);

    NSError *err = nil;
    PASS(m90fBuildMSFixture(fxPath, &err),
         "M90.12 MS: build plaintext MS fixture");

    // Write a 32-byte zero key. ``TtioPerAU encrypt <in> <out> <key>``
    // copies <in> → <out> then encrypts <out> in place, so <in> and
    // <out> must be distinct paths.
    uint8_t zeroKey[32]; memset(zeroKey, 0, 32);
    [[NSData dataWithBytes:zeroKey length:32]
        writeToFile:keyPath atomically:YES];
    int rcEnc = m90fSpawnPerAU(@[@"encrypt", fxPath, encPath, keyPath]);
    PASS(rcEnc == 0, "M90.12 MS: TtioPerAU encrypt exits 0");

    int rcDec = m90fSpawnPerAU(@[@"decrypt", encPath, mpadPath, keyPath]);
    PASS(rcDec == 0, "M90.12 MS: TtioPerAU decrypt exits 0");

    NSData *mpad = [NSData dataWithContentsOfFile:mpadPath];
    PASS(mpad.length >= 8, "M90.12 MS: .mpad file has at least the header");
    if (mpad.length < 8) {
        m90fRm(fxPath); m90fRm(encPath); m90fRm(mpadPath); m90fRm(keyPath);
        return;
    }

    const uint8_t *bytes = (const uint8_t *)mpad.bytes;
    PASS(memcmp(bytes, "MPA1", 4) == 0,
         "M90.12 MS: 4-byte magic == 'MPA1' (post-bump)");
    uint32_t entryCount = (uint32_t)bytes[4]
                       | ((uint32_t)bytes[5] << 8)
                       | ((uint32_t)bytes[6] << 16)
                       | ((uint32_t)bytes[7] << 24);
    PASS(entryCount >= 2,
         "M90.12 MS: entry count covers at least mz + intensity");

    // Walk every entry; assert each MS channel carries dtype == 1
    // (FLOAT64) and value-byte length matches the plaintext channel
    // length (2 spectra × 4 peaks × 8 B = 64 B).
    NSUInteger cur = 8;
    BOOL anyFloat64 = NO;
    BOOL allChannelsAreF64 = YES;
    NSUInteger nChannelEntries = 0;
    for (uint32_t i = 0; i < entryCount; i++) {
        NSString *key = nil;
        uint8_t dtype = 0;
        NSUInteger vLen = 0;
        if (!m90fParseMPA1Entry(mpad, &cur, &key, &dtype, &vLen)) break;
        BOOL isMz = [key hasSuffix:@"__mz"];
        BOOL isInt = [key hasSuffix:@"__intensity"];
        if (isMz || isInt) {
            nChannelEntries++;
            if (dtype != 1) allChannelsAreF64 = NO;
            if (dtype == 1) anyFloat64 = YES;
            // 2 spectra × 4 peaks × 8 B/elem = 64 B
            if (vLen != 64) allChannelsAreF64 = NO;
        }
    }
    PASS(anyFloat64,
         "M90.12 MS: at least one entry has dtype byte == 1 (FLOAT64)");
    PASS(nChannelEntries >= 2,
         "M90.12 MS: mz + intensity entries both present");
    PASS(allChannelsAreF64,
         "M90.12 MS: every mz/intensity entry has dtype 1 + 64 B value");

    m90fRm(fxPath); m90fRm(encPath); m90fRm(mpadPath); m90fRm(keyPath);
}

static void testM90_12MPA1GenomicFixture(void)
{
    NSString *toolPath = @"/home/toddw/TTI-O/objc/Tools/obj/TtioPerAU";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:toolPath]) {
        NSLog(@"M90.12: TtioPerAU not built; skipping genomic fixture test");
        PASS(YES, "M90.12 genomic: TtioPerAU not built (skipped)");
        return;
    }

    NSString *fxPath = m90fTmp(@"m12_g.tio");
    NSString *encPath = m90fTmp(@"m12_g_enc.tio");
    NSString *mpadPath = m90fTmp(@"m12_g.mpad");
    NSString *keyPath = m90fTmp(@"m12_g.key");
    m90fRm(fxPath); m90fRm(encPath); m90fRm(mpadPath); m90fRm(keyPath);

    NSError *err = nil;
    PASS(m90fBuildHeadersFixture(fxPath, &err),
         "M90.12 genomic: build plaintext genomic fixture");

    uint8_t zeroKey[32]; memset(zeroKey, 0, 32);
    [[NSData dataWithBytes:zeroKey length:32]
        writeToFile:keyPath atomically:YES];
    int rcEnc = m90fSpawnPerAU(@[@"encrypt", fxPath, encPath, keyPath]);
    PASS(rcEnc == 0, "M90.12 genomic: TtioPerAU encrypt exits 0");
    int rcDec = m90fSpawnPerAU(@[@"decrypt", encPath, mpadPath, keyPath]);
    PASS(rcDec == 0, "M90.12 genomic: TtioPerAU decrypt exits 0");

    NSData *mpad = [NSData dataWithContentsOfFile:mpadPath];
    PASS(mpad.length >= 8,
         "M90.12 genomic: .mpad file has at least the header");
    if (mpad.length < 8) {
        m90fRm(fxPath); m90fRm(encPath); m90fRm(mpadPath); m90fRm(keyPath);
        return;
    }

    const uint8_t *bytes = (const uint8_t *)mpad.bytes;
    PASS(memcmp(bytes, "MPA1", 4) == 0,
         "M90.12 genomic: 4-byte magic == 'MPA1'");
    uint32_t entryCount = (uint32_t)bytes[4]
                       | ((uint32_t)bytes[5] << 8)
                       | ((uint32_t)bytes[6] << 16)
                       | ((uint32_t)bytes[7] << 24);
    PASS(entryCount >= 2,
         "M90.12 genomic: entry count covers sequences + qualities");

    // 4 reads × 8 bases/read = 32 B for both sequences and qualities.
    NSUInteger cur = 8;
    NSUInteger nUint8 = 0;
    BOOL allUint8 = YES;
    for (uint32_t i = 0; i < entryCount; i++) {
        NSString *key = nil;
        uint8_t dtype = 0;
        NSUInteger vLen = 0;
        if (!m90fParseMPA1Entry(mpad, &cur, &key, &dtype, &vLen)) break;
        BOOL isSeq = [key hasSuffix:@"__sequences"];
        BOOL isQual = [key hasSuffix:@"__qualities"];
        if (isSeq || isQual) {
            nUint8++;
            if (dtype != 6) allUint8 = NO;
            // 4 reads × 8 = 32 B; the M90.12 invariant is that
            // genomic uint8 channels stay 1 B/element rather than
            // being inflated 8x by a pre-cast to float64.
            if (vLen != 32) allUint8 = NO;
        }
    }
    PASS(nUint8 >= 2,
         "M90.12 genomic: sequences + qualities entries both present");
    PASS(allUint8,
         "M90.12 genomic: every sequences/qualities entry has dtype 6 + "
         "32 B value (uint8, 1 B/elem)");

    m90fRm(fxPath); m90fRm(encPath); m90fRm(mpadPath); m90fRm(keyPath);
}


// ── M90.13: SAM-overlap region masking ──────────────────────────

// Build the 6-read overlap fixture used by python/test_m90_13.
static BOOL m90fBuildOverlapFixture(NSString *path, NSError **error)
{
    NSUInteger n = 6;
    NSUInteger L = 8;
    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    for (NSUInteger i = 0; i < n; i++) {
        [seqData appendBytes:"ACGTACGT" length:L];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    memset(qualData.mutableBytes, 30, n * L);

    NSMutableData *posData =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pos = (int64_t *)posData.mutableBytes;
    pos[0]=50; pos[1]=95; pos[2]=100; pos[3]=150; pos[4]=200; pos[5]=250;
    NSMutableData *mapqData = [NSMutableData dataWithLength:n];
    memset(mapqData.mutableBytes, 60, n);
    NSMutableData *flagsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *flags = (uint32_t *)flagsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) flags[i] = 0x0003;

    NSMutableData *offsetsData =
        [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *off = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) off[i] = i * L;
    NSMutableData *lengthsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *len = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) len[i] = (uint32_t)L;

    NSArray *cigars = @[@"8M", @"8M", @"8M", @"4M2I2M", @"8M", @"8M"];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [names addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [mateChroms addObject:@""];
    }
    NSMutableData *matePosData =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *mp = (int64_t *)matePosData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) mp[i] = -1;
    NSMutableData *tlensData =
        [NSMutableData dataWithLength:n * sizeof(int32_t)];

    NSArray<NSString *> *chromosomes =
        @[@"chr1", @"chr1", @"chr1", @"chr1", @"chr1", @"chr1"];

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"NA12878"
                          positions:posData
                   mappingQualities:mapqData
                              flags:flagsData
                          sequences:seqData
                          qualities:qualData
                            offsets:offsetsData
                            lengths:lengthsData
                             cigars:cigars
                          readNames:names
                    mateChromosomes:mateChroms
                      matePositions:matePosData
                    templateLengths:tlensData
                        chromosomes:chromosomes
                  signalCompression:TTIOCompressionZlib];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"M90.13 overlap fixture"
                                 isaInvestigationId:@"ISA-M90-13"
                                             msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

static void testM90_13ReadStartingBeforeExtendingIntoRegion(void)
{
    NSString *src = m90fTmp(@"m13_overlap_src.tio");
    NSString *out = m90fTmp(@"m13_overlap_anon.tio");
    m90fRm(src); m90fRm(out);
    NSError *err = nil;
    m90fBuildOverlapFixture(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy =
        [[TTIOAnonymizationPolicy alloc] init];
    policy.maskRegions = @[ @[@"chr1", @100, @200] ];
    TTIOAnonymizationResult *r =
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
    PASS(r != nil, "M90.13: anonymize succeeds");
    PASS(r.readsInMaskedRegion == 4,
         "M90.13: 4 reads masked (1, 2, 3, 4)");
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    TTIOAlignedRead *r1 = [gr readAtIndex:1 error:&err];
    TTIOAlignedRead *r2 = [gr readAtIndex:2 error:&err];
    TTIOAlignedRead *r3 = [gr readAtIndex:3 error:&err];
    TTIOAlignedRead *r4 = [gr readAtIndex:4 error:&err];
    TTIOAlignedRead *r5 = [gr readAtIndex:5 error:&err];

    PASS([r0.sequence isEqualToString:@"ACGTACGT"],
         "M90.13: read 0 (pos=50, end=57) entirely before region — preserved");
    // Read 1: pos=95, CIGAR 8M -> end=102, region [100, 200] — must mask.
    NSData *r1bytes = [r1.sequence dataUsingEncoding:NSASCIIStringEncoding];
    BOOL r1zero = YES;
    const uint8_t *p1 = (const uint8_t *)r1bytes.bytes;
    for (NSUInteger j = 0; j < 8; j++) if (p1[j] != 0) { r1zero = NO; break; }
    PASS(r1zero, "M90.13: read 1 (pos=95, end=102) overlaps region — masked");
    // Read 2: pos=100, end=107 — masked
    NSData *r2bytes = [r2.sequence dataUsingEncoding:NSASCIIStringEncoding];
    BOOL r2zero = YES;
    const uint8_t *p2 = (const uint8_t *)r2bytes.bytes;
    for (NSUInteger j = 0; j < 8; j++) if (p2[j] != 0) { r2zero = NO; break; }
    PASS(r2zero, "M90.13: read 2 (pos=100) starts in region — masked");
    // Read 3: pos=150, CIGAR 4M2I2M -> 6 ref bases, end=155 — entirely in region — masked
    NSData *r3bytes = [r3.sequence dataUsingEncoding:NSASCIIStringEncoding];
    BOOL r3zero = YES;
    const uint8_t *p3 = (const uint8_t *)r3bytes.bytes;
    for (NSUInteger j = 0; j < 8; j++) if (p3[j] != 0) { r3zero = NO; break; }
    PASS(r3zero, "M90.13: read 3 entirely in region — masked");
    // Read 4: pos=200, end=207 — boundary inclusive — masked
    NSData *r4bytes = [r4.sequence dataUsingEncoding:NSASCIIStringEncoding];
    BOOL r4zero = YES;
    const uint8_t *p4 = (const uint8_t *)r4bytes.bytes;
    for (NSUInteger j = 0; j < 8; j++) if (p4[j] != 0) { r4zero = NO; break; }
    PASS(r4zero, "M90.13: read 4 (pos=200) boundary — masked");
    // Read 5: pos=250, end=257 — entirely after region — preserved
    PASS([r5.sequence isEqualToString:@"ACGTACGT"],
         "M90.13: read 5 entirely after region — preserved");

    [ds2 closeFile];
    m90fRm(src); m90fRm(out);
}

static void testM90_13CigarInsertionDoesNotConsumeRef(void)
{
    NSString *src = m90fTmp(@"m13_ins_src.tio");
    NSString *out = m90fTmp(@"m13_ins_anon.tio");
    m90fRm(src); m90fRm(out);
    NSError *err = nil;
    m90fBuildOverlapFixture(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy =
        [[TTIOAnonymizationPolicy alloc] init];
    // read 3: pos=150, CIGAR=4M2I2M -> 6 ref bases consumed, end=155.
    // Region [156, 1000] — read 3 must NOT be masked.
    policy.maskRegions = @[ @[@"chr1", @156, @1000] ];
    [TTIOAnonymizer anonymizeDataset:ds
                          outputPath:out
                              policy:policy
                               error:&err];
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    TTIOAlignedRead *r3 = [gr readAtIndex:3 error:&err];
    PASS([r3.sequence isEqualToString:@"ACGTACGT"],
         "M90.13: CIGAR 4M2I2M end=155, region [156,1000] — read NOT masked");
    [ds2 closeFile];
    m90fRm(src); m90fRm(out);
}

static void testM90_13EmptyCigarFallsBackToPosition(void)
{
    // Build single-read fixture with empty CIGAR at pos=95. Region
    // [100, 200] — pos=95 < 100 so position-only check leaves the
    // read NOT masked (preserves M90.3 behaviour).
    NSString *path = m90fTmp(@"m13_empty.tio");
    NSString *out = m90fTmp(@"m13_empty_anon.tio");
    m90fRm(path); m90fRm(out);
    NSError *err = nil;

    NSUInteger n = 1, L = 8;
    NSMutableData *seqData = [NSMutableData dataWithBytes:"ACGTACGT" length:L];
    NSMutableData *qualData = [NSMutableData dataWithLength:L];
    memset(qualData.mutableBytes, 30, L);
    int64_t pos = 95;
    NSData *posData = [NSData dataWithBytes:&pos length:sizeof(pos)];
    uint8_t mq = 60;
    NSData *mapqData = [NSData dataWithBytes:&mq length:1];
    uint32_t fl = 0x0003;
    NSData *flagsData = [NSData dataWithBytes:&fl length:sizeof(fl)];
    uint64_t off = 0;
    NSData *offsetsData = [NSData dataWithBytes:&off length:sizeof(off)];
    uint32_t len = (uint32_t)L;
    NSData *lengthsData = [NSData dataWithBytes:&len length:sizeof(len)];
    int64_t mp = -1;
    NSData *matePosData = [NSData dataWithBytes:&mp length:sizeof(mp)];
    int32_t tl = 0;
    NSData *tlensData = [NSData dataWithBytes:&tl length:sizeof(tl)];

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"NA12878"
                          positions:posData
                   mappingQualities:mapqData
                              flags:flagsData
                          sequences:seqData
                          qualities:qualData
                            offsets:offsetsData
                            lengths:lengthsData
                             cigars:@[@""]
                          readNames:@[@"r0"]
                    mateChromosomes:@[@""]
                      matePositions:matePosData
                    templateLengths:tlensData
                        chromosomes:@[@"chr1"]
                  signalCompression:TTIOCompressionZlib];
    [TTIOSpectralDataset writeMinimalToPath:path
                                       title:@"x"
                          isaInvestigationId:@"x"
                                      msRuns:@{}
                                  genomicRuns:@{@"genomic_0001": run}
                              identifications:nil
                              quantifications:nil
                            provenanceRecords:nil
                                        error:&err];
    (void)n;

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOAnonymizationPolicy *policy =
        [[TTIOAnonymizationPolicy alloc] init];
    policy.maskRegions = @[ @[@"chr1", @100, @200] ];
    [TTIOAnonymizer anonymizeDataset:ds outputPath:out policy:policy error:&err];
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    PASS([r0.sequence isEqualToString:@"ACGTACGT"],
         "M90.13 fallback: empty CIGAR + pos=95 < 100 — read NOT masked");
    [ds2 closeFile];
    m90fRm(path); m90fRm(out);
}


// ── M90.14: seeded RNG qualities ─────────────────────────────────

// Build a 4-read genomic fixture for the M90.14 test with distinct
// per-read qualities (10, 11, 12, 13) so any leak of source bytes
// is detectable.
static BOOL m90fBuildSeededFixture(NSString *path, NSError **error)
{
    NSUInteger n = 4;
    NSUInteger L = 8;
    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    for (NSUInteger i = 0; i < n; i++) {
        [seqData appendBytes:"ACGTACGT" length:L];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    uint8_t *q = (uint8_t *)qualData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        memset(q + i * L, (int)(10 + i), L);
    }

    NSMutableData *posData =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pos = (int64_t *)posData.mutableBytes;
    pos[0]=100; pos[1]=200; pos[2]=300; pos[3]=400;
    NSMutableData *mapqData = [NSMutableData dataWithLength:n];
    memset(mapqData.mutableBytes, 60, n);
    NSMutableData *flagsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *flags = (uint32_t *)flagsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) flags[i] = 0x0003;

    NSMutableData *offsetsData =
        [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *off = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) off[i] = i * L;
    NSMutableData *lengthsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *len = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) len[i] = (uint32_t)L;

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)L]];
        [names addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [mateChroms addObject:@""];
    }
    NSMutableData *matePosData =
        [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *mp = (int64_t *)matePosData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) mp[i] = -1;
    NSMutableData *tlensData =
        [NSMutableData dataWithLength:n * sizeof(int32_t)];

    NSArray<NSString *> *chromosomes =
        @[@"chr1", @"chr1", @"chr1", @"chr1"];

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"NA12878"
                          positions:posData
                   mappingQualities:mapqData
                              flags:flagsData
                          sequences:seqData
                          qualities:qualData
                            offsets:offsetsData
                            lengths:lengthsData
                             cigars:cigars
                          readNames:names
                    mateChromosomes:mateChroms
                      matePositions:matePosData
                    templateLengths:tlensData
                        chromosomes:chromosomes
                  signalCompression:TTIOCompressionZlib];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"M90.14 seeded fixture"
                                 isaInvestigationId:@"ISA-M90-14"
                                             msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

static void testM90_14SeedReproducible(void)
{
    NSString *src = m90fTmp(@"m14_src.tio");
    NSString *outA = m90fTmp(@"m14_a.tio");
    NSString *outB = m90fTmp(@"m14_b.tio");
    m90fRm(src); m90fRm(outA); m90fRm(outB);
    NSError *err = nil;
    m90fBuildSeededFixture(src, &err);

    for (int pass = 0; pass < 2; pass++) {
        NSString *out = (pass == 0) ? outA : outB;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
        TTIOAnonymizationPolicy *policy =
            [[TTIOAnonymizationPolicy alloc] init];
        policy.randomiseQualities = YES;
        policy.randomiseQualitiesSeed = @42;
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
        [ds closeFile];
    }

    TTIOSpectralDataset *dsA = [TTIOSpectralDataset readFromFilePath:outA error:&err];
    TTIOSpectralDataset *dsB = [TTIOSpectralDataset readFromFilePath:outB error:&err];
    TTIOGenomicRun *grA = dsA.genomicRuns[@"genomic_0001"];
    TTIOGenomicRun *grB = dsB.genomicRuns[@"genomic_0001"];
    BOOL equal = YES;
    for (NSUInteger i = 0; i < grA.readCount; i++) {
        TTIOAlignedRead *ra = [grA readAtIndex:i error:&err];
        TTIOAlignedRead *rb = [grB readAtIndex:i error:&err];
        if (![ra.qualities isEqualToData:rb.qualities]) { equal = NO; break; }
    }
    PASS(equal, "M90.14: same seed produces same qualities");
    [dsA closeFile]; [dsB closeFile];
    m90fRm(src); m90fRm(outA); m90fRm(outB);
}

static void testM90_14DifferentSeedsDiffer(void)
{
    NSString *src = m90fTmp(@"m14d_src.tio");
    NSString *outA = m90fTmp(@"m14d_a.tio");
    NSString *outB = m90fTmp(@"m14d_b.tio");
    m90fRm(src); m90fRm(outA); m90fRm(outB);
    NSError *err = nil;
    m90fBuildSeededFixture(src, &err);

    NSNumber *seeds[2] = {@42, @99};
    for (int pass = 0; pass < 2; pass++) {
        NSString *out = (pass == 0) ? outA : outB;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
        TTIOAnonymizationPolicy *policy =
            [[TTIOAnonymizationPolicy alloc] init];
        policy.randomiseQualities = YES;
        policy.randomiseQualitiesSeed = seeds[pass];
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
        [ds closeFile];
    }

    TTIOSpectralDataset *dsA = [TTIOSpectralDataset readFromFilePath:outA error:&err];
    TTIOSpectralDataset *dsB = [TTIOSpectralDataset readFromFilePath:outB error:&err];
    TTIOGenomicRun *grA = dsA.genomicRuns[@"genomic_0001"];
    TTIOGenomicRun *grB = dsB.genomicRuns[@"genomic_0001"];
    BOOL anyDiff = NO;
    for (NSUInteger i = 0; i < grA.readCount; i++) {
        TTIOAlignedRead *ra = [grA readAtIndex:i error:&err];
        TTIOAlignedRead *rb = [grB readAtIndex:i error:&err];
        if (![ra.qualities isEqualToData:rb.qualities]) { anyDiff = YES; break; }
    }
    PASS(anyDiff, "M90.14: different seeds produce different qualities");
    [dsA closeFile]; [dsB closeFile];
    m90fRm(src); m90fRm(outA); m90fRm(outB);
}

static void testM90_14SeededInPhredRange(void)
{
    NSString *src = m90fTmp(@"m14r_src.tio");
    NSString *out = m90fTmp(@"m14r_anon.tio");
    m90fRm(src); m90fRm(out);
    NSError *err = nil;
    m90fBuildSeededFixture(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy =
        [[TTIOAnonymizationPolicy alloc] init];
    policy.randomiseQualities = YES;
    policy.randomiseQualitiesSeed = @42;
    [TTIOAnonymizer anonymizeDataset:ds outputPath:out policy:policy error:&err];
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    BOOL inRange = YES;
    for (NSUInteger i = 0; i < gr.readCount; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        const uint8_t *qb = (const uint8_t *)r.qualities.bytes;
        for (NSUInteger j = 0; j < r.qualities.length; j++) {
            if (qb[j] > 93) { inRange = NO; break; }
        }
        if (!inRange) break;
    }
    PASS(inRange, "M90.14: seeded Phred bytes in [0, 93]");
    [ds2 closeFile];
    m90fRm(src); m90fRm(out);
}

static void testM90_14NoSeedUsesConstant(void)
{
    NSString *src = m90fTmp(@"m14c_src.tio");
    NSString *out = m90fTmp(@"m14c_anon.tio");
    m90fRm(src); m90fRm(out);
    NSError *err = nil;
    m90fBuildSeededFixture(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy =
        [[TTIOAnonymizationPolicy alloc] init];
    policy.randomiseQualities = YES;
    policy.randomiseQualitiesConstant = 30;
    // randomiseQualitiesSeed left nil -> constant path
    [TTIOAnonymizer anonymizeDataset:ds outputPath:out policy:policy error:&err];
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    BOOL allConst = YES;
    for (NSUInteger i = 0; i < gr.readCount; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        const uint8_t *qb = (const uint8_t *)r.qualities.bytes;
        for (NSUInteger j = 0; j < r.qualities.length; j++) {
            if (qb[j] != 30) { allConst = NO; break; }
        }
        if (!allConst) break;
    }
    PASS(allConst, "M90.14: nil seed → constant-replacement path (M90.3)");
    [ds2 closeFile];
    m90fRm(src); m90fRm(out);
}


// ── M90.15: chromosomes signing ──────────────────────────────────

static void testM90_15ChromosomesSigned(void)
{
    NSString *path = m90fTmp(@"m15_sign.tio");
    m90fRm(path);
    NSError *err = nil;
    m90fBuildHeadersFixture(path, &err);

    NSDictionary *sigs =
        [TTIOSignatureManager signGenomicRun:@"genomic_0001"
                                      inFile:path
                                     withKey:m90fKey(0x42)
                                       error:&err];
    PASS(sigs != nil, "M90.15: signGenomicRun returned dict");
    PASS(sigs[@"genomic_index/chromosomes"] != nil,
         "M90.15: chromosomes compound signed");
    NSString *sig = sigs[@"genomic_index/chromosomes"];
    PASS([sig hasPrefix:@"v2:"],
         "M90.15: chromosomes signature carries v2: prefix");

    BOOL verified =
        [TTIOSignatureManager verifyGenomicRun:@"genomic_0001"
                                         inFile:path
                                        withKey:m90fKey(0x42)
                                          error:&err];
    PASS(verified,
         "M90.15: verifyGenomicRun YES on clean run with chromosomes");
    m90fRm(path);
}


// ── Public entry point ──────────────────────────────────────────

void testM90Final(void)
{
    testM90_11HeadersStripsPlaintext();
    testM90_11HeadersRoundTrip();
    testM90_11DecryptWithoutHeadersKeyFails();
    testM90_11ComposedHeadersAndRegion();
    testM90_11RegionOnlyNoHeadersFlag();

    testM90_12MPA1MSFixture();
    testM90_12MPA1GenomicFixture();

    testM90_13ReadStartingBeforeExtendingIntoRegion();
    testM90_13CigarInsertionDoesNotConsumeRef();
    testM90_13EmptyCigarFallsBackToPosition();

    testM90_14SeedReproducible();
    testM90_14DifferentSeedsDiffer();
    testM90_14SeededInPhredRange();
    testM90_14NoSeedUsesConstant();

    testM90_15ChromosomesSigned();
}
