#ifndef TTIO_VERIFIER_H
#define TTIO_VERIFIER_H

#import <Foundation/Foundation.h>

/**
 * Outcome of a signature verification cycle.
 */
typedef NS_ENUM(NSUInteger, TTIOVerificationStatus) {
    /** Signature present and valid for the supplied key. */
    TTIOVerificationStatusValid = 0,
    /** Signature present but failed verification. */
    TTIOVerificationStatusInvalid,
    /** No signature attached to the dataset / run. */
    TTIOVerificationStatusNotSigned,
    /** I/O or other operational failure. */
    TTIOVerificationStatusError,
};

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Protection/TTIOVerifier.h</p>
 *
 * <p>Higher-level verification API. Collapses the three outcomes of
 * a sign-and-verify cycle (valid / invalid / not-signed) into a
 * single enum, plus an error fallback for I/O failures. Use this
 * instead of <code>TTIOSignatureManager</code> when you want to
 * render a status to an end user.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.verifier.Verifier</code><br/>
 * Java: <code>global.thalion.ttio.protection.Verifier</code></p>
 */
@interface TTIOVerifier : NSObject

/**
 * Verifies a dataset's HMAC-SHA256 (or PQC) signature.
 *
 * @param datasetPath HDF5 path to the signed dataset.
 * @param filePath    Filesystem path to the .tio file.
 * @param key         Verification key.
 * @param error       Out-parameter populated on failure.
 * @return Verification status.
 */
+ (TTIOVerificationStatus)verifyDataset:(NSString *)datasetPath
                                 inFile:(NSString *)filePath
                                withKey:(NSData *)key
                                  error:(NSError **)error;

/**
 * Verifies a run's per-run provenance signature.
 *
 * @param runPath  HDF5 path to the run group.
 * @param filePath Filesystem path to the .tio file.
 * @param key      Verification key.
 * @param error    Out-parameter populated on failure.
 * @return Verification status.
 */
+ (TTIOVerificationStatus)verifyProvenanceInRun:(NSString *)runPath
                                         inFile:(NSString *)filePath
                                        withKey:(NSData *)key
                                          error:(NSError **)error;

@end

#endif
