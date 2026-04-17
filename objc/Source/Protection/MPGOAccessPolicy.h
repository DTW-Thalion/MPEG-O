#ifndef MPGO_ACCESS_POLICY_H
#define MPGO_ACCESS_POLICY_H

#import <Foundation/Foundation.h>

@class MPGOHDF5File;

/**
 * Access policy describing who may decrypt which streams in a `.mpgo`
 * file. Stored as a JSON string under /protection/access_policies, so
 * the policy is human-inspectable and recoverable independently of any
 * key-management system.
 *
 * The policy is intentionally schema-free at this layer: the JSON is a
 * dictionary of arbitrary key/value pairs that the application is free
 * to interpret (typical fields: `subjects`, `streams`, `expiry`,
 * `key_id`, `audit_contact`).
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.access_policy.AccessPolicy
 *   Java:   com.dtwthalion.mpgo.protection.AccessPolicy
 */
@interface MPGOAccessPolicy : NSObject <NSCopying>

@property (readonly, copy) NSDictionary *policy;

- (instancetype)initWithPolicy:(NSDictionary *)policy;

/** Write to /protection/access_policies in the file's root group. */
- (BOOL)writeToFile:(MPGOHDF5File *)file error:(NSError **)error;

/** Read /protection/access_policies. Returns nil with error if missing. */
+ (instancetype)readFromFile:(MPGOHDF5File *)file error:(NSError **)error;

@end

#endif
