#ifndef MPGO_CV_ANNOTATABLE_H
#define MPGO_CV_ANNOTATABLE_H

#import <Foundation/Foundation.h>

@class MPGOCVParam;

/**
 * Objects conforming to MPGOCVAnnotatable can be tagged with controlled-
 * vocabulary parameters from any ontology (PSI-MS, nmrCV, CHEBI, BFO, ...).
 * This is the primary extensibility mechanism in MPEG-O: the schema stays
 * minimal while semantic richness lives in curated external ontologies.
 */
@protocol MPGOCVAnnotatable <NSObject>

@required
- (void)addCVParam:(MPGOCVParam *)param;
- (void)removeCVParam:(MPGOCVParam *)param;
- (NSArray<MPGOCVParam *> *)allCVParams;
- (NSArray<MPGOCVParam *> *)cvParamsForAccession:(NSString *)accession;
- (NSArray<MPGOCVParam *> *)cvParamsForOntologyRef:(NSString *)ontologyRef;
- (BOOL)hasCVParamWithAccession:(NSString *)accession;

@end

#endif /* MPGO_CV_ANNOTATABLE_H */
