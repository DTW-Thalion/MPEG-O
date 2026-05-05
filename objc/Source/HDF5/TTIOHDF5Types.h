#ifndef TTIO_HDF5_TYPES_H
#define TTIO_HDF5_TYPES_H

#import <Foundation/Foundation.h>
#import <hdf5.h>
#import "ValueClasses/TTIOEnums.h"

/**
 * Returns the size in bytes of a single element at the given
 * precision. Mirrors <code>-[TTIOEncodingSpec elementSize]</code>;
 * available as a free function so callers that do not hold an
 * encoding-spec instance can still compute buffer sizes.
 */
NSUInteger TTIOPrecisionElementSize(TTIOPrecision precision);

/**
 * Native HDF5 type id for a given precision.
 *
 * The returned id is owned by the caller for compound types
 * (Complex128) and must be closed with <code>H5Tclose</code>; for
 * primitive types it is a builtin id (<code>H5T_NATIVE_*</code>)
 * which must NOT be closed. Use
 * <code>TTIOHDF5TypeIsBuiltin()</code> to decide which.
 */
hid_t TTIOHDF5TypeForPrecision(TTIOPrecision precision);

/**
 * Returns YES if the precision maps to a builtin HDF5 type
 * (callers must NOT close the returned hid_t), NO if it maps to a
 * caller-owned compound type (callers MUST close the returned
 * hid_t).
 */
BOOL TTIOHDF5TypeIsBuiltin(TTIOPrecision precision);

#endif
