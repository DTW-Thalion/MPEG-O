/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_PROVIDERS_COMPOUND_FIELD_H
#define TTIO_PROVIDERS_COMPOUND_FIELD_H

#import <Foundation/Foundation.h>

/**
 * <heading>TTIOCompoundFieldKind</heading>
 *
 * <p><em>Type:</em> NS_ENUM (NSInteger)</p>
 * <p><em>Declared In:</em> Providers/TTIOCompoundField.h</p>
 *
 * <p>Element type tag used in compound-dataset field schemas.
 * <code>VLBytes</code> stores variable-length byte buffers (used for
 * the per-AU encryption <code>&lt;channel&gt;_segments</code>
 * compound's ciphertext column and for fixed-length inline IV / TAG /
 * semantic-header blobs). Providers serialise <code>VLBytes</code>
 * values as <code>NSData</code>.</p>
 */
typedef NS_ENUM(NSInteger, TTIOCompoundFieldKind) {
    TTIOCompoundFieldKindUInt32   = 0,
    TTIOCompoundFieldKindInt64    = 1,
    TTIOCompoundFieldKindFloat64  = 2,
    TTIOCompoundFieldKindVLString = 3,
    TTIOCompoundFieldKindVLBytes  = 4,
};

/**
 * <heading>TTIOCompoundField</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying, NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOCompoundField.h</p>
 *
 * <p>One field inside a compound-dataset record: a name plus a
 * <code>TTIOCompoundFieldKind</code> selecting the storage type.
 * Used by <code>-createCompoundDatasetNamed:fields:count:error:</code>
 * to declare the row schema.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.base.CompoundField</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.CompoundField</code></p>
 */
@interface TTIOCompoundField : NSObject <NSCopying>

/** Field name in the row dictionary. */
@property (readonly, copy) NSString *name;

/** Element type. */
@property (readonly)       TTIOCompoundFieldKind kind;

/**
 * Convenience constructor.
 *
 * @param name Field name.
 * @param kind Element type.
 * @return A new field schema entry.
 */
+ (instancetype)fieldWithName:(NSString *)name kind:(TTIOCompoundFieldKind)kind;

/**
 * Designated initialiser.
 *
 * @param name Field name.
 * @param kind Element type.
 * @return An initialised field schema entry.
 */
- (instancetype)initWithName:(NSString *)name kind:(TTIOCompoundFieldKind)kind;

@end

#endif
