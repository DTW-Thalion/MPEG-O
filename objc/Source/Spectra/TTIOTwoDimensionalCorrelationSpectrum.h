#ifndef TTIO_TWO_D_CORRELATION_SPECTRUM_H
#define TTIO_TWO_D_CORRELATION_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOAxisDescriptor;

/**
 * 2D correlation spectrum (Noda 2D-COS): a synchronous (in-phase) and
 * an asynchronous (quadrature) rank-2 correlation matrix keyed on a
 * single spectral-variable axis (nu_1 == nu_2). Both matrices are
 * size-by-size row-major float64 buffers.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.ttio.TwoDimensionalCorrelationSpectrum
 *   Python: ttio.two_dimensional_correlation_spectrum
 *           .TwoDimensionalCorrelationSpectrum
 */
@interface TTIOTwoDimensionalCorrelationSpectrum : TTIOSpectrum

@property (readonly, copy)   NSData             *synchronousMatrix;   // float64, row-major
@property (readonly, copy)   NSData             *asynchronousMatrix;  // float64, row-major
@property (readonly)         NSUInteger          matrixSize;          // n such that matrices are n x n
@property (readonly, strong) TTIOAxisDescriptor *variableAxis;        // shared F1 = F2 axis
@property (readonly, copy)   NSString           *perturbation;
@property (readonly, copy)   NSString           *perturbationUnit;
@property (readonly, copy)   NSString           *sourceModality;      // "raman", "ir", "uv-vis", ...

- (instancetype)initWithSynchronousMatrix:(NSData *)sync
                       asynchronousMatrix:(NSData *)asyn
                               matrixSize:(NSUInteger)size
                             variableAxis:(TTIOAxisDescriptor *)axis
                             perturbation:(NSString *)perturbation
                         perturbationUnit:(NSString *)perturbationUnit
                           sourceModality:(NSString *)sourceModality
                            indexPosition:(NSUInteger)indexPosition
                                    error:(NSError **)error;

@end

#endif
