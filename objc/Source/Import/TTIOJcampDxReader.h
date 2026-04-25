#ifndef TTIO_JCAMP_DX_READER_H
#define TTIO_JCAMP_DX_READER_H

#import <Foundation/Foundation.h>

@class TTIOSpectrum;

/**
 * JCAMP-DX 5.01 reader for 1-D vibrational and UV-Vis spectra.
 * Dispatches on `##DATA TYPE=` to return one of TTIORamanSpectrum,
 * TTIOIRSpectrum, or TTIOUVVisSpectrum; unknown data types return nil
 * with an error.
 *
 * Accepts both dialects of `##XYDATA=(X++(Y..Y))`:
 *   - AFFN (fast path) — one (X, Y) pair per line, free-format decimals.
 *   - PAC / SQZ / DIF / DUP — JCAMP-DX 5.01 §5.9 character-encoded
 *     Y-stream (delegated to TTIOJcampDxDecode). Requires FIRSTX /
 *     LASTX / NPOINTS.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.jcamp_dx.read_spectrum
 *   Java:   com.dtwthalion.tio.importers.JcampDxReader
 */
@interface TTIOJcampDxReader : NSObject

/** Returns TTIORamanSpectrum, TTIOIRSpectrum, TTIOUVVisSpectrum, or nil. */
+ (TTIOSpectrum *)readSpectrumFromPath:(NSString *)path error:(NSError **)error;

@end

#endif
