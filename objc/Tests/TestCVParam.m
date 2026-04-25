#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/TTIOCVParam.h"

static TTIOCVParam *roundTripCV(TTIOCVParam *p)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:p];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testCVParam(void)
{
    // ---- construction with all fields ----
    TTIOCVParam *full =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    PASS(full != nil, "TTIOCVParam constructible via class method");
    PASS([full.ontologyRef isEqualToString:@"MS"], "ontologyRef stored");
    PASS([full.accession isEqualToString:@"MS:1000511"], "accession stored");
    PASS([full.name isEqualToString:@"ms level"], "name stored");
    PASS([full.value isEqual:@2], "value stored");
    PASS(full.unit == nil, "nil unit is preserved");

    // ---- nil optional fields ----
    TTIOCVParam *valueOnly =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000514"
                                     name:@"m/z array"
                                    value:nil
                                     unit:@"MS:1000040"];
    PASS(valueOnly.value == nil, "nil value is preserved");
    PASS([valueOnly.unit isEqualToString:@"MS:1000040"], "unit-only param keeps unit");

    TTIOCVParam *bare =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000130"
                                     name:@"positive scan"
                                    value:nil
                                     unit:nil];
    PASS(bare.value == nil && bare.unit == nil,
         "param with no value or unit is well-formed");

    // ---- string fields are copied (defensive) ----
    NSMutableString *mut = [NSMutableString stringWithString:@"original_name"];
    TTIOCVParam *defcopy =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:0000001"
                                     name:mut
                                    value:nil
                                     unit:nil];
    [mut setString:@"mutated"];
    PASS([defcopy.name isEqualToString:@"original_name"],
         "name is defensively copied");

    // ---- equality ----
    TTIOCVParam *a =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    TTIOCVParam *b =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    TTIOCVParam *diffOnto =
        [TTIOCVParam paramWithOntologyRef:@"UO"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    TTIOCVParam *diffAcc =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000512"
                                     name:@"ms level"
                                    value:@2
                                     unit:nil];
    TTIOCVParam *diffName =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"different label"
                                    value:@2
                                     unit:nil];
    TTIOCVParam *diffValue =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:@3
                                     unit:nil];
    TTIOCVParam *nilValue =
        [TTIOCVParam paramWithOntologyRef:@"MS"
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

    TTIOCVParam *nilValue2 =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000511"
                                     name:@"ms level"
                                    value:nil
                                     unit:nil];
    PASS([nilValue isEqual:nilValue2],
         "isEqual: two distinct instances with nil value compare equal");

    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS(![a isEqual:@"string"], "isEqual: foreign class → NO");

    // ---- copying (immutable) ----
    TTIOCVParam *cp = [a copy];
    PASS(cp == a, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    TTIOCVParam *decoded = roundTripCV(a);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS([decoded isEqual:a], "decoded equal to original");
    PASS([decoded.value isEqual:@2], "decoded numeric value preserved");

    TTIOCVParam *decodedBare = roundTripCV(bare);
    PASS([decodedBare isEqual:bare], "param with nil value+unit survives NSCoding");
    PASS(decodedBare.value == nil, "decoded nil value stays nil");
    PASS(decodedBare.unit  == nil, "decoded nil unit stays nil");

    // String value (not just NSNumber)
    TTIOCVParam *strParam =
        [TTIOCVParam paramWithOntologyRef:@"MS"
                                accession:@"MS:1000031"
                                     name:@"instrument model"
                                    value:@"Q Exactive HF"
                                     unit:nil];
    TTIOCVParam *decodedStr = roundTripCV(strParam);
    PASS([decodedStr.value isEqualToString:@"Q Exactive HF"],
         "string value survives NSCoding round-trip");
}
