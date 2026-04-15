#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"

static MPGOEncodingSpec *roundTripSpec(MPGOEncodingSpec *s)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:s];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testEncodingSpec(void)
{
    // ---- construction + accessors ----
    MPGOEncodingSpec *s = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat32
                                         compressionAlgorithm:MPGOCompressionZlib
                                                    byteOrder:MPGOByteOrderLittleEndian];
    PASS(s != nil, "MPGOEncodingSpec constructible via class method");
    PASS(s.precision == MPGOPrecisionFloat32, "precision stored");
    PASS(s.compressionAlgorithm == MPGOCompressionZlib, "compression stored");
    PASS(s.byteOrder == MPGOByteOrderLittleEndian, "byte order stored");

    // ---- elementSize for every precision ----
    PASS([[MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat32
                         compressionAlgorithm:MPGOCompressionNone
                                    byteOrder:MPGOByteOrderLittleEndian] elementSize] == 4,
         "Float32 element size = 4");
    PASS([[MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                         compressionAlgorithm:MPGOCompressionNone
                                    byteOrder:MPGOByteOrderLittleEndian] elementSize] == 8,
         "Float64 element size = 8");
    PASS([[MPGOEncodingSpec specWithPrecision:MPGOPrecisionInt32
                         compressionAlgorithm:MPGOCompressionNone
                                    byteOrder:MPGOByteOrderLittleEndian] elementSize] == 4,
         "Int32 element size = 4");
    PASS([[MPGOEncodingSpec specWithPrecision:MPGOPrecisionInt64
                         compressionAlgorithm:MPGOCompressionNone
                                    byteOrder:MPGOByteOrderLittleEndian] elementSize] == 8,
         "Int64 element size = 8");
    PASS([[MPGOEncodingSpec specWithPrecision:MPGOPrecisionUInt32
                         compressionAlgorithm:MPGOCompressionNone
                                    byteOrder:MPGOByteOrderLittleEndian] elementSize] == 4,
         "UInt32 element size = 4");
    PASS([[MPGOEncodingSpec specWithPrecision:MPGOPrecisionComplex128
                         compressionAlgorithm:MPGOCompressionNone
                                    byteOrder:MPGOByteOrderLittleEndian] elementSize] == 16,
         "Complex128 element size = 16");

    // ---- equality ----
    MPGOEncodingSpec *a = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                                         compressionAlgorithm:MPGOCompressionLZ4
                                                    byteOrder:MPGOByteOrderBigEndian];
    MPGOEncodingSpec *b = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                                         compressionAlgorithm:MPGOCompressionLZ4
                                                    byteOrder:MPGOByteOrderBigEndian];
    MPGOEncodingSpec *diffPrec = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat32
                                                compressionAlgorithm:MPGOCompressionLZ4
                                                           byteOrder:MPGOByteOrderBigEndian];
    MPGOEncodingSpec *diffComp = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                                                compressionAlgorithm:MPGOCompressionZlib
                                                           byteOrder:MPGOByteOrderBigEndian];
    MPGOEncodingSpec *diffByte = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                                                compressionAlgorithm:MPGOCompressionLZ4
                                                           byteOrder:MPGOByteOrderLittleEndian];

    PASS([a isEqual:a], "isEqual: reflexive");
    PASS([a isEqual:b], "isEqual: equal field values");
    PASS([a hash] == [b hash], "equal objects hash equal");
    PASS(![a isEqual:diffPrec], "isEqual: distinguishes precision");
    PASS(![a isEqual:diffComp], "isEqual: distinguishes compression");
    PASS(![a isEqual:diffByte], "isEqual: distinguishes byte order");
    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS(![a isEqual:@42], "isEqual: foreign class → NO");

    // ---- copying (immutable) ----
    MPGOEncodingSpec *copy = [a copy];
    PASS(copy == a, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    MPGOEncodingSpec *decoded = roundTripSpec(a);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS([decoded isEqual:a], "decoded equal to original");
    PASS(decoded.precision == MPGOPrecisionFloat64, "decoded precision preserved");
    PASS(decoded.compressionAlgorithm == MPGOCompressionLZ4, "decoded compression preserved");
    PASS(decoded.byteOrder == MPGOByteOrderBigEndian, "decoded byte order preserved");

    // Round-trip Complex128 (largest element size)
    MPGOEncodingSpec *cplx = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionComplex128
                                            compressionAlgorithm:MPGOCompressionNone
                                                       byteOrder:MPGOByteOrderLittleEndian];
    MPGOEncodingSpec *decodedCplx = roundTripSpec(cplx);
    PASS([decodedCplx isEqual:cplx], "Complex128 spec survives NSCoding");
    PASS([decodedCplx elementSize] == 16, "decoded Complex128 element size preserved");
}
