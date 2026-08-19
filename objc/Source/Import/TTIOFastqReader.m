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
#import "Import/TTIOGenomicStreamSource.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "ValueClasses/TTIOEnums.h"

#import <zlib.h>


NSString *const TTIOFastqReaderErrorDomain = @"TTIOFastqReaderErrorDomain";

// Mirrors Java FastqReader.PROGRESS_INTERVAL_READS (1000). Small
// enough that even small inputs get visible updates, large enough
// that per-callback overhead stays well below 1% of parse time.
const NSUInteger TTIOFastqReaderProgressIntervalReads = 1000;
const NSUInteger TTIOFastqReaderDefaultBatchReads = 100000;
const unsigned long long TTIOFastqReaderDefaultBatchBytes = 64ull << 20;


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
    // Non-progress overload: forwards to the progress-aware variant
    // with a nil block so existing callers see identical behaviour.
    return [self readFromPath:path
                  forcedPhred:forcedPhred
                   sampleName:sampleName
                     platform:platform
                 referenceUri:referenceUri
              acquisitionMode:mode
                  outDetected:outDetected
                     progress:nil
                        error:error];
}

+ (TTIOWrittenGenomicRun *)readFromPath:(NSString *)path
                            forcedPhred:(uint8_t)forcedPhred
                             sampleName:(NSString *)sampleName
                               platform:(NSString *)platform
                           referenceUri:(NSString *)referenceUri
                        acquisitionMode:(TTIOAcquisitionMode)mode
                            outDetected:(uint8_t *)outDetected
                               progress:(TTIOProgressBlock)progress
                                  error:(NSError **)error
{
    if (progress == nil) progress = TTIOProgressDiscard();
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
        // Fire per-N progress; total is unknown mid-parse so emit -1.
        if ((readNames.count % TTIOFastqReaderProgressIntervalReads) == 0) {
            progress((int64_t)readNames.count, (int64_t)-1);
        }
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

    // Final fire once the true record count is known. Stamps both
    // done + total so listeners can switch from indeterminate to
    // completion state.
    progress((int64_t)readNames.count, (int64_t)readNames.count);

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


static NSError *fqError(NSInteger code, NSString *msg)
{
    return [NSError errorWithDomain:TTIOFastqReaderErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

/* One record: name, sequence bytes, quality bytes; nil at EOF, NO with
 * *error on a malformed record. */
static BOOL fqReadRecord(gzFile fh, NSMutableData *line, NSUInteger *lineNo,
                         NSString **name, NSData **seq, NSData **qual, BOOL *eof, NSError **error)
{
    *eof = NO;
    BOOL more;
    do {
        more = read_line(fh, line);
        if (!more && line.length == 0) { *eof = YES; return YES; }
        (*lineNo)++;
    } while (line.length == 0 && more);
    if (line.length == 0) { *eof = YES; return YES; }
    const uint8_t *bytes = line.bytes;
    if (bytes[0] != '@') {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"line %lu: expected '@<name>' header", (unsigned long)*lineNo]);
        return NO;
    }
    NSString *n = parse_at_header(line);
    if (n == nil) {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"line %lu: FASTQ header missing a name token", (unsigned long)*lineNo]);
        return NO;
    }
    NSMutableData *seqLine = [NSMutableData dataWithCapacity:128];
    BOOL m2 = read_line(fh, seqLine);
    (*lineNo)++;
    if (!m2 && seqLine.length == 0) {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"truncated record at line %lu (missing sequence)", (unsigned long)*lineNo]);
        return NO;
    }
    NSMutableData *plus = [NSMutableData dataWithCapacity:8];
    BOOL m3 = read_line(fh, plus);
    (*lineNo)++;
    if ((!m3 && plus.length == 0) || plus.length < 1 || ((const uint8_t *)plus.bytes)[0] != '+') {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"line %lu: expected '+' separator", (unsigned long)*lineNo]);
        return NO;
    }
    NSMutableData *qualLine = [NSMutableData dataWithCapacity:128];
    BOOL m4 = read_line(fh, qualLine);
    (*lineNo)++;
    if (!m4 && qualLine.length == 0) {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"truncated record at line %lu (missing qualities)", (unsigned long)*lineNo]);
        return NO;
    }
    if (qualLine.length != seqLine.length) {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"line %lu: SEQ/QUAL length mismatch (%lu vs %lu) for read '%@'",
             (unsigned long)*lineNo, (unsigned long)seqLine.length, (unsigned long)qualLine.length, n]);
        return NO;
    }
    *name = n;
    *seq = [seqLine copy];
    *qual = [qualLine copy];
    return YES;
}

+ (BOOL)iterBatchesFromPath:(NSString *)path
                forcedPhred:(uint8_t)forcedPhred
                 sampleName:(NSString *)sampleName
                   platform:(NSString *)platform
               referenceUri:(NSString *)referenceUri
            acquisitionMode:(TTIOAcquisitionMode)mode
                 batchReads:(NSUInteger)batchReads
                outDetected:(uint8_t *)outDetected
                   progress:(TTIOProgressBlock)progress
                      error:(NSError **)error
                 usingBlock:(BOOL (^)(TTIOWrittenGenomicRun *batch, NSError **error))block
{
    return [self iterBatchesFromPath:path forcedPhred:forcedPhred sampleName:sampleName
                            platform:platform referenceUri:referenceUri acquisitionMode:mode
                          batchReads:batchReads batchBytes:0 outDetected:outDetected
                            progress:progress error:error usingBlock:block];
}

+ (BOOL)iterBatchesFromPath:(NSString *)path
                forcedPhred:(uint8_t)forcedPhred
                 sampleName:(NSString *)sampleName
                   platform:(NSString *)platform
               referenceUri:(NSString *)referenceUri
            acquisitionMode:(TTIOAcquisitionMode)mode
                 batchReads:(NSUInteger)batchReads
                 batchBytes:(unsigned long long)batchBytes
                outDetected:(uint8_t *)outDetected
                   progress:(TTIOProgressBlock)progress
                      error:(NSError **)error
                 usingBlock:(BOOL (^)(TTIOWrittenGenomicRun *batch, NSError **error))block
{
    if (batchBytes == 0) batchBytes = TTIOFastqReaderDefaultBatchBytes;
    if (progress == nil) progress = TTIOProgressDiscard();
    if (batchReads < 1) batchReads = 1;
    if (forcedPhred != 0 && forcedPhred != 33 && forcedPhred != 64) {
        if (error) *error = fqError(TTIOFastqReaderErrorParseFailed,
            [NSString stringWithFormat:@"forcedPhred must be 0, 33, or 64 (got %u)", (unsigned)forcedPhred]);
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = fqError(TTIOFastqReaderErrorMissingFile,
            [NSString stringWithFormat:@"FASTQ file not found: %@", path]);
        return NO;
    }
    gzFile fh = open_maybe_gzip(path);
    if (fh == NULL) {
        if (error) *error = fqError(TTIOFastqReaderErrorMissingFile,
            [NSString stringWithFormat:@"could not open %@", path]);
        return NO;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSData *> *seqs = [NSMutableArray array];
    NSMutableArray<NSData *> *quals = [NSMutableArray array];
    NSMutableData *line = [NSMutableData dataWithCapacity:128];
    NSUInteger lineNo = 0;
    __block uint8_t detected = 0;
    unsigned long long total = 0;
    BOOL ok = YES, eof = NO;
    __block NSError *innerErr = nil;
    __block unsigned long long pendingBytes = 0;

    BOOL (^emit)(void) = ^BOOL(void) {
        if (detected == 0) {
            if (forcedPhred != 0) {
                detected = forcedPhred;
            } else {
                NSMutableData *concat = [NSMutableData data];
                for (NSData *q in quals) [concat appendData:q];
                detected = [self detectPhredOffsetFromBytes:concat];
            }
        }
        NSMutableArray<NSNumber *> *offsetsArr = [NSMutableArray arrayWithCapacity:names.count];
        NSMutableArray<NSNumber *> *lengthsArr = [NSMutableArray arrayWithCapacity:names.count];
        NSMutableData *seqBuf = [NSMutableData data];
        NSMutableData *qualBuf = [NSMutableData data];
        uint64_t running = 0;
        for (NSUInteger i = 0; i < names.count; i++) {
            NSData *sq = seqs[i], *q = quals[i];
            if (detected == 64) {
                NSMutableData *q33 = [NSMutableData dataWithLength:q.length];
                const uint8_t *src = q.bytes;
                uint8_t *dst = q33.mutableBytes;
                for (NSUInteger j = 0; j < q.length; j++) dst[j] = (uint8_t)((src[j] - 31) & 0xFF);
                q = q33;
            }
            [offsetsArr addObject:@(running)];
            [lengthsArr addObject:@((uint32_t)sq.length)];
            [seqBuf appendData:sq];
            [qualBuf appendData:q];
            running += sq.length;
        }
        TTIOWrittenGenomicRun *batch = TTIOFastaReaderBuildUnalignedRun(
            [names copy], [seqBuf copy], [qualBuf copy], offsetsArr, lengthsArr,
            sampleName, platform, referenceUri, mode);
        [names removeAllObjects]; [seqs removeAllObjects]; [quals removeAllObjects];
        pendingBytes = 0;
        NSError *e = nil;
        if (!block(batch, &e)) { innerErr = e; return NO; }
        return YES;
    };

    /* Drain per record: the loop's temporaries (and each emitted
     * batch's) otherwise live until return, so memory grows with the
     * file instead of the batch. The error is carried across the pool
     * in a strong local (an out-param write inside the pool would be
     * released with it). */
    NSError *readErr = nil;
    while (ok && !eof) {
        @autoreleasepool {
            NSString *name = nil; NSData *sq = nil, *q = nil;
            NSError *re = nil;
            if (!fqReadRecord(fh, line, &lineNo, &name, &sq, &q, &eof, &re)) {
                readErr = re;
                ok = NO;
            } else if (!eof) {
                [names addObject:name]; [seqs addObject:sq]; [quals addObject:q];
                pendingBytes += (unsigned long long)sq.length * 2ull;
                total++;
                if ((total % TTIOFastqReaderProgressIntervalReads) == 0) progress((int64_t)total, (int64_t)-1);
                if ((names.count >= batchReads || pendingBytes >= batchBytes) && !emit()) ok = NO;
            }
        }
    }
    gzclose(fh);
    if (ok && names.count > 0 && !emit()) ok = NO;
    if (!ok) {
        if (readErr && error && *error == nil) *error = readErr;
        if (innerErr && error && *error == nil) *error = innerErr;
        return NO;
    }
    if (total == 0) {
        if (error) *error = fqError(TTIOFastqReaderErrorEmptyInput,
            [NSString stringWithFormat:@"no FASTQ records found in %@", path]);
        return NO;
    }
    if (outDetected) *outDetected = detected ?: (forcedPhred ?: 33);
    progress((int64_t)total, (int64_t)total);
    return YES;
}

+ (TTIOGenomicStreamSource *)streamFromPath:(NSString *)path
                                       name:(NSString *)name
                                 sampleName:(NSString *)sampleName
                                 batchReads:(NSUInteger)batchReads
                                   progress:(TTIOProgressBlock)progress
{
    return [self streamFromPath:path name:name sampleName:sampleName
                     batchReads:batchReads batchBytes:0 progress:progress];
}

+ (TTIOGenomicStreamSource *)streamFromPath:(NSString *)path
                                       name:(NSString *)name
                                 sampleName:(NSString *)sampleName
                                 batchReads:(NSUInteger)batchReads
                                 batchBytes:(unsigned long long)batchBytes
                                   progress:(TTIOProgressBlock)progress
{
    TTIOGenomicBatchProducer producer = ^BOOL(BOOL (^emit)(TTIOWrittenGenomicRun *, NSError **), NSError **error) {
        return [self iterBatchesFromPath:path forcedPhred:0 sampleName:sampleName ?: @""
                                platform:@"" referenceUri:@"" acquisitionMode:TTIOAcquisitionModeGenomicWGS
                              batchReads:batchReads batchBytes:batchBytes outDetected:NULL progress:progress
                                   error:error usingBlock:emit];
    };
    return [[TTIOGenomicStreamSource alloc] initWithName:name ?: @"genomic_0001" batches:producer
                                          referenceFasta:nil embedReference:NO
                                              blockReads:nil blockBytes:nil optLegacyWholeChannel:NO];
}

@end
