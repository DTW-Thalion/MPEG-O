/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Import/TTIOSpectralStreamSource.h"
#import "Run/TTIOSpectralStreamWriter.h"
#import "Run/TTIOWrittenSpectralBatch.h"

@implementation TTIOSpectralStreamSource

- (instancetype)initWithName:(NSString *)name
                     batches:(TTIOSpectralBatchProducer)batches
             acquisitionMode:(TTIOAcquisitionMode)mode
            instrumentConfig:(TTIOInstrumentConfig *)config
                batchSpectra:(NSUInteger)batchSpectra
          chromatogramsAfter:(NSArray<TTIOChromatogram *> *(^)(void))chromatogramsAfter
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _batches = [batches copy];
        _acquisitionMode = mode;
        _instrumentConfig = config;
        _batchSpectra = MAX(batchSpectra, (NSUInteger)1);
        _chromatogramsAfter = [chromatogramsAfter copy];
    }
    return self;
}

- (NSUInteger)writeIntoStudy:(id<TTIOStorageGroup>)study
                    progress:(TTIOProgressBlock)progress
                       error:(NSError **)error
{
    TTIOProgressBlock sink = progress ?: TTIOProgressDiscard();
    __block TTIOSpectralStreamWriter *writer = nil;
    __block unsigned long long n = 0;
    BOOL ok = _batches(^BOOL(TTIOWrittenSpectralBatch *b, NSError **innerError) {
        if (writer == nil) {
            NSArray *names = [[b.channelData allKeys] sortedArrayUsingSelector:@selector(compare:)];
            TTIOSpectralStreamWriterOptions *o =
                [TTIOSpectralStreamWriterOptions msOptionsWithMode:self->_acquisitionMode
                                                      channelNames:names
                                                  instrumentConfig:self->_instrumentConfig];
            o.batchSpectra = self->_batchSpectra;
            writer = [[TTIOSpectralStreamWriter alloc] initWithStudyGroup:study
                                                                  runName:self->_name
                                                                  options:o];
        }
        if (![writer appendBatch:b error:innerError]) return NO;
        n += b.spectrumCount;
        sink((int64_t)n, -1);
        return YES;
    }, error);
    if (!ok) return NSNotFound;
    if (writer) {
        if (_chromatogramsAfter) [writer setChromatograms:_chromatogramsAfter()];
        if (![writer close:error]) return NSNotFound;
    }
    sink((int64_t)n, (int64_t)n);
    return (NSUInteger)n;
}

@end
