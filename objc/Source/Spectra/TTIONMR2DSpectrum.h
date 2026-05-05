#ifndef TTIO_NMR_2D_SPECTRUM_H
#define TTIO_NMR_2D_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOAxisDescriptor;

/**
 * <p><em>Inherits From:</em> TTIOSpectrum : NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIONMR2DSpectrum.h</p>
 *
 * <p>2-D NMR spectrum (e.g. HSQC, COSY, NOESY): a row-major float64
 * intensity matrix of <code>width &#215; height</code> points
 * plus F1 and F2 axis descriptors and per-axis nucleus identifiers.</p>
 *
 * <p>The matrix is stored as a flattened 1-D dataset with the
 * shape recorded in scalar attributes; this is sufficient for
 * round-trip fidelity and keeps the provider API surface small.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.nmr_2d.NMR2DSpectrum</code><br/>
 * Java: <code>global.thalion.ttio.NMR2DSpectrum</code></p>
 */
@interface TTIONMR2DSpectrum : TTIOSpectrum

/** Row-major float64 intensity matrix. */
@property (readonly, copy) NSData *intensityMatrix;

/** F2 (column) point count. */
@property (readonly) NSUInteger width;

/** F1 (row) point count. */
@property (readonly) NSUInteger height;

/** F1 axis descriptor. */
@property (readonly, strong) TTIOAxisDescriptor *f1Axis;

/** F2 axis descriptor. */
@property (readonly, strong) TTIOAxisDescriptor *f2Axis;

/** Nucleus on F1 (e.g. <code>@"1H"</code>). */
@property (readonly, copy) NSString *nucleusF1;

/** Nucleus on F2 (e.g. <code>@"13C"</code>). */
@property (readonly, copy) NSString *nucleusF2;

/**
 * Designated initialiser.
 *
 * @param matrix        Row-major float64 buffer of
 *                      <code>width * height * 8</code> bytes.
 * @param width         F2 point count.
 * @param height        F1 point count.
 * @param f1            F1 axis descriptor.
 * @param f2            F2 axis descriptor.
 * @param nucleusF1     Nucleus on F1.
 * @param nucleusF2     Nucleus on F2.
 * @param indexPosition Position in parent run.
 * @param error         Out-parameter populated on failure.
 * @return An initialised spectrum, or <code>nil</code> on failure.
 */
- (instancetype)initWithIntensityMatrix:(NSData *)matrix
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                 f1Axis:(TTIOAxisDescriptor *)f1
                                 f2Axis:(TTIOAxisDescriptor *)f2
                              nucleusF1:(NSString *)nucleusF1
                              nucleusF2:(NSString *)nucleusF2
                          indexPosition:(NSUInteger)indexPosition
                                  error:(NSError **)error;

@end

#endif
