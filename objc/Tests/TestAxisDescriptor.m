#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"

static MPGOAxisDescriptor *roundTripAxis(MPGOAxisDescriptor *a)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:a];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testAxisDescriptor(void)
{
    MPGOValueRange *mzRange =
        [MPGOValueRange rangeWithMinimum:50.0 maximum:2000.0];

    // ---- construction ----
    MPGOAxisDescriptor *axis =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"MS:1000040"
                                    valueRange:mzRange
                                  samplingMode:MPGOSamplingModeNonUniform];
    PASS(axis != nil, "MPGOAxisDescriptor constructible via class method");
    PASS([axis.name isEqualToString:@"m/z"], "name stored");
    PASS([axis.unit isEqualToString:@"MS:1000040"], "unit stored");
    PASS([axis.valueRange isEqual:mzRange], "valueRange stored");
    PASS(axis.samplingMode == MPGOSamplingModeNonUniform, "samplingMode stored");

    // ---- both sampling modes ----
    MPGOAxisDescriptor *uniform =
        [MPGOAxisDescriptor descriptorWithName:@"time"
                                          unit:@"s"
                                    valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:60]
                                  samplingMode:MPGOSamplingModeUniform];
    PASS(uniform.samplingMode == MPGOSamplingModeUniform, "uniform sampling mode stored");

    // ---- name/unit are copied (defensive copy of NSString) ----
    NSMutableString *mutableName = [NSMutableString stringWithString:@"original"];
    MPGOAxisDescriptor *copyAxis =
        [MPGOAxisDescriptor descriptorWithName:mutableName
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:MPGOSamplingModeUniform];
    [mutableName setString:@"mutated"];
    PASS([copyAxis.name isEqualToString:@"original"],
         "name is defensively copied — caller mutation does not leak in");

    // ---- equality ----
    MPGOAxisDescriptor *a1 =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:MPGOSamplingModeNonUniform];
    MPGOAxisDescriptor *a2 =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:[MPGOValueRange rangeWithMinimum:50 maximum:2000]
                                  samplingMode:MPGOSamplingModeNonUniform];
    MPGOAxisDescriptor *diffName =
        [MPGOAxisDescriptor descriptorWithName:@"intensity"
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:MPGOSamplingModeNonUniform];
    MPGOAxisDescriptor *diffUnit =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"Da"
                                    valueRange:mzRange
                                  samplingMode:MPGOSamplingModeNonUniform];
    MPGOAxisDescriptor *diffRange =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:1]
                                  samplingMode:MPGOSamplingModeNonUniform];
    MPGOAxisDescriptor *diffMode =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:MPGOSamplingModeUniform];

    PASS([a1 isEqual:a1], "isEqual: reflexive");
    PASS([a1 isEqual:a2], "isEqual: equal by value (different range instance)");
    PASS([a1 hash] == [a2 hash], "equal axes hash equal");
    PASS(![a1 isEqual:diffName],  "isEqual: distinguishes name");
    PASS(![a1 isEqual:diffUnit],  "isEqual: distinguishes unit");
    PASS(![a1 isEqual:diffRange], "isEqual: distinguishes valueRange");
    PASS(![a1 isEqual:diffMode],  "isEqual: distinguishes samplingMode");
    PASS(![a1 isEqual:nil], "isEqual: nil → NO");

    // ---- copying (immutable) ----
    MPGOAxisDescriptor *c = [a1 copy];
    PASS(c == a1, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    MPGOAxisDescriptor *decoded = roundTripAxis(a1);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS([decoded isEqual:a1], "decoded equal to original");
    PASS([decoded.name isEqualToString:@"m/z"], "decoded name preserved");
    PASS([decoded.unit isEqualToString:@"u"], "decoded unit preserved");
    PASS([decoded.valueRange isEqual:mzRange], "decoded valueRange preserved");
    PASS(decoded.samplingMode == MPGOSamplingModeNonUniform, "decoded samplingMode preserved");
}
