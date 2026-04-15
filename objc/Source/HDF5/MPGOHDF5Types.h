#ifndef MPGO_HDF5_TYPES_H
#define MPGO_HDF5_TYPES_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/MPGOEnums.h"

/** Element size in bytes for a given precision. Mirrors -[MPGOEncodingSpec elementSize]. */
NSUInteger MPGOPrecisionElementSize(MPGOPrecision precision);

/**
 * Native HDF5 type id for a given precision. The returned id is owned by the
 * caller for compound types (Complex128) and must be closed with H5Tclose;
 * for primitive types it is a builtin id (H5T_NATIVE_*) which must NOT be closed.
 *
 * Use MPGOHDF5TypeIsBuiltin() to decide which.
 */
hid_t MPGOHDF5TypeForPrecision(MPGOPrecision precision);
BOOL  MPGOHDF5TypeIsBuiltin(MPGOPrecision precision);

#endif
