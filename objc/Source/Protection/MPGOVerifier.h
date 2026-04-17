#ifndef MPGO_VERIFIER_H
#define MPGO_VERIFIER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, MPGOVerificationStatus) {
    MPGOVerificationStatusValid = 0,
    MPGOVerificationStatusInvalid,
    MPGOVerificationStatusNotSigned,
    MPGOVerificationStatusError,
};

/**
 * Higher-level verification API. Collapses the three outcomes of a
 * sign-and-verify cycle (valid / invalid / not-signed) into a single
 * enum, plus an error fallback for I/O failures. Use this instead of
 * MPGOSignatureManager when you want to render a status to an end
 * user.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.verifier.Verifier
 *   Java:   com.dtwthalion.mpgo.protection.Verifier
 */
@interface MPGOVerifier : NSObject

+ (MPGOVerificationStatus)verifyDataset:(NSString *)datasetPath
                                 inFile:(NSString *)filePath
                                withKey:(NSData *)key
                                  error:(NSError **)error;

+ (MPGOVerificationStatus)verifyProvenanceInRun:(NSString *)runPath
                                         inFile:(NSString *)filePath
                                        withKey:(NSData *)key
                                          error:(NSError **)error;

@end

#endif
