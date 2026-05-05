#ifndef TTIO_CV_PARAM_H
#define TTIO_CV_PARAM_H

#import <Foundation/Foundation.h>

/**
 * <heading>TTIOCVParam</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCoding, NSCopying</p>
 * <p><em>Declared In:</em> ValueClasses/TTIOCVParam.h</p>
 *
 * <p>A single controlled-vocabulary parameter — the unit of semantic
 * annotation in TTI-O. Each parameter is a tuple of
 * <em>(ontology, accession, name, optional value, optional unit)</em>.
 * Immutable value class with value-based equality.</p>
 *
 * <p>The ontology reference is a short identifier
 * (<code>@"MS"</code>, <code>@"NMR"</code>, <code>@"CHEBI"</code>,
 * ...) and the accession is the full term identifier from that
 * ontology. The name is the human-readable term label and is
 * informational; semantic comparisons must use ontology + accession.</p>
 *
 * <p>The value and unit are optional: a parameter may carry a typed
 * value (NSNumber, NSString, ...) with an optional unit string
 * (UCUM-compatible), or it may be a name-only annotation.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.cv_param.CVParam</code><br/>
 * Java: <code>global.thalion.ttio.CVParam</code></p>
 */
@interface TTIOCVParam : NSObject <NSCoding, NSCopying>

/** Ontology short reference (e.g. <code>@"MS"</code>). */
@property (readonly, copy) NSString *ontologyRef;

/** Full term accession from the ontology. */
@property (readonly, copy) NSString *accession;

/** Human-readable term label. */
@property (readonly, copy) NSString *name;

/** Optional typed value (<code>NSNumber</code>, <code>NSString</code>,
 *  ...); <code>nil</code> for name-only annotations. */
@property (readonly, copy) id value;

/** Optional UCUM-compatible unit string; <code>nil</code> when no
 *  unit applies. */
@property (readonly, copy) NSString *unit;

/**
 * Designated initialiser.
 *
 * @param ontologyRef Ontology short reference.
 * @param accession   Term accession.
 * @param name        Human-readable term label.
 * @param value       Optional typed value; pass <code>nil</code> for
 *                    name-only annotations.
 * @param unit        Optional unit string; pass <code>nil</code>
 *                    when no unit applies.
 * @return An initialised CV parameter.
 */
- (instancetype)initWithOntologyRef:(NSString *)ontologyRef
                          accession:(NSString *)accession
                               name:(NSString *)name
                              value:(id)value
                               unit:(NSString *)unit;

/**
 * Convenience factory for the designated initialiser.
 *
 * @param ontologyRef Ontology short reference.
 * @param accession   Term accession.
 * @param name        Human-readable term label.
 * @param value       Optional typed value.
 * @param unit        Optional unit string.
 * @return An autoreleased CV parameter.
 */
+ (instancetype)paramWithOntologyRef:(NSString *)ontologyRef
                           accession:(NSString *)accession
                                name:(NSString *)name
                               value:(id)value
                                unit:(NSString *)unit;

@end

#endif /* TTIO_CV_PARAM_H */
