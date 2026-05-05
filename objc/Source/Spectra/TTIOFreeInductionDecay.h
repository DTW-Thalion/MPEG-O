#ifndef TTIO_FID_H
#define TTIO_FID_H

#import "Core/TTIOSignalArray.h"

/**
 * <p><em>Inherits From:</em> TTIOSignalArray : NSObject</p>
 * <p><em>Conforms To:</em> TTIOCVAnnotatable (inherited)</p>
 * <p><em>Declared In:</em> Spectra/TTIOFreeInductionDecay.h</p>
 *
 * <p>NMR free-induction decay. Subclass of <code>TTIOSignalArray</code>
 * that uses the <code>Complex128</code> precision (interleaved real
 * / imag doubles) plus FID-specific acquisition metadata: dwell
 * time, scan count, receiver gain.</p>
 *
 * <p>Length is the number of complex points (i.e. half the number
 * of doubles in the buffer).</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.fid.FreeInductionDecay</code><br/>
 * Java: <code>global.thalion.ttio.FreeInductionDecay</code></p>
 */
@interface TTIOFreeInductionDecay : TTIOSignalArray

/** Inter-sample dwell time in seconds. */
@property (readonly) double dwellTimeSeconds;

/** Number of accumulated scans (FTIR-style averaging). */
@property (readonly) NSUInteger scanCount;

/** Receiver gain. */
@property (readonly) double receiverGain;

/**
 * Designated initialiser.
 *
 * @param buffer            Complex128-interleaved bytes of length
 *                          <code>length * 16</code>.
 * @param length            Number of complex points.
 * @param dwell             Inter-sample dwell time in seconds.
 * @param scanCount         Accumulated-scan count.
 * @param gain              Receiver gain.
 * @return An initialised FID.
 */
- (instancetype)initWithComplexBuffer:(NSData *)buffer
                        complexLength:(NSUInteger)length
                     dwellTimeSeconds:(double)dwell
                            scanCount:(NSUInteger)scanCount
                         receiverGain:(double)gain;

@end

#endif
