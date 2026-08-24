/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Assembly/TTIOAssemblyGraph.h"
#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"
#import "Export/TTIOGfaWriter.h"
#import "Codecs/Registry/TTIOCodecRegistry.h"
#import "ValueClasses/TTIOEnums.h"

static NSString * const TTIOAssemblyGraphErrorDomain = @"TTIOAssemblyGraphError";

static NSError *agError(NSInteger code, NSString *msg)
{
    return [NSError errorWithDomain:TTIOAssemblyGraphErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *agStr(id v)
{
    return [v isKindOfClass:[NSString class]] ? v : @"";
}

@implementation TTIOAssemblyGraph {
    id<TTIOStorageGroup> _group;
    TTIOWrittenAssemblyGraph *_cached;
}

+ (instancetype)openFromGroup:(id<TTIOStorageGroup>)group
                         name:(NSString *)name
                        error:(NSError **)error
{
    // Empty tables are absent (format-spec 11a); the attributes are
    // the structural marker of an M98 graph group.
    if (![group hasAttributeNamed:@"final_newline"]) {
        if (error) *error = agError(1,
            [NSString stringWithFormat:
                @"assembly graph '%@' lacks the final_newline attribute",
                name]);
        return nil;
    }
    TTIOAssemblyGraph *g = [[TTIOAssemblyGraph alloc] init];
    g->_group = group;
    g->_name = [name copy];
    g->_gfaVersion = agStr([group attributeValueForName:@"gfa_version"
                                                  error:NULL]);
    g->_producer = agStr([group attributeValueForName:@"producer"
                                                error:NULL]);
    id nl = [group attributeValueForName:@"final_newline" error:NULL];
    g->_finalNewline = [nl isKindOfClass:[NSNumber class]]
        ? [nl boolValue] : YES;
    return g;
}

/** Decode a byte channel written with an optional @compression codec
 *  attribute (0 or absent = raw bytes). */
static NSData *agDecodeBytes(id<TTIOStorageDataset> ds, NSError **error)
{
    NSData *raw = (NSData *)[ds readAll:error];
    if (!raw) return nil;
    uint8_t codec = 0;
    if ([ds hasAttributeNamed:@"compression"]) {
        id v = [ds attributeValueForName:@"compression" error:NULL];
        if ([v isKindOfClass:[NSNumber class]]) {
            codec = (uint8_t)[v unsignedIntegerValue];
        }
    }
    if (codec == 0) return raw;
    id<TTIOCodec> c = [TTIOCodecRegistry codecForId:(TTIOCompression)codec];
    if (!c) {
        if (error) *error = agError(2,
            [NSString stringWithFormat:
                @"sequences channel names unregistered codec %u", codec]);
        return nil;
    }
    TTIODecodedChannel *dec =
        [c decode:[[TTIOBytesPayload alloc] initWithBytes:raw]
          context:[TTIOCodecContext emptyContext]
            error:error];
    if (![dec isKindOfClass:[TTIODecodedBytes class]]) return nil;
    return ((TTIODecodedBytes *)dec).data;
}

/** readRows on a table that is absent-when-empty. Never nil: absent
 *  or empty tables read as @[]. */
static NSArray<NSDictionary *> *agRowsOrEmpty(id<TTIOStorageGroup> group,
                                              NSString *name,
                                              NSError **error,
                                              BOOL *failed)
{
    if (![group hasChildNamed:name]) return @[];
    id<TTIOStorageDataset> ds = [group openDatasetNamed:name error:error];
    if (!ds) { *failed = YES; return @[]; }
    NSArray<NSDictionary *> *rows = [ds readRows:error];
    if (!rows) { *failed = YES; return @[]; }
    return rows;
}

- (TTIOWrittenAssemblyGraph *)writtenGraphWithError:(NSError **)error
{
    if (_cached) return _cached;
    BOOL failed = NO;

    NSArray<NSDictionary *> *segRows = @[];
    NSData *seqBytes = [NSData data];
    if ([_group hasChildNamed:@"segments"]) {
        id<TTIOStorageGroup> segG = [_group openGroupNamed:@"segments"
                                                     error:error];
        if (!segG) return nil;
        segRows = agRowsOrEmpty(segG, @"records", error, &failed);
        if (failed) return nil;
        if ([segG hasChildNamed:@"sequences"]) {
            id<TTIOStorageDataset> seqDs =
                [segG openDatasetNamed:@"sequences" error:error];
            if (!seqDs) return nil;
            seqBytes = agDecodeBytes(seqDs, error);
            if (!seqBytes) return nil;
        }
    }

    NSMutableArray<TTIOGraphSegment *> *segments =
        [NSMutableArray arrayWithCapacity:segRows.count];
    for (NSDictionary *row in segRows) {
        BOOL missing = [row[@"seq_missing"] unsignedIntValue] != 0;
        NSData *seq = nil;
        if (!missing) {
            NSUInteger off = [row[@"seq_offset"] unsignedLongLongValue];
            NSUInteger len = [row[@"length"] unsignedLongLongValue];
            if (off + len > seqBytes.length) {
                if (error) *error = agError(3,
                    @"segment record points outside the sequences channel");
                return nil;
            }
            seq = [seqBytes subdataWithRange:NSMakeRange(off, len)];
        }
        [segments addObject:[[TTIOGraphSegment alloc]
            initWithName:agStr(row[@"name"])
                sequence:seq
                    tags:agStr(row[@"tags"])]];
    }

    NSArray<NSDictionary *> *linkRows =
        agRowsOrEmpty(_group, @"links", error, &failed);
    if (failed) return nil;
    NSMutableArray<TTIOGraphLink *> *links =
        [NSMutableArray arrayWithCapacity:linkRows.count];
    for (NSDictionary *row in linkRows) {
        [links addObject:[[TTIOGraphLink alloc]
            initWithFromSegment:agStr(row[@"from"])
                     fromOrient:agStr(row[@"from_orient"])
                      toSegment:agStr(row[@"to"])
                       toOrient:agStr(row[@"to_orient"])
                        overlap:agStr(row[@"overlap"])
                           tags:agStr(row[@"tags"])]];
    }

    NSArray<NSDictionary *> *pathRows =
        agRowsOrEmpty(_group, @"paths", error, &failed);
    if (failed) return nil;
    NSMutableArray<TTIOGraphPath *> *paths =
        [NSMutableArray arrayWithCapacity:pathRows.count];
    for (NSDictionary *row in pathRows) {
        [paths addObject:[[TTIOGraphPath alloc]
            initWithName:agStr(row[@"name"])
             segmentList:agStr(row[@"segment_list"])
                overlaps:agStr(row[@"overlaps"])
                    tags:agStr(row[@"tags"])]];
    }

    NSArray<NSDictionary *> *exRows =
        agRowsOrEmpty(_group, @"extras", error, &failed);
    if (failed) return nil;
    NSMutableArray<NSString *> *extras =
        [NSMutableArray arrayWithCapacity:exRows.count];
    for (NSDictionary *row in exRows) {
        [extras addObject:agStr(row[@"line"])];
    }

    NSArray<NSDictionary *> *idxRows =
        agRowsOrEmpty(_group, @"line_index", error, &failed);
    if (failed) return nil;
    NSMutableData *lineTypes =
        [NSMutableData dataWithCapacity:idxRows.count * 4];
    NSMutableData *lineRows =
        [NSMutableData dataWithCapacity:idxRows.count * 8];
    for (NSDictionary *row in idxRows) {
        uint32_t t = [row[@"line_type"] unsignedIntValue];
        uint64_t r = [row[@"row"] unsignedLongLongValue];
        [lineTypes appendBytes:&t length:sizeof(t)];
        [lineRows appendBytes:&r length:sizeof(r)];
    }

    @try {
        _cached = [[TTIOWrittenAssemblyGraph alloc]
            initWithGfaVersion:_gfaVersion
                      producer:_producer
                  finalNewline:_finalNewline
                      segments:segments
                         links:links
                         paths:paths
                        extras:extras
                     lineTypes:lineTypes
                      lineRows:lineRows];
    } @catch (NSException *e) {
        if (error) *error = agError(4, e.reason ?: @"invalid line index");
        return nil;
    }
    return _cached;
}

- (NSData *)gfaDataWithError:(NSError **)error
{
    TTIOWrittenAssemblyGraph *g = [self writtenGraphWithError:error];
    if (!g) return nil;
    return [TTIOGfaWriter dataForGraph:g];
}

@end
