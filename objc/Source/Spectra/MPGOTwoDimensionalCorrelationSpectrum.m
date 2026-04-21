#import "MPGOTwoDimensionalCorrelationSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOTwoDimensionalCorrelationSpectrum

- (instancetype)initWithSynchronousMatrix:(NSData *)sync
                       asynchronousMatrix:(NSData *)asyn
                               matrixSize:(NSUInteger)size
                             variableAxis:(MPGOAxisDescriptor *)axis
                             perturbation:(NSString *)perturbation
                         perturbationUnit:(NSString *)perturbationUnit
                           sourceModality:(NSString *)sourceModality
                            indexPosition:(NSUInteger)indexPosition
                                    error:(NSError **)error
{
    NSUInteger expected = size * size * sizeof(double);
    if (sync.length != expected) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOTwoDimensionalCorrelationSpectrum: synchronousMatrix bytes %lu != size*size*8 = %lu",
            (unsigned long)sync.length, (unsigned long)expected);
        return nil;
    }
    if (asyn.length != expected) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOTwoDimensionalCorrelationSpectrum: asynchronousMatrix bytes %lu != size*size*8 = %lu",
            (unsigned long)asyn.length, (unsigned long)expected);
        return nil;
    }

    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    MPGOSignalArray *syncFlat = [[MPGOSignalArray alloc] initWithBuffer:sync
                                                                  length:size * size
                                                                encoding:enc
                                                                    axis:nil];
    MPGOSignalArray *asynFlat = [[MPGOSignalArray alloc] initWithBuffer:asyn
                                                                  length:size * size
                                                                encoding:enc
                                                                    axis:nil];
    NSDictionary *arrays = @{
        @"synchronous_matrix":  syncFlat,
        @"asynchronous_matrix": asynFlat,
    };
    self = [super initWithSignalArrays:arrays
                                  axes:(axis ? @[ axis ] : @[])
                         indexPosition:indexPosition
                       scanTimeSeconds:0
                           precursorMz:0
                       precursorCharge:0];
    if (self) {
        _synchronousMatrix  = [sync copy];
        _asynchronousMatrix = [asyn copy];
        _matrixSize         = size;
        _variableAxis       = axis;
        _perturbation       = [perturbation copy] ?: @"";
        _perturbationUnit   = [perturbationUnit copy] ?: @"";
        _sourceModality     = [sourceModality copy] ?: @"";
    }
    return self;
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGOTwoDimensionalCorrelationSpectrum class]]) return NO;
    MPGOTwoDimensionalCorrelationSpectrum *o = (MPGOTwoDimensionalCorrelationSpectrum *)other;
    if (_matrixSize != o.matrixSize) return NO;
    if (![_synchronousMatrix isEqualToData:o.synchronousMatrix]) return NO;
    if (![_asynchronousMatrix isEqualToData:o.asynchronousMatrix]) return NO;
    if (![_perturbation isEqualToString:o.perturbation]) return NO;
    if (![_perturbationUnit isEqualToString:o.perturbationUnit]) return NO;
    if (![_sourceModality isEqualToString:o.sourceModality]) return NO;
    return YES;
}

@end
