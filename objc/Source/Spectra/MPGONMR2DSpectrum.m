#import "MPGONMR2DSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGONMR2DSpectrum

- (instancetype)initWithIntensityMatrix:(NSData *)matrix
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                 f1Axis:(MPGOAxisDescriptor *)f1
                                 f2Axis:(MPGOAxisDescriptor *)f2
                              nucleusF1:(NSString *)nucleusF1
                              nucleusF2:(NSString *)nucleusF2
                          indexPosition:(NSUInteger)indexPosition
                                  error:(NSError **)error
{
    NSUInteger expected = width * height * sizeof(double);
    if (matrix.length != expected) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGONMR2DSpectrum: matrix bytes %lu != width*height*8 = %lu",
            (unsigned long)matrix.length, (unsigned long)expected);
        return nil;
    }

    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    MPGOSignalArray *flat = [[MPGOSignalArray alloc] initWithBuffer:matrix
                                                             length:width * height
                                                           encoding:enc
                                                               axis:nil];
    NSDictionary *arrays = @{ @"intensity_matrix": flat };
    self = [super initWithSignalArrays:arrays
                                  axes:@[ f1, f2 ]
                         indexPosition:indexPosition
                       scanTimeSeconds:0
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _intensityMatrix = [matrix copy];
        _width           = width;
        _height          = height;
        _f1Axis          = f1;
        _f2Axis          = f2;
        _nucleusF1       = [nucleusF1 copy];
        _nucleusF2       = [nucleusF2 copy];
    }
    return self;
}

- (BOOL)writeAdditionalAttributesToGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    if (![group setIntegerAttribute:@"matrix_width"  value:(int64_t)_width  error:error]) return NO;
    if (![group setIntegerAttribute:@"matrix_height" value:(int64_t)_height error:error]) return NO;
    if (![group setStringAttribute:@"nucleus_f1" value:(_nucleusF1 ?: @"") error:error]) return NO;
    if (![group setStringAttribute:@"nucleus_f2" value:(_nucleusF2 ?: @"") error:error]) return NO;
    return YES;
}

- (BOOL)readAdditionalAttributesFromGroup:(MPGOHDF5Group *)group error:(NSError **)error
{
    BOOL exists = NO;
    _width  = (NSUInteger)[group integerAttributeNamed:@"matrix_width"
                                                exists:&exists error:error];
    _height = (NSUInteger)[group integerAttributeNamed:@"matrix_height"
                                                exists:&exists error:error];
    _nucleusF1 = [group stringAttributeNamed:@"nucleus_f1" error:error];
    _nucleusF2 = [group stringAttributeNamed:@"nucleus_f2" error:error];

    MPGOSignalArray *flat = self.signalArrays[@"intensity_matrix"];
    _intensityMatrix = [flat.buffer copy];
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGONMR2DSpectrum class]]) return NO;
    MPGONMR2DSpectrum *o = (MPGONMR2DSpectrum *)other;
    if (_width != o.width || _height != o.height) return NO;
    if (![_intensityMatrix isEqualToData:o.intensityMatrix]) return NO;
    if (![_nucleusF1 isEqualToString:o.nucleusF1]) return NO;
    if (![_nucleusF2 isEqualToString:o.nucleusF2]) return NO;
    return YES;
}

@end
