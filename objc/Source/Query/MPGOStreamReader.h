#ifndef MPGO_STREAM_READER_H
#define MPGO_STREAM_READER_H

#import <Foundation/Foundation.h>

@class MPGOMassSpectrum;
@class MPGOHDF5File;

/**
 * Sequential reader for an MS run stored inside an `.mpgo` file.
 * Internally wraps an MPGOAcquisitionRun read-back; -nextSpectrum:
 * advances a position counter and returns spectra one at a time via
 * the existing hyperslab path. Suitable for streaming through runs
 * larger than memory.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.stream_reader.StreamReader
 *   Java:   com.dtwthalion.mpgo.StreamReader
 */
@interface MPGOStreamReader : NSObject

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                           error:(NSError **)error;

@property (readonly) NSUInteger totalCount;
@property (readonly) NSUInteger currentPosition;

- (BOOL)atEnd;
- (MPGOMassSpectrum *)nextSpectrumWithError:(NSError **)error;
- (void)reset;

- (void)close;

@end

#endif
