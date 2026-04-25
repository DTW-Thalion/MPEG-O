#ifndef TTIO_IDENTIFICATION_H
#define TTIO_IDENTIFICATION_H

#import <Foundation/Foundation.h>

@class TTIOHDF5Group;

/**
 * Links a spectrum (by its 0-based index within an acquisition run) to a
 * chemical entity identification, with a confidence score and an evidence
 * chain represented as an ordered list of free-form strings (typically CV
 * accession references such as "MS:1002217 search engine specific score").
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.identification.Identification
 *   Java:   com.dtwthalion.ttio.Identification
 */
@interface TTIOIdentification : NSObject <NSCopying>

@property (readonly, copy) NSString *runName;          // acquisition run that contains the spectrum
@property (readonly)       NSUInteger spectrumIndex;   // position within that run
@property (readonly, copy) NSString *chemicalEntity;   // CHEBI accession or formula
@property (readonly)       double    confidenceScore;  // 0..1
@property (readonly, copy) NSArray<NSString *> *evidenceChain;

- (instancetype)initWithRunName:(NSString *)runName
                  spectrumIndex:(NSUInteger)spectrumIndex
                 chemicalEntity:(NSString *)chemicalEntity
                confidenceScore:(double)score
                  evidenceChain:(NSArray<NSString *> *)evidence;

- (NSDictionary *)asPlist;
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
