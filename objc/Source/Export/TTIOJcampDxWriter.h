#ifndef TTIO_JCAMP_DX_WRITER_H
#define TTIO_JCAMP_DX_WRITER_H

#import <Foundation/Foundation.h>
#import "TTIOJcampDxEncoding.h"

@class TTIORamanSpectrum;
@class TTIOIRSpectrum;
@class TTIOUVVisSpectrum;

/**
 * JCAMP-DX 5.01 writer for 1-D vibrational spectra.
 *
 * Two `##XYDATA=(X++(Y..Y))` encoding families are supported:
 *   - AFFN (default): one free-format (X, Y) pair per line. This is
 *     the original M73 dialect and remains the default.
 *   - PAC / SQZ / DIF (JCAMP-DX 5.01 §5.9, M76): compressed forms.
 *     Equispaced X is required; a shared YFACTOR is chosen to carry
 *     ~7 significant digits of integer-scaled Y precision.
 *     Byte-for-byte identical to the Python and Java writers,
 *     gated by the fixtures under `conformance/jcamp_dx/`.
 *
 * 2-D / imaging cubes are NOT supported — use HDF5 round-trip for
 * RamanImage / IRImage, or wait for M73.1 NTUPLES support.
 *
 * Cross-language equivalents:
 *   Python: ttio.exporters.jcamp_dx.write_*_spectrum
 *   Java:   global.thalion.ttio.exporters.JcampDxWriter
 */
@interface TTIOJcampDxWriter : NSObject

// AFFN (default) — present since M73.
+ (BOOL)writeRamanSpectrum:(TTIORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

+ (BOOL)writeIRSpectrum:(TTIOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
                  error:(NSError **)error;

+ (BOOL)writeUVVisSpectrum:(TTIOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

// Encoding-aware overloads — AFFN + compressed (M76).
+ (BOOL)writeRamanSpectrum:(TTIORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(TTIOJcampDxEncoding)encoding
                     error:(NSError **)error;

+ (BOOL)writeIRSpectrum:(TTIOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
               encoding:(TTIOJcampDxEncoding)encoding
                  error:(NSError **)error;

+ (BOOL)writeUVVisSpectrum:(TTIOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(TTIOJcampDxEncoding)encoding
                     error:(NSError **)error;

@end

#endif
