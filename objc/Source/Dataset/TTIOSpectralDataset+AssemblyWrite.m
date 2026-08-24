/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Dataset/TTIOSpectralDataset+AssemblyWrite.h"
#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"
#import "Codecs/Registry/TTIOCodecRegistry.h"
#import "Providers/TTIOCompoundField.h"
#import "ValueClasses/TTIOEnums.h"

static NSError *awError(NSInteger code, NSString *msg)
{
    return [NSError errorWithDomain:@"TTIOSpectralDatasetErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

/** Codec for a concatenated segment-sequences buffer: BASE_PACK when
 *  every byte is ACGTN (upper or lower case), RANS_ORDER1 otherwise,
 *  NONE when empty. The same rule holds in the Python and Java
 *  writers so the 3 SDKs emit identical channels. */
static TTIOCompression awSequencesCodec(NSData *data)
{
    if (data.length == 0) return TTIOCompressionNone;
    static uint8_t allowed[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *ok = "ACGTNacgtn";
        for (const char *p = ok; *p; p++) allowed[(uint8_t)*p] = 1;
    });
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        if (!allowed[b[i]]) return TTIOCompressionRansOrder1;
    }
    return TTIOCompressionBasePack;
}

static BOOL awWriteBytes(id<TTIOStorageGroup> group, NSString *name,
                         NSData *data, NSError **error)
{
    TTIOCompression codec = awSequencesCodec(data);
    NSData *stored = data;
    if (codec != TTIOCompressionNone) {
        id<TTIOCodec> c = [TTIOCodecRegistry codecForId:codec];
        TTIOEncodedChannel *enc =
            [c encode:[[TTIODecodedBytes alloc] initWithData:data]
              context:[TTIOCodecContext emptyContext]
                error:error];
        if (![enc isKindOfClass:[TTIOEncodedDatasetBytes class]]) {
            if (error && !*error) {
                *error = awError(2201,
                    @"assembly sequences channel encode failed");
            }
            return NO;
        }
        stored = ((TTIOEncodedDatasetBytes *)enc).bytes;
    }
    id<TTIOStorageDataset> ds =
        [group createDatasetNamed:name
                        precision:TTIOPrecisionUInt8
                           length:stored.length
                        chunkSize:65536
                      compression:TTIOCompressionNone
                 compressionLevel:0
                       extendable:NO
                            error:error];
    if (!ds) return NO;
    if (stored.length > 0 && ![ds writeAll:stored error:error]) return NO;
    if (codec != TTIOCompressionNone) {
        if (![ds setAttributeValue:@((uint8_t)codec)
                           forName:@"compression"
                             error:error]) return NO;
    }
    return YES;
}

static BOOL awWriteCompound(id<TTIOStorageGroup> group, NSString *name,
                            NSArray<TTIOCompoundField *> *fields,
                            NSArray<NSDictionary *> *rows,
                            NSError **error)
{
    // Empty tables are ABSENT (format-spec 11a): 0-row non-extendable
    // compounds do not round-trip on every provider, and readers in
    // all 3 SDKs treat a missing table as empty.
    if (rows.count == 0) return YES;
    id<TTIOStorageDataset> ds =
        [group createCompoundDatasetNamed:name
                                   fields:fields
                                    count:rows.count
                                    error:error];
    if (!ds) return NO;
    return [ds writeAll:rows error:error];
}

@implementation TTIOSpectralDataset (AssemblyWrite)

+ (BOOL)writeAssemblyGraph:(TTIOWrittenAssemblyGraph *)graph
                     named:(NSString *)name
              toStudyGroup:(id<TTIOStorageGroup>)study
                     error:(NSError **)error
{
    id<TTIOStorageGroup> ag;
    if ([study hasChildNamed:@"assembly_graphs"]) {
        ag = [study openGroupNamed:@"assembly_graphs" error:error];
    } else {
        ag = [study createGroupNamed:@"assembly_graphs" error:error];
        if (ag && ![ag setAttributeValue:@"" forName:@"_graph_names"
                                   error:error]) return NO;
    }
    if (!ag) return NO;

    if ([ag hasChildNamed:name]) {
        if (error) *error = awError(2200,
            [NSString stringWithFormat:
                @"assembly graph '%@' already exists", name]);
        return NO;
    }
    id namesObj = [ag attributeValueForName:@"_graph_names" error:NULL];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([namesObj isKindOfClass:[NSString class]]
        && [(NSString *)namesObj length] > 0) {
        [names addObjectsFromArray:
            [(NSString *)namesObj componentsSeparatedByString:@","]];
    }
    [names addObject:name];
    if (![ag setAttributeValue:[names componentsJoinedByString:@","]
                       forName:@"_graph_names" error:error]) return NO;

    id<TTIOStorageGroup> g = [ag createGroupNamed:name error:error];
    if (!g) return NO;
    if (![g setAttributeValue:(graph.gfaVersion ?: @"1.0")
                      forName:@"gfa_version" error:error]) return NO;
    if (![g setAttributeValue:(graph.producer ?: @"")
                      forName:@"producer" error:error]) return NO;
    if (![g setAttributeValue:@((int64_t)(graph.finalNewline ? 1 : 0))
                      forName:@"final_newline" error:error]) return NO;

    // segments/: records compound + concatenated sequences channel.
    id<TTIOStorageGroup> segG = [g createGroupNamed:@"segments"
                                              error:error];
    if (!segG) return NO;
    NSMutableData *seqs = [NSMutableData data];
    NSMutableArray<NSDictionary *> *segRows =
        [NSMutableArray arrayWithCapacity:graph.segments.count];
    for (TTIOGraphSegment *s in graph.segments) {
        uint64_t off = seqs.length;
        uint64_t len = s.sequence.length;
        if (s.sequence) [seqs appendData:s.sequence];
        [segRows addObject:@{
            @"name": s.name,
            @"length": @(len),
            @"seq_offset": @(off),
            @"seq_missing": @(s.sequence == nil ? 1u : 0u),
            @"tags": s.tags,
        }];
    }
    NSArray<TTIOCompoundField *> *segFields = @[
        [TTIOCompoundField fieldWithName:@"name"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"length"
                                    kind:TTIOCompoundFieldKindUInt64],
        [TTIOCompoundField fieldWithName:@"seq_offset"
                                    kind:TTIOCompoundFieldKindUInt64],
        [TTIOCompoundField fieldWithName:@"seq_missing"
                                    kind:TTIOCompoundFieldKindUInt32],
        [TTIOCompoundField fieldWithName:@"tags"
                                    kind:TTIOCompoundFieldKindVLString],
    ];
    if (!awWriteCompound(segG, @"records", segFields, segRows, error))
        return NO;
    if (seqs.length > 0
        && !awWriteBytes(segG, @"sequences", seqs, error)) return NO;

    NSArray<TTIOCompoundField *> *linkFields = @[
        [TTIOCompoundField fieldWithName:@"from"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"from_orient"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"to"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"to_orient"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"overlap"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"tags"
                                    kind:TTIOCompoundFieldKindVLString],
    ];
    NSMutableArray<NSDictionary *> *linkRows =
        [NSMutableArray arrayWithCapacity:graph.links.count];
    for (TTIOGraphLink *l in graph.links) {
        [linkRows addObject:@{
            @"from": l.fromSegment, @"from_orient": l.fromOrient,
            @"to": l.toSegment, @"to_orient": l.toOrient,
            @"overlap": l.overlap, @"tags": l.tags,
        }];
    }
    if (!awWriteCompound(g, @"links", linkFields, linkRows, error))
        return NO;

    NSArray<TTIOCompoundField *> *pathFields = @[
        [TTIOCompoundField fieldWithName:@"name"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"segment_list"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"overlaps"
                                    kind:TTIOCompoundFieldKindVLString],
        [TTIOCompoundField fieldWithName:@"tags"
                                    kind:TTIOCompoundFieldKindVLString],
    ];
    NSMutableArray<NSDictionary *> *pathRows =
        [NSMutableArray arrayWithCapacity:graph.paths.count];
    for (TTIOGraphPath *p in graph.paths) {
        [pathRows addObject:@{
            @"name": p.name, @"segment_list": p.segmentList,
            @"overlaps": p.overlaps, @"tags": p.tags,
        }];
    }
    if (!awWriteCompound(g, @"paths", pathFields, pathRows, error))
        return NO;

    NSArray<TTIOCompoundField *> *extraFields = @[
        [TTIOCompoundField fieldWithName:@"line"
                                    kind:TTIOCompoundFieldKindVLString],
    ];
    NSMutableArray<NSDictionary *> *extraRows =
        [NSMutableArray arrayWithCapacity:graph.extras.count];
    for (NSString *line in graph.extras) {
        [extraRows addObject:@{ @"line": line }];
    }
    if (!awWriteCompound(g, @"extras", extraFields, extraRows, error))
        return NO;

    NSArray<TTIOCompoundField *> *idxFields = @[
        [TTIOCompoundField fieldWithName:@"line_type"
                                    kind:TTIOCompoundFieldKindUInt32],
        [TTIOCompoundField fieldWithName:@"row"
                                    kind:TTIOCompoundFieldKindUInt64],
    ];
    const uint32_t *types = (const uint32_t *)graph.lineTypes.bytes;
    const uint64_t *rows = (const uint64_t *)graph.lineRows.bytes;
    NSUInteger n = graph.lineCount;
    NSMutableArray<NSDictionary *> *idxRows =
        [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        [idxRows addObject:@{
            @"line_type": @(types[i]),
            @"row": @(rows[i]),
        }];
    }
    return awWriteCompound(g, @"line_index", idxFields, idxRows, error);
}

@end
