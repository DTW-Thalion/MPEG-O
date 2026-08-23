/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "Import/TTIOXMLStreamParser.h"

#include <libxml/parser.h>
#include <libxml/xmlreader.h>
#include <pthread.h>
#include <string.h>

NSString *const TTIOXMLStreamParserErrorDomain = @"TTIOXMLStreamParserErrorDomain";

/* Text nodes and lookups above libxml2's 10 MB default ceiling are
 * normal in mzML, where one base64 <binary> can carry a whole
 * chromatogram. XML_PARSE_HUGE lifts the ceiling; entity substitution
 * stays off and XML_PARSE_NONET blocks external fetches, so the
 * expansion guards HUGE also disables have nothing to act on. */
static const int kTTIOXMLParseOptions = XML_PARSE_HUGE | XML_PARSE_NONET;

/* Attributes per element handled without a heap array. mzML's widest
 * element, <cvParam>, carries six. */
#define TTIO_XML_MAX_STACK_ATTRS 24

/** First error libxml2 reported during one parse. */
@interface TTIOXMLStreamParserErrorSink : NSObject
@property (nonatomic, strong) NSError *firstError;
@end

@implementation TTIOXMLStreamParserErrorSink
@end

static pthread_once_t sTTIOXMLInitOnce = PTHREAD_ONCE_INIT;

static void TTIOXMLInitLibrary(void)
{
    xmlInitParser();
}

static NSString *TTIOXMLString(const xmlChar *s)
{
    if (!s) return nil;
    NSString *out = [NSString stringWithUTF8String:(const char *)s];
    if (out) return out;
    /* Not valid UTF-8: keep the bytes rather than drop the node. */
    return [[NSString alloc] initWithBytes:s
                                    length:strlen((const char *)s)
                                  encoding:NSISOLatin1StringEncoding];
}

static void TTIOXMLReaderError(void *arg,
                               const char *msg,
                               xmlParserSeverities severity,
                               xmlTextReaderLocatorPtr locator)
{
    if (severity != XML_PARSER_SEVERITY_ERROR &&
        severity != XML_PARSER_SEVERITY_VALIDITY_ERROR) {
        return;
    }
    TTIOXMLStreamParserErrorSink *sink =
        (__bridge TTIOXMLStreamParserErrorSink *)arg;
    if (!sink || sink.firstError) return;

    NSString *text = msg ? TTIOXMLString((const xmlChar *)msg) : nil;
    text = [(text ?: @"XML parse error")
             stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    int line = locator ? xmlTextReaderLocatorLineNumber(locator) : 0;
    NSString *desc = (line > 0)
        ? [NSString stringWithFormat:@"%@ (line %d)", text, line]
        : text;
    sink.firstError =
        [NSError errorWithDomain:TTIOXMLStreamParserErrorDomain
                            code:TTIOXMLStreamParserErrorParseFailed
                        userInfo:@{NSLocalizedDescriptionKey: desc}];
}

static NSDictionary<NSString *, NSString *> *TTIOXMLAttributes(xmlTextReaderPtr reader)
{
    int count = xmlTextReaderAttributeCount(reader);
    if (count <= 0) return @{};
    if (xmlTextReaderMoveToFirstAttribute(reader) != 1) return @{};

    /* Strong: ARC elides the autorelease on strings returned from
     * TTIOXMLString, so these arrays hold the only reference until the
     * dictionary takes one of its own. */
    __strong id keys[TTIO_XML_MAX_STACK_ATTRS] = { nil };
    __strong id vals[TTIO_XML_MAX_STACK_ATTRS] = { nil };
    NSUInteger n = 0;
    NSMutableDictionary *overflow = nil;

    do {
        NSString *name  = TTIOXMLString(xmlTextReaderConstName(reader));
        NSString *value = TTIOXMLString(xmlTextReaderConstValue(reader));
        if (!name) continue;
        if (!value) value = @"";
        if (overflow) {
            overflow[name] = value;
        } else if (n < TTIO_XML_MAX_STACK_ATTRS) {
            keys[n] = name;
            vals[n] = value;
            n++;
        } else {
            overflow = [NSMutableDictionary dictionaryWithObjects:vals
                                                          forKeys:keys
                                                            count:n];
            overflow[name] = value;
        }
    } while (xmlTextReaderMoveToNextAttribute(reader) == 1);

    xmlTextReaderMoveToElement(reader);
    if (overflow) return overflow;
    return [NSDictionary dictionaryWithObjects:vals forKeys:keys count:n];
}

static BOOL TTIOXMLDrive(xmlTextReaderPtr reader,
                         id<NSXMLParserDelegate> delegate,
                         TTIOXMLStreamParserErrorSink *sink,
                         NSError **error)
{
    const BOOL wantsStart = [delegate respondsToSelector:
        @selector(parser:didStartElement:namespaceURI:qualifiedName:attributes:)];
    const BOOL wantsEnd = [delegate respondsToSelector:
        @selector(parser:didEndElement:namespaceURI:qualifiedName:)];
    const BOOL wantsText = [delegate respondsToSelector:
        @selector(parser:foundCharacters:)];

    NSXMLParser *noParser = nil;
    int ret = 1;

    while (ret == 1) {
        @autoreleasepool {
            ret = xmlTextReaderRead(reader);
            if (ret != 1) break;

            switch (xmlTextReaderNodeType(reader)) {
            case XML_READER_TYPE_ELEMENT: {
                NSString *name = TTIOXMLString(xmlTextReaderConstName(reader));
                if (!name) break;
                BOOL empty = (xmlTextReaderIsEmptyElement(reader) == 1);
                if (wantsStart) {
                    [delegate parser:noParser
                     didStartElement:name
                        namespaceURI:nil
                       qualifiedName:nil
                          attributes:TTIOXMLAttributes(reader)];
                }
                if (empty && wantsEnd) {
                    [delegate parser:noParser
                       didEndElement:name
                        namespaceURI:nil
                       qualifiedName:nil];
                }
                break;
            }
            case XML_READER_TYPE_END_ELEMENT: {
                if (!wantsEnd) break;
                NSString *name = TTIOXMLString(xmlTextReaderConstName(reader));
                if (!name) break;
                [delegate parser:noParser
                   didEndElement:name
                    namespaceURI:nil
                   qualifiedName:nil];
                break;
            }
            case XML_READER_TYPE_TEXT:
            case XML_READER_TYPE_CDATA:
            case XML_READER_TYPE_WHITESPACE:
            case XML_READER_TYPE_SIGNIFICANT_WHITESPACE: {
                if (!wantsText) break;
                NSString *text = TTIOXMLString(xmlTextReaderConstValue(reader));
                if (text) [delegate parser:noParser foundCharacters:text];
                break;
            }
            default:
                break;
            }
        }
    }

    if (ret == 0 && !sink.firstError) return YES;

    NSError *err = sink.firstError;
    if (!err) {
        err = [NSError errorWithDomain:TTIOXMLStreamParserErrorDomain
                                  code:TTIOXMLStreamParserErrorParseFailed
                              userInfo:@{NSLocalizedDescriptionKey:
                    @"XML parse ended before the end of the document"}];
    }
    if ([delegate respondsToSelector:@selector(parser:parseErrorOccurred:)]) {
        [delegate parser:noParser parseErrorOccurred:err];
    }
    if (error) *error = err;
    return NO;
}

@implementation TTIOXMLStreamParser

+ (BOOL)parseFileAtPath:(NSString *)path
               delegate:(id<NSXMLParserDelegate>)delegate
                  error:(NSError **)error
{
    pthread_once(&sTTIOXMLInitOnce, TTIOXMLInitLibrary);

    xmlTextReaderPtr reader =
        xmlReaderForFile([path fileSystemRepresentation], NULL,
                         kTTIOXMLParseOptions);
    if (!reader) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOXMLStreamParserErrorDomain
                                         code:TTIOXMLStreamParserErrorCannotOpen
                                     userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Cannot read %@", path]}];
        }
        return NO;
    }

    TTIOXMLStreamParserErrorSink *sink = [[TTIOXMLStreamParserErrorSink alloc] init];
    xmlTextReaderSetErrorHandler(reader, TTIOXMLReaderError, (__bridge void *)sink);
    BOOL ok = TTIOXMLDrive(reader, delegate, sink, error);
    xmlFreeTextReader(reader);
    return ok;
}

+ (BOOL)parseData:(NSData *)data
         delegate:(id<NSXMLParserDelegate>)delegate
            error:(NSError **)error
{
    pthread_once(&sTTIOXMLInitOnce, TTIOXMLInitLibrary);

    if (data.length > (NSUInteger)INT_MAX) {
        /* xmlReaderForMemory takes an int length; a buffer that large
         * belongs on the path-based reader. */
        if (error) {
            *error = [NSError errorWithDomain:TTIOXMLStreamParserErrorDomain
                                         code:TTIOXMLStreamParserErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                        @"In-memory XML larger than 2 GiB; parse from a file path"}];
        }
        return NO;
    }

    xmlTextReaderPtr reader =
        xmlReaderForMemory((const char *)data.bytes, (int)data.length,
                           NULL, NULL, kTTIOXMLParseOptions);
    if (!reader) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOXMLStreamParserErrorDomain
                                         code:TTIOXMLStreamParserErrorParseFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                        @"Cannot create an XML reader over the buffer"}];
        }
        return NO;
    }

    TTIOXMLStreamParserErrorSink *sink = [[TTIOXMLStreamParserErrorSink alloc] init];
    xmlTextReaderSetErrorHandler(reader, TTIOXMLReaderError, (__bridge void *)sink);
    BOOL ok = TTIOXMLDrive(reader, delegate, sink, error);
    xmlFreeTextReader(reader);
    return ok;
}

@end
