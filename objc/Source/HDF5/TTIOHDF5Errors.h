#ifndef TTIO_HDF5_ERRORS_H
#define TTIO_HDF5_ERRORS_H

#import <Foundation/Foundation.h>

extern NSString *const TTIOErrorDomain;

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

/** Build an NSError in TTIOErrorDomain with code and printf-style message. */
NSError *TTIOMakeError(TTIOErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2,3);

#endif
