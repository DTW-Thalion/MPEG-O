#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/MPGOCVParam.h"

static MPGOCVParam *roundTripCV(MPGOCVParam *p)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:p];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testCVParam(void)
{
    // ---- construction with all fields ----
    MPGOCVParam *full =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    PASS(full != nil, "MPGOCVParam constructible via class method");
    PASS([full.ontologyRef isEqualToString:@"MS"], "ontologyRef stored");
    PASS([full.accession isEqualToString:@"MS:1000511"], "accession stored");
    PASS([full.name isEqualToString:@"ms level"], "name stored");
    PASS([full.value isEqual:@2], "value stored");
    PASS(full.unit == nil, "nil unit is preserved");

    // ---- nil optional fields ----
    MPGOCVParam *valueOnly =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000514"
                                     name:@"m/z array"
                                    value:nil
                                     unit:@"MS:1000040"];
    PASS(valueOnly.value == nil, "nil value is preserved");
    PASS([valueOnly.unit isEqualToString:@"MS:1000040"], "unit-only param keeps unit");

    MPGOCVParam *bare =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000130"
                                     name:@"positive scan"
                                    value:nil
                                     unit:nil];
    PASS(bare.value == nil && bare.unit == nil,
         "param with no value or unit is well-formed");

    // ---- string fields are copied (defensive) ----
    NSMutableString *mut = [NSMutableString stringWithString:@"original_name"];
    MPGOCVParam *defcopy =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:0000001"
                                     name:mut
                                    value:nil
                                     unit:nil];
    [mut setString:@"mutated"];
    PASS([defcopy.name isEqualToString:@"original_name"],
         "name is defensively copied");

    // ---- equality ----
    MPGOCVParam *a =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    MPGOCVParam *b =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    MPGOCVParam *diffOnto =
        [MPGOCVParam paramWithOntologyRef:@"UO"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    MPGOCVParam *diffAcc =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000512"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    MPGOCVParam *diffName =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"different label"
                                    value:@2
                                     unit:nil];
    MPGOCVParam *diffValue =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@3
                                     unit:nil];
    MPGOCVParam *nilValue =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:nil
                                     unit:nil];

    PASS([a isEqual:a], "isEqual: reflexive");
    PASS([a isEqual:b], "isEqual: equal field values");
    PASS([a hash] == [b hash], "equal params hash equal (accession + ontologyRef)");
    PASS(![a isEqual:diffOnto],  "isEqual: distinguishes ontologyRef");
    PASS(![a isEqual:diffAcc],   "isEqual: distinguishes accession");
    PASS(![a isEqual:diffName],  "isEqual: distinguishes name");
    PASS(![a isEqual:diffValue], "isEqual: distinguishes value");
    PASS(![a isEqual:nilValue],  "isEqual: non-nil value vs nil value distinguished");
    PASS([nilValue isEqual:nilValue], "isEqual: two nil-value params reflexive");

    MPGOCVParam *nilValue2 =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:nil
                                     unit:nil];
    PASS([nilValue isEqual:nilValue2],
         "isEqual: two distinct instances with nil value compare equal");

    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS(![a isEqual:@"string"], "isEqual: foreign class → NO");

    // ---- copying (immutable) ----
    MPGOCVParam *cp = [a copy];
    PASS(cp == a, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    MPGOCVParam *decoded = roundTripCV(a);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS([decoded isEqual:a], "decoded equal to original");
    PASS([decoded.value isEqual:@2], "decoded numeric value preserved");

    MPGOCVParam *decodedBare = roundTripCV(bare);
    PASS([decodedBare isEqual:bare], "param with nil value+unit survives NSCoding");
    PASS(decodedBare.value == nil, "decoded nil value stays nil");
    PASS(decodedBare.unit  == nil, "decoded nil unit stays nil");

    // String value (not just NSNumber)
    MPGOCVParam *strParam =
        [MPGOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000031"
                                     name:@"instrument model"
                                    value:@"Q Exactive HF"
                                     unit:nil];
    MPGOCVParam *decodedStr = roundTripCV(strParam);
    PASS([decodedStr.value isEqualToString:@"Q Exactive HF"],
         "string value survives NSCoding round-trip");
}
