/*
 * TTIOFastqReader.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOFastqReader
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOFastqReader.h
 *
 * FASTQ parser supporting auto-detect Phred offset (33 / 64).
 * Always normalises to Phred+33 ASCII for internal storage.
 *
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOFastqReader.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "ValueClasses/TTIOEnums.h"

#import <zlib.h>


NSString *const TTIOFastqReaderErrorDomain = @"TTIOFastqReaderErrorDomain";


// Forward declaration of the helper exported from TTIOFastaReader.m.
TTIOWrittenGenomicRun *TTIOFastaReaderBuildUnalignedRun(
    NSArray<NSString *> *readNames,
    NSData *sequences,
    NSData *qualities,
    NSArray<NSNumber *> *offsetsArr,
    NSArray<NSNumber *> *lengthsArr,
    NSString *sampleName,
    NSString *platform,
    NSString *referenceUri,
    TTIOAcquisitionMode mode);


// gzopen handles plain + gzipped uniformly.
static gzFile open_maybe_gzip(NSString *path)
{
    return gzopen([path fileSystemRepresentation], "rb");
}

static BOOL read_line(gzFile fh, NSMutableData *buf)
{
    [buf setLength:0];
    char ch;
    int n;
    while ((n = gzread(fh, &ch, 1)) > 0) {
        if (ch == '\n') return YES;
        if (ch == '\r') continue;
        [buf appendBytes:&ch length:1];
    }
    return buf.length > 0;
}

static NSString *parse_at_header(NSData *line)
{
    const uint8_t *bytes = line.bytes;
    NSUInteger len = line.length;
    if (len < 1 || bytes[0] != '@') return nil;
    NSUInteger i = 1;
    while (i < len && (bytes[i] == ' ' || bytes[i] == '\t')) i++;
    NSUInteger start = i;
    while (i < len && bytes[i] != ' ' && bytes[i] != '\t') i++;
    if (i == start) return nil;
    return [[NSString alloc] initWithBytes:bytes + start
                                    length:i - start
                                  encoding:NSUTF8StringEncoding];
}


@implementation TTIOFastqReader

+ (uint8_t)detectPhredOffsetFromBytes:(NSData *)qualities
{
    if (qualities.length == 0) return 33;
    const uint8_t *bytes = qualities.bytes;
    NSUInteger len = qualities.length;
    int lo = 256, hi = -1;
    for (NSUInteger i = 0; i < len; i++) {
        int v = bytes[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    if (lo < 59) return 33;
    if (lo >= 64 && hi <= 104) return 64;
    return 33;
}

+ (TTIOWrittenGenomicRun *)readFromPath:(NSString *)path
                            forcedPhred:(uint8_t)forcedPhred
                             sampleName:(NSString *)sampleName
                               platform:(NSString *)platform
                           referenceUri:(NSString *)referenceUri
                        acquisitionMode:(TTIOAcquisitionMode)mode
                            outDetected:(uint8_t *)outDetected
                                  error:(NSError **)error
{
    if (forcedPhred != 0 && forcedPhred != 33 && forcedPhred != 64) {
        [NSException raise:NSInvalidArgumentException
                    format:@"forcedPhred must be 0, 33, or 64 (got %u)",
                            (unsigned)forcedPhred];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                         code:TTIOFastqReaderErrorMissingFile
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"FASTQ file not found: %@", path] }];
        }
        return nil;
    }
    gzFile fh = open_maybe_gzip(path);
    if (fh == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                         code:TTIOFastqReaderErrorMissingFile
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"could not open %@", path] }];
        }
        return nil;
    }

    NSMutableArray<NSString *> *readNames = [NSMutableArray array];
    NSMutableArray<NSData *> *seqs = [NSMutableArray array];
    NSMutableArray<NSData *> *quals = [NSMutableArray array];
    NSMutableData *line = [NSMutableData dataWithCapacity:128];
    NSUInteger lineNo = 0;
    BOOL ok = YES;

    while (1) {
        BOOL more = read_line(fh, line);
        if (!more && line.length == 0) break;
        lineNo++;
        if (line.length == 0) {
            if (!more) break;
            continue;
        }
        const uint8_t *bytes = line.bytes;
        if (bytes[0] != '@') {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"line %lu: expected '@<name>' header",
                                                      (unsigned long)lineNo] }];
            }
            ok = NO;
            break;
        }
        NSString *name = parse_at_header(line);
        if (name == nil) {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"line %lu: FASTQ header missing a name token",
                                                      (unsigned long)lineNo] }];
            }
            ok = NO;
            break;
        }
        // Sequence
        NSMutableData *seqLine = [NSMutableData dataWithCapacity:128];
        BOOL m2 = read_line(fh, seqLine);
        lineNo++;
        if (!m2 && seqLine.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"truncated record at line %lu (missing sequence)",
                                                      (unsigned long)lineNo] }];
            }
            ok = NO;
            break;
        }
        // '+' separator
        NSMutableData *plus = [NSMutableData dataWithCapacity:8];
        BOOL m3 = read_line(fh, plus);
        lineNo++;
        if (!m3 && plus.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"truncated record at line %lu (missing separator)",
                                                      (unsigned long)lineNo] }];
            }
            ok = NO;
            break;
        }
        if (plus.length < 1 || ((const uint8_t *)plus.bytes)[0] != '+') {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"line %lu: expected '+' separator",
                                                      (unsigned long)lineNo] }];
            }
            ok = NO;
            break;
        }
        // Qualities
        NSMutableData *qualLine = [NSMutableData dataWithCapacity:128];
        BOOL m4 = read_line(fh, qualLine);
        lineNo++;
        if (!m4 && qualLine.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"truncated record at line %lu (missing qualities)",
                                                      (unsigned long)lineNo] }];
            }
            ok = NO;
            break;
        }
        if (qualLine.length != seqLine.length) {
            if (error) {
                *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                             code:TTIOFastqReaderErrorParseFailed
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"line %lu: SEQ/QUAL length mismatch (%lu vs %lu) for read '%@'",
                                                      (unsigned long)lineNo,
                                                      (unsigned long)seqLine.length,
                                                      (unsigned long)qualLine.length,
                                                      name] }];
            }
            ok = NO;
            break;
        }
        [readNames addObject:name];
        [seqs addObject:[seqLine copy]];
        [quals addObject:[qualLine copy]];
        if (!more) break;
    }
    gzclose(fh);
    if (!ok) return nil;

    if (readNames.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastqReaderErrorDomain
                                         code:TTIOFastqReaderErrorEmptyInput
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"no FASTQ records found in %@", path] }];
        }
        return nil;
    }

    // Detect / apply Phred offset.
    uint8_t offset;
    if (forcedPhred != 0) {
        offset = forcedPhred;
    } else {
        NSMutableData *concat = [NSMutableData data];
        for (NSData *q in quals) [concat appendData:q];
        offset = [self detectPhredOffsetFromBytes:concat];
    }
    if (outDetected) *outDetected = offset;

    if (offset == 64) {
        for (NSUInteger i = 0; i < quals.count; i++) {
            NSData *q = quals[i];
            NSMutableData *q33 = [NSMutableData dataWithLength:q.length];
            const uint8_t *src = q.bytes;
            uint8_t *dst = q33.mutableBytes;
            for (NSUInteger j = 0; j < q.length; j++) {
                dst[j] = (uint8_t)((src[j] - 31) & 0xFF);
            }
            quals[i] = [q33 copy];
        }
    }

    // Build offsets / lengths and concat sequences + qualities.
    NSMutableArray<NSNumber *> *offsetsArr = [NSMutableArray array];
    NSMutableArray<NSNumber *> *lengthsArr = [NSMutableArray array];
    NSMutableData *seqBuf = [NSMutableData dataWithCapacity:1024];
    NSMutableData *qualBuf = [NSMutableData dataWithCapacity:1024];
    uint64_t running = 0;
    for (NSUInteger i = 0; i < readNames.count; i++) {
        NSData *s = seqs[i];
        NSData *q = quals[i];
        [offsetsArr addObject:@(running)];
        [lengthsArr addObject:@((uint32_t)s.length)];
        [seqBuf appendData:s];
        [qualBuf appendData:q];
        running += (uint64_t)s.length;
    }

    return TTIOFastaReaderBuildUnalignedRun(
        readNames, [seqBuf copy], [qualBuf copy], offsetsArr, lengthsArr,
        sampleName, platform, referenceUri, mode
    );
}

@end
