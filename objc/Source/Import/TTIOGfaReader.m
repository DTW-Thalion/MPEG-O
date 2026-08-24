/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "Import/TTIOGfaReader.h"
#import "Assembly/TTIOWrittenAssemblyGraph.h"
#import "Assembly/TTIOGraphSegment.h"
#import "Assembly/TTIOGraphLink.h"
#import "Assembly/TTIOGraphPath.h"

static NSString * const TTIOGfaReaderErrorDomain = @"TTIOGfaReaderError";

/** The VN:Z: value of a header line's fields, or nil. */
static NSString *versionFromHeaderFields(NSArray<NSString *> *fields)
{
    for (NSUInteger i = 1; i < fields.count; i++) {
        if ([fields[i] hasPrefix:@"VN:Z:"]) {
            return [fields[i] substringFromIndex:5];
        }
    }
    return nil;
}

@implementation TTIOGfaReader

+ (TTIOWrittenAssemblyGraph *)graphFromData:(NSData *)data
                                      error:(NSError **)error
{
    NSString *text = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
    if (!text) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOGfaReaderErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"GFA bytes are not valid UTF-8"}];
        }
        return nil;
    }

    BOOL finalNewline = data.length > 0
        && ((const uint8_t *)data.bytes)[data.length - 1] == '\n';
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = lines.count;
    if (finalNewline) lineCount--;  // drop the empty tail element
    if (data.length == 0) lineCount = 0;

    NSMutableArray<TTIOGraphSegment *> *segments = [NSMutableArray array];
    NSMutableArray<TTIOGraphLink *> *links = [NSMutableArray array];
    NSMutableArray<TTIOGraphPath *> *paths = [NSMutableArray array];
    NSMutableArray<NSString *> *extras = [NSMutableArray array];
    NSMutableData *lineTypes = [NSMutableData dataWithCapacity:lineCount * 4];
    NSMutableData *lineRows = [NSMutableData dataWithCapacity:lineCount * 8];
    NSString *gfaVersion = nil;

    for (NSUInteger li = 0; li < lineCount; li++) {
        NSString *line = lines[li];
        NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
        NSString *t = f.count > 0 ? f[0] : @"";
        uint32_t type;
        uint64_t row;
        if ([t isEqualToString:@"S"] && f.count >= 3) {
            NSString *seqCol = f[2];
            NSData *seq = [seqCol isEqualToString:@"*"]
                ? nil
                : [seqCol dataUsingEncoding:NSUTF8StringEncoding];
            NSString *tags = f.count > 3
                ? [[f subarrayWithRange:NSMakeRange(3, f.count - 3)]
                      componentsJoinedByString:@"\t"]
                : @"";
            [segments addObject:[[TTIOGraphSegment alloc]
                initWithName:f[1] sequence:seq tags:tags]];
            type = TTIOGfaLineTypeSegment;
            row = segments.count - 1;
        } else if ([t isEqualToString:@"L"] && f.count >= 6) {
            NSString *tags = f.count > 6
                ? [[f subarrayWithRange:NSMakeRange(6, f.count - 6)]
                      componentsJoinedByString:@"\t"]
                : @"";
            [links addObject:[[TTIOGraphLink alloc]
                initWithFromSegment:f[1] fromOrient:f[2]
                          toSegment:f[3] toOrient:f[4]
                            overlap:f[5] tags:tags]];
            type = TTIOGfaLineTypeLink;
            row = links.count - 1;
        } else if ([t isEqualToString:@"P"] && f.count >= 4) {
            NSString *tags = f.count > 4
                ? [[f subarrayWithRange:NSMakeRange(4, f.count - 4)]
                      componentsJoinedByString:@"\t"]
                : @"";
            [paths addObject:[[TTIOGraphPath alloc]
                initWithName:f[1] segmentList:f[2]
                    overlaps:f[3] tags:tags]];
            type = TTIOGfaLineTypePath;
            row = paths.count - 1;
        } else {
            if (gfaVersion == nil && [t isEqualToString:@"H"]) {
                gfaVersion = versionFromHeaderFields(f);
            }
            [extras addObject:line];
            type = TTIOGfaLineTypeExtra;
            row = extras.count - 1;
        }
        [lineTypes appendBytes:&type length:sizeof(type)];
        [lineRows appendBytes:&row length:sizeof(row)];
    }

    return [[TTIOWrittenAssemblyGraph alloc]
        initWithGfaVersion:(gfaVersion ?: @"1.0")
                  producer:@""
              finalNewline:finalNewline
                  segments:segments
                     links:links
                     paths:paths
                    extras:extras
                 lineTypes:lineTypes
                  lineRows:lineRows];
}

+ (TTIOWrittenAssemblyGraph *)graphFromPath:(NSString *)path
                                      error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:0
                                            error:error];
    if (!data) return nil;
    return [self graphFromData:data error:error];
}

@end
