#ifndef MPGO_CV_PARAM_H
#define MPGO_CV_PARAM_H

#import <Foundation/Foundation.h>

/**
 * A single controlled-vocabulary parameter: (ontology, accession, name,
 * optional value, optional unit). Immutable value class. Stub in Phase 2 —
 * full implementation lands in Milestone 1.
 */
@interface MPGOCVParam : NSObject <NSCoding, NSCopying>

@property (readonly, copy) NSString *ontologyRef;
@property (readonly, copy) NSString *accession;
@property (readonly, copy) NSString *name;
@property (readonly, copy) id value;         // nullable
@property (readonly, copy) NSString *unit;   // nullable

- (instancetype)initWithOntologyRef:(NSString *)ontologyRef
                          accession:(NSString *)accession
                               name:(NSString *)name
                              value:(id)value
                               unit:(NSString *)unit;

+ (instancetype)paramWithOntologyRef:(NSString *)ontologyRef
                           accession:(NSString *)accession
                                name:(NSString *)name
                               value:(id)value
                                unit:(NSString *)unit;

@end

#endif /* MPGO_CV_PARAM_H */
