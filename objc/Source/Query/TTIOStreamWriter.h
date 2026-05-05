#ifndef TTIO_STREAM_WRITER_H
#define TTIO_STREAM_WRITER_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOMassSpectrum;
@class TTIOInstrumentConfig;

/**
 * <heading>TTIOStreamWriter</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Query/TTIOStreamWriter.h</p>
 *
 * <p>Incrementally appends mass spectra to a <code>.tio</code>
 * file.</p>
 *
 * <p>Spectra accumulate in an in-memory buffer until
 * <code>-flushWithError:</code> is called. On each flush the file is
 * rewritten so that the run group reflects every spectrum buffered so
 * far &mdash; the file remains a valid <code>.tio</code> after each
 * flush, satisfying the streaming-write acceptance criterion. Calling
 * <code>-flushAndCloseWithError:</code> performs one final flush and
 * tears down.</p>
 *
 * <p>The flush implementation is whole-file regenerative: simple,
 * correct, and bounded for streaming demos and modest run sizes (up to
 * a few thousand spectra). Larger workloads should write to extendable
 * HDF5 datasets via a different writer.</p>
 *
 * <p><strong>API status:</strong> Stable (flush integration
 * pending).</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.stream_writer.StreamWriter</code><br/>
 * Java: <code>global.thalion.ttio.StreamWriter</code></p>
 */
@interface TTIOStreamWriter : NSObject

#pragma mark - Construction

/**
 * Creates an empty <code>.tio</code> file at <code>path</code> and
 * prepares the writer to receive spectra.
 *
 * @param path     Filesystem path at which to create the
 *                 <code>.tio</code> file. Any existing file at this
 *                 path is overwritten.
 * @param runName  Run group name to use on flush (for example
 *                 <code>@"run_0001"</code>).
 * @param mode     Acquisition mode recorded on the run group.
 * @param config   Instrument-configuration metadata recorded on the
 *                 run group.
 * @param error    Out-parameter populated on failure.
 * @return An initialised writer with an empty buffer, or
 *         <code>nil</code> on failure.
 */
- (instancetype)initWithFilePath:(NSString *)path
                         runName:(NSString *)runName
                 acquisitionMode:(TTIOAcquisitionMode)mode
                instrumentConfig:(TTIOInstrumentConfig *)config
                           error:(NSError **)error;

#pragma mark - Buffering

/**
 * Appends <code>spectrum</code> to the in-memory buffer. Nothing
 * reaches disk until <code>-flushWithError:</code> or
 * <code>-flushAndCloseWithError:</code> is called.
 *
 * @param spectrum Mass spectrum to append. Must be non-nil.
 * @param error    Out-parameter populated when the writer has been
 *                 closed.
 * @return <code>YES</code> on success, <code>NO</code> if the writer
 *         is closed.
 */
- (BOOL)appendSpectrum:(TTIOMassSpectrum *)spectrum error:(NSError **)error;

#pragma mark - Flush and close

/**
 * Rewrites the entire <code>.tio</code> file from the current buffer.
 * Safe to call repeatedly; on each call the file remains a valid
 * <code>.tio</code> reflecting every spectrum buffered so far.
 *
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
- (BOOL)flushWithError:(NSError **)error;

/**
 * Performs one final flush, then marks the writer closed. Subsequent
 * <code>-appendSpectrum:error:</code> calls fail with
 * <code>TTIOErrorInvalidArgument</code>.
 *
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
- (BOOL)flushAndCloseWithError:(NSError **)error;

#pragma mark - Inspection

/** Number of spectra currently buffered (not yet necessarily
 *  persisted unless a flush has been performed). */
@property (readonly) NSUInteger spectrumCount;

@end

#endif
