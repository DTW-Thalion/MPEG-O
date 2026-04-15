#ifndef MPGO_INDEXABLE_H
#define MPGO_INDEXABLE_H

#import <Foundation/Foundation.h>

/**
 * Objects conforming to MPGOIndexable support O(1) random access by
 * integer index and, optionally, by key or range. This is the primary
 * access protocol for collections of spectra, runs, and access units.
 */
@protocol MPGOIndexable <NSObject>

@required
- (id)objectAtIndex:(NSUInteger)index;
- (NSUInteger)count;

@optional
- (id)objectForKey:(id)key;
- (NSArray *)objectsInRange:(NSRange)range;

@end

#endif /* MPGO_INDEXABLE_H */
