#import <Foundation/Foundation.h>
#import "Testing.h"

#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOCVParam.h"

/*
 * Phase 2 smoke test — just enough to verify that libMPGO is linkable
 * and the value classes can be instantiated. Milestone 1 will replace
 * this with full coverage of construction, equality, hashing, copying,
 * and NSCoding round-trips.
 */
void testPhase2Smoke(void)
{
    MPGOValueRange *range = [MPGOValueRange rangeWithMinimum:0.0 maximum:1000.0];
    PASS(range != nil, "MPGOValueRange can be constructed");
    PASS([range span] == 1000.0, "MPGOValueRange span is correct");
    PASS([range containsValue:500.0], "MPGOValueRange contains midpoint");

    MPGOEncodingSpec *spec = [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                                            compressionAlgorithm:MPGOCompressionZlib
                                                       byteOrder:MPGOByteOrderLittleEndian];
    PASS(spec != nil, "MPGOEncodingSpec can be constructed");
    PASS([spec elementSize] == 8, "Float64 element size is 8 bytes");

    MPGOAxisDescriptor *axis = [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                                                 unit:@"MS:1000040"
                                                           valueRange:range
                                                         samplingMode:MPGOSamplingModeNonUniform];
    PASS(axis != nil, "MPGOAxisDescriptor can be constructed");
    PASS([axis.name isEqualToString:@"m/z"], "Axis name stored");

    MPGOCVParam *param = [MPGOCVParam paramWithOntologyRef:@"MS"
                                                 accession:@"MS:1000514"
                                                      name:@"m/z array"
                                                     value:nil
                                                      unit:@"MS:1000040"];
    PASS(param != nil, "MPGOCVParam can be constructed");
    PASS([param.accession isEqualToString:@"MS:1000514"], "CVParam accession stored");
}
