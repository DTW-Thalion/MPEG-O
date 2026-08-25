// TestM98AssemblyGraph.m — M98: GFA parse/emit byte-exactness, the
// /study/assembly_graphs storage round-trip, the opt_assembly_graph
// feature flag, and the sequences-channel codec selection.
//
// Mirrors:
//   python/tests/test_m98_assembly_graph.py
//   java/src/test/java/.../M98AssemblyGraphTest.java
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSpectralDataset+AssemblyWrite.h"
#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"
#import "Assembly/TTIOAssemblyGraph.h"
#import "Import/TTIOGfaReader.h"
#import "Export/TTIOGfaWriter.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Protection/TTIOPerAUFile.h"
#import "Protection/TTIOSignatureManager.h"
#include <unistd.h>

/** The synthetic full-surface GFA the Phase 0 proof used: every GFA
 *  1.x line type, sequence-less S records, tag stacks, a comment, a
 *  hifiasm-style A extension, interleaved ordering. Kept in lockstep
 *  with the Python and Java fixtures. */
static NSString *m98SynthGfa(void)
{
    NSArray *lines = @[
        @"H\tVN:Z:1.0",
        @"# produced by the m98 synthetic generator",
        @"S\tutg000001l\tACGTACGTACGTNNNACGT\tLN:i:19\trd:i:12",
        @"A\tutg000001l\t0\t+\tread_00001\t0\t19\tid:i:0\tHG:A:a",
        @"S\tutg000002l\t*\tLN:i:5000",
        @"L\tutg000001l\t+\tutg000002l\t-\t15M\tL1:i:4985",
        @"S\tutg000003c\tGGGGCCCCTTTTAAAA\tLN:i:16",
        @"L\tutg000002l\t-\tutg000003c\t+\t*",
        @"C\tutg000001l\t+\tutg000003c\t-\t2\t14M\tNM:i:0",
        @"P\tscaffold_1\tutg000001l+,utg000002l-,utg000003c+\t15M,*\tXX:Z:demo",
        @"L\tutg000003c\t+\tutg000001l\t+\t0M",
    ];
    return [[lines componentsJoinedByString:@"\n"]
        stringByAppendingString:@"\n"];
}

static NSString *m98TmpPath(NSString *tag)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m98_%d_%@.tio",
            (int)getpid(), tag];
}

static void m98Rm(NSString *p)
{
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

// ── parse + emit byte-exactness ───────────────────────────────────

static void m98ParseEmit(void)
{
    NSData *src = [m98SynthGfa() dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromData:src
                                                         error:&err];
    PASS(g != nil, "M98 gfa: parse succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    if (!g) return;
    PASS(g.segments.count == 3 && g.links.count == 3
             && g.paths.count == 1 && g.extras.count == 4,
         "M98 gfa: tables S=3 L=3 P=1 X=4 (got %lu/%lu/%lu/%lu)",
         (unsigned long)g.segments.count, (unsigned long)g.links.count,
         (unsigned long)g.paths.count, (unsigned long)g.extras.count);
    PASS([g.gfaVersion isEqualToString:@"1.0"],
         "M98 gfa: version from the H line");
    PASS(g.segments[1].sequence == nil,
         "M98 gfa: * sequence parses as nil");
    PASS([[TTIOGfaWriter dataForGraph:g] isEqualToData:src],
         "M98 gfa: emit(parse(x)) == x");

    // The no-final-newline variant round-trips too.
    NSData *noNl = [src subdataWithRange:NSMakeRange(0, src.length - 1)];
    TTIOWrittenAssemblyGraph *g2 = [TTIOGfaReader graphFromData:noNl
                                                          error:&err];
    PASS(g2 != nil && !g2.finalNewline
             && [[TTIOGfaWriter dataForGraph:g2] isEqualToData:noNl],
         "M98 gfa: no-final-newline round-trip");
}

// ── storage round-trip (memory provider) ──────────────────────────

static void m98StorageRoundTrip(void)
{
    NSData *src = [m98SynthGfa() dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromData:src
                                                         error:&err];
    if (!g) { PASS(NO, "M98 storage: parse failed"); return; }

    NSString *url = [NSString stringWithFormat:@"memory://m98-%d",
                     (int)getpid()];
    [TTIOMemoryProvider discardStore:url];
    id<TTIOStorageProvider> mem = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory"
          error:&err];
    id<TTIOStorageGroup> study =
        [[mem rootGroupWithError:&err] createGroupNamed:@"study"
                                                  error:&err];
    PASS([TTIOSpectralDataset writeAssemblyGraph:g
                                           named:@"g0"
                                    toStudyGroup:study
                                           error:&err],
         "M98 storage: write to memory provider (%s)",
         [[err localizedDescription] UTF8String] ?: "");

    // Duplicate names are rejected.
    PASS(![TTIOSpectralDataset writeAssemblyGraph:g
                                            named:@"g0"
                                     toStudyGroup:study
                                            error:&err],
         "M98 storage: duplicate name rejected");

    id<TTIOStorageGroup> ag = [study openGroupNamed:@"assembly_graphs"
                                              error:&err];
    id<TTIOStorageGroup> gg = [ag openGroupNamed:@"g0" error:&err];
    TTIOAssemblyGraph *opened = [TTIOAssemblyGraph openFromGroup:gg
                                                            name:@"g0"
                                                           error:&err];
    PASS(opened != nil, "M98 storage: open succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    if (!opened) return;
    NSData *emitted = [opened gfaDataWithError:&err];
    PASS([emitted isEqualToData:src],
         "M98 storage: memory-provider re-emission byte-exact");
}

// ── writeMinimal + reopen + feature flag ──────────────────────────

static void m98WriteMinimal(void)
{
    NSData *src = [m98SynthGfa() dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromData:src
                                                         error:&err];
    if (!g) { PASS(NO, "M98 writeMinimal: parse failed"); return; }

    NSString *path = m98TmpPath(@"wm");
    m98Rm(path);
    PASS([TTIOSpectralDataset writeMinimalToPath:path
                                           title:@"M98"
                             isaInvestigationId:@"ISA-M98"
                                         msRuns:@{}
                                     genomicRuns:nil
                                  assemblyGraphs:@{@"graph_0001": g}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err],
         "M98 writeMinimal: write succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");

    // Feature flag present on the root.
    TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    PASS(f != nil, "M98 writeMinimal: reopen HDF5");
    if (f) {
        PASS([TTIOFeatureFlags root:[f rootGroup]
                    supportsFeature:@"opt_assembly_graph"],
             "M98 writeMinimal: opt_assembly_graph flag set");
        [f close];
    }

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "M98 writeMinimal: dataset reopens (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    if (ds) {
        TTIOAssemblyGraph *opened = ds.assemblyGraphs[@"graph_0001"];
        PASS(opened != nil, "M98 writeMinimal: accessor finds the graph");
        if (opened) {
            PASS([opened.gfaVersion isEqualToString:@"1.0"]
                     && opened.finalNewline,
                 "M98 writeMinimal: attributes round-trip");
            NSData *emitted = [opened gfaDataWithError:&err];
            PASS([emitted isEqualToData:src],
                 "M98 writeMinimal: HDF5 re-emission byte-exact (%s)",
                 [[err localizedDescription] UTF8String] ?: "");
        }
        [ds closeFile];
    }

    // A file without graphs has neither the flag nor the subtree.
    NSString *plain = m98TmpPath(@"plain");
    m98Rm(plain);
    PASS([TTIOSpectralDataset writeMinimalToPath:plain
                                           title:@"M98"
                             isaInvestigationId:@"ISA-M98"
                                         msRuns:@{}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err],
         "M98 writeMinimal: graph-less write succeeds");
    TTIOHDF5File *pf = [TTIOHDF5File openReadOnlyAtPath:plain error:&err];
    if (pf) {
        PASS(![TTIOFeatureFlags root:[pf rootGroup]
                     supportsFeature:@"opt_assembly_graph"],
             "M98 writeMinimal: flag absent without graphs");
        [pf close];
    }
    TTIOSpectralDataset *pds =
        [TTIOSpectralDataset readFromFilePath:plain error:&err];
    PASS(pds != nil && pds.assemblyGraphs.count == 0,
         "M98 writeMinimal: graph-less file reads back empty dict");
    if (pds) [pds closeFile];
    m98Rm(path);
    m98Rm(plain);
}

// ── sequences-channel codec selection ─────────────────────────────

static void m98SequencesCodec(void)
{
    // ACGTN alphabet: the stored channel is BASE_PACK-encoded, so the
    // dataset must be SMALLER than the raw bases and carry
    // @compression. Mechanism check: parse, write, inspect the
    // dataset, reopen, byte-compare.
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableString *bases = [NSMutableString string];
    for (int i = 0; i < 2048; i++) {
        [bases appendString:@"ACGT"];
    }
    [lines addObject:[NSString stringWithFormat:@"S\tu1\t%@", bases]];
    [lines addObject:@"L\tu1\t+\tu1\t-\t0M"];
    NSString *text = [[lines componentsJoinedByString:@"\n"]
        stringByAppendingString:@"\n"];
    NSData *src = [text dataUsingEncoding:NSUTF8StringEncoding];

    NSError *err = nil;
    TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromData:src
                                                         error:&err];
    NSString *url = [NSString stringWithFormat:@"memory://m98c-%d",
                     (int)getpid()];
    [TTIOMemoryProvider discardStore:url];
    id<TTIOStorageProvider> mem = [[TTIOProviderRegistry sharedRegistry]
        openURL:url mode:TTIOStorageOpenModeCreate provider:@"memory"
          error:&err];
    id<TTIOStorageGroup> study =
        [[mem rootGroupWithError:&err] createGroupNamed:@"study"
                                                  error:&err];
    PASS([TTIOSpectralDataset writeAssemblyGraph:g
                                           named:@"g0"
                                    toStudyGroup:study
                                           error:&err],
         "M98 codec: write succeeds");

    id<TTIOStorageGroup> segG = [[[study openGroupNamed:@"assembly_graphs"
                                                  error:NULL]
        openGroupNamed:@"g0" error:NULL]
        openGroupNamed:@"segments" error:NULL];
    id<TTIOStorageDataset> seqDs = [segG openDatasetNamed:@"sequences"
                                                    error:NULL];
    NSData *stored = (NSData *)[seqDs readAll:NULL];
    id codecAttr = [seqDs attributeValueForName:@"compression" error:NULL];
    PASS([codecAttr isKindOfClass:[NSNumber class]]
             && [codecAttr unsignedIntegerValue] == 6,
         "M98 codec: ACGT channel stored as BASE_PACK (@compression=6)");
    PASS(stored.length > 0 && stored.length < 8192,
         "M98 codec: 8,192 bases pack below 8,192 stored bytes (got %lu)",
         (unsigned long)stored.length);

    TTIOAssemblyGraph *opened = [TTIOAssemblyGraph
        openFromGroup:[[study openGroupNamed:@"assembly_graphs" error:NULL]
                          openGroupNamed:@"g0" error:NULL]
                 name:@"g0"
                error:&err];
    NSData *emitted = [opened gfaDataWithError:&err];
    if (![emitted isEqualToData:src]) {
        const uint8_t *a = src.bytes, *b = emitted.bytes;
        NSUInteger n = MIN(src.length, emitted.length), diff = n;
        for (NSUInteger i = 0; i < n; i++) {
            if (a[i] != b[i]) { diff = i; break; }
        }
        fprintf(stderr,
                "M98 codec diag: src=%lu emitted=%lu firstDiff=%lu "
                "src[d]=%c emitted[d]=%c err=%s\n",
                (unsigned long)src.length,
                (unsigned long)(emitted ? emitted.length : 0),
                (unsigned long)diff,
                diff < src.length ? a[diff] : '?',
                (emitted && diff < emitted.length) ? b[diff] : '?',
                [[err localizedDescription] UTF8String] ?: "none");
    }
    PASS([emitted isEqualToData:src],
         "M98 codec: BASE_PACK channel round-trips byte-exact");
}

// ── per-AU encryption + signatures (stage E) ──────────────────────

static NSData *m98Key(uint8_t seed)
{
    NSMutableData *k = [NSMutableData dataWithLength:32];
    uint8_t *b = k.mutableBytes;
    for (int i = 0; i < 32; i++) b[i] = (uint8_t)(seed + i);
    return k;
}

static NSString *m98WriteGraphFile(NSString *tag, NSData *src)
{
    NSError *err = nil;
    TTIOWrittenAssemblyGraph *g = [TTIOGfaReader graphFromData:src
                                                         error:&err];
    NSString *path = m98TmpPath(tag);
    m98Rm(path);
    if (![TTIOSpectralDataset writeMinimalToPath:path
                                           title:@"M98"
                             isaInvestigationId:@"ISA-M98"
                                         msRuns:@{}
                                     genomicRuns:nil
                                  assemblyGraphs:@{@"graph_0001": g}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err]) {
        return nil;
    }
    return path;
}

static void m98PerAUEncryption(void)
{
    // Workplan acceptance: a per-AU-encrypted graph decrypts in
    // place. Mechanism check: after encrypt the plaintext sequences
    // channel is GONE and the segments compound exists — a no-op
    // walker would still pass a bare round-trip.
    NSData *src = [m98SynthGfa() dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = m98WriteGraphFile(@"perau", src);
    PASS(path != nil, "M98 perau: fixture file written");
    if (!path) return;

    NSError *err = nil;
    PASS([TTIOPerAUFile encryptFilePath:path
                                    key:m98Key(0x42)
                         encryptHeaders:NO
                           providerName:nil
                                  error:&err],
         "M98 perau: encryptFilePath succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");

    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
        TTIOHDF5Group *seg =
            [[[[f.rootGroup openGroupNamed:@"study" error:NULL]
                openGroupNamed:@"assembly_graphs" error:NULL]
                    openGroupNamed:@"graph_0001" error:NULL]
                        openGroupNamed:@"segments" error:NULL];
        PASS(![seg hasChildNamed:@"sequences"]
                 && [seg hasChildNamed:@"sequences_segments"],
             "M98 perau: plaintext channel replaced by segments");
        [f close];
    }

    // The wrong key must not decrypt.
    NSError *wrongErr = nil;
    PASS(![TTIOPerAUFile decryptFilePathInPlace:path
                                            key:m98Key(0x99)
                                   providerName:nil
                                          error:&wrongErr],
         "M98 perau: wrong key rejected");

    PASS([TTIOPerAUFile decryptFilePathInPlace:path
                                           key:m98Key(0x42)
                                  providerName:nil
                                         error:&err],
         "M98 perau: decryptFilePathInPlace succeeds (%s)",
         [[err localizedDescription] UTF8String] ?: "");

    @autoreleasepool {
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:NULL];
        TTIOHDF5Group *seg =
            [[[[f.rootGroup openGroupNamed:@"study" error:NULL]
                openGroupNamed:@"assembly_graphs" error:NULL]
                    openGroupNamed:@"graph_0001" error:NULL]
                        openGroupNamed:@"segments" error:NULL];
        PASS([seg hasChildNamed:@"sequences"]
                 && ![seg hasChildNamed:@"sequences_segments"]
                 && ![seg hasAttributeNamed:@"sequences_algorithm"],
             "M98 perau: plaintext channel restored, segments removed");
        NSArray *features =
            [TTIOFeatureFlags featuresForRoot:f.rootGroup] ?: @[];
        PASS(![features containsObject:@"opt_per_au_encryption"],
             "M98 perau: opt_per_au_encryption stripped");
        [f close];
    }

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(ds != nil, "M98 perau: dataset reopens after decrypt");
    if (ds) {
        NSData *emitted =
            [ds.assemblyGraphs[@"graph_0001"] gfaDataWithError:&err];
        PASS([emitted isEqualToData:src],
             "M98 perau: decrypted graph re-emits byte-exact");
        [ds closeFile];
    }
    m98Rm(path);
}

static void m98Signatures(void)
{
    // v2: signatures cover segments/sequences the way they cover
    // genomic-run channels.
    NSData *src = [m98SynthGfa() dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = m98WriteGraphFile(@"sig", src);
    PASS(path != nil, "M98 sig: fixture file written");
    if (!path) return;

    NSError *err = nil;
    NSData *key = m98Key(0x10);
    NSDictionary *sigs = [TTIOSignatureManager
        signAssemblyGraph:@"graph_0001"
                   inFile:path
                  withKey:key
                    error:&err];
    PASS(sigs != nil && sigs[@"segments/sequences"] != nil,
         "M98 sig: segments/sequences signed (%s)",
         [[err localizedDescription] UTF8String] ?: "");
    PASS([sigs[@"segments/sequences"] hasPrefix:@"v2:"],
         "M98 sig: signature carries the v2: prefix");
    PASS([TTIOSignatureManager verifyAssemblyGraph:@"graph_0001"
                                            inFile:path
                                           withKey:key
                                             error:&err],
         "M98 sig: verification passes with the signing key");
    PASS(![TTIOSignatureManager verifyAssemblyGraph:@"graph_0001"
                                             inFile:path
                                            withKey:m98Key(0x77)
                                              error:NULL],
         "M98 sig: verification fails with the wrong key");
    m98Rm(path);
}

void testM98AssemblyGraph(void);
void testM98AssemblyGraph(void)
{
    m98ParseEmit();
    m98StorageRoundTrip();
    m98WriteMinimal();
    m98SequencesCodec();
    m98PerAUEncryption();
    m98Signatures();
}
