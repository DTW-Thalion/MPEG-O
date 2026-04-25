#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"

static TTIOEncodingSpec *roundTripSpec(TTIOEncodingSpec *s)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:s];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testEncodingSpec(void)
{
    // ---- construction + accessors ----
    TTIOEncodingSpec *s = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat32
                                         compressionAlgorithm:TTIOCompressionZlib
                                                    byteOrder:TTIOByteOrderLittleEndian];
    PASS(s != nil, "TTIOEncodingSpec constructible via class method");
    PASS(s.precision == TTIOPrecisionFloat32, "precision stored");
    PASS(s.compressionAlgorithm == TTIOCompressionZlib, "compression stored");
    PASS(s.byteOrder == TTIOByteOrderLittleEndian, "byte order stored");

    // ---- elementSize for every precision ----
    PASS([[TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat32
                         compressionAlgorithm:TTIOCompressionNone
                                    byteOrder:TTIOByteOrderLittleEndian] elementSize] == 4,
         "Float32 element size = 4");
    PASS([[TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                         compressionAlgorithm:TTIOCompressionNone
                                    byteOrder:TTIOByteOrderLittleEndian] elementSize] == 8,
         "Float64 element size = 8");
    PASS([[TTIOEncodingSpec specWithPrecision:TTIOPrecisionInt32
                         compressionAlgorithm:TTIOCompressionNone
                                    byteOrder:TTIOByteOrderLittleEndian] elementSize] == 4,
         "Int32 element size = 4");
    PASS([[TTIOEncodingSpec specWithPrecision:TTIOPrecisionInt64
                         compressionAlgorithm:TTIOCompressionNone
                                    byteOrder:TTIOByteOrderLittleEndian] elementSize] == 8,
         "Int64 element size = 8");
    PASS([[TTIOEncodingSpec specWithPrecision:TTIOPrecisionUInt32
                         compressionAlgorithm:TTIOCompressionNone
                                    byteOrder:TTIOByteOrderLittleEndian] elementSize] == 4,
         "UInt32 element size = 4");
    PASS([[TTIOEncodingSpec specWithPrecision:TTIOPrecisionComplex128
                         compressionAlgorithm:TTIOCompressionNone
                                    byteOrder:TTIOByteOrderLittleEndian] elementSize] == 16,
         "Complex128 element size = 16");

    // ---- equality ----
    TTIOEncodingSpec *a = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                                         compressionAlgorithm:TTIOCompressionLZ4
                                                    byteOrder:TTIOByteOrderBigEndian];
    TTIOEncodingSpec *b = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                                         compressionAlgorithm:TTIOCompressionLZ4
                                                    byteOrder:TTIOByteOrderBigEndian];
    TTIOEncodingSpec *diffPrec = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat32
                                                compressionAlgorithm:TTIOCompressionLZ4
                                                           byteOrder:TTIOByteOrderBigEndian];
    TTIOEncodingSpec *diffComp = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                                                compressionAlgorithm:TTIOCompressionZlib
                                                           byteOrder:TTIOByteOrderBigEndian];
    TTIOEncodingSpec *diffByte = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                                                compressionAlgorithm:TTIOCompressionLZ4
                                                           byteOrder:TTIOByteOrderLittleEndian];

    PASS([a isEqual:a], "isEqual: reflexive");
    PASS([a isEqual:b], "isEqual: equal field values");
    PASS([a hash] == [b hash], "equal objects hash equal");
    PASS(![a isEqual:diffPrec], "isEqual: distinguishes precision");
    PASS(![a isEqual:diffComp], "isEqual: distinguishes compression");
    PASS(![a isEqual:diffByte], "isEqual: distinguishes byte order");
    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS(![a isEqual:@42], "isEqual: foreign class → NO");

    // ---- copying (immutable) ----
    TTIOEncodingSpec *copy = [a copy];
    PASS(copy == a, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    TTIOEncodingSpec *decoded = roundTripSpec(a);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS([decoded isEqual:a], "decoded equal to original");
    PASS(decoded.precision == TTIOPrecisionFloat64, "decoded precision preserved");
    PASS(decoded.compressionAlgorithm == TTIOCompressionLZ4, "decoded compression preserved");
    PASS(decoded.byteOrder == TTIOByteOrderBigEndian, "decoded byte order preserved");

    // Round-trip Complex128 (largest element size)
    TTIOEncodingSpec *cplx = [TTIOEncodingSpec specWithPrecision:TTIOPrecisionComplex128
                                            compressionAlgorithm:TTIOCompressionNone
                                                       byteOrder:TTIOByteOrderLittleEndian];
    TTIOEncodingSpec *decodedCplx = roundTripSpec(cplx);
    PASS([decodedCplx isEqual:cplx], "Complex128 spec survives NSCoding");
    PASS([decodedCplx elementSize] == 16, "decoded Complex128 element size preserved");
}
