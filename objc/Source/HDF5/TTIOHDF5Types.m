#import "TTIOHDF5Types.h"

NSUInteger TTIOPrecisionElementSize(TTIOPrecision precision)
{
    switch (precision) {
        case TTIOPrecisionFloat32:    return 4;
        case TTIOPrecisionFloat64:    return 8;
        case TTIOPrecisionInt32:      return 4;
        case TTIOPrecisionInt64:      return 8;
        case TTIOPrecisionUInt32:     return 4;
        case TTIOPrecisionComplex128: return 16;
        case TTIOPrecisionUInt8:      return 1;
        case TTIOPrecisionUInt16:     return 2;  // L1: chromosome_ids
        case TTIOPrecisionUInt64:     return 8;
    }
    return 0;
}

BOOL TTIOHDF5TypeIsBuiltin(TTIOPrecision precision)
{
    return precision != TTIOPrecisionComplex128;
}

hid_t TTIOHDF5TypeForPrecision(TTIOPrecision precision)
{
    switch (precision) {
        case TTIOPrecisionFloat32: return H5T_NATIVE_FLOAT;
        case TTIOPrecisionFloat64: return H5T_NATIVE_DOUBLE;
        case TTIOPrecisionInt32:   return H5T_NATIVE_INT32;
        case TTIOPrecisionInt64:   return H5T_NATIVE_INT64;
        case TTIOPrecisionUInt32:  return H5T_NATIVE_UINT32;
        case TTIOPrecisionUInt16:  return H5T_NATIVE_UINT16;  // L1: chromosome_ids
        case TTIOPrecisionUInt8:   return H5T_NATIVE_UINT8;
        case TTIOPrecisionUInt64:  return H5T_NATIVE_UINT64;
        case TTIOPrecisionComplex128: {
            // Compound { double real; double imag; } — caller must H5Tclose().
            hid_t t = H5Tcreate(H5T_COMPOUND, 2 * sizeof(double));
            H5Tinsert(t, "real", 0,              H5T_NATIVE_DOUBLE);
            H5Tinsert(t, "imag", sizeof(double), H5T_NATIVE_DOUBLE);
            return t;
        }
    }
    return H5I_INVALID_HID;
}
