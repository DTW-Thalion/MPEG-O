#ifndef TTIO_IDENTIFICATION_H
#define TTIO_IDENTIFICATION_H

#import <Foundation/Foundation.h>

@class TTIOHDF5Group;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOIdentification.h</p>
 *
 * <p>Links a spectrum (by its zero-based index within an
 * acquisition run) to a chemical-entity identification, with a
 * confidence score and an evidence chain. The evidence chain is an
 * ordered list of free-form strings — typically CV accession
 * references such as <code>@"MS:1002217 search engine specific
 * score"</code>.</p>
 *
 * <p>Persisted as a row in the
 * <code>/study/identifications</code> compound dataset.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.identification.Identification</code><br/>
 * Java: <code>global.thalion.ttio.Identification</code></p>
 */
@interface TTIOIdentification : NSObject <NSCopying>

/** Acquisition-run name that contains the identified spectrum. */
@property (readonly, copy) NSString *runName;

/** Position of the identified spectrum within
 *  <code>runName</code>. */
@property (readonly) NSUInteger spectrumIndex;

/** Identified entity — CHEBI accession, peptide sequence, or
 *  formula. */
@property (readonly, copy) NSString *chemicalEntity;

/** Confidence in the identification (<code>0.0</code> to
 *  <code>1.0</code>). */
@property (readonly) double confidenceScore;

/** Ordered evidence references (CV accessions / scoring metadata). */
@property (readonly, copy) NSArray<NSString *> *evidenceChain;

/**
 * Designated initialiser.
 *
 * @param runName        Acquisition-run name.
 * @param spectrumIndex  Spectrum position within the run.
 * @param chemicalEntity Identified entity.
 * @param score          Confidence score.
 * @param evidence       Ordered evidence references.
 * @return An initialised identification.
 */
- (instancetype)initWithRunName:(NSString *)runName
                  spectrumIndex:(NSUInteger)spectrumIndex
                 chemicalEntity:(NSString *)chemicalEntity
                confidenceScore:(double)score
                  evidenceChain:(NSArray<NSString *> *)evidence;

/** @return Plist-friendly dictionary representation suitable for
 *          legacy-attribute serialisation. */
- (NSDictionary *)asPlist;

/**
 * @param plist Plist representation produced by
 *              <code>-asPlist</code>.
 * @return The reconstructed identification.
 */
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
