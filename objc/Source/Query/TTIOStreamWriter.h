#ifndef TTIO_STREAM_WRITER_H
#define TTIO_STREAM_WRITER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOMassSpectrum;
@class TTIOInstrumentConfig;

/**
 * Incrementally append mass spectra to an `.tio` file.
 *
 * Spectra accumulate in memory until -flushWithError: is called. On each
 * flush the file is rewritten so that the run group reflects every
 * spectrum buffered so far — the file remains a valid .tio after each
 * flush, satisfying the streaming-write acceptance criterion. Calling
 * -flushAndCloseWithError: flushes one final time and tears down.
 *
 * For v0.1 the writer's flush is whole-file regenerative: simple,
 * correct, and bounded for the streaming-demo case (≤ a few thousand
 * spectra). A future milestone may switch to extendable HDF5 datasets.
 *
 * API status: Stable (flush integration pending).
 *
 * Cross-language equivalents:
 *   Python: ttio.stream_writer.StreamWriter
 *   Java:   global.thalion.ttio.StreamWriter
 */
@interface TTIOStreamWriter : NSObject

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                 acquisitionMode:(TTIOAcquisitionMode)mode
                instrumentConfig:(TTIOInstrumentConfig *)config
                           error:(NSError **)error;

- (BOOL)appendSpectrum:(TTIOMassSpectrum *)spectrum error:(NSError **)error;

- (BOOL)flushWithError:(NSError **)error;
- (BOOL)flushAndCloseWithError:(NSError **)error;

@property (readonly) NSUInteger spectrumCount;

@end

#endif
