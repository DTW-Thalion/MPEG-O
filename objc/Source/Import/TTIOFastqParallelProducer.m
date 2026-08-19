/* SPDX-License-Identifier: LGPL-3.0-or-later */
#import "Import/TTIOFastqParallelProducer.h"
#import "Import/TTIOFastqReader.h"
#import "Import/TTIOOrderedBatchAssembler.h"
#import "Import/TTIOFastqRecordScanner.h"
#import "Import/TTIOInputSegmenter.h"
#import "Core/TTIOThreads.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#include <zlib.h>

/* Shared unaligned-run constructor (Import/TTIOFastaReader.m). */
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

static NSError *ppError(NSString *msg)
{
    return [NSError errorWithDomain:@"TTIOFastqReaderErrorDomain" code:2
                           userInfo:@{ NSLocalizedDescriptionKey : msg }];
}

/* Parse a slice of whole 4-line records. phred: 33/64 convert, 0 =
 * detect from this slice's qualities into *detectOut. */
static TTIOWrittenGenomicRun *ppParseSlice(NSData *slice, uint8_t phred, uint8_t *detectOut,
                                           NSString *sample, NSError * __autoreleasing *err)
{
    const uint8_t *b = slice.bytes;
    NSUInteger n = slice.length;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSMutableArray<NSNumber *> *lengths = [NSMutableArray array];
    NSMutableData *seqBuf = [NSMutableData dataWithCapacity:n / 2];
    NSMutableData *qualBuf = [NSMutableData dataWithCapacity:n / 2];
    unsigned long long running = 0;
    NSUInteger i = 0;
    while (i < n) {
        /* Header */
        if (b[i] != '@') { if (err) *err = ppError(@"slice does not start a record"); return nil; }
        NSUInteger hs = i + 1, he = hs;
        while (he < n && b[he] != '\n') he++;
        if (he >= n) { if (err) *err = ppError(@"truncated header in slice"); return nil; }
        NSUInteger ne = hs;
        while (ne < he && b[ne] != ' ' && b[ne] != '\t') ne++;
        NSString *name = [[NSString alloc] initWithBytes:b + hs length:ne - hs
                                                encoding:NSUTF8StringEncoding];
        if (name.length == 0) { if (err) *err = ppError(@"FASTQ header missing a name token"); return nil; }
        /* Sequence */
        NSUInteger ss = he + 1, se = ss;
        while (se < n && b[se] != '\n') se++;
        if (se >= n) { if (err) *err = ppError(@"truncated sequence in slice"); return nil; }
        /* Separator */
        NSUInteger ps = se + 1;
        if (ps >= n || b[ps] != '+') { if (err) *err = ppError(@"missing + separator"); return nil; }
        NSUInteger pe = ps;
        while (pe < n && b[pe] != '\n') pe++;
        if (pe >= n) { if (err) *err = ppError(@"truncated separator in slice"); return nil; }
        /* Qualities */
        NSUInteger qs = pe + 1, qe = qs;
        while (qe < n && b[qe] != '\n') qe++;
        if (qe >= n) { if (err) *err = ppError(@"truncated qualities in slice"); return nil; }
        if (qe - qs != se - ss) {
            if (err) *err = ppError([NSString stringWithFormat:
                @"SEQ/QUAL length mismatch (%lu vs %lu) for read '%@'",
                (unsigned long)(se - ss), (unsigned long)(qe - qs), name]);
            return nil;
        }
        [names addObject:name];
        [offsets addObject:@(running)];
        [lengths addObject:@((uint32_t)(se - ss))];
        [seqBuf appendBytes:b + ss length:se - ss];
        [qualBuf appendBytes:b + qs length:qe - qs];
        running += se - ss;
        i = qe + 1;
    }
    uint8_t effective = phred;
    if (effective == 0) {
        effective = [TTIOFastqReader detectPhredOffsetFromBytes:qualBuf];
        if (detectOut) *detectOut = effective;
    }
    if (effective == 64) {
        uint8_t *q = qualBuf.mutableBytes;
        for (NSUInteger j = 0; j < qualBuf.length; j++) q[j] = (uint8_t)((q[j] - 31) & 0xFF);
    }
    return TTIOFastaReaderBuildUnalignedRun(names, [seqBuf copy], [qualBuf copy],
                                            offsets, lengths, sample, @"", @"",
                                            TTIOAcquisitionModeGenomicWGS);
}

@implementation TTIOFastqParallelProducer

+ (TTIOGenomicBatchProducer)pipelineProducerForPath:(NSString *)path
                                         sampleName:(NSString *)sampleName
                                         batchReads:(NSUInteger)batchReads
                                         batchBytes:(unsigned long long)batchBytes
                                            threads:(NSUInteger)threads
                                           progress:(TTIOProgressBlock)progress
{
    NSUInteger effReads = batchReads > 0 ? batchReads : TTIOFastqReaderDefaultBatchReads;
    unsigned long long effBytes = batchBytes > 0 ? batchBytes : TTIOFastqReaderDefaultBatchBytes;
    NSString *sample = sampleName ?: @"";
    TTIOProgressBlock sink = progress ?: TTIOProgressDiscard();
    return ^BOOL(BOOL (^emit)(TTIOWrittenGenomicRun *, NSError **), NSError **error) {
        gzFile fh = gzopen([path fileSystemRepresentation], "rb");
        if (fh == NULL) {
            if (error) *error = ppError([NSString stringWithFormat:@"could not open %@", path]);
            return NO;
        }
        TTIOThreadPool *pool = [TTIOThreadPool poolWithThreads:threads];
        TTIOOrderedBatchAssembler *asm_ = [[TTIOOrderedBatchAssembler alloc] initWithPool:pool];
        NSUInteger window = threads + 2;
        __block uint8_t detected = 0;
        NSMutableData *carry = [NSMutableData dataWithCapacity:2u << 20];
        NSUInteger scanPos = 0, newlines = 0, lastRecordEnd = 0, recordsInCarry = 0;
        unsigned long long totalRecords = 0;
        NSUInteger seq = 0, pulled = 0;
        BOOL ok = YES, sawEof = NO;
        NSError *loopErr = nil;

        BOOL (^pullOne)(void) = ^BOOL {
            BOOL done = NO;
            NSError *pe = nil;
            TTIOWrittenGenomicRun *batch = [asm_ nextBatchWithError:&pe done:&done];
            if (done) return YES;
            if (batch == nil) {
                if (error && *error == nil) *error = pe ?: ppError(@"batch parse failed");
                return NO;
            }
            NSError *ee = nil;
            if (!emit(batch, &ee)) {
                if (error && *error == nil) *error = ee;
                return NO;
            }
            return YES;
        };

        uint8_t *chunk = malloc(1u << 20);
        if (chunk == NULL) { gzclose(fh); [pool close];
            if (error) *error = ppError(@"out of memory"); return NO; }
        while (ok && !sawEof) {
            @autoreleasepool {
                int got = gzread(fh, chunk, 1u << 20);
                if (got < 0) { loopErr = ppError(@"gzread failed"); ok = NO; break; }
                if (got == 0) { sawEof = YES; }
                else [carry appendBytes:chunk length:(NSUInteger)got];
                const uint8_t *cb = carry.bytes;
                NSUInteger cn = carry.length;
                for (NSUInteger i2 = scanPos; i2 < cn; i2++) {
                    if (cb[i2] != '\n') continue;
                    newlines++;
                    if ((newlines & 3) == 0) { lastRecordEnd = i2 + 1; recordsInCarry++; totalRecords++; }
                }
                scanPos = cn;
                BOOL cut = recordsInCarry > 0 &&
                    (recordsInCarry >= effReads || (unsigned long long)lastRecordEnd >= effBytes || sawEof);
                if (cut) {
                    NSData *slice = [carry subdataWithRange:NSMakeRange(0, lastRecordEnd)];
                    [carry replaceBytesInRange:NSMakeRange(0, lastRecordEnd) withBytes:NULL length:0];
                    scanPos -= lastRecordEnd;
                    lastRecordEnd = 0;
                    recordsInCarry = 0;
                    if (seq == 0) {
                        /* First slice on the caller: it detects the
                         * Phred offset every later slice applies, then
                         * enters the assembler as a ready slot so the
                         * consumer has one ordered path. */
                        NSError *pe = nil;
                        uint8_t det = 0;
                        TTIOWrittenGenomicRun *first = ppParseSlice(slice, 0, &det, sample, &pe);
                        if (first == nil) { loopErr = pe; ok = NO; }
                        else {
                            detected = det;
                            TTIOWrittenGenomicRun *cap = first;
                            [asm_ submitSlot:0 producer:^TTIOWrittenGenomicRun *(NSError * __autoreleasing *e2) {
                                (void)e2;
                                return cap;
                            }];
                        }
                        seq = 1;
                    } else {
                        uint8_t ph = detected;
                        [asm_ submitSlot:seq producer:^TTIOWrittenGenomicRun *(NSError * __autoreleasing *pe) {
                            @autoreleasepool {
                                return ppParseSlice(slice, ph, NULL, sample, pe);
                            }
                        }];
                        seq++;
                        while (ok && seq - pulled >= window) {
                            if (!pullOne()) { ok = NO; }
                            else pulled++;
                        }
                    }
                    sink((int64_t)totalRecords, (int64_t)-1);
                }
            }
        }
        free(chunk);
        if (ok && carry.length > 0) {
            loopErr = ppError(@"truncated record at end of file");
            ok = NO;
        }
        gzclose(fh);
        [asm_ finishAfterSlots:seq];
        while (ok && pulled < seq) {
            @autoreleasepool {
                if (!pullOne()) ok = NO;
                else pulled++;
            }
        }
        [pool close];
        if (!ok) {
            if (loopErr && error && *error == nil) *error = loopErr;
            return NO;
        }
        if (totalRecords == 0) {
            if (error) *error = ppError([NSString stringWithFormat:@"no FASTQ records found in %@", path]);
            return NO;
        }
        sink((int64_t)totalRecords, (int64_t)totalRecords);
        return YES;
    };
}

@end

/* Qualities of the complete records inside a probe window, for Phred
 * detection; nil when the window holds no complete record. */
static NSData *ppProbeQuals(NSData *probe)
{
    const uint8_t *b = probe.bytes;
    NSUInteger n = probe.length;
    NSMutableData *quals = [NSMutableData data];
    NSUInteger i = 0;
    while (i < n && b[i] == '@') {
        NSUInteger he = i;
        while (he < n && b[he] != '\n') he++;
        if (he >= n) break;
        NSUInteger se = he + 1;
        while (se < n && b[se] != '\n') se++;
        if (se >= n) break;
        NSUInteger pe = se + 1;
        while (pe < n && b[pe] != '\n') pe++;
        if (pe >= n) break;
        NSUInteger qs = pe + 1, qe = qs;
        while (qe < n && b[qe] != '\n') qe++;
        if (qe >= n) break;
        [quals appendBytes:b + qs length:qe - qs];
        i = qe + 1;
    }
    return quals.length > 0 ? quals : nil;
}

@implementation TTIOFastqParallelProducer (Shard)

+ (TTIOGenomicBatchProducer)shardProducerForPath:(NSString *)path
                                      sampleName:(NSString *)sampleName
                                      batchReads:(NSUInteger)batchReads
                                      batchBytes:(unsigned long long)batchBytes
                                         threads:(NSUInteger)threads
                                        progress:(TTIOProgressBlock)progress
{
    NSUInteger effReads = batchReads > 0 ? batchReads : TTIOFastqReaderDefaultBatchReads;
    unsigned long long effBytes = batchBytes > 0 ? batchBytes : TTIOFastqReaderDefaultBatchBytes;
    NSString *sample = sampleName ?: @"";
    TTIOProgressBlock sink = progress ?: TTIOProgressDiscard();
    return ^BOOL(BOOL (^emit)(TTIOWrittenGenomicRun *, NSError **), NSError **error) {
        NSDictionary *att = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        unsigned long long len = att.fileSize;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (fh == nil) {
            if (error) *error = ppError([NSString stringWithFormat:@"could not open %@", path]);
            return NO;
        }
        /* Tiny files gain nothing from sharding. */
        if (threads < 2 || len < 2ull * effBytes) {
            [fh closeFile];
            TTIOGenomicBatchProducer p = [self pipelineProducerForPath:path sampleName:sample
                                                            batchReads:batchReads batchBytes:batchBytes
                                                               threads:threads progress:progress];
            return p(emit, error);
        }
        /* Phred detection from the head of the file. */
        [fh seekToFileOffset:0];
        NSData *probe = [fh readDataOfLength:(NSUInteger)MIN(len, (unsigned long long)(1u << 20))];
        NSData *probeQuals = ppProbeQuals(probe);
        if (probeQuals == nil) {
            probe = nil;
            [fh seekToFileOffset:0];
            probe = [fh readDataOfLength:(NSUInteger)MIN(len, (unsigned long long)(16u << 20))];
            probeQuals = ppProbeQuals(probe);
        }
        if (probeQuals == nil) {
            [fh closeFile];
            TTIOGenomicBatchProducer p = [self pipelineProducerForPath:path sampleName:sample
                                                            batchReads:batchReads batchBytes:batchBytes
                                                               threads:threads progress:progress];
            return p(emit, error);
        }
        uint8_t detected = [TTIOFastqReader detectPhredOffsetFromBytes:probeQuals];
        probe = nil;
        /* Range boundaries on record starts, monotone. */
        NSUInteger T = threads;
        unsigned long long *bounds = malloc(sizeof(unsigned long long) * (T + 1));
        if (bounds == NULL) { [fh closeFile];
            if (error) *error = ppError(@"out of memory"); return NO; }
        bounds[0] = 0;
        for (NSUInteger k = 1; k < T; k++) {
            long long b = [TTIOFastqRecordScanner boundaryAtOrAfter:(long long)((len * k) / T)
                                                             inFile:fh
                                                         fileLength:(long long)len];
            bounds[k] = (unsigned long long)b;
            if (bounds[k] < bounds[k - 1]) bounds[k] = bounds[k - 1];
        }
        bounds[T] = len;
        [fh closeFile];
        unsigned long long budget =
            [TTIOThreads resolveMemoryBudget:nil threads:threads blockBytes:(64u << 20)] / 2ull;
        TTIOThreadPool *pool = [TTIOThreadPool poolWithThreads:threads];
        TTIOOrderedBatchAssembler *asm_ = [[TTIOOrderedBatchAssembler alloc] initWithPool:pool];
        const char *cpath = strdup([path fileSystemRepresentation]);
        for (NSUInteger k = 0; k < T; k++) {
            unsigned long long start = bounds[k], end = bounds[k + 1];
            if (start >= end) { [asm_ finishMajor:k afterMinors:0]; continue; }
            NSUInteger major = k;
            uint8_t ph = detected;
            [pool.queue addOperationWithBlock:^{
                FILE *fp = fopen(cpath, "rb");
                NSUInteger minor = 0;
                if (fp == NULL) {
                    [asm_ submitReadyMajor:major minor:minor run:nil
                                     error:ppError(@"could not open shard")
                            estimatedBytes:0 parkBudget:budget];
                    [asm_ finishMajor:major afterMinors:minor + 1];
                    return;
                }
                fseeko(fp, (off_t)start, SEEK_SET);
                unsigned long long remaining = end - start;
                NSMutableData *carry = [NSMutableData dataWithCapacity:2u << 20];
                NSUInteger scanPos = 0, newlines = 0, lastRecordEnd = 0, recordsInCarry = 0;
                uint8_t *chunk = malloc(1u << 20);
                BOOL bad = NO;
                while (!bad && (remaining > 0 || carry.length > 0)) {
                    @autoreleasepool {
                        if (remaining > 0 && chunk != NULL) {
                            size_t want = (size_t)MIN(remaining, (unsigned long long)(1u << 20));
                            size_t got = fread(chunk, 1, want, fp);
                            if (got == 0) { bad = YES; break; }
                            [carry appendBytes:chunk length:got];
                            remaining -= got;
                        }
                        const uint8_t *cb = carry.bytes;
                        NSUInteger cn = carry.length;
                        for (NSUInteger i2 = scanPos; i2 < cn; i2++) {
                            if (cb[i2] != '\n') continue;
                            newlines++;
                            if ((newlines & 3) == 0) { lastRecordEnd = i2 + 1; recordsInCarry++; }
                        }
                        scanPos = cn;
                        BOOL atEnd = remaining == 0;
                        BOOL cut = recordsInCarry > 0 &&
                            (recordsInCarry >= effReads
                             || (unsigned long long)lastRecordEnd >= effBytes
                             || atEnd);
                        if (cut) {
                            NSData *slice = [carry subdataWithRange:NSMakeRange(0, lastRecordEnd)];
                            [carry replaceBytesInRange:NSMakeRange(0, lastRecordEnd) withBytes:NULL length:0];
                            scanPos -= lastRecordEnd;
                            lastRecordEnd = 0;
                            recordsInCarry = 0;
                            NSError *pe = nil;
                            TTIOWrittenGenomicRun *run = ppParseSlice(slice, ph, NULL, sample, &pe);
                            [asm_ submitReadyMajor:major minor:minor run:run error:pe
                                    estimatedBytes:(unsigned long long)slice.length * 3ull
                                        parkBudget:budget];
                            minor++;
                            if (run == nil) { bad = YES; }
                        } else if (atEnd && carry.length > 0) {
                            /* Both bounds are record starts, so a shard
                             * never ends mid-record. */
                            [asm_ submitReadyMajor:major minor:minor run:nil
                                             error:ppError(@"shard ended mid-record")
                                    estimatedBytes:0 parkBudget:budget];
                            minor++;
                            bad = YES;
                        }
                    }
                }
                free(chunk);
                fclose(fp);
                [asm_ finishMajor:major afterMinors:minor];
            }];
        }
        [asm_ finishAfterMajors:T];
        free(bounds);
        unsigned long long totalRecords = 0;
        BOOL ok = YES;
        while (1) {
            @autoreleasepool {
                BOOL done = NO;
                NSError *pe = nil;
                TTIOWrittenGenomicRun *batch = [asm_ nextOrderedBatchWithError:&pe done:&done];
                if (done) break;
                if (batch == nil) {
                    if (ok && error && *error == nil) *error = pe ?: ppError(@"shard parse failed");
                    ok = NO;
                    continue;   /* keep draining so parked workers finish */
                }
                if (!ok) continue;
                totalRecords += batch.readCount;
                NSError *ee = nil;
                if (!emit(batch, &ee)) {
                    if (error && *error == nil) *error = ee;
                    ok = NO;
                }
                sink((int64_t)totalRecords, (int64_t)-1);
            }
        }
        [pool close];
        free((void *)cpath);
        if (!ok) return NO;
        if (totalRecords == 0) {
            if (error) *error = ppError([NSString stringWithFormat:@"no FASTQ records found in %@", path]);
            return NO;
        }
        sink((int64_t)totalRecords, (int64_t)totalRecords);
        return YES;
    };
}

@end
