#ifndef TTIO_JCAMP_DX_READER_H
#define TTIO_JCAMP_DX_READER_H

#import <Foundation/Foundation.h>

@class TTIOSpectrum;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOJcampDxReader.h</p>
 *
 * <p>JCAMP-DX 5.01 reader for one-dimensional vibrational and UV-Vis
 * spectra. Dispatches on <code>##DATA TYPE=</code> to return one of
 * <code>TTIORamanSpectrum</code>, <code>TTIOIRSpectrum</code>, or
 * <code>TTIOUVVisSpectrum</code>; unknown data types return
 * <code>nil</code> with an error.</p>
 *
 * <p>Both dialects of <code>##XYDATA=(X++(Y..Y))</code> are
 * accepted:</p>
 *
 * <ul>
 *  <li><strong>AFFN (fast path)</strong> &#8212; one (X, Y) pair per
 *      line, free-format decimals.</li>
 *  <li><strong>PAC / SQZ / DIF / DUP</strong> &#8212; JCAMP-DX 5.01
 *      §5.9 character-encoded Y-stream (delegated to
 *      <code>TTIOJcampDxDecode</code>). Requires
 *      <code>FIRSTX</code> / <code>LASTX</code> /
 *      <code>NPOINTS</code>.</li>
 * </ul>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.jcamp_dx.read_spectrum</code><br/>
 * Java: <code>global.thalion.ttio.importers.JcampDxReader</code></p>
 */
@interface TTIOJcampDxReader : NSObject

/**
 * Reads a JCAMP-DX file and returns the appropriate concrete spectrum
 * subclass.
 *
 * @param path  Filesystem path to a JCAMP-DX 5.01 document.
 * @param error Out-parameter populated when the data type is
 *              unrecognised or the file is malformed.
 * @return A <code>TTIORamanSpectrum</code>,
 *         <code>TTIOIRSpectrum</code>, or
 *         <code>TTIOUVVisSpectrum</code>, or <code>nil</code> on
 *         failure.
 */
+ (TTIOSpectrum *)readSpectrumFromPath:(NSString *)path error:(NSError **)error;

@end

#endif
