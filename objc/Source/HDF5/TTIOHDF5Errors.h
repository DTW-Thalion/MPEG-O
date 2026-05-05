#ifndef TTIO_HDF5_ERRORS_H
#define TTIO_HDF5_ERRORS_H

#import <Foundation/Foundation.h>

/**
 * TTIOErrorDomain — NSError domain for every error raised by the
 * TTI-O Objective-C implementation. Always paired with a
 * <code>TTIOErrorCode</code> value in <code>NSError.code</code> and
 * a printf-formatted localised description in
 * <code>userInfo[NSLocalizedDescriptionKey]</code>.
 */
extern NSString *const TTIOErrorDomain;

/**
 * Error codes shared across the storage, codec, and protection
 * layers. Codes are stable across releases; new codes are appended.
 */
typedef NS_ENUM(NSInteger, TTIOErrorCode) {
    TTIOErrorUnknown = 0,
    TTIOErrorFileNotFound,
    TTIOErrorFileCreate,
    TTIOErrorFileOpen,
    TTIOErrorFileClose,
    TTIOErrorGroupCreate,
    TTIOErrorGroupOpen,
    TTIOErrorDatasetCreate,
    TTIOErrorDatasetOpen,
    TTIOErrorDatasetWrite,
    TTIOErrorDatasetRead,
    TTIOErrorAttributeCreate,
    TTIOErrorAttributeRead,
    TTIOErrorAttributeWrite,
    TTIOErrorInvalidArgument,
    TTIOErrorTypeMismatch,
    TTIOErrorOutOfRange,
};

/**
 * Build an NSError in TTIOErrorDomain with a printf-formatted
 * description.
 *
 * @param code   Error code from <code>TTIOErrorCode</code>.
 * @param format printf-style format string.
 * @return An autoreleased NSError ready to assign to an
 *         <code>NSError **</code> out-parameter.
 */
NSError *TTIOMakeError(TTIOErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2,3);

#endif
