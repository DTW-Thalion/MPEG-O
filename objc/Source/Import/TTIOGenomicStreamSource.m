/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Import/TTIOGenomicStreamSource.h"
#import "Genomics/TTIOGenomicStreamWriter.h"
#import "Core/TTIOThreads.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOLazyReference.h"

@implementation TTIOGenomicStreamSource

- (instancetype)initWithName:(NSString *)name
                     batches:(TTIOGenomicBatchProducer)batches
              referenceFasta:(NSString *)referenceFasta
              embedReference:(BOOL)embedReference
                  blockReads:(NSNumber *)blockReads
                  blockBytes:(NSNumber *)blockBytes
       optLegacyWholeChannel:(BOOL)legacy
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _batches = [batches copy];
        _referenceFasta = [referenceFasta copy];
        _embedReference = embedReference;
        _blockReads = [blockReads copy];
        _blockBytes = [blockBytes copy];
        _optLegacyWholeChannel = legacy;
    }
    return self;
}

- (instancetype)sourceWithBlockReads:(NSNumber *)blockReads
                          blockBytes:(NSNumber *)blockBytes
                              legacy:(BOOL)legacy
{
    return [[TTIOGenomicStreamSource alloc] initWithName:_name batches:_batches
                                          referenceFasta:_referenceFasta
                                          embedReference:_embedReference
                                              blockReads:blockReads
                                              blockBytes:blockBytes
                                   optLegacyWholeChannel:legacy];
}

- (NSUInteger)writeIntoStudy:(id<TTIOStorageGroup>)study
                    progress:(TTIOProgressBlock)progress
                       error:(NSError **)error
{
    TTIOProgressBlock sink = progress ?: TTIOProgressDiscard();
    TTIOLazyReference *ref = nil;
    if (_referenceFasta) {
        ref = [[TTIOLazyReference alloc] initWithFastaPath:_referenceFasta error:error];
        if (!ref) return NSNotFound;
    }
    __block TTIOGenomicStreamWriter *writer = nil;
    __block unsigned long long n = 0;
    BOOL ok = _batches(^BOOL(TTIOWrittenGenomicRun *batch, NSError **innerError) {
        if (writer == nil) {
            TTIOGenomicStreamWriterOptions *o = [TTIOGenomicStreamWriterOptions optionsFromRun:batch];
            if (ref) {
                o.referenceChromSeqs = ref;
                o.embedReference = self->_embedReference || batch.embedReference;
            }
            if (self->_blockReads) o.blockReads = [self->_blockReads unsignedIntegerValue];
            if (self->_blockBytes) o.blockBytes = [self->_blockBytes unsignedLongLongValue];
            if (self->_optLegacyWholeChannel) o.optLegacyWholeChannel = YES;
            /* Same rule as the producer side, so the two halves of the
             * budget are sized off one count rather than two. */
            if (o.threads == 0) o.threads = [TTIOThreads resolveImportThreads];
            writer = [[TTIOGenomicStreamWriter alloc] initWithStudyGroup:study
                                                                 runName:self->_name
                                                                 options:o];
        }
        if (![writer appendBatch:batch error:innerError]) return NO;
        n += batch.readCount;
        sink((int64_t)n, -1);
        return YES;
    }, error);
    if (!ok) return NSNotFound;
    if (writer && ![writer close:error]) return NSNotFound;
    sink((int64_t)n, (int64_t)n);
    return (NSUInteger)n;
}

@end
