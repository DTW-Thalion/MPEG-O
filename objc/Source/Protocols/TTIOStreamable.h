#ifndef TTIO_STREAMABLE_H
#define TTIO_STREAMABLE_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Conforms To:</em> NSObject (root protocol)</p>
 * <p><em>Declared In:</em> Protocols/TTIOStreamable.h</p>
 *
 * <p>Declares the interface for sequential access with explicit
 * positioning. Conforming classes enable efficient iteration over
 * large datasets without materializing the entire collection in
 * memory; the cursor advances on each <code>-nextObject</code> call
 * and may be repositioned via <code>-seekToPosition:</code>.</p>
 *
 * <p>The streaming protocol is one-pass-by-default: callers iterate
 * forward via <code>-nextObject</code> until <code>-hasMore</code>
 * returns <code>NO</code>. Random repositioning is supported when
 * the underlying storage permits seeking (HDF5 datasets,
 * memory-backed providers); for stream-only sources, a seek may
 * raise.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.protocols.Streamable</code><br/>
 * Java: <code>global.thalion.ttio.protocols.Streamable</code></p>
 */
@protocol TTIOStreamable <NSObject>

@required

/**
 * Advances the cursor and returns the element at the new position.
 *
 * @return The next element, or <code>nil</code> if the cursor has
 *         reached the end of the stream.
 */
- (id)nextObject;

/**
 * @return <code>YES</code> if at least one more element is available
 *         from the current cursor position.
 */
- (BOOL)hasMore;

/**
 * @return The current cursor position as a zero-based index.
 *         Position <code>count</code> indicates exhaustion.
 */
- (NSUInteger)currentPosition;

/**
 * Repositions the cursor to the given absolute index.
 *
 * @param position Zero-based index to seek to. Must satisfy
 *                 <code>position &lt;= count</code>.
 * @return <code>YES</code> on success; <code>NO</code> if the
 *         underlying storage does not support seeking.
 */
- (BOOL)seekToPosition:(NSUInteger)position;

/**
 * Repositions the cursor to the start of the stream.
 */
- (void)reset;

@end

#endif /* TTIO_STREAMABLE_H */
