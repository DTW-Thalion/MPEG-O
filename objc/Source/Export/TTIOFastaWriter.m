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

#import <zlib.h>


const NSUInteger TTIOFastaWriterDefaultLineWidth = 60;
static NSString *const kErrDom = @"TTIOFastaWriterErrorDomain";


// (name, sequence) record pair.
typedef struct {
    __unsafe_unretained NSString *name;
    __unsafe_unretained NSData   *seq;
} TTIORec;


static BOOL write_records(NSArray<NSString *> *names,
                          NSArray<NSData *> *seqs,
                          NSString *path,
                          NSUInteger lineWidth,
                          int gzipOutput,
                          BOOL writeFai,
                          NSError **error)
{
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

    NSMutableData *body = [NSMutableData dataWithCapacity:64 * 1024];
    NSMutableArray<NSString *> *faiLines = [NSMutableArray array];

    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *name = names[i];
        NSData   *seq  = seqs[i];
        // Header
        NSString *hdr = [NSString stringWithFormat:@">%@\n", name];
        NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
        [body appendData:hdrData];
        NSUInteger seqOffset = body.length;
        // Wrapped sequence
        NSUInteger length = seq.length;
        const uint8_t *bytes = seq.bytes;
        for (NSUInteger start = 0; start < length; start += lineWidth) {
            NSUInteger chunk = MIN(lineWidth, length - start);
            [body appendBytes:bytes + start length:chunk];
            uint8_t lf = '\n';
            [body appendBytes:&lf length:1];
        }
        [faiLines addObject:[NSString stringWithFormat:@"%@\t%lu\t%lu\t%lu\t%lu",
                              name,
                              (unsigned long)length,
                              (unsigned long)seqOffset,
                              (unsigned long)lineWidth,
                              (unsigned long)(lineWidth + 1)]];
    }

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
    } else {
        if (![body writeToFile:path options:NSDataWritingAtomic error:error]) {
            return NO;
        }
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
    return write_records(reference.chromosomes, reference.sequences,
                         path, lineWidth, gzipOutput, writeFai, error);
}

+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
       lineWidth:(NSUInteger)lineWidth
      gzipOutput:(int)gzipOutput
        writeFai:(BOOL)writeFai
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
                         writeFai, error);
}

@end
