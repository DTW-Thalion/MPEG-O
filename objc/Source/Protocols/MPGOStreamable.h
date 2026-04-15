#ifndef MPGO_STREAMABLE_H
#define MPGO_STREAMABLE_H

#import <Foundation/Foundation.h>

/**
 * Objects conforming to MPGOStreamable support sequential access with
 * explicit positioning. This enables efficient iteration over large
 * datasets without materializing the entire collection in memory.
 */
@protocol MPGOStreamable <NSObject>

@required
- (id)nextObject;
- (BOOL)hasMore;
- (NSUInteger)currentPosition;
- (BOOL)seekToPosition:(NSUInteger)position;
- (void)reset;

@end

#endif /* MPGO_STREAMABLE_H */
