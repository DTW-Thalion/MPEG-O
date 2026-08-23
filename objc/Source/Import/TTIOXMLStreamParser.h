/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_XML_STREAM_PARSER_H
#define TTIO_XML_STREAM_PARSER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Import/TTIOXMLStreamParser.h</p>
 *
 * <p>Incremental SAX driver built on libxml2's xmlTextReader. It
 * feeds an existing <code>NSXMLParserDelegate</code> the same four
 * callbacks <code>NSXMLParser</code> sends, so a delegate written
 * against <code>NSXMLParser</code> works unchanged:</p>
 *
 * <ul>
 *  <li><code>parser:didStartElement:namespaceURI:qualifiedName:attributes:</code></li>
 *  <li><code>parser:didEndElement:namespaceURI:qualifiedName:</code></li>
 *  <li><code>parser:foundCharacters:</code></li>
 *  <li><code>parser:parseErrorOccurred:</code></li>
 * </ul>
 *
 * <p>Two differences from <code>NSXMLParser</code> matter to
 * callers:</p>
 *
 * <ol>
 *  <li>The <code>parser</code> argument is always <code>nil</code>.
 *      There is no <code>NSXMLParser</code> instance, so a delegate
 *      that calls back into it (<code>-abortParsing</code>,
 *      <code>-lineNumber</code>) cannot use this driver.</li>
 *  <li><code>parseFileAtPath:</code> reads the document in fixed-size
 *      chunks. Peak memory is the largest single text node, not the
 *      file size, so multi-gigabyte documents parse in bounded
 *      memory. <code>+[NSData dataWithContentsOfFile:]</code> plus
 *      <code>-[NSXMLParser initWithData:]</code> needs several times
 *      the file size resident.</li>
 * </ol>
 *
 * <p>Element names are the qualified names as they appear in the
 * document, matching <code>NSXMLParser</code> with
 * <code>shouldProcessNamespaces</code> set to <code>NO</code>.
 * <code>namespaceURI</code> and <code>qualifiedName</code> are
 * always <code>nil</code>. Empty elements
 * (<code>&lt;cvParam ... /&gt;</code>) produce a start callback
 * immediately followed by an end callback.</p>
 *
 * <p><strong>Parser options.</strong> <code>XML_PARSE_HUGE</code> is
 * set, which lifts libxml2's 10 MB text-node and lookup ceilings —
 * mzML files store a whole chromatogram as one base64 text node and
 * routinely cross them. It also lifts libxml2's entity-expansion
 * guards, so general entities are deliberately <em>not</em>
 * substituted and network access is off
 * (<code>XML_PARSE_NONET</code>): an entity reference is skipped
 * rather than expanded.</p>
 *
 * <p><strong>API status:</strong> Internal. Not thread-safe; one
 * parse per instance of the calling delegate.</p>
 */
@interface TTIOXMLStreamParser : NSObject

/**
 * Parse an XML document from a filesystem path, in bounded memory.
 *
 * @param path      Filesystem path to the document.
 * @param delegate  Receives the SAX callbacks. Not retained.
 * @param error     On failure, populated with an ``NSError`` in
 *                  ``TTIOXMLStreamParserErrorDomain``. May be
 *                  ``NULL``.
 * @return ``YES`` when the document parsed to completion.
 */
+ (BOOL)parseFileAtPath:(NSString *)path
               delegate:(id<NSXMLParserDelegate>)delegate
                  error:(NSError **)error;

/**
 * Parse an XML document already held in memory.
 *
 * @param data      Raw XML bytes.
 * @param delegate  Receives the SAX callbacks. Not retained.
 * @param error     On failure, populated with an ``NSError``. May be
 *                  ``NULL``.
 * @return ``YES`` when the document parsed to completion.
 */
+ (BOOL)parseData:(NSData *)data
         delegate:(id<NSXMLParserDelegate>)delegate
            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

extern NSString *const TTIOXMLStreamParserErrorDomain;

/** Codes reported in ``TTIOXMLStreamParserErrorDomain``. */
typedef NS_ENUM(NSInteger, TTIOXMLStreamParserErrorCode) {
    /** libxml2 rejected the document. */
    TTIOXMLStreamParserErrorParseFailed = 1,
    /** The path could not be opened. */
    TTIOXMLStreamParserErrorCannotOpen  = 2
};

#endif /* TTIO_XML_STREAM_PARSER_H */
