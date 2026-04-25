#ifndef TTIO_CV_ANNOTATABLE_H
#define TTIO_CV_ANNOTATABLE_H

#import <Foundation/Foundation.h>

@class TTIOCVParam;

/**
 * Objects conforming to TTIOCVAnnotatable can be tagged with controlled-
 * vocabulary parameters from any ontology (PSI-MS, nmrCV, CHEBI, BFO, ...).
 * This is the primary extensibility mechanism in TTI-O: the schema stays
 * minimal while semantic richness lives in curated external ontologies.
 *
 * Cross-language equivalents:
 *   Python: ttio.protocols.CVAnnotatable
 *   Java:   com.dtwthalion.ttio.protocols.CVAnnotatable
 *
 * API status: Stable.
 */
@protocol TTIOCVAnnotatable <NSObject>

@required
- (void)addCVParam:(TTIOCVParam *)param;
- (void)removeCVParam:(TTIOCVParam *)param;
- (NSArray<TTIOCVParam *> *)allCVParams;
- (NSArray<TTIOCVParam *> *)cvParamsForAccession:(NSString *)accession;
- (NSArray<TTIOCVParam *> *)cvParamsForOntologyRef:(NSString *)ontologyRef;
- (BOOL)hasCVParamWithAccession:(NSString *)accession;

@end

#endif /* TTIO_CV_ANNOTATABLE_H */
