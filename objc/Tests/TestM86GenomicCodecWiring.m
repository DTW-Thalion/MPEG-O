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
#import "Codecs/TTIOQuality.h"   // M86 Phase D
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
    NSDictionary *overrides = @{ @"positions": @(TTIOCompressionRansOrder0) };
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
    PASS(raised, "M86: override on 'positions' raises NSException");
    PASS(captured && [captured.name isEqualToString:NSInvalidArgumentException],
         "M86: bad-channel exception is NSInvalidArgumentException");
    PASS(captured && [captured.reason rangeOfString:@"positions"].location != NSNotFound,
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
}
