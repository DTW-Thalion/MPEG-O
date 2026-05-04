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
    // M86 Phase C (Binding Decisions §120, §124): cigars joined the
    // override-eligible set; mate_info remains the only structurally-
    // VL string channel the validator continues to reject (Gotcha
    // §137). Use `mate_info` to exercise the unknown-channel rejection
    // path now that cigars is valid.
    NSDictionary *overrides = @{ @"mate_info": @(TTIOCompressionRansOrder0) };
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
    PASS(raised, "M86: override on 'mate_info' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86: bad-channel exception is NSInvalidArgumentException");
    PASS(captured && [captured.reason rangeOfString:@"mate_info"].location != NSNotFound,
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

    PASS(seqAttr == (uint8_t)codec,
         "M86 attr/%s: sequences @compression == codec id (%u, got %u)",
         label, (unsigned)codec, (unsigned)seqAttr);
    PASS(qualAttr == 254,
         "M86 attr/%s: qualities has NO @compression (no override)", label);
    // v1.6: positions / flags / mapping_qualities no longer live under
    // signal_channels — see testV16SignalChannelsHasNoIntDups.

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
// M86 Phase C — rANS + NAME_TOKENIZED on the cigars channel.
// HANDOFF.md M86 Phase C §6.2. Mirrors Python tests #39–#47 + the
// two cross-language fixture readers.
//
// Schema lift: when signalCodecOverrides contains "cigars", the
// writer replaces the M82 compound cigars dataset (VL_STRING-in-
// compound) with a flat 1-D uint8 dataset of the same name carrying
// the codec output, plus an @compression attribute naming the codec
// id. Three codec paths accepted (Binding Decision §120):
//   - RANS_ORDER0 / RANS_ORDER1: serialise NSArray<NSString*> via
//     length-prefix-concat (varint(asciiLen) + asciiBytes per
//     CIGAR), then TTIORansEncode (Gotcha §139).
//   - NAME_TOKENIZED: TTIONameTokenizerEncode directly on the
//     list[str] (the codec's self-describing wire format).
// ════════════════════════════════════════════════════════════════════

/** Build a Phase C cigars run with caller-supplied cigars list. The
 *  other channels mirror m86PhEMakeRun's defaults so the new tests
 *  stay isolated to the cigars dispatch path. */
static TTIOWrittenGenomicRun *m86PhCMakeRun(
    NSData *seqBytes, NSData *qualBytes,
    NSArray<NSString *> *cigars,
    NSArray<NSString *> *names,
    NSDictionary<NSString *, NSNumber *> *codecOverrides,
    TTIOCompression baseCompression)
{
    NSUInteger n = cigars.count;
    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *mapqs     = [NSMutableData dataWithLength:n * sizeof(uint8_t)];
    NSMutableData *flags     = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *offsets   = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    NSMutableData *lengths   = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *matePos   = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    NSMutableData *tlens     = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    int64_t  *posp = (int64_t  *)positions.mutableBytes;
    uint8_t  *mqp  = (uint8_t  *)mapqs.mutableBytes;
    uint64_t *op   = (uint64_t *)offsets.mutableBytes;
    uint32_t *lp   = (uint32_t *)lengths.mutableBytes;
    int64_t  *mpp  = (int64_t  *)matePos.mutableBytes;
    NSUInteger readLen = (seqBytes.length > 0 && n > 0)
                         ? (seqBytes.length / n) : 0;
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *namesActual = names
        ? [names mutableCopy]
        : [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        posp[i] = (int64_t)(i * 1000);
        mqp[i]  = 60;
        op[i]   = (uint64_t)(i * readLen);
        lp[i]   = (uint32_t)readLen;
        mpp[i]  = -1;
        [mateChroms addObject:@"chr1"];
        [chroms addObject:@"chr1"];
        if (names == nil) {
            [namesActual addObject:[NSString stringWithFormat:@"r%lu",
                                                              (unsigned long)i]];
        }
    }
    (void)flags; (void)tlens;
    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"M86C_TEST"
                      positions:positions
               mappingQualities:mapqs
                          flags:flags
                      sequences:seqBytes
                      qualities:qualBytes
                        offsets:offsets
                        lengths:lengths
                         cigars:cigars
                      readNames:namesActual
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:tlens
                    chromosomes:chroms
              signalCompression:baseCompression
            signalCodecOverrides:codecOverrides];
}

/** Build the canonical Phase C 1000-read mixed-CIGAR list — the
 *  realistic-WGS workload pattern matching the Python implementer's
 *  generator (HANDOFF M86 Phase C §6.4 fixture A): 80% "100M" +
 *  10% "99M1D" + 10% "50M50S". */
static NSArray<NSString *> *m86PhCMixedCigars(NSUInteger n)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger r = i % 10;
        if (r < 8)         [out addObject:@"100M"];
        else if (r == 8)   [out addObject:@"99M1D"];
        else               [out addObject:@"50M50S"];
    }
    return out;
}

/** Build a 1000-read mixed-CIGAR Phase C run for the size tests. */
static TTIOWrittenGenomicRun *m86PhCMakeMixed1000Run(
    NSDictionary<NSString *, NSNumber *> *codecOverrides)
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
    NSArray<NSString *> *cigars = m86PhCMixedCigars(nReads);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        [names addObject:[NSString stringWithFormat:@"r%lu",
                                                    (unsigned long)i]];
    }
    return m86PhCMakeRun(seq, qual, cigars, names,
                         codecOverrides, TTIOCompressionNone);
}

/** Build a 1000-read uniform-CIGAR (all "100M") Phase C run. */
static TTIOWrittenGenomicRun *m86PhCMakeUniform1000Run(
    NSDictionary<NSString *, NSNumber *> *codecOverrides)
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
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names  = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        [cigars addObject:@"100M"];
        [names  addObject:[NSString stringWithFormat:@"r%lu",
                                                     (unsigned long)i]];
    }
    return m86PhCMakeRun(seq, qual, cigars, names,
                         codecOverrides, TTIOCompressionNone);
}

// Test 33 — round-trip cigars with RANS_ORDER1 byte-exact across a
// 100-read mixed-CIGAR input (the realistic WGS workload).
static void testRoundTripCigarsRansOrder1(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSArray<NSString *> *cigars = m86PhCMixedCigars(kM86_NReads);
    NSDictionary *overrides = @{
        @"cigars": @(TTIOCompressionRansOrder1)
    };
    TTIOWrittenGenomicRun *run = m86PhCMakeRun(seqBytes, qualBytes,
                                                cigars, nil, overrides,
                                                TTIOCompressionZlib);
    NSString *path = m86TmpPath("phc_cig_rans1");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhC: write cigars+RANS_ORDER1 succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 PhC: cigars-RANS file reopens");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhC: cigars-RANS genomicRuns dict populated");
    PASS(gr.readCount == kM86_NReads,
         "M86 PhC: cigars-RANS readCount round-trips");

    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.cigar isEqualToString:cigars[i]]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhC: cigars+RANS_ORDER1 round-trips byte-exact across "
         "all 10 reads");

    unlink(path.fileSystemRepresentation);
}

// Test 34 — round-trip cigars with NAME_TOKENIZED on uniform input
// (NAME_TOKENIZED's columnar-mode sweet spot per HANDOFF §1.2).
static void testRoundTripCigarsNameTokenizedUniform(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:kM86_NReads];
    for (NSUInteger i = 0; i < kM86_NReads; i++) [cigars addObject:@"100M"];
    NSDictionary *overrides = @{
        @"cigars": @(TTIOCompressionNameTokenized)
    };
    TTIOWrittenGenomicRun *run = m86PhCMakeRun(seqBytes, qualBytes,
                                                cigars, nil, overrides,
                                                TTIOCompressionZlib);
    NSString *path = m86TmpPath("phc_cig_nt_uni");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhC: write cigars+NAME_TOKENIZED uniform succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.cigar isEqualToString:@"100M"]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhC: cigars+NAME_TOKENIZED uniform round-trips byte-exact "
         "across all 10 reads");

    unlink(path.fileSystemRepresentation);
}

// Test 35 — round-trip cigars with NAME_TOKENIZED on mixed input.
//
// Per HANDOFF §1.2 the codec falls back to verbatim mode here (token
// shapes vary across reads); round-trip still succeeds but the wire
// is much larger than RANS_ORDER1's. The size test #36 documents
// the cost.
static void testRoundTripCigarsNameTokenizedMixed(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSArray<NSString *> *cigars = m86PhCMixedCigars(kM86_NReads);
    NSDictionary *overrides = @{
        @"cigars": @(TTIOCompressionNameTokenized)
    };
    TTIOWrittenGenomicRun *run = m86PhCMakeRun(seqBytes, qualBytes,
                                                cigars, nil, overrides,
                                                TTIOCompressionZlib);
    NSString *path = m86TmpPath("phc_cig_nt_mix");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhC: write cigars+NAME_TOKENIZED mixed succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.cigar isEqualToString:cigars[i]]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhC: cigars+NAME_TOKENIZED mixed round-trips byte-exact "
         "(verbatim-mode fallback path)");

    unlink(path.fileSystemRepresentation);
}

// Test 36 — side-by-side cigars wire size for the 1000-read mixed
// CIGAR input. Demonstrates HANDOFF §1.2 selection guidance: on
// realistic-WGS-like input RANS_ORDER1 << NAME_TOKENIZED < no-override.
static void testSizeComparisonCigarsCodecs(void)
{
    TTIOWrittenGenomicRun *noRun   = m86PhCMakeMixed1000Run(@{});
    TTIOWrittenGenomicRun *ransRun = m86PhCMakeMixed1000Run(
        @{ @"cigars": @(TTIOCompressionRansOrder1) });
    TTIOWrittenGenomicRun *ntRun   = m86PhCMakeMixed1000Run(
        @{ @"cigars": @(TTIOCompressionNameTokenized) });

    NSString *pNo   = m86TmpPath("phc_cig_size_no");
    NSString *pRans = m86TmpPath("phc_cig_size_rans");
    NSString *pNt   = m86TmpPath("phc_cig_size_nt");
    unlink(pNo.fileSystemRepresentation);
    unlink(pRans.fileSystemRepresentation);
    unlink(pNt.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(pNo,   noRun,   &err),
         "M86 PhC size: no-override cigars write succeeds");
    PASS(m86Write(pRans, ransRun, &err),
         "M86 PhC size: cigars+RANS_ORDER1 write succeeds");
    PASS(m86Write(pNt,   ntRun,   &err),
         "M86 PhC size: cigars+NAME_TOKENIZED write succeeds");

    NSDictionary *aNo   = [[NSFileManager defaultManager]
        attributesOfItemAtPath:pNo error:nil];
    NSDictionary *aRans = [[NSFileManager defaultManager]
        attributesOfItemAtPath:pRans error:nil];
    NSDictionary *aNt   = [[NSFileManager defaultManager]
        attributesOfItemAtPath:pNt error:nil];
    unsigned long long noFile   = [aNo[NSFileSize]   unsignedLongLongValue];
    unsigned long long ransFile = [aRans[NSFileSize] unsignedLongLongValue];
    unsigned long long ntFile   = [aNt[NSFileSize]   unsignedLongLongValue];

    hsize_t ransSize = m86PhEChannelStorageSize(
        pRans.fileSystemRepresentation, "cigars");
    hsize_t ntSize   = m86PhEChannelStorageSize(
        pNt.fileSystemRepresentation, "cigars");

    // HDF5 storage_size on the M82 compound misses the global VL heap.
    // Approximate the M82 footprint via file-size delta vs the rANS
    // file (which differs only in the cigars dataset). Same approach
    // as Python's test_size_comparison_cigars_codecs.
    long long signedDelta = (long long)noFile - (long long)ransFile;
    unsigned long long noFootprint = (unsigned long long)
        ((long long)ransSize + (signedDelta > 0 ? signedDelta : 0));

    printf("\n[M86 Phase C size comparison — 1000-read mixed CIGARs]\n"
           "  no-override (M82 compound): %llu bytes (approx; file=%llu)\n"
           "  RANS_ORDER1:                %llu bytes (file=%llu)\n"
           "  NAME_TOKENIZED (verbatim):  %llu bytes (file=%llu)\n",
           noFootprint, noFile,
           (unsigned long long)ransSize, ransFile,
           (unsigned long long)ntSize, ntFile);

    PASS((unsigned long long)ransSize < (unsigned long long)ntSize,
         "M86 PhC size: RANS_ORDER1 (%llu) beats NAME_TOKENIZED-verbatim "
         "(%llu) on mixed-CIGAR input (§1.2 — realistic WGS workload)",
         (unsigned long long)ransSize, (unsigned long long)ntSize);
    PASS((unsigned long long)ntSize < noFootprint,
         "M86 PhC size: NAME_TOKENIZED-verbatim (%llu) still beats M82 "
         "compound footprint (%llu) — the codec at least avoids the "
         "VL_STRING heap overhead",
         (unsigned long long)ntSize, noFootprint);

    unlink(pNo.fileSystemRepresentation);
    unlink(pRans.fileSystemRepresentation);
    unlink(pNt.fileSystemRepresentation);
}

// Test 37 — uniform-cigar size win: NAME_TOKENIZED columnar-mode and
// RANS_ORDER1 both decisively beat the raw 5000-byte length-prefix-
// concat for 1000 × "100M". Per Python's test_size_win_cigars_uniform
// we assert NAME_TOKENIZED < 50% of the raw concat baseline; rANS
// also beats raw concat. (Ordering between NT and rANS on uniform
// input depends on per-codec overhead and is not asserted.)
static void testSizeWinCigarsUniform(void)
{
    TTIOWrittenGenomicRun *ransRun = m86PhCMakeUniform1000Run(
        @{ @"cigars": @(TTIOCompressionRansOrder1) });
    TTIOWrittenGenomicRun *ntRun   = m86PhCMakeUniform1000Run(
        @{ @"cigars": @(TTIOCompressionNameTokenized) });

    NSString *pRans = m86TmpPath("phc_cig_uni_rans");
    NSString *pNt   = m86TmpPath("phc_cig_uni_nt");
    unlink(pRans.fileSystemRepresentation);
    unlink(pNt.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(pRans, ransRun, &err),
         "M86 PhC size-uni: cigars+RANS_ORDER1 write succeeds");
    PASS(m86Write(pNt,   ntRun,   &err),
         "M86 PhC size-uni: cigars+NAME_TOKENIZED write succeeds");

    hsize_t ransSize = m86PhEChannelStorageSize(
        pRans.fileSystemRepresentation, "cigars");
    hsize_t ntSize   = m86PhEChannelStorageSize(
        pNt.fileSystemRepresentation, "cigars");
    NSUInteger rawConcat = 1000 * 5;  // varint(3) + b"100M"

    PASS((unsigned long long)ntSize < (unsigned long long)(rawConcat / 2),
         "M86 PhC size-uni: NAME_TOKENIZED (%llu) < 50%% of raw concat "
         "(%lu/2 = %lu) — columnar-mode wins on uniform input",
         (unsigned long long)ntSize,
         (unsigned long)rawConcat,
         (unsigned long)(rawConcat / 2));
    PASS((unsigned long long)ransSize < (unsigned long long)rawConcat,
         "M86 PhC size-uni: RANS_ORDER1 (%llu) beats raw concat (%lu) "
         "on uniform input via order-1 entropy collapse",
         (unsigned long long)ransSize, (unsigned long)rawConcat);

    unlink(pRans.fileSystemRepresentation);
    unlink(pNt.fileSystemRepresentation);
}

// Test 38 — verify @compression attribute correctness on the cigars
// dataset under each accepted codec override.
static void testAttributeSetCorrectlyCigars(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:kM86_NReads];
    for (NSUInteger i = 0; i < kM86_NReads; i++) [cigars addObject:@"100M"];

    const TTIOCompression codecs[3] = {
        TTIOCompressionRansOrder0,
        TTIOCompressionRansOrder1,
        TTIOCompressionNameTokenized,
    };
    const char *labels[3] = {"RANS_ORDER0", "RANS_ORDER1", "NAME_TOKENIZED"};

    for (int k = 0; k < 3; k++) {
        TTIOCompression codec = codecs[k];
        NSDictionary *overrides = @{ @"cigars": @(codec) };
        TTIOWrittenGenomicRun *run = m86PhCMakeRun(seqBytes, qualBytes,
                                                    cigars, nil, overrides,
                                                    TTIOCompressionZlib);
        NSString *path = m86TmpPath("phc_cig_attr");
        unlink(path.fileSystemRepresentation);

        NSError *err = nil;
        PASS(m86Write(path, run, &err),
             "M86 PhC attr/%s: write succeeds", labels[k]);

        // Verify cigars dataset is 1-D uint8 with the right
        // @compression value.
        hid_t f = H5Fopen(path.fileSystemRepresentation,
                          H5F_ACC_RDONLY, H5P_DEFAULT);
        hid_t did = H5Dopen2(f,
            "study/genomic_runs/genomic_0001/signal_channels/cigars",
            H5P_DEFAULT);
        hid_t htype = H5Dget_type(did);
        PASS(H5Tequal(htype, H5T_NATIVE_UINT8) > 0,
             "M86 PhC attr/%s: cigars dtype == H5T_NATIVE_UINT8",
             labels[k]);
        H5Tclose(htype);
        hid_t space = H5Dget_space(did);
        int rank = H5Sget_simple_extent_ndims(space);
        PASS(rank == 1,
             "M86 PhC attr/%s: cigars is 1-D (rank=%d)", labels[k], rank);
        H5Sclose(space);
        H5Dclose(did);
        H5Fclose(f);

        uint8_t cigarsAttr = m86ReadCompressionAttr(
            path.fileSystemRepresentation, "cigars");
        PASS(cigarsAttr == (uint8_t)codec,
             "M86 PhC attr/%s: cigars @compression == %u (got %u)",
             labels[k], (unsigned)codec, (unsigned)cigarsAttr);

        // Untouched read_names remains compound (no override), and
        // sequences/qualities carry no @compression either.
        uint8_t namesAttr = m86ReadCompressionAttr(
            path.fileSystemRepresentation, "read_names");
        uint8_t seqAttr = m86ReadCompressionAttr(
            path.fileSystemRepresentation, "sequences");
        uint8_t qualAttr = m86ReadCompressionAttr(
            path.fileSystemRepresentation, "qualities");
        // read_names stays compound under no override, so the helper
        // returns 254 (sentinel for "absent attribute"). Same for
        // sequences and qualities.
        PASS(namesAttr == 254 && seqAttr == 254 && qualAttr == 254,
             "M86 PhC attr/%s: only cigars carries @compression; "
             "read_names/sequences/qualities have no attribute",
             labels[k]);

        unlink(path.fileSystemRepresentation);
    }
}

// Test 39 — without override, cigars stays compound (M82) and
// round-trips via the existing read path (which now goes through
// cigarAtIndex:'s compound fall-through).
static void testBackCompatCigarsUnchanged(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:kM86_NReads];
    for (NSUInteger i = 0; i < kM86_NReads; i++) [cigars addObject:@"100M"];

    // Empty overrides — cigars stays as the M82 compound.
    TTIOWrittenGenomicRun *run = m86PhCMakeRun(seqBytes, qualBytes,
                                                cigars, nil, @{},
                                                TTIOCompressionZlib);
    NSString *path = m86TmpPath("phc_cig_bc");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhC back-compat: empty-overrides write succeeds");

    // Verify cigars is COMPOUND (not H5T_INTEGER) and carries no
    // @compression attribute.
    hid_t f = H5Fopen(path.fileSystemRepresentation,
                      H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t did = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/cigars",
        H5P_DEFAULT);
    PASS(did >= 0, "M86 PhC back-compat: cigars dataset exists");
    hid_t htype = H5Dget_type(did);
    H5T_class_t cls = H5Tget_class(htype);
    PASS(cls == H5T_COMPOUND,
         "M86 PhC back-compat: cigars dataset class is H5T_COMPOUND "
         "(got %d) — no schema lift without override", (int)cls);
    PASS(H5Aexists(did, "compression") <= 0,
         "M86 PhC back-compat: compound cigars carries NO "
         "@compression attribute");
    H5Tclose(htype);
    if (did >= 0) H5Dclose(did);
    if (f   >= 0) H5Fclose(f);

    // Round-trip via the existing M82 compound read path through
    // cigarAtIndex:'s compound fall-through.
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.cigar isEqualToString:@"100M"]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhC back-compat: M82 compound cigars round-trips "
         "byte-exact via the cigarAtIndex: compound fall-through");

    unlink(path.fileSystemRepresentation);
}

// Test 40 — BASE_PACK on cigars raises NSException with rationale.
static void testRejectBasePackOnCigars(void)
{
    NSData *seqBytes  = m86PureACGTSequences();
    NSData *qualBytes = m86PhredCycleQualities();
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:kM86_NReads];
    for (NSUInteger i = 0; i < kM86_NReads; i++) [cigars addObject:@"100M"];
    NSDictionary *overrides = @{
        @"cigars": @(TTIOCompressionBasePack)
    };
    TTIOWrittenGenomicRun *run = m86PhCMakeRun(seqBytes, qualBytes,
                                                cigars, nil, overrides,
                                                TTIOCompressionZlib);
    NSString *path = m86TmpPath("phc_cig_bp_bad");
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
    PASS(raised, "M86 PhC: BASE_PACK on 'cigars' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhC: BASE_PACK-on-cigars exception is "
         "NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"BASE_PACK"].location != NSNotFound,
         "M86 PhC: BASE_PACK error message names the codec");
    PASS([reason rangeOfString:@"cigars"].location != NSNotFound,
         "M86 PhC: BASE_PACK error message names the channel ('cigars')");
    PASS([reason rangeOfString:@"RANS_ORDER"].location != NSNotFound
         || [reason rangeOfString:@"NAME_TOKENIZED"].location != NSNotFound,
         "M86 PhC: BASE_PACK error message points at the accepted "
         "alternatives");

    unlink(path.fileSystemRepresentation);
}
// Test 42 — cross-language fixture: Python-built cigars+RANS_ORDER1
// fixture decodes byte-exact (HANDOFF §6.4 fixture A). The fixture
// is a 100-read mixed-CIGAR run.
static void testCrossLanguageFixtureCigarsRans(void)
{
    NSString *path = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/"
                     @"m86_codec_cigars_rans.tio";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 PhC cigars-RANS cross-language fixture not "
               "found at %s\n", path.UTF8String);
        return;
    }

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil,
         "M86 PhC fixture-rans: cigars-RANS .tio opens via reader");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhC fixture-rans: genomic_0001 present");
    NSUInteger expected = 100;
    PASS(gr.readCount == expected,
         "M86 PhC fixture-rans: 100 reads from cross-language input "
         "(got %lu)", (unsigned long)gr.readCount);

    NSArray<NSString *> *expectedCigars = m86PhCMixedCigars(expected);
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < expected; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.cigar isEqualToString:expectedCigars[i]]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhC fixture-rans: 100 cigars decode byte-exact from the "
         "Python-built cross-language fixture");

    uint8_t cigarsA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "cigars");
    PASS(cigarsA == (uint8_t)TTIOCompressionRansOrder1,
         "M86 PhC fixture-rans: cigars @compression == RANS_ORDER1 "
         "(5, got %u)", (unsigned)cigarsA);
}

// Test 43 — cross-language fixture: Python-built cigars+NAME_TOKENIZED
// fixture decodes byte-exact (HANDOFF §6.4 fixture B). The fixture
// is a 100-read uniform-CIGAR run.
static void testCrossLanguageFixtureCigarsNameTokenized(void)
{
    NSString *path = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/"
                     @"m86_codec_cigars_name_tokenized.tio";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 PhC cigars-NAME_TOKENIZED cross-language "
               "fixture not found at %s\n", path.UTF8String);
        return;
    }

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil,
         "M86 PhC fixture-nt: cigars-NAME_TOKENIZED .tio opens via "
         "reader");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhC fixture-nt: genomic_0001 present");
    NSUInteger expected = 100;
    PASS(gr.readCount == expected,
         "M86 PhC fixture-nt: 100 reads from cross-language input "
         "(got %lu)", (unsigned long)gr.readCount);

    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < expected; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.cigar isEqualToString:@"100M"]) {
            allMatch = NO;
            break;
        }
    }
    PASS(allMatch,
         "M86 PhC fixture-nt: 100 cigars decode byte-exact (\"100M\" "
         "× 100) from the Python-built cross-language fixture");

    uint8_t cigarsA = m86ReadCompressionAttr(path.fileSystemRepresentation,
                                              "cigars");
    PASS(cigarsA == (uint8_t)TTIOCompressionNameTokenized,
         "M86 PhC fixture-nt: cigars @compression == NAME_TOKENIZED "
         "(8, got %u)", (unsigned)cigarsA);
}

// ── M86 Phase F — mate_info per-field decomposition ─────────────────
//
// Schema-lift wiring: when ANY of mate_info_chrom, mate_info_pos,
// mate_info_tlen is in signalCodecOverrides, mate_info changes from
// the M82 compound dataset to a subgroup containing three child
// datasets. Per-field codec dispatch routes through TTIORans /
// TTIONameTokenizer; un-overridden fields use natural-dtype HDF5
// ZLIB inside the subgroup. Reader dispatches on HDF5 link type
// (H5O_TYPE_GROUP = Phase F; H5O_TYPE_DATASET = M82).

// Realistic Phase F mate distributions matching the cross-language
// fixture (HANDOFF §6.4): 90 chr1, 5 chr2, 3 chrX, 2 unmapped ("*").
static const NSUInteger kM86F_NReads = 100;

static NSArray<NSString *> *m86PhFMateChroms(void)
{
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:kM86F_NReads];
    for (NSUInteger i = 0; i <  90; i++) [out addObject:@"chr1"];
    for (NSUInteger i = 0; i <   5; i++) [out addObject:@"chr2"];
    for (NSUInteger i = 0; i <   3; i++) [out addObject:@"chrX"];
    for (NSUInteger i = 0; i <   2; i++) [out addObject:@"*"];
    return out;
}

static NSData *m86PhFMatePositions(void)
{
    NSArray<NSString *> *chroms = m86PhFMateChroms();
    NSMutableData *out = [NSMutableData dataWithLength:kM86F_NReads * sizeof(int64_t)];
    int64_t *p = (int64_t *)out.mutableBytes;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        p[i] = [chroms[i] isEqualToString:@"*"] ? -1 : (int64_t)(i * 100 + 500);
    }
    return out;
}

static NSData *m86PhFMateTlens(void)
{
    NSArray<NSString *> *chroms = m86PhFMateChroms();
    NSMutableData *out = [NSMutableData dataWithLength:kM86F_NReads * sizeof(int32_t)];
    int32_t *p = (int32_t *)out.mutableBytes;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        p[i] = [chroms[i] isEqualToString:@"*"]
                  ? 0
                  : (int32_t)(350 + (i % 11) - 5);
    }
    return out;
}

// Build a 100-read run with the Phase F mate distributions and
// arbitrary mate_info overrides. Other channels use the M82 baseline
// (no overrides) so the fixture isolates the mate_info schema-lift.
static TTIOWrittenGenomicRun *m86PhFMakeRun(
    NSDictionary<NSString *, NSNumber *> *mateOverrides)
{
    NSUInteger n = kM86F_NReads;
    NSUInteger total = n * kM86_ReadLen;
    NSMutableData *seq = [NSMutableData dataWithLength:total];
    uint8_t *sp = (uint8_t *)seq.mutableBytes;
    static const uint8_t cycle[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < total; i++) sp[i] = cycle[i % 4];
    NSMutableData *qual = [NSMutableData dataWithLength:total];
    uint8_t *qp = (uint8_t *)qual.mutableBytes;
    for (NSUInteger i = 0; i < total; i++) qp[i] = (uint8_t)(30 + (i % 11));

    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(int64_t)];
    int64_t *pp = (int64_t *)positions.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) pp[i] = (int64_t)(i * 1000);
    NSMutableData *mapqs = [NSMutableData dataWithLength:n * sizeof(uint8_t)];
    uint8_t *mq = (uint8_t *)mapqs.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) mq[i] = 60;
    NSMutableData *flags = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    uint64_t *op = (uint64_t *)offsets.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) op[i] = (uint64_t)(i * kM86_ReadLen);
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *lp = (uint32_t *)lengths.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) lp[i] = (uint32_t)kM86_ReadLen;

    NSMutableArray<NSString *> *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *names  = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        [cigars addObject:@"100M"];
        [names  addObject:[NSString stringWithFormat:@"r%lu", (unsigned long)i]];
        [chroms addObject:@"chr1"];
    }

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"GRCh38.p14"
                        platform:@"ILLUMINA"
                      sampleName:@"M86F_MATE"
                       positions:positions
                mappingQualities:mapqs
                           flags:flags
                       sequences:seq
                       qualities:qual
                         offsets:offsets
                         lengths:lengths
                          cigars:cigars
                       readNames:names
                 mateChromosomes:m86PhFMateChroms()
                   matePositions:m86PhFMatePositions()
                 templateLengths:m86PhFMateTlens()
                     chromosomes:chroms
               signalCompression:TTIOCompressionZlib
             signalCodecOverrides:mateOverrides];
    // v1.7 #11: Phase F tests exercise the v1 per-field layout explicitly;
    // opt out of inline_v2 so the mate_info subgroup path is preserved.
    run.optDisableInlineMateInfoV2 = YES;
    return run;
}

// Verify the on-disk mate_info link is a group (Phase F) and that
// the named child dataset has the expected @compression value.
static BOOL m86PhFMateChildHasCompression(const char *path,
                                           const char *child,
                                           uint8_t expected,
                                           uint8_t *outActual)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return NO;
    char dpath[256];
    snprintf(dpath, sizeof(dpath),
             "study/genomic_runs/genomic_0001/signal_channels/mate_info/%s",
             child);
    hid_t did = H5Dopen2(f, dpath, H5P_DEFAULT);
    if (did < 0) { H5Fclose(f); return NO; }
    BOOL ok = NO;
    if (H5Aexists(did, "compression") > 0) {
        hid_t aid = H5Aopen(did, "compression", H5P_DEFAULT);
        uint8_t v = 0;
        H5Aread(aid, H5T_NATIVE_UINT8, &v);
        H5Aclose(aid);
        if (outActual) *outActual = v;
        ok = (v == expected);
    } else {
        if (outActual) *outActual = 0;
    }
    H5Dclose(did);
    H5Fclose(f);
    return ok;
}

static BOOL m86PhFMateInfoIsGroup(const char *path)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return NO;
    H5O_info_t info;
    herr_t s = H5Oget_info_by_name(f,
        "study/genomic_runs/genomic_0001/signal_channels/mate_info",
        &info, H5P_DEFAULT);
    BOOL isGroup = (s >= 0 && info.type == H5O_TYPE_GROUP);
    H5Fclose(f);
    return isGroup;
}

static BOOL m86PhFMateInfoIsDataset(const char *path)
{
    hid_t f = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    if (f < 0) return NO;
    H5O_info_t info;
    herr_t s = H5Oget_info_by_name(f,
        "study/genomic_runs/genomic_0001/signal_channels/mate_info",
        &info, H5P_DEFAULT);
    BOOL isDataset = (s >= 0 && info.type == H5O_TYPE_DATASET);
    H5Fclose(f);
    return isDataset;
}

// Test 48 — round-trip mate_info_chrom = NAME_TOKENIZED
static void testRoundTripMateChromNameTokenized(void)
{
    NSDictionary *overrides = @{
        @"mate_info_chrom": @(TTIOCompressionNameTokenized),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_chrom_nt");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhF chrom-NT: write succeeds");
    PASS(m86PhFMateInfoIsGroup(path.fileSystemRepresentation),
         "M86 PhF chrom-NT: mate_info link is a group (Phase F)");
    uint8_t actual = 0;
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "chrom",
                                        (uint8_t)TTIOCompressionNameTokenized,
                                        &actual),
         "M86 PhF chrom-NT: chrom @compression == 8 (got %u)",
         (unsigned)actual);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr.readCount == kM86F_NReads,
         "M86 PhF chrom-NT: readCount round-trips");
    NSArray<NSString *> *expectedChroms = m86PhFMateChroms();
    NSData *expectedPos = m86PhFMatePositions();
    NSData *expectedTlen = m86PhFMateTlens();
    const int64_t *epos = (const int64_t *)expectedPos.bytes;
    const int32_t *etl  = (const int32_t *)expectedTlen.bytes;
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.mateChromosome isEqualToString:expectedChroms[i]]) allMatch = NO;
        if (r.matePosition != epos[i])     allMatch = NO;
        if (r.templateLength != etl[i])    allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhF chrom-NT: all 100 mate fields round-trip byte-exact");

    unlink(path.fileSystemRepresentation);
}

// Test 49 — round-trip mate_info_pos = RANS_ORDER1
static void testRoundTripMatePosRans(void)
{
    NSDictionary *overrides = @{
        @"mate_info_pos": @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_pos_rans");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhF pos-rANS1: write succeeds");
    PASS(m86PhFMateInfoIsGroup(path.fileSystemRepresentation),
         "M86 PhF pos-rANS1: mate_info link is a group (Phase F)");
    uint8_t actual = 0;
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "pos",
                                        (uint8_t)TTIOCompressionRansOrder1,
                                        &actual),
         "M86 PhF pos-rANS1: pos @compression == 5 (got %u)",
         (unsigned)actual);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSData *expectedPos = m86PhFMatePositions();
    const int64_t *epos = (const int64_t *)expectedPos.bytes;
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (r.matePosition != epos[i]) allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhF pos-rANS1: all 100 mate positions round-trip byte-exact");

    unlink(path.fileSystemRepresentation);
}

// Test 50 — round-trip mate_info_tlen = RANS_ORDER1
static void testRoundTripMateTlenRans(void)
{
    NSDictionary *overrides = @{
        @"mate_info_tlen": @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_tlen_rans");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhF tlen-rANS1: write succeeds");
    PASS(m86PhFMateInfoIsGroup(path.fileSystemRepresentation),
         "M86 PhF tlen-rANS1: mate_info link is a group (Phase F)");
    uint8_t actual = 0;
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "tlen",
                                        (uint8_t)TTIOCompressionRansOrder1,
                                        &actual),
         "M86 PhF tlen-rANS1: tlen @compression == 5 (got %u)",
         (unsigned)actual);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSData *expectedTlen = m86PhFMateTlens();
    const int32_t *etl = (const int32_t *)expectedTlen.bytes;
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (r.templateLength != etl[i]) allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhF tlen-rANS1: all 100 template lengths round-trip byte-exact");

    unlink(path.fileSystemRepresentation);
}

// Test 51 — all three mate fields overridden
static void testRoundTripMateAllThree(void)
{
    NSDictionary *overrides = @{
        @"mate_info_chrom": @(TTIOCompressionNameTokenized),
        @"mate_info_pos":   @(TTIOCompressionRansOrder1),
        @"mate_info_tlen":  @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_all3");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhF all-3: write succeeds");
    PASS(m86PhFMateInfoIsGroup(path.fileSystemRepresentation),
         "M86 PhF all-3: mate_info link is a group (Phase F)");
    uint8_t a1 = 0, a2 = 0, a3 = 0;
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "chrom",
                                        (uint8_t)TTIOCompressionNameTokenized,
                                        &a1)
         && m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                          "pos",
                                          (uint8_t)TTIOCompressionRansOrder1,
                                          &a2)
         && m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                          "tlen",
                                          (uint8_t)TTIOCompressionRansOrder1,
                                          &a3),
         "M86 PhF all-3: chrom@8, pos@5, tlen@5 (got %u/%u/%u)",
         (unsigned)a1, (unsigned)a2, (unsigned)a3);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSArray<NSString *> *expectedChroms = m86PhFMateChroms();
    NSData *expectedPos = m86PhFMatePositions();
    NSData *expectedTlen = m86PhFMateTlens();
    const int64_t *epos = (const int64_t *)expectedPos.bytes;
    const int32_t *etl  = (const int32_t *)expectedTlen.bytes;
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.mateChromosome isEqualToString:expectedChroms[i]]) allMatch = NO;
        if (r.matePosition != epos[i])     allMatch = NO;
        if (r.templateLength != etl[i])    allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhF all-3: all 100 mate fields round-trip byte-exact with "
         "all three concurrent codec overrides");

    unlink(path.fileSystemRepresentation);
}

// Test 52 — partial override: only chrom is overridden; pos/tlen
// stay at natural dtype inside the subgroup (no @compression).
static void testRoundTripMatePartial(void)
{
    NSDictionary *overrides = @{
        @"mate_info_chrom": @(TTIOCompressionNameTokenized),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_partial");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhF partial: write (chrom-only override) succeeds");
    PASS(m86PhFMateInfoIsGroup(path.fileSystemRepresentation),
         "M86 PhF partial: mate_info link is a group (subgroup created "
         "even on a single override)");

    // chrom should have @compression == 8; pos and tlen should be the
    // natural dtypes (INT64 / INT32) with NO @compression attribute.
    uint8_t actual = 0;
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "chrom",
                                        (uint8_t)TTIOCompressionNameTokenized,
                                        &actual),
         "M86 PhF partial: chrom @compression == 8 (got %u)",
         (unsigned)actual);

    hid_t f = H5Fopen(path.fileSystemRepresentation, H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t posDs = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/mate_info/pos",
        H5P_DEFAULT);
    hid_t tlenDs = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/mate_info/tlen",
        H5P_DEFAULT);
    PASS(posDs >= 0 && tlenDs >= 0,
         "M86 PhF partial: pos and tlen child datasets exist");
    PASS(H5Aexists(posDs, "compression") <= 0,
         "M86 PhF partial: pos carries NO @compression (natural-dtype path)");
    PASS(H5Aexists(tlenDs, "compression") <= 0,
         "M86 PhF partial: tlen carries NO @compression (natural-dtype path)");
    if (posDs >= 0)  H5Dclose(posDs);
    if (tlenDs >= 0) H5Dclose(tlenDs);
    if (f >= 0)      H5Fclose(f);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSArray<NSString *> *expectedChroms = m86PhFMateChroms();
    NSData *expectedPos = m86PhFMatePositions();
    NSData *expectedTlen = m86PhFMateTlens();
    const int64_t *epos = (const int64_t *)expectedPos.bytes;
    const int32_t *etl  = (const int32_t *)expectedTlen.bytes;
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.mateChromosome isEqualToString:expectedChroms[i]]) allMatch = NO;
        if (r.matePosition != epos[i])     allMatch = NO;
        if (r.templateLength != etl[i])    allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhF partial: all 100 mate fields round-trip — chrom via "
         "NAME_TOKENIZED dispatch, pos+tlen via natural-dtype HDF5 read");

    unlink(path.fileSystemRepresentation);
}

// Test 53 — back-compat: no mate_info_* override → still M82 compound
static void testBackCompatMateInfoUnchanged(void)
{
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(@{});
    NSString *path = m86TmpPath("phf_backcompat");
    unlink(path.fileSystemRepresentation);

    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 PhF back-compat: empty mate overrides write succeeds");
    PASS(m86PhFMateInfoIsDataset(path.fileSystemRepresentation),
         "M86 PhF back-compat: mate_info link is a DATASET (M82 compound)");

    hid_t f = H5Fopen(path.fileSystemRepresentation,
                      H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t did = H5Dopen2(f,
        "study/genomic_runs/genomic_0001/signal_channels/mate_info",
        H5P_DEFAULT);
    hid_t htype = H5Dget_type(did);
    H5T_class_t cls = H5Tget_class(htype);
    PASS(cls == H5T_COMPOUND,
         "M86 PhF back-compat: mate_info dataset is H5T_COMPOUND (got %d)",
         (int)cls);
    H5Tclose(htype);
    if (did >= 0) H5Dclose(did);
    if (f >= 0)   H5Fclose(f);

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    NSArray<NSString *> *expectedChroms = m86PhFMateChroms();
    NSData *expectedPos = m86PhFMatePositions();
    NSData *expectedTlen = m86PhFMateTlens();
    const int64_t *epos = (const int64_t *)expectedPos.bytes;
    const int32_t *etl  = (const int32_t *)expectedTlen.bytes;
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { allMatch = NO; break; }
        if (![r.mateChromosome isEqualToString:expectedChroms[i]]) allMatch = NO;
        if (r.matePosition != epos[i])     allMatch = NO;
        if (r.templateLength != etl[i])    allMatch = NO;
    }
    PASS(allMatch,
         "M86 PhF back-compat: M82 compound mate_info round-trips byte-"
         "exact via the link-type dispatch's compound fall-through");

    unlink(path.fileSystemRepresentation);
}

// Test 54 — bare 'mate_info' key is rejected with a Phase F-aware
// error message naming all three per-field keys.
static void testRejectBareMateInfoKey(void)
{
    NSDictionary *overrides = @{
        @"mate_info": @(TTIOCompressionRansOrder1),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_bare_bad");
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
    PASS(raised, "M86 PhF: bare 'mate_info' key raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhF: bare-key exception is NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"mate_info_chrom"].location != NSNotFound,
         "M86 PhF: bare-key error message names mate_info_chrom");
    PASS([reason rangeOfString:@"mate_info_pos"].location != NSNotFound,
         "M86 PhF: bare-key error message names mate_info_pos");
    PASS([reason rangeOfString:@"mate_info_tlen"].location != NSNotFound,
         "M86 PhF: bare-key error message names mate_info_tlen");

    unlink(path.fileSystemRepresentation);
}

// Test 55 — wrong codec on mate_info_pos rejected (NAME_TOKENIZED on int field).
static void testRejectWrongCodecOnMatePos(void)
{
    NSDictionary *overrides = @{
        @"mate_info_pos": @(TTIOCompressionNameTokenized),
    };
    TTIOWrittenGenomicRun *run = m86PhFMakeRun(overrides);
    NSString *path = m86TmpPath("phf_pos_nt_bad");
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
         "M86 PhF: NAME_TOKENIZED on mate_info_pos raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86 PhF: pos-NT exception is NSInvalidArgumentException");
    NSString *reason = captured ? captured.reason : @"";
    PASS([reason rangeOfString:@"NAME_TOKENIZED"].location != NSNotFound
         || [reason rangeOfString:@"NameTokenized"].location != NSNotFound,
         "M86 PhF: pos-NT error message names the codec");
    PASS([reason rangeOfString:@"mate_info_pos"].location != NSNotFound,
         "M86 PhF: pos-NT error message names the channel");

    unlink(path.fileSystemRepresentation);
}
static void testCrossLanguageFixtureMateInfoFull(void)
{
    NSString *path = @"/home/toddw/TTI-O/objc/Tests/Fixtures/genomic/"
                     @"m86_codec_mate_info_full.tio";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("SKIP: M86 PhF mate_info-full cross-language fixture not "
               "found at %s\n", path.UTF8String);
        return;
    }

    PASS(m86PhFMateInfoIsGroup(path.fileSystemRepresentation),
         "M86 PhF fixture: mate_info link is a group (Phase F)");
    uint8_t a1 = 0, a2 = 0, a3 = 0;
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "chrom",
                                        (uint8_t)TTIOCompressionNameTokenized,
                                        &a1),
         "M86 PhF fixture: chrom @compression == 8 (got %u)", (unsigned)a1);
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "pos",
                                        (uint8_t)TTIOCompressionRansOrder1,
                                        &a2),
         "M86 PhF fixture: pos @compression == 5 (got %u)", (unsigned)a2);
    PASS(m86PhFMateChildHasCompression(path.fileSystemRepresentation,
                                        "tlen",
                                        (uint8_t)TTIOCompressionRansOrder1,
                                        &a3),
         "M86 PhF fixture: tlen @compression == 5 (got %u)", (unsigned)a3);

    NSError *err = nil;
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil, "M86 PhF fixture: file opens via reader");
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M86 PhF fixture: genomic_0001 present");
    PASS(gr.readCount == kM86F_NReads,
         "M86 PhF fixture: 100 reads from cross-language input "
         "(got %lu)", (unsigned long)gr.readCount);

    NSArray<NSString *> *expectedChroms = m86PhFMateChroms();
    NSData *expectedPos = m86PhFMatePositions();
    NSData *expectedTlen = m86PhFMateTlens();
    const int64_t *epos = (const int64_t *)expectedPos.bytes;
    const int32_t *etl  = (const int32_t *)expectedTlen.bytes;
    BOOL chromsOK = YES, posOK = YES, tlenOK = YES;
    for (NSUInteger i = 0; i < kM86F_NReads; i++) {
        TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
        if (r == nil) { chromsOK = posOK = tlenOK = NO; break; }
        if (![r.mateChromosome isEqualToString:expectedChroms[i]]) chromsOK = NO;
        if (r.matePosition != epos[i])     posOK = NO;
        if (r.templateLength != etl[i])    tlenOK = NO;
    }
    PASS(chromsOK,
         "M86 PhF fixture: 100 mate chromosomes decode byte-exact from "
         "the Python-built cross-language fixture");
    PASS(posOK,
         "M86 PhF fixture: 100 mate positions decode byte-exact from "
         "the Python-built cross-language fixture");
    PASS(tlenOK,
         "M86 PhF fixture: 100 template lengths decode byte-exact from "
         "the Python-built cross-language fixture");
}

// ── v1.6: Phase B integer-channel codec wiring REMOVED ──────────────
//
// v1.5 wrote positions/flags/mapping_qualities under BOTH
// genomic_index/ AND signal_channels/. v1.6 drops the signal_channels/
// copy — those fields live exclusively in genomic_index/ now (mirroring
// MS's spectrum_index/ pattern). These tests pin the new contract.
// ─────────────────────────────────────────────────────────────────────

static void testV16RejectOverrideForChannel(NSString *channel,
                                             TTIOCompression codec,
                                             const char *label)
{
    NSData *seq = m86PureACGTSequences();
    NSData *qual = m86PhredCycleQualities();
    TTIOWrittenGenomicRun *run = m86MakeRun(seq, qual,
        @{channel: @(codec)}, TTIOCompressionZlib);
    NSString *path = m86TmpPath(label);
    NSError *err = nil;
    BOOL ok = NO;
    @try {
        ok = m86Write(path, run, &err);
    } @catch (NSException *ex) {
        NSString *reason = ex.reason ?: @"";
        PASS([reason rangeOfString:@"v1.6"].location != NSNotFound
             || [reason rangeOfString:@"genomic_index"].location != NSNotFound,
             "M86 v1.6 reject %s: exception mentions v1.6 or genomic_index "
             "(got: %s)", label, reason.UTF8String);
        unlink(path.fileSystemRepresentation);
        return;
    }
    PASS(!ok, "M86 v1.6 reject %s: write must fail with override on %s",
         label, channel.UTF8String);
    unlink(path.fileSystemRepresentation);
}

static void testV16RejectsPositionsOverride(void)
{
    testV16RejectOverrideForChannel(@"positions",
        TTIOCompressionRansOrder1, "v16-pos");
}

static void testV16RejectsFlagsOverride(void)
{
    testV16RejectOverrideForChannel(@"flags",
        TTIOCompressionRansOrder0, "v16-flags");
}

static void testV16RejectsMappingQualitiesOverride(void)
{
    testV16RejectOverrideForChannel(@"mapping_qualities",
        TTIOCompressionRansOrder1, "v16-mapq");
}

static void testV16SignalChannelsHasNoIntDups(void)
{
    NSData *seq = m86PureACGTSequences();
    NSData *qual = m86PhredCycleQualities();
    TTIOWrittenGenomicRun *run = m86MakeRun(seq, qual, @{},
        TTIOCompressionZlib);
    NSString *path = m86TmpPath("v16-no-dups");
    NSError *err = nil;
    PASS(m86Write(path, run, &err),
         "M86 v1.6 no-dups: write succeeds (err=%s)",
         err.localizedDescription.UTF8String ?: "(none)");

    // Probe via raw HDF5 to assert dataset absence in signal_channels/
    // and presence in genomic_index/.
    hid_t f = H5Fopen(path.fileSystemRepresentation,
                      H5F_ACC_RDONLY, H5P_DEFAULT);
    PASS(f >= 0, "M86 v1.6: file opens via H5Fopen");
    if (f < 0) { unlink(path.fileSystemRepresentation); return; }

    NSString *runRoot = @"study/genomic_runs/genomic_0001";
    for (NSString *ch in @[@"positions", @"flags", @"mapping_qualities"]) {
        NSString *scPath = [NSString stringWithFormat:@"%@/signal_channels/%@",
                                                       runRoot, ch];
        NSString *giPath = [NSString stringWithFormat:@"%@/genomic_index/%@",
                                                       runRoot, ch];
        htri_t scExists = H5Lexists(f, scPath.UTF8String, H5P_DEFAULT);
        htri_t giExists = H5Lexists(f, giPath.UTF8String, H5P_DEFAULT);
        PASS(scExists <= 0,
             "M86 v1.6: signal_channels/%s must NOT be written",
             ch.UTF8String);
        PASS(giExists > 0,
             "M86 v1.6: genomic_index/%s must remain canonical",
             ch.UTF8String);
    }
    H5Fclose(f);
    unlink(path.fileSystemRepresentation);
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
    // v1.6: Phase B integer-channel codec wiring REMOVED. Tests of
    // testRoundTripPositionsRansOrder1 / Flags / MappingQualities /
    // SizeWinPositions / AttributeSetCorrectlyIntegerChannels /
    // RejectBasePackOnPositions / RejectQualityBinnedOnFlags /
    // RoundTripFullStack / CrossLanguageFixtureIntegerChannels —
    // all removed (per-record integer fields now live exclusively in
    // genomic_index/, mirroring MS's spectrum_index/ pattern). See
    // docs/format-spec.md §4 and §10.7.
    // M86 Phase C — rANS + NAME_TOKENIZED on the cigars channel.
    // Mirrors Python tests #39–#47 + the two cross-language fixtures.
    testRoundTripCigarsRansOrder1();
    testRoundTripCigarsNameTokenizedUniform();
    testRoundTripCigarsNameTokenizedMixed();
    testSizeComparisonCigarsCodecs();
    testSizeWinCigarsUniform();
    testAttributeSetCorrectlyCigars();
    testBackCompatCigarsUnchanged();
    testRejectBasePackOnCigars();
    // v1.6: testRoundTripFullSevenOverrides removed (depended on the
    // dropped integer-channel keys).
    testCrossLanguageFixtureCigarsRans();
    testCrossLanguageFixtureCigarsNameTokenized();
    // M86 Phase F — mate_info per-field decomposition. Mirrors
    // Python tests #48–#56 + the cross-language fixture.
    testRoundTripMateChromNameTokenized();
    testRoundTripMatePosRans();
    testRoundTripMateTlenRans();
    testRoundTripMateAllThree();
    testRoundTripMatePartial();
    testBackCompatMateInfoUnchanged();
    testRejectBareMateInfoKey();
    testRejectWrongCodecOnMatePos();
    // v1.6: testRoundTripFullTenOverrides removed (same reason).
    testCrossLanguageFixtureMateInfoFull();
    // v1.6: contract tests for the removed dual-write.
    testV16RejectsPositionsOverride();
    testV16RejectsFlagsOverride();
    testV16RejectsMappingQualitiesOverride();
    testV16SignalChannelsHasNoIntDups();
}
