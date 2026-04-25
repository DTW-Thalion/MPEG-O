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
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOProviderRegistry.h"
#include <unistd.h>
#include <string.h>

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

// ── GenomicIndex (in-memory) ───────────────────────────────────────

static TTIOGenomicIndex *makeIndex6(void)
{
    uint64_t offsets[6]    = {0, 150, 300, 450, 600, 750};
    uint32_t lengths[6]    = {150, 150, 150, 150, 150, 150};
    int64_t  positions[6]  = {100, 15000, 100, 200, 100, 25000};
    uint8_t  mapqs[6]      = {60, 60, 0, 60, 60, 60};
    uint32_t flags[6]      = {0, 0, 0x4, 0x10, 0x1, 0};
    NSArray *chroms = @[@"chr1", @"chr1", @"chr2", @"chr2", @"chrX", @"chr1"];

    return [[TTIOGenomicIndex alloc]
        initWithOffsets:[NSData dataWithBytes:offsets length:sizeof(offsets)]
                lengths:[NSData dataWithBytes:lengths length:sizeof(lengths)]
            chromosomes:chroms
              positions:[NSData dataWithBytes:positions length:sizeof(positions)]
       mappingQualities:[NSData dataWithBytes:mapqs length:sizeof(mapqs)]
                  flags:[NSData dataWithBytes:flags length:sizeof(flags)]];
}

static void testGenomicIndexInMemory(void)
{
    TTIOGenomicIndex *idx = makeIndex6();
    PASS(idx.count == 6, "M82: GenomicIndex count");
    PASS([idx offsetAt:0] == 0, "M82: offsetAt[0]");
    PASS([idx lengthAt:5] == 150, "M82: lengthAt[5]");
    PASS([idx positionAt:1] == 15000, "M82: positionAt[1]");
    PASS([idx mappingQualityAt:2] == 0, "M82: mappingQualityAt[2]");
    PASS([idx flagsAt:3] == 0x10, "M82: flagsAt[3]");
    PASS([[idx chromosomeAt:4] isEqualToString:@"chrX"], "M82: chromosomeAt[4]");

    NSIndexSet *region = [idx indicesForRegion:@"chr1" start:10000 end:20000];
    PASS([region containsIndex:1] && region.count == 1,
         "M82: indicesForRegion narrows correctly");

    NSIndexSet *empty = [idx indicesForRegion:@"chrY" start:0 end:1000000];
    PASS(empty.count == 0, "M82: indicesForRegion empty when no match");

    NSIndexSet *unmapped = [idx indicesForUnmapped];
    PASS([unmapped containsIndex:2] && unmapped.count == 1,
         "M82: indicesForUnmapped");

    NSIndexSet *reverse = [idx indicesForFlag:0x10];
    PASS([reverse containsIndex:3] && reverse.count == 1,
         "M82: indicesForFlag(reverse)");

    NSIndexSet *paired = [idx indicesForFlag:0x1];
    PASS([paired containsIndex:4] && paired.count == 1,
         "M82: indicesForFlag(paired)");
}

// ── WrittenGenomicRun container ────────────────────────────────────

static void testWrittenGenomicRunConstruction(void)
{
    uint64_t offsets[2]   = {0, 150};
    uint32_t lengths[2]   = {150, 150};
    int64_t  positions[2] = {1000, 2000};
    uint8_t  mapqs[2]     = {60, 60};
    uint32_t flags[2]     = {0, 0};
    int64_t  matePos[2]   = {-1, -1};
    int32_t  tlens[2]     = {0, 0};

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"NA12878"
                           positions:[NSData dataWithBytes:positions length:sizeof(positions)]
                    mappingQualities:[NSData dataWithBytes:mapqs length:sizeof(mapqs)]
                               flags:[NSData dataWithBytes:flags length:sizeof(flags)]
                           sequences:[NSMutableData dataWithLength:300]
                           qualities:[NSMutableData dataWithLength:300]
                             offsets:[NSData dataWithBytes:offsets length:sizeof(offsets)]
                             lengths:[NSData dataWithBytes:lengths length:sizeof(lengths)]
                              cigars:@[@"150M", @"150M"]
                           readNames:@[@"r1", @"r2"]
                     mateChromosomes:@[@"", @""]
                       matePositions:[NSData dataWithBytes:matePos length:sizeof(matePos)]
                     templateLengths:[NSData dataWithBytes:tlens length:sizeof(tlens)]
                         chromosomes:@[@"chr1", @"chr1"]
                  signalCompression:TTIOCompressionZlib];

    PASS(run != nil, "M82: WrittenGenomicRun constructible");
    PASS(run.acquisitionMode == TTIOAcquisitionModeGenomicWGS,
         "M82: acquisitionMode preserved");
    PASS([run.referenceUri isEqualToString:@"GRCh38.p14"],
         "M82: referenceUri preserved");
    PASS(run.cigars.count == 2, "M82: cigars count preserved");
    PASS(run.readCount == 2, "M82: readCount derived from offsets");
    PASS(run.signalCompression == TTIOCompressionZlib,
         "M82: signalCompression preserved");
}

// ── GenomicIndex disk round-trip ───────────────────────────────────

static void testGenomicIndexDiskRoundTrip(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_m82idx_%d.h5", (int)getpid()];
    unlink([path fileSystemRepresentation]);

    TTIOGenomicIndex *original = makeIndex6();
    NSError *err = nil;

    id<TTIOStorageProvider> w = [[TTIOProviderRegistry sharedRegistry]
        openURL:path
           mode:TTIOStorageOpenModeCreate
       provider:@"hdf5"
          error:&err];
    PASS(w != nil, "M82: HDF5 provider opens for index round-trip");
    id<TTIOStorageGroup> root = [w rootGroupWithError:&err];
    id<TTIOStorageGroup> idxGroup = [root createGroupNamed:@"genomic_index" error:&err];
    PASS([original writeToGroup:idxGroup error:&err], "M82: GenomicIndex.write");
    [w close];

    id<TTIOStorageProvider> r = [[TTIOProviderRegistry sharedRegistry]
        openURL:path
           mode:TTIOStorageOpenModeRead
       provider:@"hdf5"
          error:&err];
    id<TTIOStorageGroup> root2 = [r rootGroupWithError:&err];
    id<TTIOStorageGroup> idxGroup2 = [root2 openGroupNamed:@"genomic_index" error:&err];
    TTIOGenomicIndex *loaded = [TTIOGenomicIndex readFromGroup:idxGroup2 error:&err];
    PASS(loaded != nil, "M82: GenomicIndex.read");

    PASS(loaded.count == original.count, "M82: index count round-trips");
    BOOL allMatch = YES;
    for (NSUInteger i = 0; i < original.count; i++) {
        if ([loaded offsetAt:i] != [original offsetAt:i]) allMatch = NO;
        if ([loaded lengthAt:i] != [original lengthAt:i]) allMatch = NO;
        if ([loaded positionAt:i] != [original positionAt:i]) allMatch = NO;
        if ([loaded mappingQualityAt:i] != [original mappingQualityAt:i]) allMatch = NO;
        if ([loaded flagsAt:i] != [original flagsAt:i]) allMatch = NO;
        if (![[loaded chromosomeAt:i] isEqualToString:[original chromosomeAt:i]]) allMatch = NO;
    }
    PASS(allMatch, "M82: all 6 columns round-trip byte-exactly");

    [r close];
    unlink([path fileSystemRepresentation]);
}

// ── Synthetic genomic run helper (matches Python _make_written_run) ─

static TTIOWrittenGenomicRun *makeWrittenGenomicRun(NSUInteger nReads, BOOL paired)
{
    NSUInteger readLength = 150;
    NSArray<NSString *> *chromsPool = @[@"chr1", @"chr2", @"chrX"];
    NSMutableArray<NSString *> *chroms = [NSMutableArray array];
    NSMutableData *positionsData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    int64_t *positions = (int64_t *)positionsData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) {
        [chroms addObject:chromsPool[i % 3]];
        positions[i] = 10000 + (int64_t)((i / 3) * 100);
    }

    NSMutableData *flagsData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    uint32_t *flags = (uint32_t *)flagsData.mutableBytes;
    if (paired) {
        for (NSUInteger i = 0; i < nReads; i++) flags[i] = 0x1;
    }

    NSMutableData *mapqsData = [NSMutableData dataWithLength:nReads * sizeof(uint8_t)];
    memset(mapqsData.mutableBytes, 60, nReads);

    NSMutableData *sequencesData = [NSMutableData dataWithLength:nReads * readLength];
    uint8_t *seqBytes = (uint8_t *)sequencesData.mutableBytes;
    const char bases[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < nReads * readLength; i++) {
        seqBytes[i] = (uint8_t)bases[i % 4];
    }

    NSMutableData *qualitiesData = [NSMutableData dataWithLength:nReads * readLength];
    memset(qualitiesData.mutableBytes, 30, nReads * readLength);

    NSMutableData *offsetsData = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
    uint64_t *offsets = (uint64_t *)offsetsData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) offsets[i] = i * readLength;

    NSMutableData *lengthsData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
    uint32_t *lengths = (uint32_t *)lengthsData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) lengths[i] = (uint32_t)readLength;

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names  = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < nReads; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)readLength]];
        [names  addObject:[NSString stringWithFormat:@"read_%06lu", (unsigned long)i]];
        [mateChroms addObject:paired ? chroms[i] : @""];
    }

    NSMutableData *matePosData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    int64_t *matePos = (int64_t *)matePosData.mutableBytes;
    NSMutableData *tlensData = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
    int32_t *tlens = (int32_t *)tlensData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) {
        matePos[i] = paired ? positions[i] + 200 : -1;
        tlens[i]   = paired ? 200 : 0;
    }

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"NA12878"
                      positions:positionsData
               mappingQualities:mapqsData
                          flags:flagsData
                      sequences:sequencesData
                      qualities:qualitiesData
                        offsets:offsetsData
                        lengths:lengthsData
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePosData
                templateLengths:tlensData
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
}

// ── Acceptance #1 — 100-read round-trip via HDF5 ──────────────────

static void testBasicRoundTrip100Reads(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_m82rt_%d.tio", (int)getpid()];
    unlink([path fileSystemRepresentation]);

    TTIOWrittenGenomicRun *written = makeWrittenGenomicRun(100, NO);
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"t"
                                    isaInvestigationId:@"i"
                                                msRuns:@{}
                                            genomicRuns:@{@"genomic_0001": written}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "M82: writeMinimalToPath with genomicRuns succeeds");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "M82: readFromFilePath succeeds for genomic file");

    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M82: genomicRuns dict populated");
    PASS(gr.readCount == 100, "M82: readCount round-trips");
    PASS([gr.referenceUri isEqualToString:@"GRCh38.p14"],
         "M82: referenceUri round-trips");
    PASS(gr.acquisitionMode == TTIOAcquisitionModeGenomicWGS,
         "M82: acquisitionMode round-trips");

    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    PASS(r0 != nil, "M82: readAtIndex[0] succeeds");
    PASS([r0.readName isEqualToString:@"read_000000"],
         "M82: readName[0] = read_000000");
    PASS([r0.chromosome isEqualToString:@"chr1"],
         "M82: chromosome[0] = chr1");
    PASS(r0.position == 10000, "M82: position[0] = 10000");
    PASS([r0.cigar isEqualToString:@"150M"], "M82: cigar[0] = 150M");
    PASS(r0.sequence.length == 150, "M82: sequence[0] length = 150");
    PASS(r0.flags == 0, "M82: flags[0] = 0");
    PASS([r0.mateChromosome isEqualToString:@""],
         "M82: mateChromosome[0] sentinel");
    PASS(r0.matePosition == -1, "M82: matePosition[0] sentinel");

    TTIOAlignedRead *r99 = [gr readAtIndex:99 error:&err];
    PASS(r99 != nil, "M82: readAtIndex[99] succeeds");
    PASS([r99.readName isEqualToString:@"read_000099"],
         "M82: readName[99] = read_000099");

    unlink([path fileSystemRepresentation]);
}

// ── Acceptance #2 — region query ──────────────────────────────────

static void testRegionQuery(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_m82rq_%d.tio", (int)getpid()];
    unlink([path fileSystemRepresentation]);

    TTIOWrittenGenomicRun *written = makeWrittenGenomicRun(100, NO);
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                        title:@"t"
                          isaInvestigationId:@"i"
                                      msRuns:@{}
                                  genomicRuns:@{@"genomic_0001": written}
                              identifications:nil
                              quantifications:nil
                            provenanceRecords:nil
                                        error:&err];
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];

    NSArray *results = [gr readsInRegion:@"chr1" start:10000 end:10500];
    PASS(results.count > 0, "M82: region query returns reads");
    BOOL allChr1 = YES, allInRange = YES;
    for (TTIOAlignedRead *r in results) {
        if (![r.chromosome isEqualToString:@"chr1"]) allChr1 = NO;
        if (r.position < 10000 || r.position >= 10500) allInRange = NO;
    }
    PASS(allChr1, "M82: region query — all results on chr1");
    PASS(allInRange, "M82: region query — all results in [10000, 10500)");

    NSArray *empty = [gr readsInRegion:@"chrY" start:0 end:1000000];
    PASS(empty.count == 0, "M82: region query empty when no match");

    unlink([path fileSystemRepresentation]);
}

// ── Acceptance #3 — flag filter (unmapped + reverse) ──────────────

static void testFlagFilter(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_m82ff_%d.tio", (int)getpid()];
    unlink([path fileSystemRepresentation]);

    // Patch the synthetic written run so flags[7]=0x4, flags[3]=0x10, flags[9]=0x10
    TTIOWrittenGenomicRun *w0 = makeWrittenGenomicRun(100, NO);
    NSMutableData *flagsData = [w0.flagsData mutableCopy];
    uint32_t *flags = (uint32_t *)flagsData.mutableBytes;
    flags[7] |= 0x4;
    flags[3] |= 0x10;
    flags[9] |= 0x10;

    TTIOWrittenGenomicRun *patched = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:w0.acquisitionMode
                   referenceUri:w0.referenceUri
                       platform:w0.platform
                     sampleName:w0.sampleName
                      positions:w0.positionsData
               mappingQualities:w0.mappingQualitiesData
                          flags:flagsData
                      sequences:w0.sequencesData
                      qualities:w0.qualitiesData
                        offsets:w0.offsetsData
                        lengths:w0.lengthsData
                         cigars:w0.cigars
                      readNames:w0.readNames
                mateChromosomes:w0.mateChromosomes
                  matePositions:w0.matePositionsData
                templateLengths:w0.templateLengthsData
                    chromosomes:w0.chromosomes
              signalCompression:w0.signalCompression];

    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                        title:@"t"
                          isaInvestigationId:@"i"
                                      msRuns:@{}
                                  genomicRuns:@{@"genomic_0001": patched}
                              identifications:nil
                              quantifications:nil
                            provenanceRecords:nil
                                        error:&err];
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];

    NSIndexSet *unmapped = [gr.index indicesForUnmapped];
    PASS([unmapped containsIndex:7] && unmapped.count == 1,
         "M82: indicesForUnmapped returns [7]");
    NSIndexSet *reverse = [gr.index indicesForFlag:0x10];
    PASS([reverse containsIndex:3] && [reverse containsIndex:9] && reverse.count == 2,
         "M82: indicesForFlag(0x10) returns [3, 9]");

    unlink([path fileSystemRepresentation]);
}

// ── Acceptance #4 — paired-end mate info ──────────────────────────

static void testPairedEndMateInfo(void)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/ttio_m82pe_%d.tio", (int)getpid()];
    unlink([path fileSystemRepresentation]);

    TTIOWrittenGenomicRun *written = makeWrittenGenomicRun(100, YES);  // paired
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:path
                                        title:@"t"
                          isaInvestigationId:@"i"
                                      msRuns:@{}
                                  genomicRuns:@{@"genomic_0001": written}
                              identifications:nil
                              quantifications:nil
                            provenanceRecords:nil
                                        error:&err];
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:&err];
    TTIOGenomicRun *gr = ds.genomicRuns[@"genomic_0001"];
    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];

    PASS([r0 isPaired], "M82: read[0] is paired");
    PASS([r0.mateChromosome isEqualToString:written.mateChromosomes[0]],
         "M82: mateChromosome round-trips");
    PASS(r0.matePosition == 10200, "M82: matePosition round-trips");
    PASS(r0.templateLength == 200, "M82: templateLength round-trips");

    unlink([path fileSystemRepresentation]);
}

void testM82GenomicRun(void)
{
    testAlignedReadBasicFields();
    testAlignedReadFlagAccessors();
    testAlignedReadEquality();
    testGenomicIndexInMemory();
    testWrittenGenomicRunConstruction();
    testGenomicIndexDiskRoundTrip();
    testBasicRoundTrip100Reads();
    testRegionQuery();
    testFlagFilter();
    testPairedEndMateInfo();
    // Subsequent tasks append more test functions called from here.
}
