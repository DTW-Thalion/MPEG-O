#ifndef TTIO_FID_H
#define TTIO_FID_H

#import "Core/TTIOSignalArray.h"

/**
 * NMR free-induction decay. Subclass of TTIOSignalArray that uses the
 * Complex128 precision (interleaved real/imag doubles) plus FID-specific
 * acquisition metadata: dwell time, scan count, receiver gain.
 *
 * Length is the number of complex points (i.e. half the number of
 * doubles in the buffer).
 *
 * Cross-language equivalents:
 *   Python: ttio.fid.FreeInductionDecay
 *   Java:   global.thalion.ttio.FreeInductionDecay
 */
@interface TTIOFreeInductionDecay : TTIOSignalArray

@property (readonly) double     dwellTimeSeconds;
@property (readonly) NSUInteger scanCount;
@property (readonly) double     receiverGain;

- (instancetype)initWithComplexBuffer:(NSData *)buffer
                          complexLength:(NSUInteger)length
                       dwellTimeSeconds:(double)dwell
                              scanCount:(NSUInteger)scanCount
                           receiverGain:(double)gain;

@end

#endif
