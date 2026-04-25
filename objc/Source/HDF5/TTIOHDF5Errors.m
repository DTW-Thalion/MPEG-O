#import "TTIOHDF5Errors.h"

NSString *const TTIOErrorDomain = @"org.tio.TTIOErrorDomain";

NSError *TTIOMakeError(TTIOErrorCode code, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    return [NSError errorWithDomain:TTIOErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}
