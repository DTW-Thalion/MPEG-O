#ifndef MPGO_JCAMP_DX_READER_H
#define MPGO_JCAMP_DX_READER_H

#import <Foundation/Foundation.h>

@class MPGOSpectrum;

/**
 * JCAMP-DX 5.01 reader for 1-D vibrational spectra. Dispatches on
 * `##DATA TYPE=` to return either an MPGORamanSpectrum or an
 * MPGOIRSpectrum; unknown data types return nil with an error.
 *
 * Accepts the AFFN `##XYDATA=(X++(Y..Y))` dialect emitted by
 * MPGOJcampDxWriter and the more generic "one (X, Y) pair per line"
 * variant. PAC/SQZ/DIF compression is not supported in M73.
 */
@interface MPGOJcampDxReader : NSObject

/** Returns an MPGORamanSpectrum, MPGOIRSpectrum, or nil on error. */
+ (MPGOSpectrum *)readSpectrumFromPath:(NSString *)path error:(NSError **)error;

@end

#endif
