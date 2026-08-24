/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"

@implementation TTIOWrittenAssemblyGraph

- (instancetype)initWithGfaVersion:(NSString *)gfaVersion
                          producer:(NSString *)producer
                      finalNewline:(BOOL)finalNewline
                          segments:(NSArray<TTIOGraphSegment *> *)segments
                             links:(NSArray<TTIOGraphLink *> *)links
                             paths:(NSArray<TTIOGraphPath *> *)paths
                            extras:(NSArray<NSString *> *)extras
                         lineTypes:(NSData *)lineTypes
                          lineRows:(NSData *)lineRows
{
    self = [super init];
    if (self) {
        NSUInteger n = lineTypes.length / sizeof(uint32_t);
        if (lineRows.length != n * sizeof(uint64_t)) {
            [NSException raise:NSInvalidArgumentException
                        format:@"lineRows must hold one uint64 per "
                               @"lineTypes entry (%lu lines, %lu rows)",
                               (unsigned long)n,
                               (unsigned long)(lineRows.length / sizeof(uint64_t))];
        }
        const uint32_t *types = (const uint32_t *)lineTypes.bytes;
        const uint64_t *rows = (const uint64_t *)lineRows.bytes;
        NSUInteger counts[4] = { segments.count, links.count,
                                 paths.count, extras.count };
        NSUInteger seen[4] = { 0, 0, 0, 0 };
        for (NSUInteger i = 0; i < n; i++) {
            if (types[i] > TTIOGfaLineTypeExtra
                || rows[i] >= counts[types[i]]) {
                [NSException raise:NSInvalidArgumentException
                            format:@"line_index entry %lu (type %u, "
                                   @"row %llu) is out of range",
                                   (unsigned long)i, types[i],
                                   (unsigned long long)rows[i]];
            }
            seen[types[i]]++;
        }
        for (int t = 0; t < 4; t++) {
            if (seen[t] != counts[t]) {
                [NSException raise:NSInvalidArgumentException
                            format:@"line_index covers %lu rows of "
                                   @"type %d, table has %lu",
                                   (unsigned long)seen[t], t,
                                   (unsigned long)counts[t]];
            }
        }
        _gfaVersion = [gfaVersion copy] ?: @"1.0";
        _producer = [producer copy] ?: @"";
        _finalNewline = finalNewline;
        _segments = [segments copy];
        _links = [links copy];
        _paths = [paths copy];
        _extras = [extras copy];
        _lineTypes = [lineTypes copy];
        _lineRows = [lineRows copy];
    }
    return self;
}

- (NSUInteger)lineCount
{
    return _lineTypes.length / sizeof(uint32_t);
}

@end
