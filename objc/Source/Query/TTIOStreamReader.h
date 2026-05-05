#ifndef TTIO_STREAM_READER_H
#define TTIO_STREAM_READER_H

#import <Foundation/Foundation.h>

@class TTIOMassSpectrum;
@class TTIOHDF5File;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Query/TTIOStreamReader.h</p>
 *
 * <p>Sequential reader for an MS run stored inside a <code>.tio</code>
 * file. Internally wraps a <code>TTIOAcquisitionRun</code> read-back;
 * <code>-nextSpectrumWithError:</code> advances a position counter and
 * returns spectra one at a time via the existing hyperslab path,
 * making it suitable for streaming through runs larger than memory.</p>
 *
 * <p>The reader holds the file open until <code>-close</code> is sent.
 * Callers may inspect <code>-totalCount</code> and
 * <code>-currentPosition</code> to drive progress UIs, or call
 * <code>-reset</code> to restart from the first spectrum.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.stream_reader.StreamReader</code><br/>
 * Java: <code>global.thalion.ttio.StreamReader</code></p>
 */
@interface TTIOStreamReader : NSObject

#pragma mark - Construction

/**
 * Opens <code>path</code> read-only and prepares the named run for
 * sequential read-back. Returns <code>nil</code> on failure with
 * <code>error</code> populated.
 *
 * @param path    Absolute or relative path to an existing
 *                <code>.tio</code> file.
 * @param runName Run group name inside the file (for example
 *                <code>@"run_0001"</code>).
 * @param error   Out-parameter populated on failure.
 * @return An initialised reader positioned at index <code>0</code>,
 *         or <code>nil</code> on failure.
 */
- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                           error:(NSError **)error;

#pragma mark - Position

/** Total number of spectra in the run. */
@property (readonly) NSUInteger totalCount;

/** Zero-based index of the next spectrum that
 *  <code>-nextSpectrumWithError:</code> will return. */
@property (readonly) NSUInteger currentPosition;

/**
 * @return <code>YES</code> when the position has advanced past the
 *         last spectrum; <code>NO</code> otherwise.
 */
- (BOOL)atEnd;

#pragma mark - Iteration

/**
 * Materialises and returns the spectrum at
 * <code>currentPosition</code>, then advances by one. Returns
 * <code>nil</code> when the iterator has reached the end or on read
 * failure.
 *
 * @param error Out-parameter populated on read failure.
 * @return The next mass spectrum, or <code>nil</code> at end of run
 *         or on failure.
 */
- (TTIOMassSpectrum *)nextSpectrumWithError:(NSError **)error;

/**
 * Repositions the iterator to the start of the run.
 */
- (void)reset;

#pragma mark - Lifecycle

/**
 * Releases the underlying file handle and run reference. Subsequent
 * calls to <code>-nextSpectrumWithError:</code> return
 * <code>nil</code>.
 */
- (void)close;

@end

#endif
