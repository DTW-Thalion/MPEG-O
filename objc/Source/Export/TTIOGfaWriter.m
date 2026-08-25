/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "Export/TTIOGfaWriter.h"
#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"

static void appendString(NSMutableData *out, NSString *s)
{
    [out appendData:[s dataUsingEncoding:NSUTF8StringEncoding]];
}

@implementation TTIOGfaWriter

+ (NSData *)dataForGraph:(TTIOWrittenAssemblyGraph *)graph
{
    NSMutableData *out = [NSMutableData data];
    const uint32_t *types = (const uint32_t *)graph.lineTypes.bytes;
    const uint64_t *rows = (const uint64_t *)graph.lineRows.bytes;
    NSUInteger n = graph.lineCount;
    for (NSUInteger i = 0; i < n; i++) {
        if (i > 0) [out appendBytes:"\n" length:1];
        NSUInteger row = (NSUInteger)rows[i];
        switch (types[i]) {
        case TTIOGfaLineTypeSegment: {
            TTIOGraphSegment *s = graph.segments[row];
            appendString(out, @"S\t");
            appendString(out, s.name);
            [out appendBytes:"\t" length:1];
            if (s.sequence) {
                [out appendData:s.sequence];
            } else {
                [out appendBytes:"*" length:1];
            }
            if (s.tags.length > 0) {
                [out appendBytes:"\t" length:1];
                appendString(out, s.tags);
            }
            break;
        }
        case TTIOGfaLineTypeLink: {
            TTIOGraphLink *l = graph.links[row];
            NSString *fixed = [NSString stringWithFormat:
                @"L\t%@\t%@\t%@\t%@\t%@",
                l.fromSegment, l.fromOrient, l.toSegment,
                l.toOrient, l.overlap];
            appendString(out, fixed);
            if (l.tags.length > 0) {
                [out appendBytes:"\t" length:1];
                appendString(out, l.tags);
            }
            break;
        }
        case TTIOGfaLineTypePath: {
            TTIOGraphPath *p = graph.paths[row];
            NSString *fixed = [NSString stringWithFormat:
                @"P\t%@\t%@\t%@",
                p.name, p.segmentList, p.overlaps];
            appendString(out, fixed);
            if (p.tags.length > 0) {
                [out appendBytes:"\t" length:1];
                appendString(out, p.tags);
            }
            break;
        }
        default:
            appendString(out, graph.extras[row]);
            break;
        }
    }
    if (graph.finalNewline) [out appendBytes:"\n" length:1];
    return out;
}

+ (BOOL)writeGraph:(TTIOWrittenAssemblyGraph *)graph
            toPath:(NSString *)path
             error:(NSError **)error
{
    return [[self dataForGraph:graph] writeToFile:path
                                          options:NSDataWritingAtomic
                                            error:error];
}

@end
