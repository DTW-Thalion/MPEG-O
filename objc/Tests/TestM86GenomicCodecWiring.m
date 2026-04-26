// TestM86GenomicCodecWiring.m — v0.12 M86.
//
// Wires the rANS (M83) and BASE_PACK (M84) codecs into the genomic
// signal-channel write/read pipeline through TTIOWrittenGenomicRun
// .signalCodecOverrides + TTIOGenomicRun's lazy decode cache. Eleven
// test cases mirror Python's test_m86_genomic_codec_wiring.py and
// HANDOFF.md M86 §6.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "Testing.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Codecs/TTIORans.h"      // M86 Phase B (size-win encoder probe)
#import "Codecs/TTIOQuality.h"   // M86 Phase D
#import "Codecs/TTIONameTokenizer.h"   // M86 Phase E
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>
#include <string.h>

// ── Common cross-language test inputs (HANDOFF.md M86 §6.2) ─────────

static const NSUInteger kM86_NReads  = 10;
static const NSUInteger kM86_ReadLen = 100;
static const NSUInteger kM86_TotalBytes = 1000; // 10 * 100

/** 1000-byte pure-ACGT sequences buffer ((b"ACGT" * 25) * 10). */
static NSData *m86PureACGTSequences(void)
{
    NSMutableData *d = [NSMutableData dataWithLength:kM86_TotalBytes];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    static const uint8_t cycle[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < kM86_TotalBytes; i++) {
        p[i] = cycle[i % 4];
    }
    return d;
}

/** 1000-byte Phred 30–40 cycling qualities buffer. */
static NSData *m86PhredCycleQualities(void)
{
    NSMutableData *d = [NSMutableData dataWithLength:kM86_TotalBytes];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < kM86_TotalBytes; i++) {
        p[i] = (uint8_t)(30 + (i % 11));
    }
    return d;
}

/** Per-read string slice of the sequences buffer. */
static NSString *m86ExpectedSequenceSlice(NSData *seqBytes, NSUInteger i)
{
    NSData *slice = [seqBytes subdataWithRange:
        NSMakeRange(i * kM86_ReadLen, kM86_ReadLen)];
    return [[NSString alloc] initWithData:slice encoding:NSASCIIStringEncoding];
}

/** Per-read NSData slice of the qualities buffer. */
static NSData *m86ExpectedQualitySlice(NSData *qualBytes, NSUInteger i)
{
    return [qualBytes subdataWithRange:
        NSMakeRange(i * kM86_ReadLen, kM86_ReadLen)];
}

// ── Synthetic 10-read × 100-bp run builder ──────────────────────────

static NSData *m86_dataFromBytes(const void *bytes, NSUInteger length)
{
    return [NSData dataWithBytes:bytes length:length];
}

/** Build the Python-equivalent _make_run() WrittenGenomicRun. */
static TTIOWrittenGenomicRun *m86MakeRun(
    NSData *seqBytes, NSData *qualBytes,
    NSDictionary<NSString *, NSNumber *> *codecOverrides,
    TTIOCompression baseCompression)
{
    NSUInteger n = kM86_NReads;
    int64_t  positions[kM86_NReads];
    uint8_t  mapqs[kM86_NReads];
    uint32_t flags[kM86_NReads];
    uint64_t offsets[kM86_NReads];
    uint32_t lengths[kM86_NReads];
    int64_t  matePositions[kM86_NReads];
    int32_t  templateLengths[kM86_NReads];
    NSMutableArray<NSString *> *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *names  = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        positions[i]      = (int64_t)(i * 1000);
        mapqs[i]          = 60;
        flags[i]          = 0;
        offsets[i]        = (uint64_t)(i * kM86_ReadLen);
        lengths[i]        = (uint32_t)kM86_ReadLen;
        matePositions[i]  = -1;
        templateLengths[i] = 0;
        [cigars addObject:@"100M"];
        [names  addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }
    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"M86_TEST"
                      positions:m86_dataFromBytes(positions, sizeof(positions))
               mappingQualities:m86_dataFromBytes(mapqs, sizeof(mapqs))
                          flags:m86_dataFromBytes(flags, sizeof(flags))
                      sequences:seqBytes
                      qualities:qualBytes
                        offsets:m86_dataFromBytes(offsets, sizeof(offsets))
                        lengths:m86_dataFromBytes(lengths, sizeof(lengths))
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:m86_dataFromBytes(matePositions, sizeof(matePositions))
                templateLengths:m86_dataFromBytes(templateLengths, sizeof(templateLengths))
                    chromosomes:chroms
              signalCompression:baseCompression
            signalCodecOverrides:codecOverrides];
}

static NSString *m86TmpPath(const char *tag)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m86_%s_%d.tio",
                                       tag, (int)getpid()];
}

static BOOL m86Write(NSString *path, TTIOWrittenGenomicRun *run, NSError **error)
{
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"t"
                                isaInvestigationId:@"i"
                                            msRuns:@{}
                                        genomicRuns:@{@"genomic_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

// ── Tests 1–5: round-trip with each codec / mixed ───────────────────

static void m86_round_trip_with_codec(TTIOCompression codec, BOOL onQualities,
                                      const char *codecLabel,
                                      const char *channelLabel,
                                      const char *fileTag)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSString *channelKey = onQualities ? @"qualities" : @"sequences";
    NSDictionary *overrides = @{ channelKey: @(codec) };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath(fileTag);
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86: write %s on %s succeeds", codecLabel, channelLabel);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "M86: %s/%s reopens", codecLabel, channelLabel);
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86: %s/%s genomicRuns dict populated",
         codecLabel, channelLabel);
    PASS(gr.readCount == kM86_NReads,
         "M86: %s/%s readCount round-trips", codecLabel, channelLabel);

    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        NSString *expectedSeq = m86ExpectedSequenceSlice(seqBytes, i);
        NSData   *expectedQual = m86ExpectedQualitySlice(qualBytes, i);
        if (![r.sequence isEqualToString:expectedSeq])    allMatch = NO;
        if (![r.qualities isEqualToData:expectedQual])    allMatch = NO;
    }
    PASS(allMatch, "M86: %s/%s round-trips byte-exact across all 10 reads",
         codecLabel, channelLabel);

    unlink(path.fileSystemRepresentation);
}

static void testRoundTripSequencesRansOrder0(void)
{
    m86_round_trip_with_codec(TTIOCompressionRansOrder0, NO,
                              "rANS-order0", "sequences", "rans0_seq");
}

static void testRoundTripSequencesRansOrder1(void)
{
    m86_round_trip_with_codec(TTIOCompressionRansOrder1, NO,
                              "rANS-order1", "sequences", "rans1_seq");
}

static void testRoundTripSequencesBasePack(void)
{
    m86_round_trip_with_codec(TTIOCompressionBasePack, NO,
                              "BASE_PACK", "sequences", "bp_seq");
}

static void testRoundTripQualitiesRansOrder1(void)
{
    m86_round_trip_with_codec(TTIOCompressionRansOrder1, YES,
                              "rANS-order1", "qualities", "rans1_qual");
}

static void testRoundTripMixed(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSDictionary *overrides = @{
        @"sequences": @(TTIOCompressionBasePack),
        @"qualities": @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("mixed");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86: mixed BASE_PACK+rANS1 write succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr.readCount == kM86_NReads, "M86: mixed readCount round-trips");

    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
    }
    PASS(allMatch, "M86: mixed round-trips byte-exact");

    unlink(path.fileSystemRepresentation);
}

// ── Test 6: back-compat — empty overrides goes through M82 path ────

static void testBackCompatNoOverrides(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            @{}, TTIOCompressionZlib);
    NSString *path = m86TmpPath("noov");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86: empty-overrides write succeeds (back-compat)");

    // Sanity: open the H5 file directly and check no @compression on
    // the byte channels (matches Python's test_back_compat_no_overrides).
    hid_t f = H5Fopen(path.fileSystemRepresentation, H5F_ACC_RDONLY, H5P_DEFAULT);
    PASS(f >= 0, "M86: back-compat file opens via H5Fopen");
    hid_t seqDs = H5Dopen2(f, "study/genomic_runs/genomic_0001/signal_channels/sequences",
                           H5P_DEFAULT);
    hid_t qualDs = H5Dopen2(f, "study/genomic_runs/genomic_0001/signal_channels/qualities",
                            H5P_DEFAULT);
    PASS(seqDs >= 0 && qualDs >= 0, "M86: back-compat byte channels exist");
    PASS(H5Aexists(seqDs, "compression") <= 0,
         "M86: back-compat sequences carries NO @compression");
    PASS(H5Aexists(qualDs, "compression") <= 0,
         "M86: back-compat qualities carries NO @compression");
    if (seqDs >= 0)  H5Dclose(seqDs);
    if (qualDs >= 0) H5Dclose(qualDs);
    if (f >= 0)      H5Fclose(f);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
    }
    PASS(allMatch, "M86: back-compat round-trips byte-exact (no codec dispatch)");

    unlink(path.fileSystemRepresentation);
}

// ── Tests 7–8: validation rejects bad overrides ─────────────────────

static void testRejectInvalidChannel(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    // M86 Phase B (Binding Decision §117): positions/flags/
    // mapping_qualities are now valid override channels for the rANS
    // codecs. Use `cigars` (still not in the override-eligible set)
    // to exercise the unknown-channel rejection path.
    NSDictionary *overrides = @{ @"cigars": @(TTIOCompressionRansOrder0) };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("badch");
    unlink(path.fileSystemRepresentation);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        m86Write(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised, "M86: override on 'cigars' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86: bad-channel exception is NSInvalidArgumentException");
    PASS(captured && [captured.reason rangeOfString:@"cigars"].location != NSNotFound,
         "M86: bad-channel exception names the rejected channel");

    // Validation runs before the genomic_runs subtree is built, so no
    // genomic_runs/genomic_0001 entry should exist if the file was
    // partially written. (The outer .tio file is created by the
    // top-level open; we only assert the rejected run was not stored.)
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        hid_t f = H5Fopen(path.fileSystemRepresentation,
                          H5F_ACC_RDONLY, H5P_DEFAULT);
        BOOL hasRunSubgroup = NO;
        if (f >= 0) {
            hasRunSubgroup =
                H5Lexists(f, "study/genomic_runs/genomic_0001",
                          H5P_DEFAULT) > 0;
            H5Fclose(f);
        }
        PASS(!hasRunSubgroup,
             "M86: bad-channel validation leaves no genomic_0001 subgroup");
    } else {
        PASS(YES,
             "M86: bad-channel validation leaves no genomic_0001 subgroup");
    }

    unlink(path.fileSystemRepresentation);
}

static void testRejectInvalidCodec(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    // LZ4 is an HDF5 filter, not a TTIO byte-stream codec.
    NSDictionary *overrides = @{ @"sequences": @(TTIOCompressionLZ4) };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("badcodec");
    unlink(path.fileSystemRepresentation);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        m86Write(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised, "M86: override with LZ4 raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86: bad-codec exception is NSInvalidArgumentException");
    PASS(captured && [captured.reason rangeOfString:@"not supported"].location != NSNotFound,
         "M86: bad-codec exception mentions 'not supported'");

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        hid_t f = H5Fopen(path.fileSystemRepresentation,
                          H5F_ACC_RDONLY, H5P_DEFAULT);
        BOOL hasRunSubgroup = NO;
        if (f >= 0) {
            hasRunSubgroup =
                H5Lexists(f, "study/genomic_runs/genomic_0001",
                          H5P_DEFAULT) > 0;
            H5Fclose(f);
        }
        PASS(!hasRunSubgroup,
             "M86: bad-codec validation leaves no genomic_0001 subgroup");
    } else {
        PASS(YES,
             "M86: bad-codec validation leaves no genomic_0001 subgroup");
    }

    unlink(path.fileSystemRepresentation);
}

// ── Test 9: @compression attribute set correctly per codec ──────────

static uint8_t m86ReadCompressionAttr(const char *path, const char *channel)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 255;
    char dsname[256];
    snprintf(dsname, sizeof(dsname),
             "study/genomic_runs/genomic_0001/signal_channels/%s", channel);
    hid_t did = H5Dopen2(f, dsname, H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return 255; }
    uint8_t v = 0;
    BOOL exists = H5Aexists(did, "compression") > 0;
    if (exists) {
        hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
        H5Aread(aid, H5T_NATIVE_UINT8, &v);
        H5Aclose(aid);
    } else {
        v = 254; // sentinel for "absent"
    }
    H5Dclose(did);
    H5Fclose(f);
    return v;
}

static void m86_attribute_set_correctly_for_codec(TTIOCompression codec,
                                                  const char *label,
                                                  const char *fileTag)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSDictionary *overrides = @{ @"sequences": @(codec) };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath(fileTag);
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err), "M86 attr/%s: write succeeds", label);

    uint8_t seqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation, "sequences");
    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation, "qualities");
    uint8_t posAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation, "positions");
    uint8_t flagAttr = m86ReadCompressionAttr(path.fileSystemRepresentation, "flags");
    uint8_t mapqAttr = m86ReadCompressionAttr(path.fileSystemRepresentation, "mapping_qualities");

    PASS(seqAttr == (uint8_t)codec,
         "M86 attr/%s: sequences @compression == codec id (%u, got %u)",
         label, (unsigned)codec, (unsigned)seqAttr);
    PASS(qualAttr == 254,
         "M86 attr/%s: qualities has NO @compression (no override)", label);
    PASS(posAttr == 254 && flagAttr == 254 && mapqAttr == 254,
         "M86 attr/%s: integer channels carry no @compression", label);

    unlink(path.fileSystemRepresentation);
}

static void testAttributeSetCorrectly(void)
{
    m86_attribute_set_correctly_for_codec(TTIOCompressionRansOrder0,
                                          "rANS0", "attr_rans0");
    m86_attribute_set_correctly_for_codec(TTIOCompressionRansOrder1,
                                          "rANS1", "attr_rans1");
    m86_attribute_set_correctly_for_codec(TTIOCompressionBasePack,
                                          "BASE_PACK", "attr_bp");
}

// ── Test 10: BASE_PACK size win — 100 000 bp pure-ACGT < 30% raw ────

/** Build a 1000-read × 100-bp pure-ACGT run for the size-win test. */
static TTIOWrittenGenomicRun *m86MakeLargeRun(
    NSDictionary<NSString *, NSNumber *> *codecOverrides,
    TTIOCompression baseCompression)
{
    NSUInteger nReads = 1000;
    NSUInteger readLen = 100;
    NSUInteger total = nReads * readLen;

    NSMutableData *seq = [NSMutableData dataWithLength:total];
    uint8_t *sp = (uint8_t *)seq.mutableBytes;
    static const uint8_t cycle[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < total; i++) sp[i] = cycle[i % 4];
    NSMutableData *qual = [NSMutableData dataWithLength:total];
    uint8_t *qp = (uint8_t *)qual.mutableBytes;
    for (NSUInteger i = 0; i < total; i++) qp[i] = (uint8_t)(30 + (i % 11));

    NSMutableData *positions = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *mapqs     = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
    NSMutableData *flags     = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *offsets   = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    NSMutableData *lengths   = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *matePos   = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *tlens     = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
    int64_t  *posp = (int64_t  *)positions.mutableBytes;
    uint8_t  *mqp  = (uint8_t  *)mapqs.mutableBytes;
    uint32_t *fp   = (uint32_t *)flags.mutableBytes;
    uint64_t *op   = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp   = (uint32_t *)lengths.mutableBytes;
    int64_t  *mpp  = (int64_t  *)matePos.mutableBytes;
    int32_t  *tlp  = (int32_t  *)tlens.mutableBytes;

    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names  = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        posp[i] = (int64_t)(i * 1000);
        mqp[i]  = 60;
        fp[i]   = 0;
        op[i]   = (uint64_t)(i * readLen);
        lp[i]   = (uint32_t)readLen;
        mpp[i]  = -1;
        tlp[i]  = 0;
        [cigars addObject:@"100M"];
        [names addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"SIZE_WIN"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seq
                      qualities:qual
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:baseCompression
            signalCodecOverrides:codecOverrides];
}

/** Storage size of the sequences dataset, via H5Dget_storage_size. */
static hsize_t m86SequencesStorageSize(const char *path)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 0;
    hid_t did = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/sequences",
        H5P_DEFAULT);
    hsize_t sz = 0;
    if (did >= 0) {
        sz = H5Dget_storage_size(did);
        H5Dclose(did);
    }
    H5Fclose(f);
    return sz;
}

static void testSizeWinBasePack(void)
{
    // Baseline uses TTIOCompressionNone (Python uses signal_compression
    // = "none" per the M86 implementer note — gzip would skew the
    // ratio against BASE_PACK's pre-coded high-entropy stream).
    TTIOWrittenGenomicRun *raw = m86MakeLargeRun(@{}, TTIOCompressionNone);
    TTIOWrittenGenomicRun *bp  = m86MakeLargeRun(
        @{ @"sequences": @(TTIOCompressionBasePack) },
        TTIOCompressionNone);

    NSString *rawPath = m86TmpPath("sw_raw");
    NSString *bpPath  = m86TmpPath("sw_bp");
    unlink(rawPath.fileSystemRepresentation);
    unlink(bpPath.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(rawPath, raw, &err), "M86 size-win: raw write succeeds");
    PASS(m86Write(bpPath,  bp,  &err), "M86 size-win: BASE_PACK write succeeds");

    hsize_t rawSize = m86SequencesStorageSize(rawPath.fileSystemRepresentation);
    hsize_t bpSize  = m86SequencesStorageSize(bpPath.fileSystemRepresentation);

    PASS(rawSize > 0, "M86 size-win: raw sequences dataset non-empty");
    PASS(bpSize > 0,  "M86 size-win: BASE_PACK sequences dataset non-empty");

    double ratio = (double)bpSize / (double)rawSize;
    PASS(ratio < 0.30,
         "M86 size-win: BASE_PACK / raw ratio %.3f < 0.30 "
         "(raw=%llu bytes, bp=%llu bytes)",
         ratio,
         (unsigned long long)rawSize, (unsigned long long)bpSize);

    unlink(rawPath.fileSystemRepresentation);
    unlink(bpPath.fileSystemRepresentation);
}

// ── Test 11: cross-language fixtures decode byte-exact ──────────────

static void m86_verify_fixture(const char *codecName, TTIOCompression expected)
{
    NSString *path = [NSString stringWithFormat:
        @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/m86_codec_%s.tio",
        codecName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 cross-language fixture not found at %s\n",
               path.UTF8String);
        return;
    }

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 fixture/%s: opens via M86 read path", codecName);
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 fixture/%s: genomic_0001 present", codecName);
    PASS(gr.readCount == kM86_NReads,
         "M86 fixture/%s: 10 reads from cross-language input", codecName);

    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
    }
    PASS(allMatch,
         "M86 fixture/%s: 10 reads decode byte-exact to known input",
         codecName);

    // And confirm the @compression attribute carries the expected codec id.
    uint8_t seqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation, "sequences");
    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation, "qualities");
    PASS(seqAttr == (uint8_t)expected,
         "M86 fixture/%s: sequences @compression == %u (got %u)",
         codecName, (unsigned)expected, (unsigned)seqAttr);
    PASS(qualAttr == (uint8_t)expected,
         "M86 fixture/%s: qualities @compression == %u (got %u)",
         codecName, (unsigned)expected, (unsigned)qualAttr);
}

static void testCrossLanguageFixtures(void)
{
    m86_verify_fixture("rans_order0", TTIOCompressionRansOrder0);
    m86_verify_fixture("rans_order1", TTIOCompressionRansOrder1);
    m86_verify_fixture("base_pack",   TTIOCompressionBasePack);
}

// ── M86 Phase D — QUALITY_BINNED on the qualities channel ──────────
//
// Mirrors python/tests/test_m86_genomic_codec_wiring.py tests 12–17
// plus the cross-language fixture test. The fixture uses bin-centre
// quality values so the lossy QUALITY_BINNED round-trip is byte-exact
// and meaningful for cross-language conformance comparison.
// HANDOFF.md M86 Phase D §5.2 + §120.

// Bin centres for the Illumina-8 scheme — every byte at a bin centre
// round-trips byte-exact through QUALITY_BINNED (HANDOFF.md M85 §97).
static const uint8_t kM86_BinCentres[8] = {0, 5, 15, 22, 27, 32, 37, 40};

/** 1000-byte bin-centre qualities buffer (cycle the 8 centres × 125). */
static NSData *m86BinCentreQualities(void)
{
    NSMutableData *d = [NSMutableData dataWithLength:kM86_TotalBytes];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < kM86_TotalBytes; i++) {
        p[i] = kM86_BinCentres[i % 8];
    }
    return d;
}

/** Storage size of an arbitrary signal-channel dataset. */
static hsize_t m86ChannelStorageSize(const char *path, const char *channel)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 0;
    char dsname[256];
    snprintf(dsname, sizeof(dsname),
             "study/genomic_runs/genomic_0001/signal_channels/%s", channel);
    hid_t did = H5Dopen2(f, dsname, H5P_DEFAULT);
    hsize_t sz = 0;
    if (did >= 0) {
        sz = H5Dget_storage_size(did);
        H5Dclose(did);
    }
    H5Fclose(f);
    return sz;
}

// Test 12 — bin-centre qualities round-trip byte-exact.
static void testRoundTripQualitiesQualityBinned(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    NSDictionary *overrides = @{
        @"qualities": @(TTIOCompressionQualityBinned)
    };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("qb_centres");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhD: write QUALITY_BINNED on qualities (bin centres) succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 PhD: QUALITY_BINNED bin-centre file reopens");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr.readCount == kM86_NReads,
         "M86 PhD: QUALITY_BINNED bin-centre readCount round-trips");

    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhD: QUALITY_BINNED bin-centre qualities round-trip "
         "byte-exact across all 10 reads");

    unlink(path.fileSystemRepresentation);
}

// Test 13 — arbitrary Phred values round-trip via the lossy mapping.
static void testRoundTripQualitiesQualityBinnedLossy(void)
{
    // 1000 bytes cycling Phred 0..49 — covers every bin and the
    // saturation case (≥40 → centre 40).
    NSMutableData *arbitrary = [NSMutableData dataWithLength:kM86_TotalBytes];
    uint8_t *ap = (uint8_t *)arbitrary.mutableBytes;
    for (NSUInteger i = 0; i < kM86_TotalBytes; i++) {
        ap[i] = (uint8_t)(i % 50);
    }
    // Compute the expected lossy output via the codec's public
    // encode/decode round-trip — keeps this test as a pure integration
    // check (we don't reimplement the bin table here).
    NSError *codecErr = nil;
    NSData *expectedQual = TTIOQualityDecode(TTIOQualityEncode(arbitrary),
                                             &codecErr);
    PASS(expectedQual != nil && expectedQual.length == kM86_TotalBytes,
         "M86 PhD: codec round-trip helper produces a %lu-byte buffer",
         (unsigned long)kM86_TotalBytes);
    PASS(![expectedQual isEqualToData:arbitrary],
         "M86 PhD: lossy mapping must differ from input "
         "(otherwise the test is degenerate)");

    NSData *seqBytes = m86PureACGTSequences();
    NSDictionary *overrides = @{
        @"qualities": @(TTIOCompressionQualityBinned)
    };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, arbitrary,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("qb_lossy");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhD: write QUALITY_BINNED with arbitrary Phred values succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(expectedQual, i)]) allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhD: QUALITY_BINNED arbitrary Phred values round-trip via "
         "documented lossy mapping across all 10 reads");

    unlink(path.fileSystemRepresentation);
}

// Test 14 — QUALITY_BINNED qualities dataset is significantly smaller.
//
// 4-bits-per-index + 6-byte header — wire stream is 6 + 50 000 = 50 006
// bytes for a 100 000-byte input. Target ratio: < 0.55 (matches Python).
static void testSizeWinQualityBinned(void)
{
    // Build a 1000-read × 100-bp run with bin-centre qualities both ways.
    NSUInteger nReads = 1000;
    NSUInteger readLen = 100;
    NSUInteger total = nReads * readLen;

    NSMutableData *seq = [NSMutableData dataWithLength:total];
    uint8_t *sp = (uint8_t *)seq.mutableBytes;
    static const uint8_t cycle[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < total; i++) sp[i] = cycle[i % 4];

    NSMutableData *qual = [NSMutableData dataWithLength:total];
    uint8_t *qp = (uint8_t *)qual.mutableBytes;
    for (NSUInteger i = 0; i < total; i++) qp[i] = kM86_BinCentres[i % 8];

    NSMutableData *positions = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *mapqs     = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
    NSMutableData *flags     = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *offsets   = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    NSMutableData *lengths   = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *matePos   = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *tlens     = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
    int64_t  *posp = (int64_t  *)positions.mutableBytes;
    uint8_t  *mqp  = (uint8_t  *)mapqs.mutableBytes;
    uint32_t *fp   = (uint32_t *)flags.mutableBytes;
    uint64_t *op   = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp   = (uint32_t *)lengths.mutableBytes;
    int64_t  *mpp  = (int64_t  *)matePos.mutableBytes;
    int32_t  *tlp  = (int32_t  *)tlens.mutableBytes;
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names  = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        posp[i] = (int64_t)(i * 1000);
        mqp[i]  = 60;
        fp[i]   = 0;
        op[i]   = (uint64_t)(i * readLen);
        lp[i]   = (uint32_t)readLen;
        mpp[i]  = -1;
        tlp[i]  = 0;
        [cigars addObject:@"100M"];
        [names addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }

    TTIOWrittenGenomicRun * (^buildRun)(NSDictionary *) =
        ^(NSDictionary *overrides) {
            return [[TTIOWrittenGenomicRun alloc]
                initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                           referenceUri:@"GRCh38.p14"
                               platform:@"ILLUMINA"
                             sampleName:@"SIZE_WIN_QB"
                              positions:positions
                       mappingQualities:mapqs
                                  flags:flags
                              sequences:seq
                              qualities:qual
                                offsets:offsets
                                lengths:lengths
                                 cigars:cigars
                              readNames:names
                        mateChromosomes:mateChroms
                          matePositions:matePos
                        templateLengths:tlens
                            chromosomes:chroms
                      signalCompression:TTIOCompressionNone
                    signalCodecOverrides:overrides];
        };

    TTIOWrittenGenomicRun *raw = buildRun(@{});
    TTIOWrittenGenomicRun *qb  = buildRun(
        @{ @"qualities": @(TTIOCompressionQualityBinned) });

    NSString *rawPath = m86TmpPath("qb_sw_raw");
    NSString *qbPath  = m86TmpPath("qb_sw_qb");
    unlink(rawPath.fileSystemRepresentation);
    unlink(qbPath.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(rawPath, raw, &err),
         "M86 PhD size-win: raw qualities write succeeds");
    PASS(m86Write(qbPath,  qb,  &err),
         "M86 PhD size-win: QUALITY_BINNED qualities write succeeds");

    hsize_t rawSize = m86ChannelStorageSize(rawPath.fileSystemRepresentation,
                                            "qualities");
    hsize_t qbSize  = m86ChannelStorageSize(qbPath.fileSystemRepresentation,
                                            "qualities");
    PASS(rawSize > 0 && qbSize > 0,
         "M86 PhD size-win: both qualities datasets non-empty "
         "(raw=%llu, qb=%llu)",
         (unsigned long long)rawSize, (unsigned long long)qbSize);

    double ratio = (double)qbSize / (double)rawSize;
    PASS(ratio < 0.55,
         "M86 PhD size-win: QUALITY_BINNED / raw ratio %.3f < 0.55 "
         "(raw=%llu bytes, qb=%llu bytes)",
         ratio, (unsigned long long)rawSize, (unsigned long long)qbSize);

    unlink(rawPath.fileSystemRepresentation);
    unlink(qbPath.fileSystemRepresentation);
}

// Test 15 — QUALITY_BINNED qualities channel carries @compression == 7.
static void testAttributeSetCorrectlyQualityBinned(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    NSDictionary *overrides = @{
        @"qualities": @(TTIOCompressionQualityBinned)
    };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("qb_attr");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhD attr: QUALITY_BINNED qualities write succeeds");

    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "qualities");
    uint8_t seqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "sequences");
    PASS(qualAttr == (uint8_t)TTIOCompressionQualityBinned,
         "M86 PhD attr: qualities @compression == 7 (got %u)",
         (unsigned)qualAttr);
    PASS(seqAttr == 254,
         "M86 PhD attr: sequences carries NO @compression (no override)");

    unlink(path.fileSystemRepresentation);
}

// Test 16 — QUALITY_BINNED on sequences raises with the rationale.
static void testRejectQualityBinnedOnSequences(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    NSDictionary *overrides = @{
        @"sequences": @(TTIOCompressionQualityBinned)
    };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("qb_bad_seq");
    unlink(path.fileSystemRepresentation);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        m86Write(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised,
         "M86 PhD: QUALITY_BINNED on 'sequences' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhD: QUALITY_BINNED-on-sequences exception is "
         "NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"QUALITY_BINNED"].location != NSNotFound,
         "M86 PhD: error message names the codec (QUALITY_BINNED)");
    PASS([reason rangeOfString:@"sequences"].location != NSNotFound,
         "M86 PhD: error message names the channel ('sequences')");
    PASS([reason rangeOfString:@"lossy"
                       options:NSCaseInsensitiveSearch].location != NSNotFound,
         "M86 PhD: error message explains 'lossy' rationale");
    BOOL hasPhredOrQuality =
        [reason rangeOfString:@"Phred"].location != NSNotFound ||
        [reason rangeOfString:@"quality"
                      options:NSCaseInsensitiveSearch].location != NSNotFound;
    PASS(hasPhredOrQuality,
         "M86 PhD: error message mentions Phred or quality scores");

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        hid_t f = H5Fopen(path.fileSystemRepresentation,
                          H5F_ACC_RDONLY, H5P_DEFAULT);
        BOOL hasRunSubgroup = NO;
        if (f >= 0) {
            hasRunSubgroup =
                H5Lexists(f, "study/genomic_runs/genomic_0001",
                          H5P_DEFAULT) > 0;
            H5Fclose(f);
        }
        PASS(!hasRunSubgroup,
             "M86 PhD: QUALITY_BINNED-on-sequences leaves no genomic_0001 subgroup");
    } else {
        PASS(YES,
             "M86 PhD: QUALITY_BINNED-on-sequences leaves no genomic_0001 subgroup");
    }

    unlink(path.fileSystemRepresentation);
}

// Test 17 — mixed BASE_PACK on sequences + QUALITY_BINNED on qualities.
static void testMixedQualityBinnedWithRans(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    NSDictionary *overrides = @{
        @"sequences": @(TTIOCompressionBasePack),
        @"qualities": @(TTIOCompressionQualityBinned),
    };
    TTIOWrittenGenomicRun *run = m86MakeRun(seqBytes, qualBytes,
                                            overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("qb_mixed");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhD mixed: BASE_PACK seq + QUALITY_BINNED qual write succeeds");

    uint8_t seqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "sequences");
    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "qualities");
    PASS(seqAttr  == (uint8_t)TTIOCompressionBasePack,
         "M86 PhD mixed: sequences @compression == BASE_PACK (6, got %u)",
         (unsigned)seqAttr);
    PASS(qualAttr == (uint8_t)TTIOCompressionQualityBinned,
         "M86 PhD mixed: qualities @compression == QUALITY_BINNED (7, got %u)",
         (unsigned)qualAttr);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhD mixed: both channels round-trip byte-exact across all 10 reads");

    unlink(path.fileSystemRepresentation);
}

// Cross-language QUALITY_BINNED fixture (BASE_PACK seq + QUALITY_BINNED qual).
static void testCrossLanguageFixtureQualityBinned(void)
{
    NSString *path = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/"
                     @"m86_codec_quality_binned.tio";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 PhD cross-language fixture not found at %s\n",
               path.UTF8String);
        return;
    }

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil,
         "M86 PhD fixture: QUALITY_BINNED .tio opens via M86 read path");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhD fixture: genomic_0001 present");
    PASS(gr.readCount == kM86_NReads,
         "M86 PhD fixture: 10 reads from cross-language input");

    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhD fixture: 10 reads decode byte-exact to bin-centre input "
         "(BASE_PACK seq + QUALITY_BINNED qual)");

    uint8_t seqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "sequences");
    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "qualities");
    PASS(seqAttr == (uint8_t)TTIOCompressionBasePack,
         "M86 PhD fixture: sequences @compression == BASE_PACK (6, got %u)",
         (unsigned)seqAttr);
    PASS(qualAttr == (uint8_t)TTIOCompressionQualityBinned,
         "M86 PhD fixture: qualities @compression == QUALITY_BINNED (7, got %u)",
         (unsigned)qualAttr);
}

// ── M86 Phase E — NAME_TOKENIZED on the read_names channel ─────────
//
// Phase E lifts the read_names channel from VL_STRING-in-compound
// storage to a flat 1-D uint8 dataset that can carry the
// @compression attribute. Tests mirror Python's tests 18-23 plus a
// cross-language fixture decode. HANDOFF.md M86 Phase E §6.2.

/** Structured Illumina-style read names matching the Python
 *  cross-language fixture generator:
 *      INSTR:RUN:1:{i//4}:{i%4}:{i*100}    for i in 0..n-1.
 *  Same generator the Java agent uses so cross-language input is
 *  byte-identical. */
static NSArray<NSString *> *m86PhEStructuredNames(NSUInteger n)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        [out addObject:[NSString stringWithFormat:
            @"INSTR:RUN:1:%lu:%lu:%lu",
            (unsigned long)(i / 4),
            (unsigned long)(i % 4),
            (unsigned long)(i * 100)]];
    }
    return out;
}

/** Phase-E run builder — m86MakeRun's structured-names twin.
 *  Identical layout but the readNames are Illumina-structured so the
 *  NAME_TOKENIZED columnar mode actually exercises numeric/string
 *  column detection. */
static TTIOWrittenGenomicRun *m86PhEMakeRun(
    NSData *seqBytes, NSData *qualBytes,
    NSArray<NSString *> *names,
    NSDictionary<NSString *, NSNumber *> *codecOverrides,
    TTIOCompression baseCompression)
{
    NSUInteger n = names.count;
    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *mapqs     = [NSMutableData dataWithLength:n * sizeof(uint8_t)];
    NSMutableData *flags     = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *offsets   = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    NSMutableData *lengths   = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *matePos   = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *tlens     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    int64_t  *posp = (int64_t  *)positions.mutableBytes;
    uint8_t  *mqp  = (uint8_t  *)mapqs.mutableBytes;
    uint32_t *fp   = (uint32_t *)flags.mutableBytes;
    uint64_t *op   = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp   = (uint32_t *)lengths.mutableBytes;
    int64_t  *mpp  = (int64_t  *)matePos.mutableBytes;
    int32_t  *tlp  = (int32_t  *)tlens.mutableBytes;
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        posp[i] = (int64_t)(i * 1000);
        mqp[i]  = 60;
        fp[i]   = 0;
        op[i]   = (uint64_t)(i * kM86_ReadLen);
        lp[i]   = (uint32_t)kM86_ReadLen;
        mpp[i]  = -1;
        tlp[i]  = 0;
        [cigars addObject:@"100M"];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }
    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"M86_TEST"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seqBytes
                      qualities:qualBytes
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:baseCompression
            signalCodecOverrides:codecOverrides];
}

// Test 18 — round-trip read_names with NAME_TOKENIZED, byte-exact.
static void testRoundTripReadNamesNameTokenized(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSArray<NSString *> *names = m86PhEStructuredNames(kM86_NReads);
    NSDictionary *overrides = @{
        @"read_names": @(TTIOCompressionNameTokenized)
    };
    TTIOWrittenGenomicRun *run = m86PhEMakeRun(seqBytes, qualBytes, names,
                                               overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("nt_rt");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhE: write NAME_TOKENIZED on read_names succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 PhE: NAME_TOKENIZED file reopens");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhE: NAME_TOKENIZED genomicRuns dict populated");
    PASS(gr.readCount == kM86_NReads,
         "M86 PhE: NAME_TOKENIZED readCount round-trips");

    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.readName isEqualToString:names[i]]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhE: NAME_TOKENIZED round-trips byte-exact across all 10 "
         "structured Illumina read names");

    unlink(path.fileSystemRepresentation);
}

/** Build a 1000-read run with structured Illumina names for the
 *  size-win test. */
static TTIOWrittenGenomicRun *m86PhEMakeLargeRun(
    NSDictionary<NSString *, NSNumber *> *codecOverrides,
    TTIOCompression baseCompression)
{
    NSUInteger nReads = 1000;
    NSUInteger readLen = 100;
    NSUInteger total = nReads * readLen;

    NSMutableData *seq = [NSMutableData dataWithLength:total];
    uint8_t *sp = (uint8_t *)seq.mutableBytes;
    static const uint8_t cycle[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < total; i++) sp[i] = cycle[i % 4];
    NSMutableData *qual = [NSMutableData dataWithLength:total];
    uint8_t *qp = (uint8_t *)qual.mutableBytes;
    for (NSUInteger i = 0; i < total; i++) qp[i] = (uint8_t)(30 + (i % 11));

    NSMutableData *positions = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *mapqs     = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
    NSMutableData *flags     = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *offsets   = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    NSMutableData *lengths   = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    NSMutableData *matePos   = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    NSMutableData *tlens     = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
    int64_t  *posp = (int64_t  *)positions.mutableBytes;
    uint8_t  *mqp  = (uint8_t  *)mapqs.mutableBytes;
    uint32_t *fp   = (uint32_t *)flags.mutableBytes;
    uint64_t *op   = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp   = (uint32_t *)lengths.mutableBytes;
    int64_t  *mpp  = (int64_t  *)matePos.mutableBytes;
    int32_t  *tlp  = (int32_t  *)tlens.mutableBytes;

    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names  = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        posp[i] = (int64_t)(i * 1000);
        mqp[i]  = 60;
        fp[i]   = 0;
        op[i]   = (uint64_t)(i * readLen);
        lp[i]   = (uint32_t)readLen;
        mpp[i]  = -1;
        tlp[i]  = 0;
        [cigars addObject:@"100M"];
        [names addObject:[NSString stringWithFormat:
            @"INSTR:RUN:1:%lu:%lu:%lu",
            (unsigned long)(i / 4), (unsigned long)(i % 4),
            (unsigned long)(i * 100)]];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"SIZE_WIN_NT"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seq
                      qualities:qual
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:baseCompression
            signalCodecOverrides:codecOverrides];
}

/** Storage size of any signal_channels child dataset. */
static hsize_t m86PhEChannelStorageSize(const char *path, const char *channel)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return 0;
    char dsname[256];
    snprintf(dsname, sizeof(dsname),
             "study/genomic_runs/genomic_0001/signal_channels/%s", channel);
    hid_t did = H5Dopen2(f, dsname, H5P_DEFAULT);
    hsize_t sz = 0;
    if (did >= 0) {
        sz = H5Dget_storage_size(did);
        H5Dclose(did);
    }
    H5Fclose(f);
    return sz;
}

// Test 19 — NAME_TOKENIZED storage is significantly smaller than the
// M82 VL_STRING compound. The HDF5 VL_STRING compound stores its
// primary chunk plus a separate global heap holding the variable-
// length payloads; H5Dget_storage_size reports only the primary
// chunk and misses the heap. The realistic comparison is the total
// file-size delta between the two writes (mirrors Python's
// test_size_win_name_tokenized — HANDOFF.md §6.1 "the exact ratio
// depends on HDF5 VL_STRING overhead; just verify it's a meaningful
// win"). Target: NAME_TOKENIZED < 50% of the M82 footprint.
static void testSizeWinNameTokenized(void)
{
    TTIOWrittenGenomicRun *raw = m86PhEMakeLargeRun(@{}, TTIOCompressionNone);
    TTIOWrittenGenomicRun *nt  = m86PhEMakeLargeRun(
        @{ @"read_names": @(TTIOCompressionNameTokenized) },
        TTIOCompressionNone);

    NSString *rawPath = m86TmpPath("nt_sw_raw");
    NSString *ntPath  = m86TmpPath("nt_sw_nt");
    unlink(rawPath.fileSystemRepresentation);
    unlink(ntPath.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(rawPath, raw, &err),
         "M86 PhE size-win: raw read_names compound write succeeds");
    PASS(m86Write(ntPath,  nt,  &err),
         "M86 PhE size-win: NAME_TOKENIZED read_names write succeeds");

    NSDictionary *rawAttrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:rawPath error:nil];
    NSDictionary *ntAttrs  = [[NSFileManager defaultManager]
        attributesOfItemAtPath:ntPath error:nil];
    unsigned long long rawFileSize = [rawAttrs[NSFileSize] unsignedLongLongValue];
    unsigned long long ntFileSize  = [ntAttrs[NSFileSize]  unsignedLongLongValue];
    PASS(rawFileSize > 0 && ntFileSize > 0,
         "M86 PhE size-win: both files non-empty "
         "(raw=%llu, nt=%llu)", rawFileSize, ntFileSize);

    // The two files differ only in the read_names channel (both
    // written with TTIOCompressionNone for parity with the Python
    // baseline). Footprint attributable to read_names = the codec
    // stream plus the bytes saved by switching layouts.
    hsize_t ntCodecBytes = m86PhEChannelStorageSize(
        ntPath.fileSystemRepresentation, "read_names");
    PASS(ntCodecBytes > 0,
         "M86 PhE size-win: NAME_TOKENIZED dataset non-empty "
         "(nt_codec=%llu)", (unsigned long long)ntCodecBytes);

    long long saved = (long long)rawFileSize - (long long)ntFileSize;
    unsigned long long m82Footprint = ntCodecBytes + (saved > 0 ? saved : 0);
    double ratio = (double)ntCodecBytes / (double)m82Footprint;
    PASS(ratio < 0.50,
         "M86 PhE size-win: NAME_TOKENIZED / M82-footprint ratio %.3f "
         "< 0.50 (codec=%llu bytes, m82_footprint=%llu bytes, "
         "saved=%lld bytes)",
         ratio, (unsigned long long)ntCodecBytes, m82Footprint, saved);

    unlink(rawPath.fileSystemRepresentation);
    unlink(ntPath.fileSystemRepresentation);
}

// Test 20 — read_names dataset is 1-D uint8 with @compression == 8.
static void testAttributeSetCorrectlyNameTokenized(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSArray<NSString *> *names = m86PhEStructuredNames(kM86_NReads);
    NSDictionary *overrides = @{
        @"read_names": @(TTIOCompressionNameTokenized)
    };
    TTIOWrittenGenomicRun *run = m86PhEMakeRun(seqBytes, qualBytes, names,
                                               overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("nt_attr");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhE attr: NAME_TOKENIZED read_names write succeeds");

    // Open the underlying H5 file and verify (a) the read_names
    // dataset's type class is H5T_INTEGER (i.e. flat uint8, not
    // compound); (b) the @compression attribute is uint8 with
    // value 8 (NAME_TOKENIZED).
    hid_t f = H5Fopen(path.fileSystemRepresentation,
                      H5F_ACC_RDONLY, H5P_DEFAULT);
    PASS(f >= 0, "M86 PhE attr: file opens via H5Fopen");
    hid_t did = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/read_names",
        H5P_DEFAULT);
    PASS(did >= 0, "M86 PhE attr: read_names dataset exists");

    hid_t htype = H5Dget_type(did);
    H5T_class_t cls = H5Tget_class(htype);
    PASS(cls == H5T_INTEGER,
         "M86 PhE attr: read_names dataset class is H5T_INTEGER (got %d)",
         (int)cls);
    PASS(H5Tequal(htype, H5T_NATIVE_UINT8) > 0,
         "M86 PhE attr: read_names dtype equals H5T_NATIVE_UINT8");
    H5Tclose(htype);

    hid_t space = H5Dget_space(did);
    int rank = H5Sget_simple_extent_ndims(space);
    PASS(rank == 1, "M86 PhE attr: read_names is 1-D (rank=%d)", rank);
    H5Sclose(space);

    uint8_t attr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "read_names");
    PASS(attr == (uint8_t)TTIOCompressionNameTokenized,
         "M86 PhE attr: read_names @compression == 8 (got %u)",
         (unsigned)attr);

    if (did >= 0) H5Dclose(did);
    if (f   >= 0) H5Fclose(f);

    unlink(path.fileSystemRepresentation);
}

// Test 21 — without override, read_names is still compound (M82).
static void testBackCompatReadNamesUnchanged(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSArray<NSString *> *names = m86PhEStructuredNames(kM86_NReads);
    // Empty overrides — should leave read_names as the M82 compound.
    TTIOWrittenGenomicRun *run = m86PhEMakeRun(seqBytes, qualBytes, names,
                                               @{}, TTIOCompressionZlib);
    NSString *path = m86TmpPath("nt_bc");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhE back-compat: empty-overrides write succeeds");

    // Open underlying H5 file; verify read_names is COMPOUND
    // (not H5T_INTEGER) and carries no @compression attribute.
    hid_t f = H5Fopen(path.fileSystemRepresentation,
                      H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t did = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/read_names",
        H5P_DEFAULT);
    PASS(did >= 0, "M86 PhE back-compat: read_names dataset exists");
    hid_t htype = H5Dget_type(did);
    H5T_class_t cls = H5Tget_class(htype);
    PASS(cls == H5T_COMPOUND,
         "M86 PhE back-compat: read_names dataset class is H5T_COMPOUND "
         "(got %d) — no schema lift without override", (int)cls);
    PASS(H5Aexists(did, "compression") <= 0,
         "M86 PhE back-compat: compound read_names carries NO "
         "@compression attribute");
    H5Tclose(htype);
    if (did >= 0) H5Dclose(did);
    if (f   >= 0) H5Fclose(f);

    // Round-trip via the existing M82 compound read path.
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.readName isEqualToString:names[i]]) {
            allMatch = NO; break;
        }
    }
    PASS(allMatch,
         "M86 PhE back-compat: M82 compound read_names round-trips "
         "byte-exact via the existing read path");

    unlink(path.fileSystemRepresentation);
}

// Test 22 — NAME_TOKENIZED on sequences raises with the rationale.
//
// Mirrors testRejectQualityBinnedOnSequences: the validation must
// name the codec, the channel, mention "tokenises UTF-8", and
// point at the read_names channel.
static void testRejectNameTokenizedOnSequences(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSArray<NSString *> *names = m86PhEStructuredNames(kM86_NReads);
    NSDictionary *overrides = @{
        @"sequences": @(TTIOCompressionNameTokenized)
    };
    TTIOWrittenGenomicRun *run = m86PhEMakeRun(seqBytes, qualBytes, names,
                                               overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("nt_bad_seq");
    unlink(path.fileSystemRepresentation);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        m86Write(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised,
         "M86 PhE: NAME_TOKENIZED on 'sequences' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhE: bad-channel exception is NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"NAME_TOKENIZED"].location != NSNotFound,
         "M86 PhE: error message names the codec (NAME_TOKENIZED)");
    PASS([reason rangeOfString:@"sequences"].location != NSNotFound,
         "M86 PhE: error message names the channel ('sequences')");
    PASS([reason rangeOfString:@"tokenises UTF-8"].location != NSNotFound,
         "M86 PhE: error message explains the tokenises-UTF-8 rationale");
    PASS([reason rangeOfString:@"read_names"].location != NSNotFound,
         "M86 PhE: error message points at the read_names channel");

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        hid_t f = H5Fopen(path.fileSystemRepresentation,
                          H5F_ACC_RDONLY, H5P_DEFAULT);
        BOOL hasRunSubgroup = NO;
        if (f >= 0) {
            hasRunSubgroup =
                H5Lexists(f, "study/genomic_runs/genomic_0001",
                          H5P_DEFAULT) > 0;
            H5Fclose(f);
        }
        PASS(!hasRunSubgroup,
             "M86 PhE: NAME_TOKENIZED-on-sequences leaves no "
             "genomic_0001 subgroup");
    } else {
        PASS(YES,
             "M86 PhE: NAME_TOKENIZED-on-sequences leaves no "
             "genomic_0001 subgroup");
    }

    unlink(path.fileSystemRepresentation);
}

// Test 23 — mixed: BASE_PACK seq + QUALITY_BINNED qual + NAME_TOKENIZED rn.
// Exercises the full Phase A/D/E codec stack on a single file.
static void testMixedAllThreeOverrides(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    NSArray<NSString *> *names = m86PhEStructuredNames(kM86_NReads);
    NSDictionary *overrides = @{
        @"sequences":  @(TTIOCompressionBasePack),
        @"qualities":  @(TTIOCompressionQualityBinned),
        @"read_names": @(TTIOCompressionNameTokenized),
    };
    TTIOWrittenGenomicRun *run = m86PhEMakeRun(seqBytes, qualBytes, names,
                                               overrides, TTIOCompressionZlib);
    NSString *path = m86TmpPath("nt_mixed3");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhE mixed-3: BASE_PACK seq + QUALITY_BINNED qual + "
         "NAME_TOKENIZED rn write succeeds");

    uint8_t seqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "sequences");
    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "qualities");
    uint8_t nameAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "read_names");
    PASS(seqAttr  == (uint8_t)TTIOCompressionBasePack,
         "M86 PhE mixed-3: sequences @compression == BASE_PACK (6, got %u)",
         (unsigned)seqAttr);
    PASS(qualAttr == (uint8_t)TTIOCompressionQualityBinned,
         "M86 PhE mixed-3: qualities @compression == QUALITY_BINNED "
         "(7, got %u)", (unsigned)qualAttr);
    PASS(nameAttr == (uint8_t)TTIOCompressionNameTokenized,
         "M86 PhE mixed-3: read_names @compression == NAME_TOKENIZED "
         "(8, got %u)", (unsigned)nameAttr);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) allMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  allMatch = NO;
        if (![r.readName isEqualToString:names[i]]) allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhE mixed-3: all three channels (seq/qual/read_names) "
         "round-trip byte-exact across all 10 reads");

    unlink(path.fileSystemRepresentation);
}

// Cross-language NAME_TOKENIZED fixture — built by Python from the
// same structured-Illumina-name generator the ObjC builder above
// uses. Decoding here verifies the cross-language wire format
// (byte-exact-on-decoded-names).
static void testCrossLanguageFixtureNameTokenized(void)
{
    NSString *path = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/"
                     @"m86_codec_name_tokenized.tio";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 PhE cross-language fixture not found at %s\n",
               path.UTF8String);
        return;
    }

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil,
         "M86 PhE fixture: NAME_TOKENIZED .tio opens via M86 read path");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhE fixture: genomic_0001 present");
    PASS(gr.readCount == kM86_NReads,
         "M86 PhE fixture: 10 reads from cross-language input");

    NSArray<NSString *> *expectedNames = m86PhEStructuredNames(kM86_NReads);
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.readName isEqualToString:expectedNames[i]]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhE fixture: 10 reads decode byte-exact to structured "
         "Illumina names from the Python-built cross-language fixture");

    uint8_t nameAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "read_names");
    PASS(nameAttr == (uint8_t)TTIOCompressionNameTokenized,
         "M86 PhE fixture: read_names @compression == 8 (got %u)",
         (unsigned)nameAttr);
}

// ════════════════════════════════════════════════════════════════════
// M86 Phase B — rANS on integer channels (positions / flags /
// mapping_qualities). Mirrors python/tests/test_m86_genomic_codec_
// wiring.py tests #30–#37 (HANDOFF.md M86 Phase B §6.2). The Phase B
// dispatch is wired through a new int-channel codec helper that
// serialises the integer arrays to little-endian bytes before passing
// them to the M83 rANS codec; the read-side helper
// -intChannelArrayNamed: decodes whole-channel and caches
// per Binding Decisions §115–§119.
// ════════════════════════════════════════════════════════════════════

/** Build a Phase B-style genomic run with caller-supplied integer
 *  arrays for positions / flags / mapping_qualities. The positions in
 *  this run also drive the genomic_index, so per-read position assert-
 *  ions go through the index (per Binding Decision §119) — the helper
 *  -intChannelArrayNamed: exercises the signal_channels/ codec path
 *  directly. */
static TTIOWrittenGenomicRun *m86PhBMakeRun(
    NSData *positionsData,
    NSData *flagsData,
    NSData *mapqsData,
    NSDictionary<NSString *, NSNumber *> *codecOverrides,
    TTIOCompression baseCompression)
{
    NSUInteger n = positionsData.length / sizeof(int64_t);
    NSData *seqBytes = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    // Note: m86PureACGTSequences() / m86PhredCycleQualities() both
    // produce kM86_NReads * kM86_ReadLen bytes; this Phase B helper
    // is exercised at kM86_NReads (10), so the sizes match.
    if (n != kM86_NReads) {
        // Helper invariant: positions must contain exactly kM86_NReads
        // int64 elements so the synthesized seq/qual/offset buffers
        // line up. Bail loudly so callers don't get cryptic decode
        // errors downstream.
        [NSException raise:NSInternalInconsistencyException
                    format:@"Phase B helper expects kM86_NReads-sized "
                           @"positions input (got %lu)",
                           (unsigned long)n];
    }

    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *matePos = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *tlens   = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    uint64_t *op = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp = (uint32_t *)lengths.mutableBytes;
    int64_t  *mp = (int64_t  *)matePos.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        op[i] = (uint64_t)(i * kM86_ReadLen);
        lp[i] = (uint32_t)kM86_ReadLen;
        mp[i] = -1;
    }
    (void)tlens;  // zero-initialised
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *names  = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        [cigars addObject:@"100M"];
        [names  addObject:[NSString stringWithFormat:@"r%lu",
                                                     (unsigned long)i]];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }
    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"M86_PHASEB"
                      positions:positionsData
               mappingQualities:mapqsData
                          flags:flagsData
                      sequences:seqBytes
                      qualities:qualBytes
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:baseCompression
            signalCodecOverrides:codecOverrides];
}

// Test 24 — round-trip positions (int64) with RANS_ORDER1 byte-exact
// through the new -intChannelArrayNamed: helper.
static void testRoundTripPositionsRansOrder1(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    int64_t *pp = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        pp[i] = (int64_t)(i * 1000 + 1000000);
    }
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    uint8_t *mq = (uint8_t *)mapqs.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) mq[i] = 60;

    TTIOWrittenGenomicRun *run = m86PhBMakeRun(
        positions, flags, mapqs,
        @{ @"positions": @(TTIOCompressionRansOrder1) },
        TTIOCompressionZlib);
    NSString *path = m86TmpPath("phb_pos_rt");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhB: write positions+RANS_ORDER1 succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 PhB: positions-codec file reopens");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhB: positions-codec genomicRuns dict populated");

    NSData *decoded = [gr intChannelArrayNamed:@"positions" error:&err];
    PASS(decoded != nil,
         "M86 PhB: -intChannelArrayNamed:'positions' returns non-nil");
    PASS(decoded.length == kM86_NReads * sizeof(int64_t),
         "M86 PhB: positions decoded length == n_reads * 8 (got %lu)",
         (unsigned long)decoded.length);
    BOOL allMatch = YES;
    if (decoded.length == kM86_NReads * sizeof(int64_t)) {
        const int64_t *got = (const int64_t *)decoded.bytes;
        for (NSUInteger i = 0; i < kM86_NReads; i++) {
            if (got[i] != (int64_t)(i * 1000 + 1000000)) {
                allMatch = NO;
                break;
            }
        }
    } else {
        allMatch = NO;
    }
    PASS(allMatch, "M86 PhB: positions int64 values round-trip byte-exact");

    unlink(path.fileSystemRepresentation);
}

// Test 25 — round-trip flags (uint32) with RANS_ORDER0 byte-exact.
static void testRoundTripFlagsRansOrder0(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    int64_t *pp = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) pp[i] = (int64_t)(i * 1000);
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    uint32_t *fp = (uint32_t *)flags.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        fp[i] = (i % 2 == 0) ? 0x0001u : 0x0083u;
    }
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    uint8_t *mq = (uint8_t *)mapqs.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) mq[i] = 60;

    TTIOWrittenGenomicRun *run = m86PhBMakeRun(
        positions, flags, mapqs,
        @{ @"flags": @(TTIOCompressionRansOrder0) },
        TTIOCompressionZlib);
    NSString *path = m86TmpPath("phb_flg_rt");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhB: write flags+RANS_ORDER0 succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSData *decoded = [gr intChannelArrayNamed:@"flags" error:&err];
    PASS(decoded != nil && decoded.length == kM86_NReads * sizeof(uint32_t),
         "M86 PhB: flags decoded length == n_reads * 4 (got %lu)",
         (unsigned long)(decoded ? decoded.length : 0));
    BOOL allMatch = YES;
    if (decoded.length == kM86_NReads * sizeof(uint32_t)) {
        const uint32_t *got = (const uint32_t *)decoded.bytes;
        for (NSUInteger i = 0; i < kM86_NReads; i++) {
            uint32_t expected = (i % 2 == 0) ? 0x0001u : 0x0083u;
            if (got[i] != expected) { allMatch = NO; break; }
        }
    } else {
        allMatch = NO;
    }
    PASS(allMatch, "M86 PhB: flags uint32 values round-trip byte-exact");

    unlink(path.fileSystemRepresentation);
}

// Test 26 — round-trip mapping_qualities (uint8) with RANS_ORDER1.
//
// Per Gotcha §131 the LE serialisation is a no-op for uint8 (1 byte
// per element), but the dispatch path is still exercised end-to-end.
static void testRoundTripMappingQualitiesRansOrder1(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    int64_t *pp = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) pp[i] = (int64_t)(i * 1000);
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    uint8_t *mq = (uint8_t *)mapqs.mutableBytes;
    // 80% MAPQ 60, 20% MAPQ 0 — typical Illumina distribution.
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        mq[i] = (i % 5 != 0) ? 60 : 0;
    }

    TTIOWrittenGenomicRun *run = m86PhBMakeRun(
        positions, flags, mapqs,
        @{ @"mapping_qualities": @(TTIOCompressionRansOrder1) },
        TTIOCompressionZlib);
    NSString *path = m86TmpPath("phb_mq_rt");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhB: write mapping_qualities+RANS_ORDER1 succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSData *decoded = [gr intChannelArrayNamed:@"mapping_qualities"
                                          error:&err];
    PASS(decoded != nil && decoded.length == kM86_NReads,
         "M86 PhB: mapping_qualities decoded length == n_reads (got %lu)",
         (unsigned long)(decoded ? decoded.length : 0));
    BOOL allMatch = YES;
    if (decoded.length == kM86_NReads) {
        const uint8_t *got = (const uint8_t *)decoded.bytes;
        for (NSUInteger i = 0; i < kM86_NReads; i++) {
            uint8_t expected = (i % 5 != 0) ? 60 : 0;
            if (got[i] != expected) { allMatch = NO; break; }
        }
    } else {
        allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhB: mapping_qualities uint8 values round-trip byte-exact");

    unlink(path.fileSystemRepresentation);
}

// Test 27 — size win for clustered positions (10000 reads / 100 loci).
//
// Per the implementer's deviation note (Python test #33 changed the
// baseline from HDF5-ZLIB to raw LE bytes — ZLIB's LZ77 beats rANS on
// monotonic sequences, so the realistic test pattern is "clustered
// positions" mimicking high-coverage WGS, 100 reads per locus).
// Compare the rANS encoder output against the raw int64 LE byte
// length; target < 50% (Python achieved 18.4%).
static void testSizeWinPositions(void)
{
    NSUInteger nReads = 10000;
    NSMutableData *raw = [NSMutableData dataWithLength:
                          nReads * sizeof(int64_t)];
    int64_t *src = (int64_t *)raw.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) {
        src[i] = (int64_t)(1000000 + (i / 100) * 1000);
    }
    NSUInteger rawLen = raw.length;

    // Encode through the same code path the writer uses: identity
    // memcpy on x86/ARM (host LE) then TTIORansEncode.
    NSData *encoded = TTIORansEncode(raw, 1);
    PASS(encoded != nil && encoded.length > 0,
         "M86 PhB size-win: rANS order-1 encode of clustered positions "
         "produces non-empty output (%lu bytes)",
         (unsigned long)(encoded ? encoded.length : 0));
    NSUInteger encodedLen = encoded.length;
    double ratio = (double)encodedLen / (double)rawLen;
    PASS(ratio < 0.50,
         "M86 PhB size-win: rANS_ORDER1 clustered positions ratio %.3f "
         "< 0.50 (encoded=%lu bytes, raw_int64_LE=%lu bytes)",
         ratio, (unsigned long)encodedLen, (unsigned long)rawLen);
}

// Test 28 — verify @compression attribute correctness on integer
// channels under rANS overrides (HANDOFF.md §5.2).
static void testAttributeSetCorrectlyIntegerChannels(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    int64_t *pp = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) pp[i] = (int64_t)(i * 1000);
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    uint8_t *mq = (uint8_t *)mapqs.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) mq[i] = 60;

    NSDictionary *overrides = @{
        @"positions":         @(TTIOCompressionRansOrder1),
        @"flags":             @(TTIOCompressionRansOrder0),
        @"mapping_qualities": @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = m86PhBMakeRun(positions, flags, mapqs,
                                               overrides,
                                               TTIOCompressionZlib);
    NSString *path = m86TmpPath("phb_attr");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhB attr: write all-three integer overrides succeeds");

    uint8_t posAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                             "positions");
    uint8_t flgAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                             "flags");
    uint8_t mqAttr  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                             "mapping_qualities");
    PASS(posAttr == (uint8_t)TTIOCompressionRansOrder1,
         "M86 PhB attr: positions @compression == RANS_ORDER1 (5, got %u)",
         (unsigned)posAttr);
    PASS(flgAttr == (uint8_t)TTIOCompressionRansOrder0,
         "M86 PhB attr: flags @compression == RANS_ORDER0 (4, got %u)",
         (unsigned)flgAttr);
    PASS(mqAttr == (uint8_t)TTIOCompressionRansOrder1,
         "M86 PhB attr: mapping_qualities @compression == RANS_ORDER1 "
         "(5, got %u)", (unsigned)mqAttr);

    // Verify the dataset class is H5T_INTEGER (uint8) for each codec-
    // compressed channel.
    hid_t f = H5Fopen(path.fileSystemRepresentation,
                      H5F_ACC_RDONLY, H5P_DEFAULT);
    PASS(f >= 0, "M86 PhB attr: file opens via H5Fopen");
    const char *channels[] = {"positions", "flags", "mapping_qualities"};
    BOOL allUint8 = YES;
    for (int k = 0; k < 3; k++) {
        char dsname[256];
        snprintf(dsname, sizeof(dsname),
                 "study/genomic_runs/genomic_0001/signal_channels/%s",
                 channels[k]);
        hid_t did = H5Dopen2(f, dsname, H5P_DEFAULT);
        if (did < 0) { allUint8 = NO; continue; }
        hid_t ht = H5Dget_type(did);
        if (H5Tequal(ht, H5T_NATIVE_UINT8) <= 0) allUint8 = NO;
        H5Tclose(ht);
        H5Dclose(did);
    }
    if (f >= 0) H5Fclose(f);
    PASS(allUint8,
         "M86 PhB attr: all 3 codec-compressed integer datasets are "
         "H5T_NATIVE_UINT8 on disk");

    // Untouched byte channels (sequences/qualities) still carry no
    // @compression attribute (sentinel 254).
    uint8_t seqAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                             "sequences");
    uint8_t qualAttr = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "qualities");
    PASS(seqAttr == 254 && qualAttr == 254,
         "M86 PhB attr: untouched sequences/qualities carry no "
         "@compression attribute");

    unlink(path.fileSystemRepresentation);
}

// Test 29 — reject BASE_PACK on positions with the wrong-content
// rationale (Binding Decision §117).
static void testRejectBasePackOnPositions(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    NSDictionary *overrides = @{
        @"positions": @(TTIOCompressionBasePack),
    };
    TTIOWrittenGenomicRun *run = m86PhBMakeRun(positions, flags, mapqs,
                                               overrides,
                                               TTIOCompressionZlib);
    NSString *path = m86TmpPath("phb_bp_pos");
    unlink(path.fileSystemRepresentation);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        m86Write(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised, "M86 PhB: BASE_PACK on 'positions' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhB: BASE_PACK-on-positions exception is "
         "NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"BASE_PACK"].location != NSNotFound,
         "M86 PhB: BASE_PACK error names the codec");
    PASS([reason rangeOfString:@"positions"].location != NSNotFound,
         "M86 PhB: BASE_PACK error names the channel ('positions')");
    PASS([reason rangeOfString:@"RANS_ORDER"].location != NSNotFound,
         "M86 PhB: BASE_PACK error points at the rANS replacement");

    unlink(path.fileSystemRepresentation);
}

// Test 30 — reject QUALITY_BINNED on flags.
static void testRejectQualityBinnedOnFlags(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    NSDictionary *overrides = @{
        @"flags": @(TTIOCompressionQualityBinned),
    };
    TTIOWrittenGenomicRun *run = m86PhBMakeRun(positions, flags, mapqs,
                                               overrides,
                                               TTIOCompressionZlib);
    NSString *path = m86TmpPath("phb_qb_flg");
    unlink(path.fileSystemRepresentation);

    BOOL raised = NO;
    NSException *captured = nil;
    @try {
        NSError *err = nil;
        m86Write(path, run, &err);
    } @catch (NSException *e) {
        raised = YES;
        captured = e;
    }
    PASS(raised,
         "M86 PhB: QUALITY_BINNED on 'flags' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhB: QB-on-flags exception is NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"QUALITY_BINNED"].location != NSNotFound,
         "M86 PhB: QUALITY_BINNED error names the codec");
    PASS([reason rangeOfString:@"flags"].location != NSNotFound,
         "M86 PhB: QUALITY_BINNED error names the channel ('flags')");
    PASS([reason rangeOfString:@"RANS_ORDER"].location != NSNotFound,
         "M86 PhB: QUALITY_BINNED error points at the rANS replacement");

    unlink(path.fileSystemRepresentation);
}

// Test 31 — full-stack: all six channel overrides at once. Gotcha
// §133 — most likely to surface ordering bugs across the codec
// dispatch matrix.
static void testRoundTripFullStack(void)
{
    NSMutableData *positions = [NSMutableData dataWithLength:
                                kM86_NReads * sizeof(int64_t)];
    int64_t *pp = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        pp[i] = (int64_t)(i * 1000 + 1000000);
    }
    NSMutableData *flags = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint32_t)];
    uint32_t *fp = (uint32_t *)flags.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        fp[i] = (i % 2 == 0) ? 0x0001u : 0x0083u;
    }
    NSMutableData *mapqs = [NSMutableData dataWithLength:
                            kM86_NReads * sizeof(uint8_t)];
    uint8_t *mq = (uint8_t *)mapqs.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        mq[i] = (i % 5 != 0) ? 60 : 0;
    }

    // Build the run inline so the read_names are structured for
    // NAME_TOKENIZED and the qualities are bin-centre Phred for
    // QUALITY_BINNED to round-trip byte-exact.
    NSData *seqBytes = m86PureACGTSequences();
    NSData *qualBytes = m86BinCentreQualities();
    NSArray<NSString *> *names = m86PhEStructuredNames(kM86_NReads);

    NSMutableData *offsets = [NSMutableData dataWithLength:
                              kM86_NReads * sizeof(uint64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:
                              kM86_NReads * sizeof(uint32_t)];
    NSMutableData *matePos = [NSMutableData dataWithLength:
                              kM86_NReads * sizeof(int64_t)];
    NSMutableData *tlens   = [NSMutableData dataWithLength:
                              kM86_NReads * sizeof(int32_t)];
    uint64_t *op = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp = (uint32_t *)lengths.mutableBytes;
    int64_t  *mp = (int64_t  *)matePos.mutableBytes;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        op[i] = (uint64_t)(i * kM86_ReadLen);
        lp[i] = (uint32_t)kM86_ReadLen;
        mp[i] = -1;
    }
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:kM86_NReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:kM86_NReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:kM86_NReads];
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        [cigars addObject:@"100M"];
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
    }

    NSDictionary *overrides = @{
        @"sequences":         @(TTIOCompressionBasePack),
        @"qualities":         @(TTIOCompressionQualityBinned),
        @"read_names":        @(TTIOCompressionNameTokenized),
        @"positions":         @(TTIOCompressionRansOrder1),
        @"flags":             @(TTIOCompressionRansOrder0),
        @"mapping_qualities": @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"M86_FULL_STACK"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seqBytes
                      qualities:qualBytes
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib
            signalCodecOverrides:overrides];
    NSString *path = m86TmpPath("phb_full_stack");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhB full-stack: write all-six overrides succeeds");

    // Verify all six @compression attributes on disk.
    uint8_t seqA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "sequences");
    uint8_t qualA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                           "qualities");
    uint8_t nameA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                           "read_names");
    uint8_t posA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "positions");
    uint8_t flgA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "flags");
    uint8_t mqA  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "mapping_qualities");
    PASS(seqA == TTIOCompressionBasePack
         && qualA == TTIOCompressionQualityBinned
         && nameA == TTIOCompressionNameTokenized
         && posA == TTIOCompressionRansOrder1
         && flgA == TTIOCompressionRansOrder0
         && mqA  == TTIOCompressionRansOrder1,
         "M86 PhB full-stack: all 6 @compression attributes correct "
         "(seq=%u, qual=%u, names=%u, pos=%u, flg=%u, mq=%u)",
         (unsigned)seqA, (unsigned)qualA, (unsigned)nameA,
         (unsigned)posA, (unsigned)flgA, (unsigned)mqA);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhB full-stack: file reopens through reader");

    // Byte/string channels via the AlignedRead reader (existing path).
    BOOL byteStringMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { byteStringMatch = NO; break; }
        if (![r.sequence isEqualToString:m86ExpectedSequenceSlice(seqBytes, i)]) byteStringMatch = NO;
        if (![r.qualities isEqualToData:m86ExpectedQualitySlice(qualBytes, i)])  byteStringMatch = NO;
        if (![r.readName isEqualToString:names[i]]) byteStringMatch = NO;
    }
    PASS(byteStringMatch,
         "M86 PhB full-stack: byte/string channels (seq/qual/read_names) "
         "round-trip byte-exact across all 10 reads");

    // Integer channels via the new Phase B helper. Per Binding
    // Decision §119 -readAtIndex: does NOT consume these — it reads
    // from the genomic_index — so the helper is the correct probe.
    NSData *posD = [gr intChannelArrayNamed:@"positions" error:&err];
    NSData *flgD = [gr intChannelArrayNamed:@"flags" error:&err];
    NSData *mqD  = [gr intChannelArrayNamed:@"mapping_qualities" error:&err];
    BOOL intMatch = (posD.length == kM86_NReads * sizeof(int64_t)
                     && flgD.length == kM86_NReads * sizeof(uint32_t)
                     && mqD.length == kM86_NReads);
    if (intMatch) {
        const int64_t  *pg = (const int64_t  *)posD.bytes;
        const uint32_t *fg = (const uint32_t *)flgD.bytes;
        const uint8_t  *mg = (const uint8_t  *)mqD.bytes;
        for (NSUInteger i = 0; i < kM86_NReads; i++) {
            if (pg[i] != (int64_t)(i * 1000 + 1000000)) intMatch = NO;
            uint32_t expF = (i % 2 == 0) ? 0x0001u : 0x0083u;
            if (fg[i] != expF) intMatch = NO;
            uint8_t expM = (i % 5 != 0) ? 60 : 0;
            if (mg[i] != expM) intMatch = NO;
        }
    }
    PASS(intMatch,
         "M86 PhB full-stack: integer channels (positions/flags/"
         "mapping_qualities) round-trip byte-exact via "
         "-intChannelArrayNamed:");

    unlink(path.fileSystemRepresentation);
}

// Test 32 — cross-language fixture: read the Python-built
// m86_codec_integer_channels.tio and verify all three integer
// channels decode byte-exact (HANDOFF.md §6.4).
static void testCrossLanguageFixtureIntegerChannels(void)
{
    NSString *path = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/"
                     @"m86_codec_integer_channels.tio";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 PhB cross-language fixture not found at %s\n",
               path.UTF8String);
        return;
    }

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 PhB fixture: integer-channel .tio opens");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhB fixture: genomic_0001 present");
    NSUInteger expectedReads = 100;
    PASS(gr.readCount == expectedReads,
         "M86 PhB fixture: 100 reads from cross-language input "
         "(got %lu)", (unsigned long)gr.readCount);

    NSData *posD = [gr intChannelArrayNamed:@"positions" error:&err];
    NSData *flgD = [gr intChannelArrayNamed:@"flags" error:&err];
    NSData *mqD  = [gr intChannelArrayNamed:@"mapping_qualities" error:&err];

    BOOL allMatch = (posD.length == expectedReads * sizeof(int64_t)
                     && flgD.length == expectedReads * sizeof(uint32_t)
                     && mqD.length == expectedReads);
    if (allMatch) {
        const int64_t  *pg = (const int64_t  *)posD.bytes;
        const uint32_t *fg = (const uint32_t *)flgD.bytes;
        const uint8_t  *mg = (const uint8_t  *)mqD.bytes;
        for (NSUInteger i = 0; i < expectedReads; i++) {
            int64_t expP = (int64_t)(i * 1000 + 1000000);
            uint32_t expF = (i % 2 == 0) ? 0x0001u : 0x0083u;
            uint8_t expM = (i % 5 != 0) ? 60 : 0;
            if (pg[i] != expP) { allMatch = NO; break; }
            if (fg[i] != expF) { allMatch = NO; break; }
            if (mg[i] != expM) { allMatch = NO; break; }
        }
    }
    PASS(allMatch,
         "M86 PhB fixture: all 3 integer channels decode byte-exact "
         "from the Python-built cross-language fixture");

    uint8_t posA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "positions");
    uint8_t flgA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "flags");
    uint8_t mqA  = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                          "mapping_qualities");
    PASS(posA == (uint8_t)TTIOCompressionRansOrder1
         && flgA == (uint8_t)TTIOCompressionRansOrder0
         && mqA  == (uint8_t)TTIOCompressionRansOrder1,
         "M86 PhB fixture: @compression attrs match the Python writer "
         "(pos=%u, flg=%u, mq=%u)",
         (unsigned)posA, (unsigned)flgA, (unsigned)mqA);
}

// ── Entry point ─────────────────────────────────────────────────────

void testM86GenomicCodecWiring(void)
{
    testRoundTripSequencesRansOrder0();
    testRoundTripSequencesRansOrder1();
    testRoundTripSequencesBasePack();
    testRoundTripQualitiesRansOrder1();
    testRoundTripMixed();
    testBackCompatNoOverrides();
    testRejectInvalidChannel();
    testRejectInvalidCodec();
    testAttributeSetCorrectly();
    testSizeWinBasePack();
    testCrossLanguageFixtures();
    // M86 Phase D — QUALITY_BINNED on the qualities channel.
    testRoundTripQualitiesQualityBinned();
    testRoundTripQualitiesQualityBinnedLossy();
    testSizeWinQualityBinned();
    testAttributeSetCorrectlyQualityBinned();
    testRejectQualityBinnedOnSequences();
    testMixedQualityBinnedWithRans();
    testCrossLanguageFixtureQualityBinned();
    // M86 Phase E — NAME_TOKENIZED on the read_names channel.
    testRoundTripReadNamesNameTokenized();
    testSizeWinNameTokenized();
    testAttributeSetCorrectlyNameTokenized();
    testBackCompatReadNamesUnchanged();
    testRejectNameTokenizedOnSequences();
    testMixedAllThreeOverrides();
    testCrossLanguageFixtureNameTokenized();
    // M86 Phase B — rANS on the integer channels (positions /
    // flags / mapping_qualities). Mirrors Python tests #30–#37.
    testRoundTripPositionsRansOrder1();
    testRoundTripFlagsRansOrder0();
    testRoundTripMappingQualitiesRansOrder1();
    testSizeWinPositions();
    testAttributeSetCorrectlyIntegerChannels();
    testRejectBasePackOnPositions();
    testRejectQualityBinnedOnFlags();
    testRoundTripFullStack();
    testCrossLanguageFixtureIntegerChannels();
}
