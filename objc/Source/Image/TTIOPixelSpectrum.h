#ifndef TTIO_PIXEL_SPECTRUM_H
#define TTIO_PIXEL_SPECTRUM_H

#import <Foundation/Foundation.h>

/**
 * A single pixel from an MSImage projected as a (mz, intensity) record.
 *
 * <p>Output format of {@code -[TTIOMSImage pixelSpectra]}; consumed by
 * the imzML writer (continuous mode -- every pixel shares the same
 * <code>mz</code> NSData buffer).</p>
 */
@interface TTIOPixelSpectrum : NSObject

@property (readonly) NSUInteger x;
@property (readonly) NSUInteger y;
@property (readonly) NSUInteger z;

/** Length-spectralPoints float64 m/z values. Shared across pixels in
 *  continuous mode. */
@property (readonly, strong) NSData *mz;

/** Length-spectralPoints float64 intensity values. */
@property (readonly, copy) NSData *intensity;

- (instancetype)initWithX:(NSUInteger)x
                        y:(NSUInteger)y
                        z:(NSUInteger)z
                       mz:(NSData *)mz
                intensity:(NSData *)intensity;

@end

#endif
