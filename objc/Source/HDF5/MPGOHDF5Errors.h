#ifndef MPGO_HDF5_ERRORS_H
#define MPGO_HDF5_ERRORS_H

#import <Foundation/Foundation.h>

extern NSString *const MPGOErrorDomain;

typedef NS_ENUM(NSInteger, MPGOErrorCode) {
    MPGOErrorUnknown = 0,
    MPGOErrorFileNotFound,
    MPGOErrorFileCreate,
    MPGOErrorFileOpen,
    MPGOErrorFileClose,
    MPGOErrorGroupCreate,
    MPGOErrorGroupOpen,
    MPGOErrorDatasetCreate,
    MPGOErrorDatasetOpen,
    MPGOErrorDatasetWrite,
    MPGOErrorDatasetRead,
    MPGOErrorAttributeCreate,
    MPGOErrorAttributeRead,
    MPGOErrorAttributeWrite,
    MPGOErrorInvalidArgument,
    MPGOErrorTypeMismatch,
    MPGOErrorOutOfRange,
};

/** Build an NSError in MPGOErrorDomain with code and printf-style message. */
NSError *MPGOMakeError(MPGOErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2,3);

#endif
