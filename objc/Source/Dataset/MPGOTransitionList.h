#ifndef MPGO_TRANSITION_LIST_H
#define MPGO_TRANSITION_LIST_H

#import <Foundation/Foundation.h>

@class MPGOValueRange;

/**
 * One SRM/MRM transition: precursor → product m/z with its collision
 * energy and an optional retention-time window.
 */
@interface MPGOTransition : NSObject <NSCopying>

@property (readonly) double precursorMz;
@property (readonly) double productMz;
@property (readonly) double collisionEnergy;
@property (readonly, strong) MPGOValueRange *retentionTimeWindow;  // nullable

- (instancetype)initWithPrecursorMz:(double)precursor
                          productMz:(double)product
                    collisionEnergy:(double)ce
                retentionTimeWindow:(MPGOValueRange *)window;

@end

/**
 * Ordered list of MPGOTransition objects. Stored in the dataset as a
 * single JSON-encoded string attribute under /study/transitions/.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.transition_list.TransitionList
 *   Java:   com.dtwthalion.mpgo.TransitionList
 */
@interface MPGOTransitionList : NSObject

@property (readonly, copy) NSArray<MPGOTransition *> *transitions;

- (instancetype)initWithTransitions:(NSArray<MPGOTransition *> *)transitions;

- (NSUInteger)count;
- (MPGOTransition *)transitionAtIndex:(NSUInteger)index;

- (NSDictionary *)asPlist;
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
