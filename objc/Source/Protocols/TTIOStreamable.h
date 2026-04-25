#ifndef TTIO_STREAMABLE_H
#define TTIO_STREAMABLE_H

#import <Foundation/Foundation.h>

/**
 * Objects conforming to TTIOStreamable support sequential access with
 * explicit positioning. This enables efficient iteration over large
 * datasets without materializing the entire collection in memory.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.protocols.Streamable
 *   Java:   com.dtwthalion.tio.protocols.Streamable
 */
@protocol TTIOStreamable <NSObject>

@required
- (id)nextObject;
- (BOOL)hasMore;
- (NSUInteger)currentPosition;
- (BOOL)seekToPosition:(NSUInteger)position;
- (void)reset;

@end

#endif /* TTIO_STREAMABLE_H */
