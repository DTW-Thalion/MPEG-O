#ifndef TTIO_QUANTIFICATION_H
#define TTIO_QUANTIFICATION_H

#import <Foundation/Foundation.h>

/**
 * Abundance value for a chemical entity in a sample, with optional
 * normalization metadata. Stored alongside identifications under
 * /study/quantifications/ in the TTI-O container.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.quantification.Quantification
 *   Java:   com.dtwthalion.ttio.Quantification
 */
@interface TTIOQuantification : NSObject <NSCopying>

@property (readonly, copy) NSString *chemicalEntity;
@property (readonly, copy) NSString *sampleRef;
@property (readonly)       double    abundance;
@property (readonly, copy) NSString *normalizationMethod;  // nullable, e.g. "median", "TIC"

- (instancetype)initWithChemicalEntity:(NSString *)entity
                             sampleRef:(NSString *)sampleRef
                             abundance:(double)abundance
                   normalizationMethod:(NSString *)method;

- (NSDictionary *)asPlist;
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
