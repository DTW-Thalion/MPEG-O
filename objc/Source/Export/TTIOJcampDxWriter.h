#ifndef TTIO_JCAMP_DX_WRITER_H
#define TTIO_JCAMP_DX_WRITER_H

#import <Foundation/Foundation.h>
#import "TTIOJcampDxEncoding.h"

@class TTIORamanSpectrum;
@class TTIOIRSpectrum;
@class TTIOUVVisSpectrum;

/**
 * <heading>TTIOJcampDxWriter</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOJcampDxWriter.h</p>
 *
 * <p>JCAMP-DX 5.01 writer for one-dimensional vibrational spectra
 * (Raman / IR / UV-Vis).</p>
 *
 * <p>Two <code>##XYDATA=(X++(Y..Y))</code> encoding families are
 * supported:</p>
 *
 * <ul>
 *  <li><strong>AFFN</strong> (default): one free-format
 *      (X, Y) pair per line.</li>
 *  <li><strong>PAC / SQZ / DIF</strong> (JCAMP-DX 5.01 §5.9):
 *      compressed forms. Equispaced X is required; a shared YFACTOR
 *      is chosen to carry approximately seven significant digits of
 *      integer-scaled Y precision. Byte-for-byte identical to the
 *      Python and Java writers, gated by the fixtures under
 *      <code>conformance/jcamp_dx/</code>.</li>
 * </ul>
 *
 * <p>2-D / imaging cubes are not supported &mdash; use HDF5
 * round-trip for <code>RamanImage</code> / <code>IRImage</code>, or
 * wait for NTUPLES support.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.jcamp_dx.write_*_spectrum</code><br/>
 * Java:
 * <code>global.thalion.ttio.exporters.JcampDxWriter</code></p>
 */
@interface TTIOJcampDxWriter : NSObject

#pragma mark - AFFN (default)

/**
 * Writes a Raman spectrum in AFFN encoding.
 *
 * @param spec  Raman spectrum to serialise.
 * @param path  Destination path.
 * @param title <code>##TITLE=</code> value for the LDR header.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeRamanSpectrum:(TTIORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

/**
 * Writes an IR spectrum in AFFN encoding.
 *
 * @param spec  IR spectrum to serialise.
 * @param path  Destination path.
 * @param title <code>##TITLE=</code> value for the LDR header.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeIRSpectrum:(TTIOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
                  error:(NSError **)error;

/**
 * Writes a UV-Vis spectrum in AFFN encoding.
 *
 * @param spec  UV-Vis spectrum to serialise.
 * @param path  Destination path.
 * @param title <code>##TITLE=</code> value for the LDR header.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeUVVisSpectrum:(TTIOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error;

#pragma mark - Encoding-aware overloads

/**
 * Writes a Raman spectrum in a caller-chosen encoding.
 *
 * @param spec     Raman spectrum.
 * @param path     Destination path.
 * @param title    LDR title.
 * @param encoding Encoding family (AFFN / PAC / SQZ / DIF).
 * @param error    Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeRamanSpectrum:(TTIORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(TTIOJcampDxEncoding)encoding
                     error:(NSError **)error;

/**
 * Writes an IR spectrum in a caller-chosen encoding.
 *
 * @param spec     IR spectrum.
 * @param path     Destination path.
 * @param title    LDR title.
 * @param encoding Encoding family.
 * @param error    Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeIRSpectrum:(TTIOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
               encoding:(TTIOJcampDxEncoding)encoding
                  error:(NSError **)error;

/**
 * Writes a UV-Vis spectrum in a caller-chosen encoding.
 *
 * @param spec     UV-Vis spectrum.
 * @param path     Destination path.
 * @param title    LDR title.
 * @param encoding Encoding family.
 * @param error    Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeUVVisSpectrum:(TTIOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(TTIOJcampDxEncoding)encoding
                     error:(NSError **)error;

@end

#endif
