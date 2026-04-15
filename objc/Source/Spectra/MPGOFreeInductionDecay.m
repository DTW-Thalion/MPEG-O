#import "MPGOFreeInductionDecay.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOFreeInductionDecay

- (instancetype)initWithComplexBuffer:(NSData *)buffer
                          complexLength:(NSUInteger)length
                       dwellTimeSeconds:(double)dwell
                              scanCount:(NSUInteger)scanCount
                           receiverGain:(double)gain
{
    NSParameterAssert(buffer.length == length * 2 * sizeof(double));
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionComplex128
                       compressionAlgorithm:MPGOCompressionNone
                                  byteOrder:MPGOByteOrderLittleEndian];
    self = [super initWithBuffer:buffer length:length encoding:enc axis:nil];
    if (self) {
        _dwellTimeSeconds = dwell;
        _scanCount        = scanCount;
        _receiverGain     = gain;
    }
    return self;
}

- (BOOL)writeToGroup:(MPGOHDF5Group *)group
                name:(NSString *)name
           chunkSize:(NSUInteger)chunkSize
    compressionLevel:(int)compressionLevel
               error:(NSError **)error
{
    if (![super writeToGroup:group
                        name:name
                   chunkSize:chunkSize
            compressionLevel:compressionLevel
                       error:error]) return NO;

    MPGOHDF5Group *sub = [group openGroupNamed:name error:error];
    if (!sub) return NO;
    if (![sub setIntegerAttribute:@"fid_scan_count"
                            value:(int64_t)_scanCount error:error]) return NO;

    MPGOHDF5Dataset *dwell = [sub createDatasetNamed:@"_fid_dwell_time"
                                            precision:MPGOPrecisionFloat64
                                               length:1
                                            chunkSize:0
                                     compressionLevel:0
                                                error:error];
    if (!dwell) return NO;
    double dt[1] = { _dwellTimeSeconds };
    if (![dwell writeData:[NSData dataWithBytes:dt length:sizeof(dt)] error:error]) return NO;

    MPGOHDF5Dataset *gain = [sub createDatasetNamed:@"_fid_receiver_gain"
                                           precision:MPGOPrecisionFloat64
                                              length:1
                                           chunkSize:0
                                    compressionLevel:0
                                               error:error];
    if (!gain) return NO;
    double g[1] = { _receiverGain };
    return [gain writeData:[NSData dataWithBytes:g length:sizeof(g)] error:error];
}

+ (instancetype)readFromGroup:(MPGOHDF5Group *)group
                         name:(NSString *)name
                        error:(NSError **)error
{
    MPGOSignalArray *base = [super readFromGroup:group name:name error:error];
    if (!base) return nil;

    MPGOHDF5Group *sub = [group openGroupNamed:name error:error];
    if (!sub) return nil;

    BOOL exists = NO;
    NSUInteger scanCount =
        (NSUInteger)[sub integerAttributeNamed:@"fid_scan_count"
                                        exists:&exists error:error];

    MPGOHDF5Dataset *dwellD = [sub openDatasetNamed:@"_fid_dwell_time" error:error];
    if (!dwellD) return nil;
    NSData *dwellData = [dwellD readDataWithError:error];
    double dwell = ((const double *)dwellData.bytes)[0];

    MPGOHDF5Dataset *gainD = [sub openDatasetNamed:@"_fid_receiver_gain" error:error];
    if (!gainD) return nil;
    NSData *gainData = [gainD readDataWithError:error];
    double gain = ((const double *)gainData.bytes)[0];

    return [[self alloc] initWithComplexBuffer:base.buffer
                                  complexLength:base.length
                               dwellTimeSeconds:dwell
                                      scanCount:scanCount
                                   receiverGain:gain];
}

- (BOOL)isEqual:(id)other
{
    if (![super isEqual:other]) return NO;
    if (![other isKindOfClass:[MPGOFreeInductionDecay class]]) return NO;
    MPGOFreeInductionDecay *o = (MPGOFreeInductionDecay *)other;
    return _dwellTimeSeconds == o.dwellTimeSeconds
        && _scanCount        == o.scanCount
        && _receiverGain     == o.receiverGain;
}

@end
