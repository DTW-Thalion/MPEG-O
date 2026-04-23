#ifndef MPGO_JCAMP_DX_WRITER_H
#define MPGO_JCAMP_DX_WRITER_H

#import <Foundation/Foundation.h>
#import "MPGOJcampDxEncoding.h"

@class MPGORamanSpectrum;
@class MPGOIRSpectrum;
@class MPGOUVVisSpectrum;

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
 *   Python: mpeg_o.exporters.jcamp_dx.write_*_spectrum
 *   Java:   com.dtwthalion.mpgo.exporters.JcampDxWriter
 */
@interface MPGOJcampDxWriter : NSObject

// AFFN (default) — present since M73.
+ (BOOL)writeRamanSpectrum:(MPGORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

+ (BOOL)writeIRSpectrum:(MPGOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
                  error:(NSError **)error;

+ (BOOL)writeUVVisSpectrum:(MPGOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

// Encoding-aware overloads — AFFN + compressed (M76).
+ (BOOL)writeRamanSpectrum:(MPGORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(MPGOJcampDxEncoding)encoding
                     error:(NSError **)error;

+ (BOOL)writeIRSpectrum:(MPGOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
               encoding:(MPGOJcampDxEncoding)encoding
                  error:(NSError **)error;

+ (BOOL)writeUVVisSpectrum:(MPGOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(MPGOJcampDxEncoding)encoding
                     error:(NSError **)error;

@end

#endif
