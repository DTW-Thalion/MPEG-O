#ifndef TTIO_TRANSITION_LIST_H
#define TTIO_TRANSITION_LIST_H

#import <Foundation/Foundation.h>

@class TTIOValueRange;

/**
 * <heading>TTIOTransition</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOTransitionList.h</p>
 *
 * <p>One SRM/MRM transition: precursor &rarr; product m/z with its
 * collision energy and an optional retention-time window.</p>
 */
@interface TTIOTransition : NSObject <NSCopying>

/** Precursor m/z. */
@property (readonly) double precursorMz;

/** Product m/z. */
@property (readonly) double productMz;

/** Collision energy (eV). */
@property (readonly) double collisionEnergy;

/** Optional retention-time window; <code>nil</code> if the
 *  transition is monitored throughout the run. */
@property (readonly, strong) TTIOValueRange *retentionTimeWindow;

/**
 * Designated initialiser.
 */
- (instancetype)initWithPrecursorMz:(double)precursor
                          productMz:(double)product
                    collisionEnergy:(double)ce
                retentionTimeWindow:(TTIOValueRange *)window;

@end

/**
 * <heading>TTIOTransitionList</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Dataset/TTIOTransitionList.h</p>
 *
 * <p>Ordered list of <code>TTIOTransition</code> objects. Stored in
 * the dataset as a single JSON-encoded string attribute under
 * <code>/study/transitions/</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transition_list.TransitionList</code><br/>
 * Java: <code>global.thalion.ttio.TransitionList</code></p>
 */
@interface TTIOTransitionList : NSObject

/** Underlying transitions in insertion order. */
@property (readonly, copy) NSArray<TTIOTransition *> *transitions;

/**
 * Designated initialiser.
 *
 * @param transitions Ordered transitions.
 * @return An initialised transition list.
 */
- (instancetype)initWithTransitions:(NSArray<TTIOTransition *> *)transitions;

/** @return Number of transitions. */
- (NSUInteger)count;

/**
 * @param index Zero-based position; must satisfy
 *              <code>index &lt; count</code>.
 * @return The transition at <code>index</code>.
 */
- (TTIOTransition *)transitionAtIndex:(NSUInteger)index;

/** @return Plist representation of the list. */
- (NSDictionary *)asPlist;

/**
 * @param plist Plist representation produced by
 *              <code>-asPlist</code>.
 * @return The reconstructed transition list.
 */
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
