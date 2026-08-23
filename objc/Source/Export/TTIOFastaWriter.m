/*
 * TTIOFastaWriter.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOFastaWriter
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Export/TTIOFastaWriter.h
 *
 * FASTA exporter for TTIOReferenceImport and TTIOWrittenGenomicRun.
 * Builds the body in memory so .fai offsets can be computed in the
 * same pass as the body bytes.
 *
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOFastaWriter.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"

#import <zlib.h>


const NSUInteger TTIOFastaWriterDefaultLineWidth = 60;
// Mirrors Java FastaWriter.PROGRESS_INTERVAL_READS (1000).
const NSUInteger TTIOFastaWriterProgressIntervalReads = 1000;
static NSString *const kErrDom = @"TTIOFastaWriterErrorDomain";


static BOOL write_records(NSArray<NSString *> *names,
                          NSArray<NSData *> *seqs,
                          NSString *path,
                          NSUInteger lineWidth,
                          int gzipOutput,
                          BOOL writeFai,
                          TTIOProgressBlock progress,
                          NSError **error)
{
    if (progress == nil) progress = TTIOProgressDiscard();
    if (lineWidth < 1) {
        if (error) {
            *error = [NSError errorWithDomain:kErrDom code:1
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"lineWidth must be >= 1 (got %lu)", (unsigned long)lineWidth] }];
        }
        return NO;
    }
    BOOL gz;
    if (gzipOutput == 0) {
        gz = [path.lowercaseString hasSuffix:@".gz"];
    } else {
        gz = (gzipOutput == 1);
    }

    /* Stream 1 MiB chunks to a .part file renamed on success; a running
     * byte position gives the .fai offsets the old in-memory body's
     * length gave. */
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
    unsigned long long pos = 0;
    NSMutableArray<NSString *> *faiLines = [NSMutableArray array];

    for (NSUInteger i = 0; writeOk && i < names.count; i++) {
        NSString *name = names[i];
        NSData   *seq  = seqs[i];
        // Header
        NSString *hdr = [NSString stringWithFormat:@">%@\n", name];
        NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
        [body appendData:hdrData];
        pos += hdrData.length;
        unsigned long long seqOffset = pos;
        // Wrapped sequence
        NSUInteger length = seq.length;
        const uint8_t *bytes = seq.bytes;
        for (NSUInteger start = 0; start < length; start += lineWidth) {
            NSUInteger chunk = MIN(lineWidth, length - start);
            [body appendBytes:bytes + start length:chunk];
            uint8_t lf = '\n';
            [body appendBytes:&lf length:1];
            pos += chunk + 1;
            if (body.length >= (1 << 20)) {
                flush(body);
                body.length = 0;
            }
        }
        [faiLines addObject:[NSString stringWithFormat:@"%@\t%lu\t%llu\t%lu\t%lu",
                              name,
                              (unsigned long)length,
                              seqOffset,
                              (unsigned long)lineWidth,
                              (unsigned long)(lineWidth + 1)]];

        // Per-N progress fire. Total = names.count.
        if (((i + 1) % TTIOFastaWriterProgressIntervalReads) == 0) {
            progress((int64_t)(i + 1), (int64_t)names.count);
        }
    }
    flush(body);
    if (gf) { if (gzclose(gf) != Z_OK) writeOk = NO; }
    else if (fp) { if (fclose(fp) != 0) writeOk = NO; }
    if (!writeOk) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        if (error) {
            *error = [NSError errorWithDomain:kErrDom code:3
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"short write to %@", path] }];
        }
        return NO;
    }
    // Final fire.
    progress((int64_t)names.count, (int64_t)names.count);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:NULL];
    if (![fm moveItemAtPath:tmp toPath:path error:error]) {
        return NO;
    }

    if (writeFai && !gz) {
        NSString *faiPath = [path stringByAppendingString:@".fai"];
        NSMutableString *faiBody = [NSMutableString string];
        for (NSString *ln in faiLines) {
            [faiBody appendString:ln];
            [faiBody appendString:@"\n"];
        }
        if (![faiBody writeToFile:faiPath atomically:YES
                          encoding:NSASCIIStringEncoding error:error]) {
            return NO;
        }
    }
    return YES;
}


@implementation TTIOFastaWriter

+ (BOOL)writeReference:(TTIOReferenceImport *)reference
                toPath:(NSString *)path
             lineWidth:(NSUInteger)lineWidth
            gzipOutput:(int)gzipOutput
              writeFai:(BOOL)writeFai
                 error:(NSError **)error
{
    return [self writeReference:reference
                         toPath:path
                      lineWidth:lineWidth
                     gzipOutput:gzipOutput
                       writeFai:writeFai
                       progress:nil
                          error:error];
}

+ (BOOL)writeReference:(TTIOReferenceImport *)reference
                toPath:(NSString *)path
             lineWidth:(NSUInteger)lineWidth
            gzipOutput:(int)gzipOutput
              writeFai:(BOOL)writeFai
              progress:(TTIOProgressBlock)progress
                 error:(NSError **)error
{
    return write_records(reference.chromosomes, reference.sequences,
                         path, lineWidth, gzipOutput, writeFai,
                         progress, error);
}

+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
       lineWidth:(NSUInteger)lineWidth
      gzipOutput:(int)gzipOutput
        writeFai:(BOOL)writeFai
           error:(NSError **)error
{
    return [self writeRun:run
                   toPath:path
                lineWidth:lineWidth
               gzipOutput:gzipOutput
                 writeFai:writeFai
                 progress:nil
                    error:error];
}

+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
       lineWidth:(NSUInteger)lineWidth
      gzipOutput:(int)gzipOutput
        writeFai:(BOOL)writeFai
        progress:(TTIOProgressBlock)progress
           error:(NSError **)error
{
    NSArray<NSString *> *readNames = run.readNames;
    NSData *seqs = run.sequencesData;
    NSData *offsetsData = run.offsetsData;
    NSData *lengthsData = run.lengthsData;
    const uint64_t *offsets = offsetsData.bytes;
    const uint32_t *lengths = lengthsData.bytes;
    const uint8_t  *seqBytes = seqs.bytes;

    NSMutableArray<NSString *> *outNames = [NSMutableArray arrayWithCapacity:readNames.count];
    NSMutableArray<NSData *> *outSeqs = [NSMutableArray arrayWithCapacity:readNames.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < readNames.count; i++) {
        NSString *name = readNames[i];
        if ([seen containsObject:name]) {
            name = [NSString stringWithFormat:@"%@#%lu", name, (unsigned long)i];
        }
        [seen addObject:name];
        [outNames addObject:name];
        NSData *slice = [NSData dataWithBytes:seqBytes + offsets[i] length:lengths[i]];
        [outSeqs addObject:slice];
    }
    return write_records(outNames, outSeqs, path, lineWidth, gzipOutput,
                         writeFai, progress, error);
}

+ (BOOL)writeReadSideRun:(TTIOGenomicRun *)run
                  toPath:(NSString *)path
               lineWidth:(NSUInteger)lineWidth
              gzipOutput:(int)gzipOutput
                writeFai:(BOOL)writeFai
                   error:(NSError **)error
{
    return [self writeReadSideRun:run
                           toPath:path
                        lineWidth:lineWidth
                       gzipOutput:gzipOutput
                         writeFai:writeFai
                         progress:nil
                            error:error];
}

+ (BOOL)writeReadSideRun:(TTIOGenomicRun *)run
                  toPath:(NSString *)path
               lineWidth:(NSUInteger)lineWidth
              gzipOutput:(int)gzipOutput
                writeFai:(BOOL)writeFai
                progress:(TTIOProgressBlock)progress
                   error:(NSError **)error
{
    // Same bulk-fetch pattern as TTIOFastqWriter:
    // pre-fetch the whole sequences buffer + read-names list once,
    // slice in-memory per record. Skips per-read AlignedRead
    // materialisation.
    NSUInteger n = [run count];
    NSData *seqAll = [run wholeSequencesData];
    NSArray<NSString *> *namesAll = [run allReadNames];
    const uint8_t *seqBytes = seqAll.bytes;
    TTIOGenomicIndex *idx = run.index;
    NSMutableArray<NSString *> *outNames = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSData *> *outSeqs = [NSMutableArray arrayWithCapacity:n];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < n; i++) {
        uint64_t off = [idx offsetAt:i];
        uint32_t len = [idx lengthAt:i];
        NSString *name = (i < namesAll.count) ? namesAll[i] : @"";
        if ([seen containsObject:name]) {
            name = [NSString stringWithFormat:@"%@#%lu", name, (unsigned long)i];
        }
        [seen addObject:name];
        [outNames addObject:name];
        NSData *seq = (len > 0)
            ? [NSData dataWithBytes:seqBytes + off length:len]
            : [NSData data];
        [outSeqs addObject:seq];
    }
    return write_records(outNames, outSeqs, path, lineWidth, gzipOutput,
                         writeFai, progress, error);
}

@end
