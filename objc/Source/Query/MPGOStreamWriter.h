#ifndef MPGO_STREAM_WRITER_H
#define MPGO_STREAM_WRITER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/MPGOEnums.h"

@class MPGOMassSpectrum;
@class MPGOInstrumentConfig;

/**
 * Incrementally append mass spectra to an `.mpgo` file.
 *
 * Spectra accumulate in memory until -flushWithError: is called. On each
 * flush the file is rewritten so that the run group reflects every
 * spectrum buffered so far — the file remains a valid .mpgo after each
 * flush, satisfying the streaming-write acceptance criterion. Calling
 * -flushAndCloseWithError: flushes one final time and tears down.
 *
 * For v0.1 the writer's flush is whole-file regenerative: simple,
 * correct, and bounded for the streaming-demo case (≤ a few thousand
 * spectra). A future milestone may switch to extendable HDF5 datasets.
 */
@interface MPGOStreamWriter : NSObject

- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                 acquisitionMode:(MPGOAcquisitionMode)mode
                instrumentConfig:(MPGOInstrumentConfig *)config
                           error:(NSError **)error;

- (BOOL)appendSpectrum:(MPGOMassSpectrum *)spectrum error:(NSError **)error;

- (BOOL)flushWithError:(NSError **)error;
- (BOOL)flushAndCloseWithError:(NSError **)error;

@property (readonly) NSUInteger spectrumCount;

@end

#endif
