#ifndef TTIO_ACCESS_POLICY_H
#define TTIO_ACCESS_POLICY_H

#import <Foundation/Foundation.h>

@class TTIOHDF5File;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Protection/TTIOAccessPolicy.h</p>
 *
 * <p>Access policy describing who may decrypt which streams in a
 * <code>.tio</code> file. Stored as a JSON string under
 * <code>/protection/access_policies</code>, so the policy is
 * human-inspectable and recoverable independently of any
 * key-management system.</p>
 *
 * <p>The policy is intentionally schema-free at this layer: the
 * JSON is a dictionary of arbitrary key/value pairs that the
 * application is free to interpret. Typical fields:
 * <code>subjects</code>, <code>streams</code>, <code>expiry</code>,
 * <code>key_id</code>, <code>audit_contact</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.access_policy.AccessPolicy</code><br/>
 * Java: <code>global.thalion.ttio.protection.AccessPolicy</code></p>
 */
@interface TTIOAccessPolicy : NSObject <NSCopying>

/** Underlying policy dictionary (free-form JSON-compatible). */
@property (readonly, copy) NSDictionary *policy;

/**
 * Designated initialiser.
 *
 * @param policy Free-form policy dictionary.
 * @return An initialised access policy.
 */
- (instancetype)initWithPolicy:(NSDictionary *)policy;

/**
 * Writes the policy to
 * <code>/protection/access_policies</code> in the file's root
 * group.
 *
 * @param file  Destination file.
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeToFile:(TTIOHDF5File *)file error:(NSError **)error;

/**
 * Reads <code>/protection/access_policies</code>.
 *
 * @param file  Source file.
 * @param error Out-parameter populated on failure (including
 *              attribute-absent).
 * @return The materialised policy, or <code>nil</code> on failure.
 */
+ (instancetype)readFromFile:(TTIOHDF5File *)file error:(NSError **)error;

@end

#endif
