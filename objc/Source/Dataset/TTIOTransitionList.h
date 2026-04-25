#ifndef TTIO_TRANSITION_LIST_H
#define TTIO_TRANSITION_LIST_H

#import <Foundation/Foundation.h>

@class TTIOValueRange;

/**
 * One SRM/MRM transition: precursor → product m/z with its collision
 * energy and an optional retention-time window.
 */
@interface TTIOTransition : NSObject <NSCopying>

@property (readonly) double precursorMz;
@property (readonly) double productMz;
@property (readonly) double collisionEnergy;
@property (readonly, strong) TTIOValueRange *retentionTimeWindow;  // nullable

- (instancetype)initWithPrecursorMz:(double)precursor
                          productMz:(double)product
                    collisionEnergy:(double)ce
                retentionTimeWindow:(TTIOValueRange *)window;

@end

/**
 * Ordered list of TTIOTransition objects. Stored in the dataset as a
 * single JSON-encoded string attribute under /study/transitions/.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.transition_list.TransitionList
 *   Java:   global.thalion.ttio.TransitionList
 */
@interface TTIOTransitionList : NSObject

@property (readonly, copy) NSArray<TTIOTransition *> *transitions;

- (instancetype)initWithTransitions:(NSArray<TTIOTransition *> *)transitions;

- (NSUInteger)count;
- (TTIOTransition *)transitionAtIndex:(NSUInteger)index;

- (NSDictionary *)asPlist;
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
