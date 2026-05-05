#ifndef TTIO_INDEXABLE_H
#define TTIO_INDEXABLE_H

#import <Foundation/Foundation.h>

/**
 * <heading>TTIOIndexable</heading>
 *
 * <p><em>Conforms To:</em> NSObject (root protocol)</p>
 * <p><em>Declared In:</em> Protocols/TTIOIndexable.h</p>
 *
 * <p>Declares the interface for collections that support O(1) random
 * access by integer index and, optionally, by key or range. This is
 * the primary access protocol for collections of spectra, runs, and
 * access units in TTI-O.</p>
 *
 * <p>Conforming classes must guarantee constant-time
 * <code>-objectAtIndex:</code> within the bounds <code>[0, count)</code>;
 * out-of-range accesses raise <code>NSRangeException</code>. The
 * optional key-based and range-based accessors are provided when the
 * underlying storage permits efficient lookup.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.protocols.Indexable</code><br/>
 * Java: <code>global.thalion.ttio.protocols.Indexable</code></p>
 */
@protocol TTIOIndexable <NSObject>

@required

/**
 * Returns the element at the given position.
 *
 * @param index Zero-based index into the collection. Must satisfy
 *              <code>index &lt; count</code>.
 * @return The element at <code>index</code>.
 * @throws NSRangeException if <code>index &gt;= count</code>.
 */
- (id)objectAtIndex:(NSUInteger)index;

/**
 * @return The number of elements in the collection.
 */
- (NSUInteger)count;

@optional

/**
 * Returns the element associated with the given key, if the
 * collection supports keyed lookup.
 *
 * @param key Implementation-defined key (typically an
 *            <code>NSString</code> name or a numeric identifier).
 * @return The matching element, or <code>nil</code> if no element
 *         is associated with the key.
 */
- (id)objectForKey:(id)key;

/**
 * Returns a contiguous slice of the collection.
 *
 * @param range NSRange whose location and length must lie within
 *              <code>[0, count]</code>.
 * @return Elements in the range, in collection order.
 * @throws NSRangeException if the range exceeds
 *         <code>[0, count]</code>.
 */
- (NSArray *)objectsInRange:(NSRange)range;

@end

#endif /* TTIO_INDEXABLE_H */
