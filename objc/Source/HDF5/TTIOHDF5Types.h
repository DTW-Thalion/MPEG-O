#ifndef TTIO_HDF5_TYPES_H
#define TTIO_HDF5_TYPES_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/TTIOEnums.h"

/** Element size in bytes for a given precision. Mirrors -[TTIOEncodingSpec elementSize]. */
NSUInteger TTIOPrecisionElementSize(TTIOPrecision precision);

/**
 * Native HDF5 type id for a given precision. The returned id is owned by the
 * caller for compound types (Complex128) and must be closed with H5Tclose;
 * for primitive types it is a builtin id (H5T_NATIVE_*) which must NOT be closed.
 *
 * Use TTIOHDF5TypeIsBuiltin() to decide which.
 */
hid_t TTIOHDF5TypeForPrecision(TTIOPrecision precision);
BOOL  TTIOHDF5TypeIsBuiltin(TTIOPrecision precision);

#endif
