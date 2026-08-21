// TestQualitiesV5.m
//
// Qualities V5 (sequence context): umbrella dispatch, the writer
// gate, reader ordering, and the shared golden decode fixture.
// Python: test_qualities_v5.py; Java: QualitiesV5Test.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"

#include <stdint.h>
#include <string.h>
#include <unistd.h>

// xorshift64, same generator family as the C and Java tests. Quality
// is a function of the current base plus 2 bits of noise with i.i.d.
// bases, the shape sequence context exists for.
static uint64_t v5xs(uint64_t *s)
{
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}

static void v5MotifCorpus(NSMutableData *qual, NSMutableData *seq,
                          NSUInteger nReads, NSUInteger len)
{
    static const uint8_t B[4] = {'A','C','G','T'};
    [qual setLength:nReads * len];
    [seq setLength:nReads * len];
    uint8_t *q = qual.mutableBytes, *sq = seq.mutableBytes;
    uint64_t s = 42;
    for (NSUInteger k = 0; k < nReads * len; k++) {
        unsigned bi = (unsigned)(v5xs(&s) % 4);
        sq[k] = B[bi];
        q[k] = (uint8_t)(40 + 10 * bi + (v5xs(&s) % 4));
    }
}

static NSArray<NSNumber *> *v5Fill(NSUInteger n, NSInteger v)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) [a addObject:@(v)];
    return a;
}

static NSString *v5FixturePath(NSString *name)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSString *c1 = [[here stringByAppendingPathComponent:@"Tests/Fixtures"]
                          stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:c1]) return c1;
        NSString *c2 = [[here stringByAppendingPathComponent:@"objc/Tests/Fixtures"]
                          stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:c2]) return c2;
        here = [here stringByDeletingLastPathComponent];
    }
    return nil;
}

// On-disk M94.Z version byte of the qualities channel blob.
static int v5QualitiesVersionByte(NSString *path)
{
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
    if (!f) return -1;
    TTIOHDF5Group *sc = [[[[[f rootGroup]
        openGroupNamed:@"study" error:NULL]
        openGroupNamed:@"genomic_runs" error:NULL]
        openGroupNamed:@"genomic_0001" error:NULL]
        openGroupNamed:@"signal_channels" error:NULL];
    TTIOHDF5Dataset *ds = [sc openDatasetNamed:@"qualities" error:NULL];
    NSData *blob = [ds readDataWithError:NULL];
    int v = (blob && blob.length > 4)
        ? ((const uint8_t *)blob.bytes)[4] : -1;
    [f close];
    return v;
}

static NSData *v5U32Array(NSUInteger n, uint32_t v)
{
    NSMutableData *d = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    uint32_t *p = d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) p[i] = v;
    return d;
}

static TTIOWrittenGenomicRun *v5MakeRun(NSUInteger nReads, NSUInteger len,
                                        BOOL disable)
{
    NSMutableData *qual = [NSMutableData data], *seq = [NSMutableData data];
    v5MotifCorpus(qual, seq, nReads, len);
    NSMutableData *positions = [NSMutableData dataWithLength:nReads * 8];
    int64_t *pp = positions.mutableBytes;
    NSMutableData *offsets = [NSMutableData dataWithLength:nReads * 8];
    uint64_t *op = offsets.mutableBytes;
    NSMutableData *matePos = [NSMutableData dataWithLength:nReads * 8];
    int64_t *mp = matePos.mutableBytes;
    NSMutableData *mapqs = [NSMutableData dataWithLength:nReads];
    memset(mapqs.mutableBytes, 60, nReads);
    NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
    NSMutableArray *chroms = [NSMutableArray arrayWithCapacity:nReads];
    for (NSUInteger i = 0; i < nReads; i++) {
        pp[i] = 10000 + (int64_t)i * 100;
        op[i] = (uint64_t)i * len;
        mp[i] = -1;
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)len]];
        [names addObject:[NSString stringWithFormat:@"read_%06lu", (unsigned long)i]];
        [mateChroms addObject:@"*"];
        [chroms addObject:@"chr1"];
    }
    TTIOWrittenGenomicRun *run = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"V5_TEST"
                      positions:positions
               mappingQualities:mapqs
                          flags:[NSMutableData dataWithLength:nReads * 4]
                      sequences:seq
                      qualities:qual
                        offsets:offsets
                        lengths:v5U32Array(nReads, (uint32_t)len)
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePos
                templateLengths:[NSMutableData dataWithLength:nReads * 4]
                    chromosomes:chroms
              signalCompression:TTIOCompressionNone
            signalCodecOverrides:@{@"qualities": @(TTIOCompressionFqzcompNx16Z)}];
    run.optDisableQualitiesV5 = disable;
    return run;
}

void testQualitiesV5(void)
{
    // ── Codec level ────────────────────────────────────────────────
    NSMutableData *qual = [NSMutableData data], *seq = [NSMutableData data];
    v5MotifCorpus(qual, seq, 11000, 100);
    NSArray *lens = v5Fill(11000, 100);
    NSArray *flags = v5Fill(11000, 0);
    NSError *err = nil;

    NSData *v4 = [TTIOFqzcompNx16Z encodeWithQualities:qual
                                            readLengths:lens
                                           revcompFlags:flags
                                                  error:&err];
    PASS(v4 != nil && ((const uint8_t *)v4.bytes)[4] == 4,
         "sequence-less encode emits version 4");

    err = nil;
    NSData *v5 = [TTIOFqzcompNx16Z encodeWithQualities:qual
                                            readLengths:lens
                                           revcompFlags:flags
                                              sequences:seq
                                                  error:&err];
    PASS(v5 != nil && ((const uint8_t *)v5.bytes)[4] == 5,
         "motif corpus with sequences emits version 5");
    PASS(v5.length < v4.length, "version 5 is smaller on the motif corpus");

    err = nil;
    NSData *v4b = [TTIOFqzcompNx16Z encodeWithQualities:qual
                                             readLengths:lens
                                            revcompFlags:flags
                                               sequences:nil
                                                   error:&err];
    PASS(v4b != nil && [v4b isEqualToData:v4],
         "nil sequences is byte-identical to the sequence-less encode");

    err = nil;
    NSDictionary *rt = [TTIOFqzcompNx16Z decodeData:v5
                                        revcompFlags:flags
                                   sequencesProvider:^NSData * { return seq; }
                                               error:&err];
    PASS(rt != nil && [rt[@"qualities"] isEqualToData:qual],
         "version 5 round trips through the provider decode");

    err = nil;
    NSDictionary *noSeq = [TTIOFqzcompNx16Z decodeData:v5
                                           revcompFlags:flags
                                                  error:&err];
    PASS(noSeq == nil && err != nil
         && [err.localizedDescription rangeOfString:@"sequences"].location
            != NSNotFound,
         "version 5 without sequences fails naming sequences");

    // ── Sticky-strategy primitives: hint 7 + the stream sniffer ────
    {
        err = nil;
        uint8_t pad = (uint8_t)((-(NSInteger)qual.length) & 0x3);
        NSData *pinned = [TTIOFqzcompNx16Z encodeQualWithQualities:qual
                                                       readLengths:lens
                                                      revcompFlags:flags
                                                         sequences:seq
                                                      strategyHint:TTIOM94ZHintV4Auto
                                                          padCount:pad
                                                             error:&err];
        PASS(pinned != nil && [pinned isEqualToData:v4],
             "hint 7 with sequences is byte-identical to V4-auto");
        PASS([TTIOFqzcompNx16Z strategyOfEncodedStream:v4] == 4,
             "sniffer reads V4");
        NSInteger autoWin = [TTIOFqzcompNx16Z strategyOfEncodedStream:v5];
        PASS(autoWin == 5 || autoWin == 6,
             "sniffer reads the auto V5 winner");

        NSMutableData *sq = [NSMutableData data], *ss = [NSMutableData data];
        v5MotifCorpus(sq, ss, 300, 100);
        NSArray *slens = v5Fill(300, 100), *sflags = v5Fill(300, 0);
        uint8_t sPad = (uint8_t)((-(NSInteger)sq.length) & 0x3);
        err = nil;
        NSData *s5 = [TTIOFqzcompNx16Z encodeQualWithQualities:sq
                                                   readLengths:slens
                                                  revcompFlags:sflags
                                                     sequences:ss
                                                  strategyHint:5
                                                      padCount:sPad
                                                         error:&err];
        PASS(s5 != nil && [TTIOFqzcompNx16Z strategyOfEncodedStream:s5] == 5,
             "sniffer reads S5");
        err = nil;
        NSData *s6 = [TTIOFqzcompNx16Z encodeQualWithQualities:sq
                                                   readLengths:slens
                                                  revcompFlags:sflags
                                                     sequences:ss
                                                  strategyHint:6
                                                      padCount:sPad
                                                         error:&err];
        PASS(s6 != nil && [TTIOFqzcompNx16Z strategyOfEncodedStream:s6] == 6,
             "sniffer reads S6");

        uint8_t junk[2] = {88, 88};
        PASS([TTIOFqzcompNx16Z strategyOfEncodedStream:
                  [NSData dataWithBytes:junk length:2]] < 0,
             "sniffer rejects a non-M94Z stream");

        // ── V6: hint 8, sniffs as 8, decodes with no sequences ──
        err = nil;
        NSData *v6 = [TTIOFqzcompNx16Z encodeQualWithQualities:qual
                                                  readLengths:lens
                                                 revcompFlags:flags
                                                    sequences:nil
                                                 strategyHint:TTIOM94ZHintV6
                                                     padCount:pad
                                                        error:&err];
        PASS(v6 != nil && ((const uint8_t *)v6.bytes)[4] == 6,
             "hint 8 emits version 6");
        PASS([TTIOFqzcompNx16Z strategyOfEncodedStream:v6] == 8,
             "sniffer reads V6");

        err = nil;
        NSData *v6s = [TTIOFqzcompNx16Z encodeQualWithQualities:qual
                                                   readLengths:lens
                                                  revcompFlags:flags
                                                     sequences:seq
                                                  strategyHint:TTIOM94ZHintV6
                                                      padCount:pad
                                                         error:&err];
        PASS(v6s != nil && [v6s isEqualToData:v6],
             "hint 8 ignores sequences at the default width of 0");

        err = nil;
        NSDictionary *v6back = [TTIOFqzcompNx16Z decodeData:v6
                                               revcompFlags:flags
                                                      error:&err];
        PASS(v6back != nil
             && [(NSData *)v6back[@"qualities"] isEqualToData:qual],
             "V6 round-trips without sequences");

        err = nil;
        NSDictionary *v6prov = [TTIOFqzcompNx16Z decodeData:v6
                                               revcompFlags:flags
                                          sequencesProvider:nil
                                                      error:&err];
        PASS(v6prov != nil
             && [(NSData *)v6prov[@"qualities"] isEqualToData:qual],
             "V6 decodes through the provider overload with no provider");

        /* The width reaches the stream through the class knob, and a
         * decoder needs the sequences only because the stream says so.
         * Python: test_v6_sequence_context_round_trips_and_shrinks;
         * Java: QualitiesV5Test.v6SequenceContextRoundTrips. */
        PASS([TTIOFqzcompNx16Z v6SequenceContextBits] == 0,
             "V6 sequence context is off by default");
        [TTIOFqzcompNx16Z setV6SequenceContextBits:4];
        PASS([TTIOFqzcompNx16Z v6SequenceContextBits] == 4,
             "V6 sequence context width is readable back");
        err = nil;
        NSData *v6w = [TTIOFqzcompNx16Z encodeQualWithQualities:qual
                                                   readLengths:lens
                                                  revcompFlags:flags
                                                     sequences:seq
                                                  strategyHint:TTIOM94ZHintV6
                                                      padCount:pad
                                                         error:&err];
        PASS(v6w != nil && ![v6w isEqualToData:v6] && v6w.length < v6.length,
             "a width of 4 uses the sequences and shrinks the stream "
             "(%lu vs %lu)", (unsigned long)v6w.length, (unsigned long)v6.length);
        err = nil;
        NSDictionary *v6wback = [TTIOFqzcompNx16Z decodeData:v6w
                                                revcompFlags:flags
                                           sequencesProvider:^NSData *{ return seq; }
                                                       error:&err];
        PASS(v6wback != nil
             && [(NSData *)v6wback[@"qualities"] isEqualToData:qual],
             "a width of 4 round-trips through the sequences provider (%s)",
             [[err localizedDescription] UTF8String] ?: "nil err");

        [TTIOFqzcompNx16Z setV6SequenceContextBits:TTIOM94ZV6SbitsAuto];
        err = nil;
        NSData *v6a = [TTIOFqzcompNx16Z encodeQualWithQualities:qual
                                                   readLengths:lens
                                                  revcompFlags:flags
                                                     sequences:seq
                                                  strategyHint:TTIOM94ZHintV6
                                                      padCount:pad
                                                         error:&err];
        PASS(v6a != nil && v6a.length <= v6.length,
             "the automatic width never loses to a width of 0 (%lu vs %lu)",
             (unsigned long)v6a.length, (unsigned long)v6.length);
        [TTIOFqzcompNx16Z setV6SequenceContextBits:0];
        PASS([TTIOFqzcompNx16Z v6SequenceContextBits] == 0,
             "V6 sequence context restored to off");
    }

    // ── Golden fixture — the cross-language decode contract ────────
    {
        NSString *pb = v5FixturePath(@"qualities_v5_golden.bin");
        NSString *ps = v5FixturePath(@"qualities_v5_golden_seq.bin");
        NSString *pq = v5FixturePath(@"qualities_v5_golden_qual.bin");
        PASS(pb != nil && ps != nil && pq != nil, "golden fixture located");
        if (pb && ps && pq) {
            NSData *blob = [NSData dataWithContentsOfFile:pb];
            NSData *gseq = [NSData dataWithContentsOfFile:ps];
            NSData *gqual = [NSData dataWithContentsOfFile:pq];
            err = nil;
            NSDictionary *r = [TTIOFqzcompNx16Z decodeData:blob
                                               revcompFlags:v5Fill(300, 0)
                                          sequencesProvider:^NSData * { return gseq; }
                                                      error:&err];
            PASS(r != nil && [r[@"qualities"] isEqualToData:gqual],
                 "golden V5 stream decodes bit-exactly");
        }

        NSString *p6 = v5FixturePath(@"qualities_v6_golden.bin");
        NSString *q6 = v5FixturePath(@"qualities_v6_golden_qual.bin");
        PASS(p6 != nil && q6 != nil, "V6 golden fixture located");
        if (p6 && q6) {
            NSData *blob6 = [NSData dataWithContentsOfFile:p6];
            NSData *qual6 = [NSData dataWithContentsOfFile:q6];
            PASS(((const uint8_t *)blob6.bytes)[4] == 6,
                 "V6 golden carries version byte 6");
            err = nil;
            NSDictionary *r6 = [TTIOFqzcompNx16Z decodeData:blob6
                                               revcompFlags:v5Fill(300, 0)
                                                      error:&err];
            PASS(r6 != nil && [r6[@"qualities"] isEqualToData:qual6],
                 "golden V6 stream decodes bit-exactly");
        }
    }

    // ── File level: writer gate + reader ordering ──────────────────
    {
        NSString *path = [NSString stringWithFormat:
            @"/tmp/ttio_test_qv5_%d.tio", (int)getpid()];
        unlink([path fileSystemRepresentation]);
        TTIOWrittenGenomicRun *run = v5MakeRun(11000, 100, NO);
        NSData *expectQual = [run.qualitiesData copy];
        NSError *werr = nil;
        PASS([TTIOSpectralDataset writeMinimalToPath:path
                                               title:@"v5"
                                  isaInvestigationId:@"V5"
                                              msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run}
                                     identifications:nil
                                     quantifications:nil
                                   provenanceRecords:nil
                                               error:&werr],
             "V5 genomic file writes");
        PASS(v5QualitiesVersionByte(path) == 5,
             "qualities channel carries version byte 5 on disk");
        NSError *rerr = nil;
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:path error:&rerr];
        PASS(ds != nil, "V5 genomic file reopens");
        if (ds) {
            TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
            PASS(gr != nil, "genomic run present");
            NSMutableData *got = [NSMutableData data];
            for (NSUInteger i = 0; i < 3 && gr; i++) {
                TTIOAlignedRead *rd = [gr readAtIndex:i error:&rerr];
                PASS(rd != nil, "read materialises");
                if (rd) [got appendData:rd.qualities];
            }
            PASS([got isEqualToData:
                     [expectQual subdataWithRange:NSMakeRange(0, 300)]],
                 "decoded qualities match through the V5 file path");
        }
        unlink([path fileSystemRepresentation]);

        // Opt-out keeps version 4 on disk.
        TTIOWrittenGenomicRun *run4 = v5MakeRun(11000, 100, YES);
        NSData *expectQual4 = [run4.qualitiesData copy];
        werr = nil;
        PASS([TTIOSpectralDataset writeMinimalToPath:path
                                               title:@"v4"
                                  isaInvestigationId:@"V4"
                                              msRuns:@{}
                                         genomicRuns:@{@"genomic_0001": run4}
                                     identifications:nil
                                     quantifications:nil
                                   provenanceRecords:nil
                                               error:&werr],
             "opt-out genomic file writes");
        PASS(v5QualitiesVersionByte(path) == 4,
             "opt-out keeps version byte 4 on disk");
        rerr = nil;
        TTIOSpectralDataset *ds4 =
            [TTIOSpectralDataset readFromFilePath:path error:&rerr];
        PASS(ds4 != nil, "opt-out file reopens");
        if (ds4) {
            TTIOGenomicRun *gr4 = ds4.genomicRuns[@"genomic_0001"];
            TTIOAlignedRead *rd = gr4 ? [gr4 readAtIndex:1 error:&rerr] : nil;
            PASS(rd != nil && [rd.qualities isEqualToData:
                     [expectQual4 subdataWithRange:NSMakeRange(100, 100)]],
                 "opt-out file reads back");
        }
        unlink([path fileSystemRepresentation]);
    }
}
