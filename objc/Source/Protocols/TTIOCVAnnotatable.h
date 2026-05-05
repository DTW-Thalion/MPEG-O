#ifndef TTIO_CV_ANNOTATABLE_H
#define TTIO_CV_ANNOTATABLE_H

#import <Foundation/Foundation.h>

@class TTIOCVParam;

/**
 * <p><em>Conforms To:</em> NSObject (root protocol)</p>
 * <p><em>Declared In:</em> Protocols/TTIOCVAnnotatable.h</p>
 *
 * <p>Declares the interface for attaching and querying controlled-vocabulary
 * (CV) annotations on a TTI-O object. Annotations are
 * <code>TTIOCVParam</code> instances keyed by ontology reference and
 * accession number, drawn from any external ontology (PSI-MS, nmrCV,
 * CHEBI, BFO, ...).</p>
 *
 * <p>This is the primary extensibility mechanism in TTI-O: the
 * schema stays minimal while semantic richness lives in curated
 * external ontologies. Concrete spectrum classes,
 * <code>TTIOSignalArray</code>, and <code>TTIOAcquisitionRun</code>
 * conform to this protocol.</p>
 *
 * <p>Conforming classes are not required to be thread-safe;
 * mutating CV annotations from multiple threads is undefined
 * behaviour unless the concrete class documents otherwise.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.protocols.CVAnnotatable</code><br/>
 * Java: <code>global.thalion.ttio.protocols.CVAnnotatable</code></p>
 */
@protocol TTIOCVAnnotatable <NSObject>

@required

/**
 * Attaches a controlled-vocabulary annotation.
 *
 * @param param The annotation to attach. Duplicates are allowed;
 *              annotations are stored in insertion order.
 */
- (void)addCVParam:(TTIOCVParam *)param;

/**
 * Removes a previously attached CV annotation. No-op if the
 * annotation is not present.
 *
 * @param param The annotation to remove. Equality is determined by
 *              the conforming class (typically value equality on
 *              ontology reference + accession + value).
 */
- (void)removeCVParam:(TTIOCVParam *)param;

/**
 * @return All CV annotations attached to this object, in insertion
 *         order. Empty array if none.
 */
- (NSArray<TTIOCVParam *> *)allCVParams;

/**
 * Returns annotations matching a specific accession across any
 * ontology.
 *
 * @param accession Accession number (e.g. <code>@"MS:1000511"</code>).
 * @return Matching annotations in insertion order. Empty array if
 *         none match.
 */
- (NSArray<TTIOCVParam *> *)cvParamsForAccession:(NSString *)accession;

/**
 * Returns annotations sourced from a specific ontology.
 *
 * @param ontologyRef Ontology short reference (e.g.
 *                    <code>@"MS"</code>, <code>@"NMR"</code>).
 * @return Matching annotations in insertion order. Empty array if
 *         none match.
 */
- (NSArray<TTIOCVParam *> *)cvParamsForOntologyRef:(NSString *)ontologyRef;

/**
 * @param accession Accession number to test for.
 * @return <code>YES</code> if at least one annotation with the given
 *         accession is present.
 */
- (BOOL)hasCVParamWithAccession:(NSString *)accession;

@end

#endif /* TTIO_CV_ANNOTATABLE_H */
