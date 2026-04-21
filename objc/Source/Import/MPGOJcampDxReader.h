#ifndef MPGO_JCAMP_DX_READER_H
#define MPGO_JCAMP_DX_READER_H

#import <Foundation/Foundation.h>

@class MPGOSpectrum;

/**
 * JCAMP-DX 5.01 reader for 1-D vibrational and UV-Vis spectra.
 * Dispatches on `##DATA TYPE=` to return one of MPGORamanSpectrum,
 * MPGOIRSpectrum, or MPGOUVVisSpectrum; unknown data types return nil
 * with an error.
 *
 * Accepts both dialects of `##XYDATA=(X++(Y..Y))`:
 *   - AFFN (fast path) — one (X, Y) pair per line, free-format decimals.
 *   - PAC / SQZ / DIF / DUP — JCAMP-DX 5.01 §5.9 character-encoded
 *     Y-stream (delegated to MPGOJcampDxDecode). Requires FIRSTX /
 *     LASTX / NPOINTS.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.importers.jcamp_dx.read_spectrum
 *   Java:   com.dtwthalion.mpgo.importers.JcampDxReader
 */
@interface MPGOJcampDxReader : NSObject

/** Returns MPGORamanSpectrum, MPGOIRSpectrum, MPGOUVVisSpectrum, or nil. */
+ (MPGOSpectrum *)readSpectrumFromPath:(NSString *)path error:(NSError **)error;

@end

#endif
