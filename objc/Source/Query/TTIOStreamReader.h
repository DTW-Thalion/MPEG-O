#ifndef TTIO_STREAM_READER_H
#define TTIO_STREAM_READER_H

#import <Foundation/Foundation.h>

@class TTIOMassSpectrum;
@class TTIOHDF5File;

/**
 * Sequential reader for an MS run stored inside an `.tio` file.
 * Internally wraps an TTIOAcquisitionRun read-back; -nextSpectrum:
 * advances a position counter and returns spectra one at a time via
 * the existing hyperslab path. Suitable for streaming through runs
 * larger than memory.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.stream_reader.StreamReader
 *   Java:   global.thalion.ttio.StreamReader
 */
@interface TTIOStreamReader : NSObject

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                           error:(NSError **)error;

@property (readonly) NSUInteger totalCount;
@property (readonly) NSUInteger currentPosition;

- (BOOL)atEnd;
- (TTIOMassSpectrum *)nextSpectrumWithError:(NSError **)error;
- (void)reset;

- (void)close;

@end

#endif
