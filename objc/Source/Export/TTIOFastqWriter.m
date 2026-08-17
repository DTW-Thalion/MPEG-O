/*
 * TTIOFastqWriter.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOFastqWriter
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Export/TTIOFastqWriter.h
 *
 * FASTQ exporter. Maps the 0xFF "qualities unknown" sentinel to
 * Phred 0 ('!') on output so the result is always a parseable
 * FASTQ.
 *
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOFastqWriter.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"

#import <zlib.h>


static const uint8_t kQualUnknownByte = 0xFF;
static const uint8_t kPhred33Fill = '!';

static NSString *const kErrDom = @"TTIOFastqWriterErrorDomain";

// Mirrors Java FastqWriter.PROGRESS_INTERVAL_READS (1000).
const NSUInteger TTIOFastqWriterProgressIntervalReads = 1000;


@implementation TTIOFastqWriter

+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
      gzipOutput:(int)gzipOutput
     phredOffset:(uint8_t)phredOffset
           error:(NSError **)error
{
    return [self writeRun:run
                   toPath:path
               gzipOutput:gzipOutput
              phredOffset:phredOffset
                 progress:nil
                    error:error];
}

+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
      gzipOutput:(int)gzipOutput
     phredOffset:(uint8_t)phredOffset
        progress:(TTIOProgressBlock)progress
           error:(NSError **)error
{
    if (progress == nil) progress = TTIOProgressDiscard();
    if (phredOffset != 33 && phredOffset != 64) {
        if (error) {
            *error = [NSError errorWithDomain:kErrDom code:1
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"phredOffset must be 33 or 64 (got %u)", (unsigned)phredOffset] }];
        }
        return NO;
    }
    BOOL gz;
    if (gzipOutput == 0) {
        gz = [path.lowercaseString hasSuffix:@".gz"];
    } else {
        gz = (gzipOutput == 1);
    }

    NSArray<NSString *> *readNames = run.readNames;
    NSData *seqs = run.sequencesData;
    NSData *quals = run.qualitiesData;
    NSData *offsetsData = run.offsetsData;
    NSData *lengthsData = run.lengthsData;
    const uint64_t *offsets = offsetsData.bytes;
    const uint32_t *lengths = lengthsData.bytes;
    const uint8_t  *seqBytes = seqs.bytes;
    const uint8_t  *qualBytes = quals.bytes;
    NSUInteger qualLen = quals.length;

    NSMutableData *body = [NSMutableData dataWithCapacity:64 * 1024];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < readNames.count; i++) {
        uint64_t off = offsets[i];
        uint32_t len = lengths[i];
        NSString *name = readNames[i];
        if ([seen containsObject:name]) {
            name = [NSString stringWithFormat:@"%@#%lu", name, (unsigned long)i];
        }
        [seen addObject:name];
        // Build qualities slice with sentinel mapping + phred shift.
        NSMutableData *qualSlice = [NSMutableData dataWithCapacity:len];
        if (qualLen >= off + len && len > 0) {
            uint8_t *out = malloc(len);
            for (uint32_t j = 0; j < len; j++) {
                uint8_t b = qualBytes[off + j];
                if (b == kQualUnknownByte) b = kPhred33Fill;
                if (phredOffset == 64) b = (uint8_t)((b + 31) & 0xFF);
                out[j] = b;
            }
            [qualSlice appendBytes:out length:len];
            free(out);
        } else if (len > 0) {
            // No qualities buffer (or short) — pad with Phred 0.
            uint8_t fill = (phredOffset == 64) ? (uint8_t)('!' + 31) : kPhred33Fill;
            uint8_t *out = malloc(len);
            memset(out, fill, len);
            [qualSlice appendBytes:out length:len];
            free(out);
        }
        // Record bytes
        uint8_t at = '@';
        [body appendBytes:&at length:1];
        [body appendData:[name dataUsingEncoding:NSUTF8StringEncoding]];
        uint8_t lf = '\n';
        [body appendBytes:&lf length:1];
        if (len > 0) {
            [body appendBytes:seqBytes + off length:len];
        }
        [body appendBytes:&lf length:1];
        uint8_t plus = '+';
        [body appendBytes:&plus length:1];
        [body appendBytes:&lf length:1];
        [body appendData:qualSlice];
        [body appendBytes:&lf length:1];

        // Per-N progress fire. Total IS known (run.readNames.count).
        if (((i + 1) % TTIOFastqWriterProgressIntervalReads) == 0) {
            progress((int64_t)(i + 1), (int64_t)readNames.count);
        }
    }
    // Final fire — total = total.
    progress((int64_t)readNames.count, (int64_t)readNames.count);

    if (gz) {
        gzFile gf = gzopen([path fileSystemRepresentation], "wb");
        if (gf == NULL) {
            if (error) {
                *error = [NSError errorWithDomain:kErrDom code:2
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"could not open %@ for writing", path] }];
            }
            return NO;
        }
        int written = gzwrite(gf, body.bytes, (unsigned)body.length);
        gzclose(gf);
        if (written != (int)body.length) {
            if (error) {
                *error = [NSError errorWithDomain:kErrDom code:3
                                         userInfo:@{ NSLocalizedDescriptionKey :
                                                     [NSString stringWithFormat:@"short gzip write to %@", path] }];
            }
            return NO;
        }
        return YES;
    }
    return [body writeToFile:path options:NSDataWritingAtomic error:error];
}

+ (BOOL)writeReadSideRun:(TTIOGenomicRun *)run
                  toPath:(NSString *)path
              gzipOutput:(int)gzipOutput
             phredOffset:(uint8_t)phredOffset
                   error:(NSError **)error
{
    return [self writeReadSideRun:run
                           toPath:path
                       gzipOutput:gzipOutput
                      phredOffset:phredOffset
                         progress:nil
                            error:error];
}

+ (BOOL)writeReadSideRun:(TTIOGenomicRun *)run
                  toPath:(NSString *)path
              gzipOutput:(int)gzipOutput
             phredOffset:(uint8_t)phredOffset
                progress:(TTIOProgressBlock)progress
                   error:(NSError **)error
{
    if (progress == nil) progress = TTIOProgressDiscard();
    if (phredOffset != 33 && phredOffset != 64) {
        if (error) {
            *error = [NSError errorWithDomain:kErrDom code:1
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"phredOffset must be 33 or 64 (got %u)",
                                                  (unsigned)phredOffset] }];
        }
        return NO;
    }
    BOOL gz;
    if (gzipOutput == 0) {
        gz = [path.lowercaseString hasSuffix:@".gz"];
    } else {
        gz = (gzipOutput == 1);
    }

    // Reads stream out through -iterReadsFrom:to:usingBlock: (one
    // decoded block resident for a blocks_v1 run) into a 1 MiB chunk
    // flushed to the file (plain or gzip) as it fills.
    NSUInteger n = [run count];
    gzFile gf = NULL;
    FILE *fp = NULL;
    NSString *tmp = [path stringByAppendingString:@".part"];
    if (gz) {
        gf = gzopen([tmp fileSystemRepresentation], "wb");
    } else {
        fp = fopen([tmp fileSystemRepresentation], "wb");
    }
    if (!gf && !fp) {
        if (error) {
            *error = [NSError errorWithDomain:kErrDom code:2
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"could not open %@ for writing", path] }];
        }
        return NO;
    }
    __block BOOL writeOk = YES;
    BOOL (^flush)(NSData *) = ^BOOL(NSData *chunk) {
        if (chunk.length == 0) return YES;
        if (gf) {
            if (gzwrite(gf, chunk.bytes, (unsigned)chunk.length) != (int)chunk.length) writeOk = NO;
        } else if (fwrite(chunk.bytes, 1, chunk.length, fp) != chunk.length) {
            writeOk = NO;
        }
        return writeOk;
    };
    NSMutableData *body = [NSMutableData dataWithCapacity:1 << 20];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    __block NSUInteger done = 0;
    NSError *iterErr = nil;
    BOOL ok = [run iterReadsFrom:0 to:n error:&iterErr
                      usingBlock:^(TTIOAlignedRead *r, NSUInteger i, BOOL *stop) {
        NSData *seq = [r.sequence dataUsingEncoding:NSASCIIStringEncoding] ?: [NSData data];
        NSUInteger len = seq.length;
        NSData *q = r.qualities;
        NSMutableData *qualSlice = [NSMutableData dataWithLength:len];
        uint8_t *out = qualSlice.mutableBytes;
        const uint8_t *qb = q.bytes;
        for (NSUInteger j = 0; j < len; j++) {
            uint8_t b = (j < q.length) ? qb[j] : kQualUnknownByte;
            if (b == kQualUnknownByte) b = kPhred33Fill;
            if (phredOffset == 64) b = (uint8_t)((b + 31) & 0xFF);
            out[j] = b;
        }
        NSString *name = r.readName ?: @"";
        if ([seen containsObject:name]) {
            name = [NSString stringWithFormat:@"%@#%lu", name, (unsigned long)i];
        }
        [seen addObject:name];
        uint8_t at = '@', lf = '\n', plus = '+';
        [body appendBytes:&at length:1];
        [body appendData:[name dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendBytes:&lf length:1];
        [body appendData:seq];
        [body appendBytes:&lf length:1];
        [body appendBytes:&plus length:1];
        [body appendBytes:&lf length:1];
        [body appendData:qualSlice];
        [body appendBytes:&lf length:1];
        done++;
        if (body.length >= (1 << 20)) {
            if (!flush(body)) *stop = YES;
            [body setLength:0];
        }
        if ((done % TTIOFastqWriterProgressIntervalReads) == 0) {
            progress((int64_t)done, (int64_t)n);
        }
    }];
    if (ok && writeOk) flush(body);
    if (gf) gzclose(gf);
    if (fp) fclose(fp);
    if (!ok || !writeOk) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        if (error) {
            *error = iterErr ?: [NSError errorWithDomain:kErrDom code:3
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"short write to %@", path] }];
        }
        return NO;
    }
    progress((int64_t)n, (int64_t)n);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:NULL];
    return [fm moveItemAtPath:tmp toPath:path error:error];
}

@end
