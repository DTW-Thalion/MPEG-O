#ifndef MPGO_JCAMP_DX_WRITER_H
#define MPGO_JCAMP_DX_WRITER_H

#import <Foundation/Foundation.h>

@class MPGORamanSpectrum;
@class MPGOIRSpectrum;

/**
 * JCAMP-DX 5.01 writer for 1-D vibrational spectra.
 *
 * Emits AFFN-format `##XYDATA=(X++(Y..Y))` blocks — plain ASCII
 * floats, no PAC/SQZ/DIF compression. Header is the core IUPAC
 * LDR set (TITLE, JCAMP-DX, DATA TYPE, ORIGIN, OWNER, XUNITS,
 * YUNITS, FIRSTX, LASTX, DELTAX, NPOINTS, XFACTOR, YFACTOR).
 * Modality-specific scalars travel as user-defined `##$` labels
 * so they round-trip without polluting the IUPAC namespace.
 *
 * 2-D / imaging cubes are NOT supported — use HDF5 round-trip for
 * RamanImage / IRImage, or wait for M73.1 NTUPLES support.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.exporters.jcamp_dx.write_spectrum
 *   Java:   com.dtwthalion.mpgo.exporters.JcampDxWriter
 */
@interface MPGOJcampDxWriter : NSObject

+ (BOOL)writeRamanSpectrum:(MPGORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

+ (BOOL)writeIRSpectrum:(MPGOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
                  error:(NSError **)error;

@end

#endif
