/*
 * TestM90GenomicProtection.m — M90 Genomic Protection ObjC parity.
 *
 * Mirrors python/tests/test_m90_1_genomic_per_au_encryption.py,
 * test_m90_2_genomic_signatures.py, test_m90_3_genomic_anonymisation.py,
 * and test_m90_4_region_encryption.py.
 *
 *   M90.1 — per-AU AES-256-GCM on /study/genomic_runs/<n>/signal_channels
 *   M90.2 — sign/verify helpers spanning every signal channel + index column
 *   M90.3 — anonymisation policies for genomic runs
 *   M90.4 — region-based per-AU encryption (per-chromosome key dispatch)
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

static NSString *m90TmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m90_%d_%@",
            (int)getpid(), suffix];
}

static void m90RmFile(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSData *m90Key(uint8_t byte)
{
    uint8_t buf[32]; memset(buf, byte, 32);
    return [NSData dataWithBytes:buf length:32];
}


// Build a small genomic-only fixture: 4 reads × 8 bases.
//   sequences = "ACGTACGTACGTACGTACGTACGTACGTACGT" (32 bytes)
//   qualities = 32 × 30
static BOOL m90BuildSimpleGenomic(NSString *path,
                                    NSArray<NSString *> *chromosomes,
                                    NSError **error)
{
    NSUInteger n = chromosomes.count;
    NSUInteger L = 8;

    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    const uint8_t pattern[] = {'A','C','G','T','A','C','G','T'};
    for (NSUInteger i = 0; i < n; i++) {
        [seqData appendBytes:pattern length:L];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    memset(qualData.mutableBytes, 30, n * L);

    NSMutableData *posData = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pos = (int64_t *)posData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        pos[i] = (int64_t)((i + 1) * 100);
    }
    NSMutableData *mapqData = [NSMutableData dataWithLength:n];
    memset(mapqData.mutableBytes, 60, n);
    NSMutableData *flagsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *flagsPtr = (uint32_t *)flagsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) flagsPtr[i] = 0x0003;

    NSMutableData *offsetsData =
        [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *off = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) off[i] = i * L;

    NSMutableData *lengthsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *len = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) len[i] = (uint32_t)L;

    NSMutableArray<NSString *> *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *names  = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *mateChroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)L]];
        [names  addObject:[NSString stringWithFormat:@"read_%03lu", (unsigned long)i]];
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
                                              title:@"M90 fixture"
                                 isaInvestigationId:@"ISA-M90"
                                             msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}


// ────────────────────────────────────────────────────────────────────
// M90.1 — per-AU encryption on genomic signal channels
// ────────────────────────────────────────────────────────────────────

static void testM90_1EncryptStripsPlaintext(void)
{
    NSString *path = m90TmpPath(@"m901_strip.tio");
    m90RmFile(path);
    NSError *err = nil;
    PASS(m90BuildSimpleGenomic(path,
                                @[@"chr1", @"chr1", @"chr2", @"chr2"], &err),
         "M90.1: build genomic fixture");

    BOOL ok = [TTIOPerAUFile encryptFilePath:path
                                         key:m90Key(0x42)
                              encryptHeaders:NO
                                providerName:nil
                                       error:&err];
    PASS(ok, "M90.1: encryptFilePath on genomic-only succeeds");

    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    TTIOHDF5Group *root = f.rootGroup;
    NSArray *features = [TTIOFeatureFlags featuresForRoot:root] ?: @[];
    PASS([features containsObject:@"opt_per_au_encryption"],
         "M90.1: opt_per_au_encryption flag set");
    TTIOHDF5Group *sig =
        [[[[root openGroupNamed:@"study" error:NULL]
            openGroupNamed:@"genomic_runs" error:NULL]
                openGroupNamed:@"genomic_0001" error:NULL]
                    openGroupNamed:@"signal_channels" error:NULL];
    PASS([sig hasChildNamed:@"sequences_segments"],
         "M90.1: sequences_segments compound created");
    PASS([sig hasChildNamed:@"qualities_segments"],
         "M90.1: qualities_segments compound created");
    PASS(![sig hasChildNamed:@"sequences"],
         "M90.1: bare sequences dataset deleted");
    PASS(![sig hasChildNamed:@"qualities"],
         "M90.1: bare qualities dataset deleted");
    [f close];
    m90RmFile(path);
}

static void testM90_1RoundTripByteExact(void)
{
    NSString *path = m90TmpPath(@"m901_rt.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildSimpleGenomic(path,
                            @[@"chr1", @"chr1", @"chr2", @"chr2"], &err);

    // Capture original plaintext bytes.
    NSMutableData *origSeq = [NSMutableData data];
    const uint8_t pattern[] = {'A','C','G','T','A','C','G','T'};
    for (int i = 0; i < 4; i++) [origSeq appendBytes:pattern length:8];
    NSMutableData *origQual = [NSMutableData dataWithLength:32];
    memset(origQual.mutableBytes, 30, 32);

    BOOL ok = [TTIOPerAUFile encryptFilePath:path
                                         key:m90Key(0x42)
                              encryptHeaders:NO
                                providerName:nil
                                       error:&err];
    PASS(ok, "M90.1: encrypt for round-trip");

    NSDictionary *plain = [TTIOPerAUFile decryptFilePath:path
                                                      key:m90Key(0x42)
                                             providerName:nil
                                                    error:&err];
    PASS(plain != nil, "M90.1: decryptFilePath succeeds");
    NSDictionary *runOut = plain[@"genomic_0001"];
    PASS(runOut != nil, "M90.1: genomic_0001 in decrypt result");
    PASS([runOut[@"sequences"] isEqualToData:origSeq],
         "M90.1: sequences round-trip byte-exact uint8");
    PASS([runOut[@"qualities"] isEqualToData:origQual],
         "M90.1: qualities round-trip byte-exact uint8");

    m90RmFile(path);
}

static void testM90_1WrongKeyRejected(void)
{
    NSString *path = m90TmpPath(@"m901_wrongkey.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildSimpleGenomic(path, @[@"chr1", @"chr1", @"chr2", @"chr2"], &err);

    [TTIOPerAUFile encryptFilePath:path
                                key:m90Key(0x42)
                     encryptHeaders:NO
                       providerName:nil
                              error:&err];
    err = nil;
    NSDictionary *plain = [TTIOPerAUFile decryptFilePath:path
                                                      key:m90Key(0xFF)
                                             providerName:nil
                                                    error:&err];
    PASS(plain == nil && err != nil,
         "M90.1: wrong key rejected (AES-GCM auth)");
    m90RmFile(path);
}


// ────────────────────────────────────────────────────────────────────
// M90.2 — signatures over genomic datasets
// ────────────────────────────────────────────────────────────────────

static void testM90_2HmacSequencesRoundTrip(void)
{
    NSString *path = m90TmpPath(@"m902_seq.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildSimpleGenomic(path, @[@"chr1", @"chr1", @"chr2", @"chr2"], &err);

    NSData *key = m90Key(0x42);
    NSString *dsPath = @"/study/genomic_runs/genomic_0001/signal_channels/sequences";
    BOOL ok = [TTIOSignatureManager signDataset:dsPath
                                         inFile:path
                                        withKey:key
                                          error:&err];
    PASS(ok, "M90.2: sign sequences dataset (hmac-sha256)");
    BOOL verified = [TTIOSignatureManager verifyDataset:dsPath
                                                  inFile:path
                                                 withKey:key
                                                   error:&err];
    PASS(verified, "M90.2: verify sequences round-trips");
    err = nil;
    BOOL wrong = [TTIOSignatureManager verifyDataset:dsPath
                                                inFile:path
                                               withKey:m90Key(0x00)
                                                 error:&err];
    PASS(!wrong, "M90.2: wrong key rejected on sequences");
    m90RmFile(path);
}

static void testM90_2HmacQualitiesRoundTrip(void)
{
    NSString *path = m90TmpPath(@"m902_qual.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildSimpleGenomic(path, @[@"chr1", @"chr1", @"chr2", @"chr2"], &err);

    NSData *key = m90Key(0x42);
    NSString *dsPath = @"/study/genomic_runs/genomic_0001/signal_channels/qualities";
    [TTIOSignatureManager signDataset:dsPath
                               inFile:path
                              withKey:key
                                error:&err];
    BOOL verified = [TTIOSignatureManager verifyDataset:dsPath
                                                  inFile:path
                                                 withKey:key
                                                   error:&err];
    PASS(verified, "M90.2: verify qualities round-trips");
    m90RmFile(path);
}

static void testM90_2SignGenomicRunSignsAllSeven(void)
{
    NSString *path = m90TmpPath(@"m902_run.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildSimpleGenomic(path, @[@"chr1", @"chr1", @"chr2", @"chr2"], &err);

    NSDictionary *sigs = [TTIOSignatureManager signGenomicRun:@"genomic_0001"
                                                       inFile:path
                                                      withKey:m90Key(0x42)
                                                        error:&err];
    PASS(sigs != nil, "M90.2: signGenomicRun returns dict");
    PASS(sigs[@"signal_channels/sequences"] != nil,
         "M90.2: signal_channels/sequences signed");
    PASS(sigs[@"signal_channels/qualities"] != nil,
         "M90.2: signal_channels/qualities signed");
    PASS(sigs[@"genomic_index/offsets"] != nil,
         "M90.2: genomic_index/offsets signed");
    PASS(sigs[@"genomic_index/lengths"] != nil,
         "M90.2: genomic_index/lengths signed");
    PASS(sigs[@"genomic_index/positions"] != nil,
         "M90.2: genomic_index/positions signed");
    PASS(sigs[@"genomic_index/mapping_qualities"] != nil,
         "M90.2: genomic_index/mapping_qualities signed");
    PASS(sigs[@"genomic_index/flags"] != nil,
         "M90.2: genomic_index/flags signed");

    BOOL verified = [TTIOSignatureManager verifyGenomicRun:@"genomic_0001"
                                                     inFile:path
                                                    withKey:m90Key(0x42)
                                                      error:&err];
    PASS(verified, "M90.2: verifyGenomicRun YES on clean signed run");
    m90RmFile(path);
}

static void testM90_2VerifyDetectsTamper(void)
{
    NSString *path = m90TmpPath(@"m902_tamper.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildSimpleGenomic(path, @[@"chr1", @"chr1", @"chr2", @"chr2"], &err);

    NSData *key = m90Key(0x42);
    [TTIOSignatureManager signGenomicRun:@"genomic_0001"
                                  inFile:path
                                 withKey:key
                                   error:&err];

    // Tamper with the sequences dataset directly via libhdf5: flip
    // the first byte. We have to open RW.
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:NULL];
    hid_t did = H5Dopen2(f.rootGroup.groupId,
        "/study/genomic_runs/genomic_0001/signal_channels/sequences",
        H5P_DEFAULT);
    if (did >= 0) {
        uint8_t buf[32];
        H5Dread(did, H5T_STD_U8LE, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
        buf[0] ^= 0x01;
        H5Dwrite(did, H5T_STD_U8LE, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
        H5Dclose(did);
    }
    [f close];

    err = nil;
    BOOL verified = [TTIOSignatureManager verifyGenomicRun:@"genomic_0001"
                                                     inFile:path
                                                    withKey:key
                                                      error:&err];
    PASS(!verified, "M90.2: verifyGenomicRun NO after byte tampering");
    m90RmFile(path);
}


// ────────────────────────────────────────────────────────────────────
// M90.3 — genomic anonymisation policies
// ────────────────────────────────────────────────────────────────────

// Build the M90.3 fixture: 6 reads on chr1/chr1/chr2/chr3/chr3/chr3.
// Distinct quality per read so we can prove randomisation worked.
static BOOL m90BuildSixReadGenomic(NSString *path, NSError **error)
{
    NSUInteger n = 6;
    NSUInteger L = 8;
    NSArray<NSString *> *chromosomes =
        @[@"chr1", @"chr1", @"chr2", @"chr3", @"chr3", @"chr3"];

    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    const uint8_t pattern[] = {'A','C','G','T','A','C','G','T'};
    for (NSUInteger i = 0; i < n; i++) {
        [seqData appendBytes:pattern length:L];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    uint8_t *q = (uint8_t *)qualData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        memset(q + i * L, (int)(10 + i), L);
    }

    NSMutableData *posData = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pos = (int64_t *)posData.mutableBytes;
    pos[0]=100; pos[1]=200; pos[2]=50;
    pos[3]=1000; pos[4]=2000; pos[5]=3000;

    NSMutableData *mapqData = [NSMutableData dataWithLength:n];
    memset(mapqData.mutableBytes, 60, n);
    NSMutableData *flagsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *flagsPtr = (uint32_t *)flagsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) flagsPtr[i] = 0x0003;

    NSMutableData *offsetsData =
        [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *off = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) off[i] = i * L;
    NSMutableData *lengthsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *len = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) len[i] = (uint32_t)L;

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names  = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)L]];
        [names  addObject:[NSString stringWithFormat:@"sensitive_id_%04lu",
                            (unsigned long)i]];
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
                                              title:@"M90.3 fixture"
                                 isaInvestigationId:@"ISA-M90-3"
                                             msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

static void testM90_3StripReadNames(void)
{
    NSString *src = m90TmpPath(@"m903_src1.tio");
    NSString *out = m90TmpPath(@"m903_anon1.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    policy.stripReadNames = YES;
    TTIOAnonymizationResult *r =
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
    PASS(r != nil, "M90.3 strip: anonymize succeeded");
    PASS(r.readNamesStripped == 6, "M90.3 strip: readNamesStripped == 6");
    PASS([r.policiesApplied containsObject:@"strip_read_names"],
         "M90.3 strip: strip_read_names recorded");
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    PASS(gr.readCount == 6, "M90.3 strip: read count preserved");
    BOOL allEmpty = YES;
    for (NSUInteger i = 0; i < gr.readCount; i++) {
        TTIOAlignedRead *rd = [gr readAtIndex:i error:&err];
        if (rd.readName.length != 0) { allEmpty = NO; break; }
    }
    PASS(allEmpty, "M90.3 strip: every read_name == empty string");
    [ds2 closeFile];
    m90RmFile(src); m90RmFile(out);
}

static void testM90_3RandomiseQualities(void)
{
    NSString *src = m90TmpPath(@"m903_src2.tio");
    NSString *out = m90TmpPath(@"m903_anon2.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    policy.randomiseQualities = YES;  // default constant 30
    TTIOAnonymizationResult *r =
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
    PASS(r != nil, "M90.3 randomise: anonymize succeeded");
    PASS(r.qualitiesRandomised == 6, "M90.3 randomise: qualitiesRandomised == 6");
    PASS([r.policiesApplied containsObject:@"randomise_qualities"],
         "M90.3 randomise: randomise_qualities recorded");
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    BOOL allThirty = YES;
    for (NSUInteger i = 0; i < gr.readCount; i++) {
        TTIOAlignedRead *rd = [gr readAtIndex:i error:&err];
        const uint8_t *qb = (const uint8_t *)rd.qualities.bytes;
        for (NSUInteger j = 0; j < rd.qualities.length; j++) {
            if (qb[j] != 30) { allThirty = NO; break; }
        }
        if (!allThirty) break;
    }
    PASS(allThirty, "M90.3 randomise: every Phred byte == 30 (default)");
    [ds2 closeFile];
    m90RmFile(src); m90RmFile(out);
}

static void testM90_3RandomiseQualitiesCustomConstant(void)
{
    NSString *src = m90TmpPath(@"m903_src2c.tio");
    NSString *out = m90TmpPath(@"m903_anon2c.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    policy.randomiseQualities = YES;
    policy.randomiseQualitiesConstant = 42;
    [TTIOAnonymizer anonymizeDataset:ds
                          outputPath:out
                              policy:policy
                               error:&err];
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    const uint8_t *qb = (const uint8_t *)r0.qualities.bytes;
    BOOL allFortyTwo = YES;
    for (NSUInteger j = 0; j < r0.qualities.length; j++) {
        if (qb[j] != 42) { allFortyTwo = NO; break; }
    }
    PASS(allFortyTwo,
         "M90.3 randomise custom: per-base Phred == 42 (custom constant)");
    [ds2 closeFile];
    m90RmFile(src); m90RmFile(out);
}

static void testM90_3MaskRegionsSingle(void)
{
    NSString *src = m90TmpPath(@"m903_src3.tio");
    NSString *out = m90TmpPath(@"m903_anon3.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    // Mask all of chr1 (positions 0..1000).
    policy.maskRegions = @[ @[@"chr1", @0, @1000] ];
    TTIOAnonymizationResult *r =
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
    PASS(r != nil, "M90.3 mask: anonymize succeeded");
    PASS(r.readsInMaskedRegion == 2,
         "M90.3 mask single: reads_in_masked_region == 2 (chr1@100, chr1@200)");
    PASS([r.policiesApplied containsObject:@"mask_regions"],
         "M90.3 mask: mask_regions recorded");
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    PASS(gr.readCount == 6, "M90.3 mask: read count preserved");
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    TTIOAlignedRead *r2 = [gr readAtIndex:2 error:&err];
    BOOL r0AllZero = YES;
    const uint8_t *r0bytes = (const uint8_t *)
        [r0.sequence dataUsingEncoding:NSASCIIStringEncoding].bytes;
    for (NSUInteger j = 0; j < 8; j++) {
        if (r0bytes[j] != 0) { r0AllZero = NO; break; }
    }
    PASS(r0AllZero, "M90.3 mask: read 0 (chr1) sequence zeroed");
    PASS([r2.sequence isEqualToString:@"ACGTACGT"],
         "M90.3 mask: read 2 (chr2) sequence preserved");
    [ds2 closeFile];
    m90RmFile(src); m90RmFile(out);
}

static void testM90_3MaskRegionsMultiple(void)
{
    NSString *src = m90TmpPath(@"m903_src4.tio");
    NSString *out = m90TmpPath(@"m903_anon4.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    policy.maskRegions = @[
        @[@"chr1", @0, @1000],
        @[@"chr3", @1500, @2500],
    ];
    TTIOAnonymizationResult *r =
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
    PASS(r.readsInMaskedRegion == 3,
         "M90.3 mask multi: 2 chr1 + 1 chr3 (pos 2000) = 3");
    [ds closeFile];
    m90RmFile(src); m90RmFile(out);
}

static void testM90_3CombinedPolicies(void)
{
    NSString *src = m90TmpPath(@"m903_src5.tio");
    NSString *out = m90TmpPath(@"m903_anon5.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    policy.stripReadNames = YES;
    policy.maskRegions = @[ @[@"chr1", @0, @1000] ];
    TTIOAnonymizationResult *r =
        [TTIOAnonymizer anonymizeDataset:ds
                              outputPath:out
                                  policy:policy
                                   error:&err];
    PASS(r.readNamesStripped == 6, "M90.3 combined: 6 read names stripped");
    PASS(r.readsInMaskedRegion == 2,
         "M90.3 combined: 2 reads in masked region");
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    PASS(r0.readName.length == 0,
         "M90.3 combined: read 0 read_name empty");
    [ds2 closeFile];
    m90RmFile(src); m90RmFile(out);
}

static void testM90_3NoOpPreservesGenomic(void)
{
    NSString *src = m90TmpPath(@"m903_src6.tio");
    NSString *out = m90TmpPath(@"m903_anon6.tio");
    m90RmFile(src); m90RmFile(out);
    NSError *err = nil;
    m90BuildSixReadGenomic(src, &err);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:src error:&err];
    TTIOAnonymizationPolicy *policy = [[TTIOAnonymizationPolicy alloc] init];
    [TTIOAnonymizer anonymizeDataset:ds
                          outputPath:out
                              policy:policy
                               error:&err];
    [ds closeFile];

    TTIOSpectralDataset *ds2 = [TTIOSpectralDataset readFromFilePath:out error:&err];
    TTIOGenomicRun *gr = ds2.genomicRuns[@"genomic_0001"];
    PASS(gr.readCount == 6, "M90.3 noop: read count preserved");
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    PASS([r0.readName isEqualToString:@"sensitive_id_0000"],
         "M90.3 noop: read names preserved verbatim");
    PASS([r0.sequence isEqualToString:@"ACGTACGT"],
         "M90.3 noop: sequences preserved verbatim");
    [ds2 closeFile];
    m90RmFile(src); m90RmFile(out);
}


// ────────────────────────────────────────────────────────────────────
// M90.4 — region-based per-AU encryption
// ────────────────────────────────────────────────────────────────────

// Build the M90.4 fixture: 6 reads, chr1 / chr1 / chr6 / chr6 / chrX / chrX
// with distinct sequences per chromosome group.
static BOOL m90BuildRegionFixture(NSString *path, NSError **error)
{
    NSUInteger n = 6;
    NSUInteger L = 8;
    NSArray *chromosomes = @[
        @"chr1", @"chr1", @"chr6", @"chr6", @"chrX", @"chrX",
    ];
    const uint8_t pattern[6][8] = {
        {'A','A','A','A','A','A','A','A'},   // chr1 read 0
        {'T','T','T','T','T','T','T','T'},   // chr1 read 1
        {'G','G','G','G','G','G','G','G'},   // chr6 read 0
        {'C','C','C','C','C','C','C','C'},   // chr6 read 1
        {'N','N','N','N','N','N','N','N'},   // chrX read 0
        {'A','C','G','T','A','C','G','T'},   // chrX read 1
    };
    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    for (NSUInteger i = 0; i < n; i++) {
        [seqData appendBytes:pattern[i] length:L];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    uint8_t *q = (uint8_t *)qualData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        memset(q + i * L, (int)(20 + i), L);
    }

    NSMutableData *posData = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pos = (int64_t *)posData.mutableBytes;
    pos[0]=100; pos[1]=200; pos[2]=1000;
    pos[3]=1100; pos[4]=5000; pos[5]=5100;

    NSMutableData *mapqData = [NSMutableData dataWithLength:n];
    memset(mapqData.mutableBytes, 60, n);
    NSMutableData *flagsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *flagsPtr = (uint32_t *)flagsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) flagsPtr[i] = 0x0003;
    NSMutableData *offsetsData =
        [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *off = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) off[i] = i * L;
    NSMutableData *lengthsData =
        [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *len = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) len[i] = (uint32_t)L;

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names  = [NSMutableArray array];
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
                                              title:@"M90.4 region fixture"
                                 isaInvestigationId:@"ISA-M90-4"
                                             msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

static void testM90_4DecryptWithChr6KeyReturnsClear(void)
{
    NSString *path = m90TmpPath(@"m904_rt.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildRegionFixture(path, &err);
    NSData *keyHla = m90Key(0x42);

    BOOL ok = [TTIOPerAUFile encryptFilePathByRegion:path
                                                 keyMap:@{@"chr6": keyHla}
                                          providerName:nil
                                                 error:&err];
    PASS(ok, "M90.4: encryptFilePathByRegion (chr6 only) succeeds");

    NSDictionary *result =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{@"chr6": keyHla}
                                    providerName:nil
                                           error:&err];
    PASS(result != nil, "M90.4: decryptFilePathByRegion succeeds");
    NSData *seqs = result[@"genomic_0001"][@"sequences"];
    PASS(seqs.length == 48, "M90.4: 6 reads × 8 bases = 48 bytes total");
    const uint8_t *b = (const uint8_t *)seqs.bytes;
    PASS(memcmp(b + 0,  "AAAAAAAA", 8) == 0,
         "M90.4: chr1 read 0 (clear) returns 'A' bytes");
    PASS(memcmp(b + 16, "GGGGGGGG", 8) == 0,
         "M90.4: chr6 read 0 (decrypted) returns 'G' bytes");
    PASS(memcmp(b + 40, "ACGTACGT", 8) == 0,
         "M90.4: chrX read 1 (clear) returns 'ACGTACGT'");

    m90RmFile(path);
}

static void testM90_4TwoKeysChr6AndChrX(void)
{
    NSString *path = m90TmpPath(@"m904_two.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildRegionFixture(path, &err);
    NSData *keyHla = m90Key(0x42);
    NSData *keyX   = m90Key(0x77);

    [TTIOPerAUFile encryptFilePathByRegion:path
                                       keyMap:@{@"chr6": keyHla, @"chrX": keyX}
                                providerName:nil
                                       error:&err];
    NSDictionary *result =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{@"chr6": keyHla, @"chrX": keyX}
                                    providerName:nil
                                           error:&err];
    NSData *seqs = result[@"genomic_0001"][@"sequences"];
    const uint8_t *b = (const uint8_t *)seqs.bytes;
    PASS(memcmp(b + 0,  "AAAAAAAA", 8) == 0,
         "M90.4 twokeys: chr1 stays clear");
    PASS(memcmp(b + 16, "GGGGGGGG", 8) == 0,
         "M90.4 twokeys: chr6 decrypted");
    PASS(memcmp(b + 32, "NNNNNNNN", 8) == 0,
         "M90.4 twokeys: chrX decrypted");
    m90RmFile(path);
}

static void testM90_4MissingKeyForEncryptedFails(void)
{
    NSString *path = m90TmpPath(@"m904_miss.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildRegionFixture(path, &err);

    [TTIOPerAUFile encryptFilePathByRegion:path
                                       keyMap:@{@"chr6": m90Key(0x42)}
                                providerName:nil
                                       error:&err];
    err = nil;
    NSDictionary *result =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{}
                                    providerName:nil
                                           error:&err];
    PASS(result == nil && err != nil,
         "M90.4: empty keyMap fails on encrypted chr6 segments");
    m90RmFile(path);
}

static void testM90_4WrongKeyFails(void)
{
    NSString *path = m90TmpPath(@"m904_wrong.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildRegionFixture(path, &err);

    [TTIOPerAUFile encryptFilePathByRegion:path
                                       keyMap:@{@"chr6": m90Key(0x42)}
                                providerName:nil
                                       error:&err];
    err = nil;
    NSDictionary *result =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{@"chr6": m90Key(0xFF)}
                                    providerName:nil
                                           error:&err];
    PASS(result == nil && err != nil,
         "M90.4: wrong chr6 key rejected (AES-GCM auth)");
    m90RmFile(path);
}

static void testM90_4QualitiesDispatchSameWay(void)
{
    NSString *path = m90TmpPath(@"m904_q.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildRegionFixture(path, &err);
    NSData *keyHla = m90Key(0x42);

    [TTIOPerAUFile encryptFilePathByRegion:path
                                       keyMap:@{@"chr6": keyHla}
                                providerName:nil
                                       error:&err];
    NSDictionary *result =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{@"chr6": keyHla}
                                    providerName:nil
                                           error:&err];
    NSData *quals = result[@"genomic_0001"][@"qualities"];
    const uint8_t *b = (const uint8_t *)quals.bytes;
    // Per-read distinct: read i has Phred (20+i) repeated.
    BOOL r0Ok = YES, r2Ok = YES, r5Ok = YES;
    for (NSUInteger j = 0; j < 8; j++) {
        if (b[0  + j] != 20) r0Ok = NO;
        if (b[16 + j] != 22) r2Ok = NO;
        if (b[40 + j] != 25) r5Ok = NO;
    }
    PASS(r0Ok, "M90.4 qualities: chr1 read 0 (clear) Phred==20");
    PASS(r2Ok, "M90.4 qualities: chr6 read 0 (decrypted) Phred==22");
    PASS(r5Ok, "M90.4 qualities: chrX read 1 (clear) Phred==25");
    m90RmFile(path);
}

static void testM90_4EmptyKeyMapNoop(void)
{
    NSString *path = m90TmpPath(@"m904_noop.tio");
    m90RmFile(path);
    NSError *err = nil;
    m90BuildRegionFixture(path, &err);

    BOOL ok = [TTIOPerAUFile encryptFilePathByRegion:path
                                                 keyMap:@{}
                                          providerName:nil
                                                 error:&err];
    PASS(ok, "M90.4 noop: empty keyMap encrypt succeeds (all clear)");
    NSDictionary *result =
        [TTIOPerAUFile decryptFilePathByRegion:path
                                          keyMap:@{}
                                    providerName:nil
                                           error:&err];
    PASS(result != nil, "M90.4 noop: empty keyMap decrypt succeeds");
    NSData *seqs = result[@"genomic_0001"][@"sequences"];
    NSMutableData *expected = [NSMutableData data];
    [expected appendBytes:"AAAAAAAA" length:8];
    [expected appendBytes:"TTTTTTTT" length:8];
    [expected appendBytes:"GGGGGGGG" length:8];
    [expected appendBytes:"CCCCCCCC" length:8];
    [expected appendBytes:"NNNNNNNN" length:8];
    [expected appendBytes:"ACGTACGT" length:8];
    PASS([seqs isEqualToData:expected],
         "M90.4 noop: end-to-end byte-exact preservation");
    m90RmFile(path);
}


// ── Entry point ────────────────────────────────────────────────────

void testM90GenomicProtection(void)
{
    // M90.1
    testM90_1EncryptStripsPlaintext();
    testM90_1RoundTripByteExact();
    testM90_1WrongKeyRejected();

    // M90.2
    testM90_2HmacSequencesRoundTrip();
    testM90_2HmacQualitiesRoundTrip();
    testM90_2SignGenomicRunSignsAllSeven();
    testM90_2VerifyDetectsTamper();

    // M90.3
    testM90_3StripReadNames();
    testM90_3RandomiseQualities();
    testM90_3RandomiseQualitiesCustomConstant();
    testM90_3MaskRegionsSingle();
    testM90_3MaskRegionsMultiple();
    testM90_3CombinedPolicies();
    testM90_3NoOpPreservesGenomic();

    // M90.4
    testM90_4DecryptWithChr6KeyReturnsClear();
    testM90_4TwoKeysChr6AndChrX();
    testM90_4MissingKeyForEncryptedFails();
    testM90_4WrongKeyFails();
    testM90_4QualitiesDispatchSameWay();
    testM90_4EmptyKeyMapNoop();
}
