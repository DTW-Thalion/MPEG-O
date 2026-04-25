/*
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOWrittenRun.h"

@implementation TTIOWrittenRun

- (instancetype)initWithSpectrumClassName:(NSString *)spectrumClassName
                          acquisitionMode:(int64_t)acquisitionMode
                              channelData:(NSDictionary<NSString *, NSData *> *)channelData
                                  offsets:(NSData *)offsets
                                  lengths:(NSData *)lengths
                           retentionTimes:(NSData *)retentionTimes
                                 msLevels:(NSData *)msLevels
                               polarities:(NSData *)polarities
                             precursorMzs:(NSData *)precursorMzs
                         precursorCharges:(NSData *)precursorCharges
                      basePeakIntensities:(NSData *)basePeakIntensities
{
    self = [super init];
    if (!self) return nil;
    _spectrumClassName = [spectrumClassName copy];
    _acquisitionMode = acquisitionMode;
    _channelData = [channelData copy];
    _offsets = [offsets copy];
    _lengths = [lengths copy];
    _retentionTimes = [retentionTimes copy];
    _msLevels = [msLevels copy];
    _polarities = [polarities copy];
    _precursorMzs = [precursorMzs copy];
    _precursorCharges = [precursorCharges copy];
    _basePeakIntensities = [basePeakIntensities copy];
    _nucleusType = @"";
    _signalCompression = @"gzip";
    return self;
}

@end
