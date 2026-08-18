/* External-FASTA branch of TTIOReferenceResolver: a run written against
 * a multi-chromosome FASTA records the reference-set md5, and the
 * resolver must accept it (and still accept the pre-1.9
 * single-chromosome digests).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOReferenceResolver.h"
#import "Genomics/TTIOLazyReference.h"
#include <openssl/md5.h>
#include <unistd.h>

static NSData *rreMD5(NSArray<NSData *> *parts)
{
    MD5_CTX c; MD5_Init(&c);
    for (NSData *d in parts) MD5_Update(&c, d.bytes, d.length);
    uint8_t digest[16]; MD5_Final(digest, &c);
    return [NSData dataWithBytes:digest length:16];
}

static NSData *rreBytes(const char *s)
{
    return [NSData dataWithBytes:s length:strlen(s)];
}

void testReferenceResolverExternal(void);
void testReferenceResolverExternal(void)
{
    NSString *fa = [NSString stringWithFormat:@"/tmp/rre-%d.fa", (int)getpid()];
    NSString *fai = [fa stringByAppendingString:@".fai"];
    [@">chr2\nGGGGCCCC\n>chr1\nacgtACGT\n>chrM\nTTTT\n" writeToFile:fa atomically:YES
                                                       encoding:NSASCIIStringEncoding error:NULL];
    NSData *chr1 = rreBytes("acgtACGT");
    NSData *chr1Upper = rreBytes("ACGTACGT");
    NSData *setMD5 = rreMD5(@[chr1, rreBytes("GGGGCCCC"), rreBytes("TTTT")]);

    NSError *e = nil;
    TTIOLazyReference *lazy = [[TTIOLazyReference alloc] initWithFastaPath:fa error:&e];
    PASS(lazy != nil, "rre: LazyReference opens the FASTA");
    PASS([[lazy setMD5] isEqualToData:setMD5], "rre: setMD5 is the sorted-concatenation digest");
    NSString *side = [fa stringByAppendingString:@".ttio-md5"];
    NSString *sideText = [NSString stringWithContentsOfFile:side encoding:NSASCIIStringEncoding error:NULL];
    NSArray *parts = [[sideText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                      componentsSeparatedByString:@" "];
    PASS(parts.count == 3 && [(NSString *)parts[0] length] == 32, "rre: sidecar written as <hex> <size> <mtime>");
    [[NSString stringWithFormat:@"00000000000000000000000000000000 %@ %@\n", parts[1], parts[2]]
        writeToFile:side atomically:YES encoding:NSASCIIStringEncoding error:NULL];
    uint8_t z[16] = {0};
    TTIOLazyReference *lazy2 = [[TTIOLazyReference alloc] initWithFastaPath:fa error:&e];
    PASS([[lazy2 setMD5] isEqualToData:[NSData dataWithBytes:z length:16]], "rre: sidecar trusted while size and mtime match");
    [@"00000000000000000000000000000000 1 1\n" writeToFile:side atomically:YES encoding:NSASCIIStringEncoding error:NULL];
    TTIOLazyReference *lazy3 = [[TTIOLazyReference alloc] initWithFastaPath:fa error:&e];
    PASS([[lazy3 setMD5] isEqualToData:setMD5], "rre: stale sidecar recomputed");

    TTIOReferenceResolver *r = [[TTIOReferenceResolver alloc] initWithRootGroup:nil
                                                            externalReferencePath:fa];
    NSData *got = [r resolveURI:@"x" expectedMD5:setMD5 chromosome:@"chr1" error:&e];
    PASS([got isEqualToData:chr1Upper], "rre: reference-set md5 resolves chr1 (upper-cased)");
    got = [r resolveURI:@"x" expectedMD5:setMD5 chromosome:@"chr2" error:&e];
    PASS([got isEqualToData:rreBytes("GGGGCCCC")], "rre: reference-set md5 resolves chr2");
    got = [r resolveURI:@"x" expectedMD5:rreMD5(@[chr1]) chromosome:@"chr1" error:&e];
    PASS([got isEqualToData:chr1Upper], "rre: single-chromosome raw md5 still resolves");
    got = [r resolveURI:@"x" expectedMD5:rreMD5(@[chr1Upper]) chromosome:@"chr1" error:&e];
    PASS([got isEqualToData:chr1Upper], "rre: single-chromosome upper md5 still resolves");
    e = nil;
    uint8_t zeros[16] = {0};
    got = [r resolveURI:@"x" expectedMD5:[NSData dataWithBytes:zeros length:16] chromosome:@"chr1" error:&e];
    PASS(got == nil && e != nil, "rre: a wrong digest is an error");
    PASS([e.localizedDescription rangeOfString:@"whole FASTA"].location != NSNotFound,
         "rre: the error names the whole-FASTA digest");
    e = nil;
    got = [r resolveURI:@"x" expectedMD5:setMD5 chromosome:@"chrZ" error:&e];
    PASS(got == nil && e != nil, "rre: an unknown chromosome is an error");

    unlink([fa fileSystemRepresentation]);
    unlink([fai fileSystemRepresentation]);
    unlink([[fa stringByAppendingString:@".ttio-md5"] fileSystemRepresentation]);
}
