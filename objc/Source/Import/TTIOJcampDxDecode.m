#import "TTIOJcampDxDecode.h"
#import "HDF5/TTIOHDF5Errors.h"

typedef struct {
    int digit;
    int sign;
} TTIOCompCode;

static NSDictionary<NSNumber *, NSValue *> *gSqz = nil;
static NSDictionary<NSNumber *, NSValue *> *gDif = nil;
static NSDictionary<NSNumber *, NSNumber *> *gDup = nil;
static NSCharacterSet *gCompressionChars = nil;
static NSCharacterSet *gDetectChars = nil;

static NSValue *codeVal(int digit, int sign)
{
    TTIOCompCode c = { digit, sign };
    return [NSValue valueWithBytes:&c objCType:@encode(TTIOCompCode)];
}

static void setupTables(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *sqz = [NSMutableDictionary dictionary];
        sqz[@('@')] = codeVal(0, +1);
        const char *posS = "ABCDEFGHI";
        const char *negS = "abcdefghi";
        for (int i = 0; i < 9; i++) {
            sqz[@((unichar)posS[i])] = codeVal(i + 1, +1);
            sqz[@((unichar)negS[i])] = codeVal(i + 1, -1);
        }
        gSqz = sqz;

        NSMutableDictionary *dif = [NSMutableDictionary dictionary];
        dif[@('%')] = codeVal(0, +1);
        const char *posD = "JKLMNOPQR";
        const char *negD = "jklmnopqr";
        for (int i = 0; i < 9; i++) {
            dif[@((unichar)posD[i])] = codeVal(i + 1, +1);
            dif[@((unichar)negD[i])] = codeVal(i + 1, -1);
        }
        gDif = dif;

        NSMutableDictionary *dup = [NSMutableDictionary dictionary];
        const char *dupC = "STUVWXYZ";
        for (int i = 0; i < 8; i++) {
            dup[@((unichar)dupC[i])] = @(i + 2);
        }
        dup[@('s')] = @9;
        gDup = dup;

        NSMutableCharacterSet *cs = [NSMutableCharacterSet new];
        for (NSNumber *k in sqz) { [cs addCharactersInString:[NSString stringWithFormat:@"%C", [k unsignedShortValue]]]; }
        for (NSNumber *k in dif) { [cs addCharactersInString:[NSString stringWithFormat:@"%C", [k unsignedShortValue]]]; }
        for (NSNumber *k in dup) { [cs addCharactersInString:[NSString stringWithFormat:@"%C", [k unsignedShortValue]]]; }
        gCompressionChars = [cs copy];

        NSMutableCharacterSet *det = [cs mutableCopy];
        [det removeCharactersInString:@"Ee"];
        gDetectChars = [det copy];
    });
}

@implementation TTIOJcampDxDecode

+ (BOOL)hasCompression:(NSString *)body
{
    setupTables();
    NSRange r = [body rangeOfCharacterFromSet:gDetectChars];
    return r.location != NSNotFound;
}

static NSArray<NSString *> *tokenize(NSString *line)
{
    setupTables();
    NSMutableArray *tokens = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    NSUInteger len = line.length;
    for (NSUInteger i = 0; i < len; i++) {
        unichar ch = [line characterAtIndex:i];
        if ([[NSCharacterSet whitespaceCharacterSet] characterIsMember:ch]) {
            if (cur.length) { [tokens addObject:[cur copy]]; cur.string = @""; }
            continue;
        }
        if (ch == '$') break;
        BOOL isComp = [gCompressionChars characterIsMember:ch];
        if (isComp || ch == '+' || ch == '-') {
            if (cur.length) { [tokens addObject:[cur copy]]; cur.string = @""; }
            [cur appendFormat:@"%C", ch];
            continue;
        }
        if ((ch >= '0' && ch <= '9') || ch == '.' || ch == 'e' || ch == 'E') {
            [cur appendFormat:@"%C", ch];
            continue;
        }
        if (cur.length) { [tokens addObject:[cur copy]]; cur.string = @""; }
    }
    if (cur.length) [tokens addObject:[cur copy]];
    return tokens;
}

static double parseSqzOrAffn(NSString *tok)
{
    setupTables();
    unichar head = [tok characterAtIndex:0];
    NSValue *v = gSqz[@(head)];
    if (v) {
        TTIOCompCode c; [v getValue:&c];
        NSString *rest = [tok substringFromIndex:1];
        double magnitude;
        if (rest.length == 0) {
            magnitude = (double)c.digit;
        } else {
            magnitude = [[NSString stringWithFormat:@"%d%@", c.digit, rest] doubleValue];
        }
        return c.sign * magnitude;
    }
    return [tok doubleValue];
}

static double parseDif(NSString *tok)
{
    setupTables();
    unichar head = [tok characterAtIndex:0];
    NSValue *v = gDif[@(head)];
    TTIOCompCode c; [v getValue:&c];
    NSString *rest = [tok substringFromIndex:1];
    double magnitude;
    if (rest.length == 0) {
        magnitude = (double)c.digit;
    } else {
        magnitude = [[NSString stringWithFormat:@"%d%@", c.digit, rest] doubleValue];
    }
    return c.sign * magnitude;
}

static NSInteger parseDupCount(NSString *tok)
{
    setupTables();
    unichar head = [tok characterAtIndex:0];
    NSInteger base = [gDup[@(head)] integerValue];
    NSString *rest = [tok substringFromIndex:1];
    if (rest.length == 0) return base;
    return [[NSString stringWithFormat:@"%ld%@", (long)base, rest] integerValue];
}

+ (BOOL)decodeLines:(NSArray<NSString *> *)lines
             firstx:(double)firstx
             deltax:(double)deltax
            xfactor:(double)xfactor
            yfactor:(double)yfactor
            outXs:(NSMutableArray<NSNumber *> *)outXs
            outYs:(NSMutableArray<NSNumber *> *)outYs
            error:(NSError **)error
{
    setupTables();
    [outXs removeAllObjects];
    [outYs removeAllObjects];

    NSMutableArray<NSNumber *> *ysRaw = [NSMutableArray array];
    BOOL havePrev = NO;
    double prevLastY = 0.0;

    for (NSString *raw in lines) {
        NSRange cmt = [raw rangeOfString:@"$$"];
        NSString *base = cmt.location == NSNotFound ? raw : [raw substringToIndex:cmt.location];
        NSString *line = [base stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;

        NSArray<NSString *> *toks = tokenize(line);
        if (toks.count < 2) continue;

        BOOL haveCurrent = NO;
        double currentY = 0.0;
        NSMutableArray<NSNumber *> *lineYs = [NSMutableArray array];

        for (NSUInteger i = 1; i < toks.count; i++) {
            NSString *tok = toks[i];
            unichar head = [tok characterAtIndex:0];
            if (gDif[@(head)] != nil) {
                double base2;
                if (haveCurrent) {
                    base2 = currentY;
                } else if (havePrev) {
                    base2 = prevLastY;
                } else {
                    if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                        @"JCAMP-DX: DIF token at start of data stream");
                    return NO;
                }
                currentY = base2 + parseDif(tok);
                haveCurrent = YES;
                [lineYs addObject:@(currentY)];
            } else if (gDup[@(head)] != nil) {
                if (!haveCurrent) {
                    if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                        @"JCAMP-DX: DUP token before any absolute Y");
                    return NO;
                }
                NSInteger count = parseDupCount(tok) - 1;
                for (NSInteger k = 0; k < count; k++) [lineYs addObject:@(currentY)];
            } else {
                currentY = parseSqzOrAffn(tok);
                haveCurrent = YES;
                [lineYs addObject:@(currentY)];
            }
        }

        if (havePrev && lineYs.count > 0 &&
            fabs([lineYs[0] doubleValue] - prevLastY) < 1e-9) {
            [lineYs removeObjectAtIndex:0];
        }
        if (lineYs.count > 0) {
            [ysRaw addObjectsFromArray:lineYs];
            prevLastY = [[lineYs lastObject] doubleValue];
            havePrev = YES;
        }
    }

    NSUInteger n = ysRaw.count;
    for (NSUInteger i = 0; i < n; i++) {
        double x = (firstx + (double)i * deltax) * xfactor;
        double y = [ysRaw[i] doubleValue] * yfactor;
        [outXs addObject:@(x)];
        [outYs addObject:@(y)];
    }
    return YES;
}

@end
