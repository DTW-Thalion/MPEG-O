#ifndef TTIO_VERIFIER_H
#define TTIO_VERIFIER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, TTIOVerificationStatus) {
    TTIOVerificationStatusValid = 0,
    TTIOVerificationStatusInvalid,
    TTIOVerificationStatusNotSigned,
    TTIOVerificationStatusError,
};

/**
 * Higher-level verification API. Collapses the three outcomes of a
 * sign-and-verify cycle (valid / invalid / not-signed) into a single
 * enum, plus an error fallback for I/O failures. Use this instead of
 * TTIOSignatureManager when you want to render a status to an end
 * user.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.verifier.Verifier
 *   Java:   com.dtwthalion.tio.protection.Verifier
 */
@interface TTIOVerifier : NSObject

+ (TTIOVerificationStatus)verifyDataset:(NSString *)datasetPath
                                 inFile:(NSString *)filePath
                                withKey:(NSData *)key
                                  error:(NSError **)error;

+ (TTIOVerificationStatus)verifyProvenanceInRun:(NSString *)runPath
                                         inFile:(NSString *)filePath
                                        withKey:(NSData *)key
                                          error:(NSError **)error;

@end

#endif
