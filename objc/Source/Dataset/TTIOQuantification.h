#ifndef TTIO_QUANTIFICATION_H
#define TTIO_QUANTIFICATION_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOQuantification.h</p>
 *
 * <p>Abundance value for a chemical entity in a sample, with
 * optional normalisation metadata. Persisted alongside
 * identifications as a row in the
 * <code>/study/quantifications</code> compound dataset.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.quantification.Quantification</code><br/>
 * Java: <code>global.thalion.ttio.Quantification</code></p>
 */
@interface TTIOQuantification : NSObject <NSCopying>

/** Identified entity (matches an
 *  <code>identification.chemicalEntity</code>). */
@property (readonly, copy) NSString *chemicalEntity;

/** Sample identifier from the ISA-Tab investigation. */
@property (readonly, copy) NSString *sampleRef;

/** Abundance value (units depend on
 *  <code>normalizationMethod</code>). */
@property (readonly) double abundance;

/** Optional normalisation method (e.g. <code>@"median"</code>,
 *  <code>@"TIC"</code>); <code>nil</code> when raw abundance is
 *  reported. */
@property (readonly, copy) NSString *normalizationMethod;

/** Free-form unit label for <code>abundance</code> (e.g.
 *  <code>@"ng/mL"</code>, <code>@"peak-area"</code>,
 *  <code>@"ion-count"</code>, <code>@"normalized"</code>). Empty
 *  string when not specified — readers should interpret an empty
 *  unit as "implied by <code>normalizationMethod</code>".
 *
 *  <p>Cross-language equivalents: Java <code>Quantification.unit()</code>,
 *  Python <code>Quantification.unit</code>.</p>
 */
@property (readonly, copy) NSString *unit;

/**
 * Pre-unit initialiser; defaults <code>unit</code> to empty string.
 * Retained for source-compatibility with callers compiled against
 * the 4-property API.
 */
- (instancetype)initWithChemicalEntity:(NSString *)entity
                             sampleRef:(NSString *)sampleRef
                             abundance:(double)abundance
                   normalizationMethod:(NSString *)method;

/**
 * Designated initialiser.
 *
 * @param entity    Identified entity.
 * @param sampleRef Sample identifier.
 * @param abundance Abundance value.
 * @param method    Optional normalisation method; pass
 *                  <code>nil</code> for raw values.
 * @param unit      Free-form unit label; pass empty string when not
 *                  specified.
 * @return An initialised quantification.
 */
- (instancetype)initWithChemicalEntity:(NSString *)entity
                             sampleRef:(NSString *)sampleRef
                             abundance:(double)abundance
                   normalizationMethod:(NSString *)method
                                  unit:(NSString *)unit;

/** @return Plist-friendly dictionary representation. */
- (NSDictionary *)asPlist;

/**
 * @param plist Plist representation produced by
 *              <code>-asPlist</code>.
 * @return The reconstructed quantification.
 */
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
