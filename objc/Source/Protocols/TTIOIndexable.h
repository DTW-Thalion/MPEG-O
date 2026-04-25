#ifndef TTIO_INDEXABLE_H
#define TTIO_INDEXABLE_H

#import <Foundation/Foundation.h>

/**
 * Objects conforming to TTIOIndexable support O(1) random access by
 * integer index and, optionally, by key or range. This is the primary
 * access protocol for collections of spectra, runs, and access units.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.protocols.Indexable
 *   Java:   com.dtwthalion.tio.protocols.Indexable
 */
@protocol TTIOIndexable <NSObject>

@required
- (id)objectAtIndex:(NSUInteger)index;
- (NSUInteger)count;

@optional
- (id)objectForKey:(id)key;
- (NSArray *)objectsInRange:(NSRange)range;

@end

#endif /* TTIO_INDEXABLE_H */
