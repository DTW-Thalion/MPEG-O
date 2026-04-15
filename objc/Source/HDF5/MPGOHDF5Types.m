#import "MPGOHDF5Types.h"

NSUInteger MPGOPrecisionElementSize(MPGOPrecision precision)
{
    switch (precision) {
        case MPGOPrecisionFloat32:    return 4;
        case MPGOPrecisionFloat64:    return 8;
        case MPGOPrecisionInt32:      return 4;
        case MPGOPrecisionInt64:      return 8;
        case MPGOPrecisionUInt32:     return 4;
        case MPGOPrecisionComplex128: return 16;
    }
    return 0;
}

BOOL MPGOHDF5TypeIsBuiltin(MPGOPrecision precision)
{
    return precision != MPGOPrecisionComplex128;
}

hid_t MPGOHDF5TypeForPrecision(MPGOPrecision precision)
{
    switch (precision) {
        case MPGOPrecisionFloat32: return H5T_NATIVE_FLOAT;
        case MPGOPrecisionFloat64: return H5T_NATIVE_DOUBLE;
        case MPGOPrecisionInt32:   return H5T_NATIVE_INT32;
        case MPGOPrecisionInt64:   return H5T_NATIVE_INT64;
        case MPGOPrecisionUInt32:  return H5T_NATIVE_UINT32;
        case MPGOPrecisionComplex128: {
            // Compound { double real; double imag; } — caller must H5Tclose().
            hid_t t = H5Tcreate(H5T_COMPOUND, 2 * sizeof(double));
            H5Tinsert(t, "real", 0,              H5T_NATIVE_DOUBLE);
            H5Tinsert(t, "imag", sizeof(double), H5T_NATIVE_DOUBLE);
            return t;
        }
    }
    return H5I_INVALID_HID;
}
