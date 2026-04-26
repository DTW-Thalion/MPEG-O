/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * NAME_TOKENIZED genomic read-name codec — lean two-token-type columnar.
 *
 * <p>Clean-room implementation matching the Python reference
 * ({@code python/src/ttio/codecs/name_tokenizer.py}) byte-for-byte.
 * The two-token-type tokenisation (numeric digit-runs vs string
 * non-digit-runs) is the simplest possible structural split of an
 * ASCII string; per-column type detection, delta encoding for
 * monotonic integer columns, and inline-dictionary encoding for
 * repeat-heavy string columns are all standard data-compression
 * techniques. <b>No htslib, no CRAM tools-Java, no SRA toolkit, no
 * samtools, no Bonfield 2022 reference source consulted at any
 * point.</b> This codec is <i>inspired by</i> CRAM 3.1's name
 * tokenisation algorithm in spirit but does NOT aim for CRAM-3.1
 * wire compatibility (HANDOFF.md M85B §10).
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.name_tokenizer}</li>
 *   <li>Objective-C: {@code TTIONameTokenizer}</li>
 * </ul>
 *
 * <p>Wire format (big-endian throughout, self-contained):
 * <pre>
 *   Header (7 bytes):
 *     Offset  Size  Field
 *     ──────  ────  ──────────────────────────────────────────
 *     0       1     version            (0x00)
 *     1       1     scheme_id          (0x00 = "lean-columnar")
 *     2       1     mode               (0x00 = columnar, 0x01 = verbatim)
 *     3       4     n_reads            (uint32 BE)
 *
 *   Columnar body (mode = 0x00):
 *     n_columns          (uint8; 0..255)
 *     column_type_table  (n_columns × uint8: 0 = numeric, 1 = string)
 *     per-column streams (in column order):
 *         Numeric: varint(first_value) + (n_reads-1) × svarint(delta_i)
 *         String:  n_reads × code_or_literal
 *             where each entry is varint(code), and if
 *             code == current_dict_size, immediately followed by
 *             varint(literal_byte_length) + literal_bytes.
 *
 *   Verbatim body (mode = 0x01):
 *     n_reads × { varint(byte_length), literal_bytes }
 * </pre>
 *
 * <p>Varints are unsigned LEB128 (low 7 bits of value first; top
 * bit = continuation flag). Signed deltas use zigzag-then-LEB128:
 * {@code encode(n) = (n << 1) ^ (n >> 63)} (two's-complement
 * arithmetic shift on int64).
 *
 * <p>Tokenisation rules (HANDOFF.md M85B §2.1; binding decisions
 * §103, §104):
 * <ul>
 *   <li>A numeric token is a maximal contiguous run of ASCII digits
 *       0..9 that is either (a) the single character "0", or
 *       (b) a digit-run of length ≥ 1 whose first character is NOT
 *       "0", AND whose integer value fits in int64 (&lt; 2^63).</li>
 *   <li>All other digit-runs are absorbed into the surrounding
 *       string token.</li>
 *   <li>A string token is a maximal run of bytes such that no valid
 *       numeric token appears inside it. Tokens alternate types
 *       after parsing. The empty name "" yields zero tokens.</li>
 * </ul>
 *
 * <p>Worked examples:
 * <pre>
 *   "READ:1:2"  → ["READ:", 1, ":", 2]
 *   "r0"        → ["r", 0]
 *   "r007"      → ["r007"]            (007 invalid numeric)
 *   "r007:1"    → ["r007:", 1]
 *   "0"         → [0]                 (single "0" valid)
 *   "0042"      → ["0042"]            (leading-zero run)
 *   "123abc"    → [123, "abc"]
 *   ""          → []
 * </pre>
 *
 * <p>The codec uses columnar mode IFF (a) all reads have exactly the
 * same number of tokens, AND (b) per-column token type matches across
 * all reads. Otherwise verbatim mode is used. The encoder picks
 * automatically (no caller-facing flag in v0).
 *
 * <p>Names must be 7-bit ASCII (binding decision §10 non-goals);
 * non-ASCII strings raise {@link IllegalArgumentException} on encode.
 */
public final class NameTokenizer {

    // ── Wire-format constants ───────────────────────────────────────

    /** Version byte — first byte of every NAME_TOKENIZED stream. */
    private static final byte VERSION = 0x00;

    /** Scheme id for the lean-columnar scheme (only one defined in v0). */
    private static final byte SCHEME_LEAN_COLUMNAR = 0x00;

    /** Mode byte: columnar body. */
    private static final byte MODE_COLUMNAR = 0x00;

    /** Mode byte: verbatim body. */
    private static final byte MODE_VERBATIM = 0x01;

    /** Header length: 1 (version) + 1 (scheme) + 1 (mode) + 4 (n_reads). */
    private static final int HEADER_LEN = 7;

    /** Column type tag: numeric. */
    private static final int TYPE_NUMERIC = 0;

    /** Column type tag: string. */
    private static final int TYPE_STRING = 1;

    private NameTokenizer() {
        // Utility class — non-instantiable.
    }

    // ── Token model ─────────────────────────────────────────────────

    /**
     * A single token from a tokenised name. Either numeric (with
     * {@code longValue} set and {@code isNumeric == true}) or string
     * (with {@code stringValue} set and {@code isNumeric == false}).
     */
    private static final class Token {
        final boolean isNumeric;
        final long longValue;
        final String stringValue;

        static Token numeric(long v) {
            return new Token(true, v, null);
        }

        static Token string(String s) {
            return new Token(false, 0L, s);
        }

        private Token(boolean isNumeric, long longValue, String stringValue) {
            this.isNumeric = isNumeric;
            this.longValue = longValue;
            this.stringValue = stringValue;
        }
    }

    // ── Public API ──────────────────────────────────────────────────

    /**
     * Encode a list of read names using NAME_TOKENIZED.
     *
     * <p>Tokenises each name into numeric and string runs, detects
     * per-column type, and emits either a columnar or verbatim stream
     * per the wire format in this class's javadoc. Returns a
     * self-contained byte array.
     *
     * <p>Names must be 7-bit ASCII; non-ASCII strings raise
     * {@link IllegalArgumentException}. An empty list produces an
     * 8-byte stream (header + n_columns = 0).
     *
     * @param names list of read names; must not be {@code null} and
     *              must not contain {@code null} elements.
     * @return encoded stream.
     * @throws IllegalArgumentException on non-ASCII input, null
     *         element, or if {@code names.size()} exceeds uint32.
     */
    public static byte[] encode(List<String> names) {
        if (names == null) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED encode: names must not be null");
        }
        long nReadsL = names.size();
        if (nReadsL > 0xFFFFFFFFL) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED n_reads " + nReadsL
                    + " exceeds uint32 limit");
        }
        int nReads = (int) nReadsL;

        // Pre-validate ASCII for every name and capture raw bytes for
        // possible verbatim path. Mirrors Python's early-validation
        // contract.
        byte[][] encodedNames = new byte[nReads][];
        for (int i = 0; i < nReads; i++) {
            String name = names.get(i);
            if (name == null) {
                throw new IllegalArgumentException(
                    "NAME_TOKENIZED name at index " + i + " is null");
            }
            for (int j = 0; j < name.length(); j++) {
                if (name.charAt(j) > 0x7F) {
                    throw new IllegalArgumentException(
                        "NAME_TOKENIZED name at index " + i
                            + " contains non-ASCII bytes");
                }
            }
            encodedNames[i] = name.getBytes(StandardCharsets.US_ASCII);
        }

        // Pass 1: tokenise.
        List<List<Token>> tokenised = new ArrayList<>(nReads);
        for (int i = 0; i < nReads; i++) {
            tokenised.add(tokenize(names.get(i)));
        }

        // Pass 2: choose mode (and infer type table for columnar).
        int[] typeTable = selectTypeTable(tokenised);
        boolean columnar = (typeTable != null);
        byte mode = columnar ? MODE_COLUMNAR : MODE_VERBATIM;

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(VERSION & 0xFF);
        out.write(SCHEME_LEAN_COLUMNAR & 0xFF);
        out.write(mode & 0xFF);
        writeUInt32BE(out, nReads);

        if (columnar) {
            encodeColumnar(out, tokenised, typeTable);
        } else {
            encodeVerbatim(out, encodedNames);
        }

        return out.toByteArray();
    }

    /**
     * Decode a stream produced by {@link #encode(List)}.
     *
     * <p>Returns the list of read names in the original order.
     *
     * @param encoded the encoded stream.
     * @return list of decoded read names.
     * @throws IllegalArgumentException if the stream is shorter than
     *         the 7-byte header, has a bad version byte, has a bad
     *         scheme_id, has a bad mode byte, or contains a malformed
     *         body (varint runs off the end, trailing bytes, an
     *         inline-dictionary code that exceeds the current dict
     *         size, etc.).
     */
    public static List<String> decode(byte[] encoded) {
        if (encoded == null) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED decode: input must not be null");
        }
        if (encoded.length < HEADER_LEN) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED stream too short for header: "
                    + encoded.length + " < " + HEADER_LEN);
        }

        int version = Byte.toUnsignedInt(encoded[0]);
        if (version != (VERSION & 0xFF)) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED bad version byte: 0x"
                    + String.format("%02x", version) + " (expected 0x00)");
        }

        int schemeId = Byte.toUnsignedInt(encoded[1]);
        if (schemeId != (SCHEME_LEAN_COLUMNAR & 0xFF)) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED unknown scheme_id: 0x"
                    + String.format("%02x", schemeId)
                    + " (only 0x00 = 'lean-columnar' is defined)");
        }

        int mode = Byte.toUnsignedInt(encoded[2]);
        long nReadsU = readUInt32BE(encoded, 3);
        if (nReadsU > Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED declared n_reads too large: " + nReadsU);
        }
        int nReads = (int) nReadsU;

        int[] offsetRef = {HEADER_LEN};
        List<String> names;
        if (mode == (MODE_COLUMNAR & 0xFF)) {
            names = decodeColumnar(encoded, offsetRef, nReads);
        } else if (mode == (MODE_VERBATIM & 0xFF)) {
            names = decodeVerbatim(encoded, offsetRef, nReads);
        } else {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED bad mode byte: 0x"
                    + String.format("%02x", mode)
                    + " (expected 0x00 columnar or 0x01 verbatim)");
        }

        if (offsetRef[0] != encoded.length) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED trailing bytes: consumed "
                    + offsetRef[0] + " of " + encoded.length);
        }
        return names;
    }

    // ── Tokeniser ───────────────────────────────────────────────────

    /**
     * Tokenise an ASCII read name into alternating numeric/string
     * tokens per HANDOFF.md §2.1.
     */
    private static List<Token> tokenize(String name) {
        List<Token> tokens = new ArrayList<>();
        int n = name.length();
        if (n == 0) {
            return tokens;
        }

        StringBuilder strBuf = new StringBuilder();
        int i = 0;
        while (i < n) {
            char c = name.charAt(i);
            if (c >= '0' && c <= '9') {
                // Consume maximal digit-run.
                int start = i;
                while (i < n) {
                    char d = name.charAt(i);
                    if (d < '0' || d > '9') break;
                    i++;
                }
                int runLen = i - start;
                String run = name.substring(start, i);
                boolean validNumeric = false;
                long value = 0;
                if (runLen == 1 || run.charAt(0) != '0') {
                    // Length 1 OR no leading zero. Now check int64
                    // overflow. A run of ≤ 18 ASCII digits is always
                    // < 10^18 < 2^63 = 9_223_372_036_854_775_808.
                    // For 19 digits, the value can be up to 10^19 - 1
                    // which overflows. Beyond 19 it's hopeless. We
                    // attempt a manual parse that detects overflow.
                    if (runLen <= 18) {
                        value = Long.parseLong(run);
                        validNumeric = true;
                    } else if (runLen == 19) {
                        // Check digit-by-digit against Long.MAX_VALUE
                        // = 9223372036854775807 (19 digits).
                        try {
                            value = Long.parseLong(run);
                            // parseLong accepts values up to 2^63 - 1.
                            // It throws NumberFormatException for >=
                            // 2^63. So a successful parse is safe.
                            validNumeric = true;
                        } catch (NumberFormatException ex) {
                            validNumeric = false;
                        }
                    } else {
                        // 20+ digits → guaranteed overflow.
                        validNumeric = false;
                    }
                }
                if (validNumeric) {
                    if (strBuf.length() > 0) {
                        tokens.add(Token.string(strBuf.toString()));
                        strBuf.setLength(0);
                    }
                    tokens.add(Token.numeric(value));
                } else {
                    // Absorb invalid digit-run into surrounding string.
                    strBuf.append(run);
                }
            } else {
                // Consume maximal non-digit run.
                int start = i;
                while (i < n) {
                    char d = name.charAt(i);
                    if (d >= '0' && d <= '9') break;
                    i++;
                }
                strBuf.append(name, start, i);
            }
        }

        if (strBuf.length() > 0) {
            tokens.add(Token.string(strBuf.toString()));
        }
        return tokens;
    }

    // ── Mode selection ──────────────────────────────────────────────

    /**
     * Returns a per-column type table iff all reads share the same
     * token count and per-column type. Returns {@code null} to signal
     * verbatim mode. Empty input yields a zero-length table (columnar
     * empty stream — HANDOFF.md §3.3 / gotcha §111).
     */
    private static int[] selectTypeTable(List<List<Token>> tokenised) {
        if (tokenised.isEmpty()) {
            return new int[0];
        }
        List<Token> first = tokenised.get(0);
        int firstCount = first.size();
        for (int i = 1; i < tokenised.size(); i++) {
            if (tokenised.get(i).size() != firstCount) {
                return null;
            }
        }
        int[] types = new int[firstCount];
        for (int c = 0; c < firstCount; c++) {
            types[c] = first.get(c).isNumeric ? TYPE_NUMERIC : TYPE_STRING;
        }
        for (int i = 1; i < tokenised.size(); i++) {
            List<Token> row = tokenised.get(i);
            for (int c = 0; c < firstCount; c++) {
                int expected = row.get(c).isNumeric ? TYPE_NUMERIC : TYPE_STRING;
                if (expected != types[c]) {
                    return null;
                }
            }
        }
        return types;
    }

    // ── Columnar encode / decode ────────────────────────────────────

    private static void encodeColumnar(
        ByteArrayOutputStream out,
        List<List<Token>> tokenised,
        int[] typeTable
    ) {
        int nReads = tokenised.size();
        int nColumns = typeTable.length;
        if (nColumns > 0xFF) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED n_columns " + nColumns
                    + " exceeds uint8 limit");
        }
        out.write(nColumns & 0xFF);
        for (int t : typeTable) {
            out.write(t & 0xFF);
        }
        if (nReads == 0) {
            return;
        }

        for (int col = 0; col < nColumns; col++) {
            int colType = typeTable[col];
            if (colType == TYPE_NUMERIC) {
                long prev = tokenised.get(0).get(col).longValue;
                writeVarint(out, prev);
                for (int r = 1; r < nReads; r++) {
                    long cur = tokenised.get(r).get(col).longValue;
                    writeSvarint(out, cur - prev);
                    prev = cur;
                }
            } else {
                // Inline dictionary, codes assigned in insertion order.
                Map<String, Integer> dict = new HashMap<>();
                for (int r = 0; r < nReads; r++) {
                    String token = tokenised.get(r).get(col).stringValue;
                    Integer code = dict.get(token);
                    if (code == null) {
                        int newCode = dict.size();
                        dict.put(token, newCode);
                        writeVarint(out, newCode);
                        byte[] payload = token.getBytes(StandardCharsets.US_ASCII);
                        writeVarint(out, payload.length);
                        out.write(payload, 0, payload.length);
                    } else {
                        writeVarint(out, code);
                    }
                }
            }
        }
    }

    private static List<String> decodeColumnar(
        byte[] buf, int[] offsetRef, int nReads
    ) {
        int offset = offsetRef[0];
        if (offset >= buf.length) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED columnar body missing n_columns byte");
        }
        int nColumns = Byte.toUnsignedInt(buf[offset]);
        offset++;
        if (offset + nColumns > buf.length) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED columnar type table truncated: need "
                    + nColumns + " bytes at offset " + offset);
        }
        int[] typeTable = new int[nColumns];
        for (int c = 0; c < nColumns; c++) {
            int t = Byte.toUnsignedInt(buf[offset + c]);
            if (t != TYPE_NUMERIC && t != TYPE_STRING) {
                throw new IllegalArgumentException(
                    "NAME_TOKENIZED unknown column type 0x"
                        + String.format("%02x", t));
            }
            typeTable[c] = t;
        }
        offset += nColumns;

        if (nReads == 0) {
            offsetRef[0] = offset;
            return new ArrayList<>();
        }

        // Per-column materialisation.
        Object[][] columns = new Object[nColumns][];
        long[] tmpVarint = new long[2];
        for (int c = 0; c < nColumns; c++) {
            int colType = typeTable[c];
            Object[] colValues = new Object[nReads];
            if (colType == TYPE_NUMERIC) {
                offset = readVarint(buf, offset, tmpVarint);
                long seed = tmpVarint[0];
                colValues[0] = seed;
                long prev = seed;
                for (int r = 1; r < nReads; r++) {
                    offset = readSvarint(buf, offset, tmpVarint);
                    long delta = tmpVarint[0];
                    long cur = prev + delta;
                    colValues[r] = cur;
                    prev = cur;
                }
            } else {
                List<String> dictEntries = new ArrayList<>();
                for (int r = 0; r < nReads; r++) {
                    offset = readVarint(buf, offset, tmpVarint);
                    long codeL = tmpVarint[0];
                    int curSize = dictEntries.size();
                    if (codeL < 0 || codeL > Integer.MAX_VALUE) {
                        throw new IllegalArgumentException(
                            "NAME_TOKENIZED string code " + codeL
                                + " out of int range");
                    }
                    int code = (int) codeL;
                    if (code < curSize) {
                        colValues[r] = dictEntries.get(code);
                    } else if (code == curSize) {
                        offset = readVarint(buf, offset, tmpVarint);
                        long lengthL = tmpVarint[0];
                        if (lengthL < 0 || lengthL > Integer.MAX_VALUE) {
                            throw new IllegalArgumentException(
                                "NAME_TOKENIZED string literal length "
                                    + lengthL + " out of int range");
                        }
                        int length = (int) lengthL;
                        if (offset + length > buf.length) {
                            throw new IllegalArgumentException(
                                "NAME_TOKENIZED string literal runs off end of stream");
                        }
                        // Validate ASCII while building the string.
                        for (int k = 0; k < length; k++) {
                            int b = Byte.toUnsignedInt(buf[offset + k]);
                            if (b > 0x7F) {
                                throw new IllegalArgumentException(
                                    "NAME_TOKENIZED string literal contains non-ASCII bytes");
                            }
                        }
                        String text = new String(
                            buf, offset, length, StandardCharsets.US_ASCII);
                        offset += length;
                        dictEntries.add(text);
                        colValues[r] = text;
                    } else {
                        throw new IllegalArgumentException(
                            "NAME_TOKENIZED string code " + code
                                + " > current dict size " + curSize
                                + " (malformed)");
                    }
                }
            }
            columns[c] = colValues;
        }

        // Reassemble names.
        List<String> names = new ArrayList<>(nReads);
        for (int r = 0; r < nReads; r++) {
            StringBuilder sb = new StringBuilder();
            for (int c = 0; c < nColumns; c++) {
                Object v = columns[c][r];
                if (typeTable[c] == TYPE_NUMERIC) {
                    sb.append(((Long) v).longValue());
                } else {
                    sb.append((String) v);
                }
            }
            names.add(sb.toString());
        }
        offsetRef[0] = offset;
        return names;
    }

    // ── Verbatim encode / decode ────────────────────────────────────

    private static void encodeVerbatim(
        ByteArrayOutputStream out, byte[][] encodedNames
    ) {
        for (byte[] payload : encodedNames) {
            writeVarint(out, payload.length);
            out.write(payload, 0, payload.length);
        }
    }

    private static List<String> decodeVerbatim(
        byte[] buf, int[] offsetRef, int nReads
    ) {
        int offset = offsetRef[0];
        List<String> names = new ArrayList<>(nReads);
        long[] tmp = new long[2];
        for (int r = 0; r < nReads; r++) {
            offset = readVarint(buf, offset, tmp);
            long lengthL = tmp[0];
            if (lengthL < 0 || lengthL > Integer.MAX_VALUE) {
                throw new IllegalArgumentException(
                    "NAME_TOKENIZED verbatim entry length " + lengthL
                        + " out of int range");
            }
            int length = (int) lengthL;
            if (offset + length > buf.length) {
                throw new IllegalArgumentException(
                    "NAME_TOKENIZED verbatim entry runs off end of stream");
            }
            for (int k = 0; k < length; k++) {
                int b = Byte.toUnsignedInt(buf[offset + k]);
                if (b > 0x7F) {
                    throw new IllegalArgumentException(
                        "NAME_TOKENIZED verbatim entry contains non-ASCII bytes");
                }
            }
            names.add(new String(buf, offset, length, StandardCharsets.US_ASCII));
            offset += length;
        }
        offsetRef[0] = offset;
        return names;
    }

    // ── Varint / svarint helpers ────────────────────────────────────

    /**
     * Write an unsigned LEB128 varint of a non-negative long value.
     * Negative values are not legal here.
     */
    private static void writeVarint(ByteArrayOutputStream out, long n) {
        if (n < 0) {
            throw new IllegalArgumentException(
                "NAME_TOKENIZED writeVarint: negative value " + n);
        }
        // Unsigned long-shift loop.
        while (Long.compareUnsigned(n, 0x80L) >= 0) {
            out.write((int) ((n & 0x7FL) | 0x80L));
            n >>>= 7;
        }
        out.write((int) (n & 0x7FL));
    }

    /**
     * Decode an unsigned LEB128 varint at {@code buf[offset:]}.
     * Stores the value into {@code out[0]} and returns the new
     * offset. Up to 10 bytes are accepted (full uint64 range).
     */
    private static int readVarint(byte[] buf, int offset, long[] out) {
        long value = 0;
        int shift = 0;
        int pos = offset;
        int n = buf.length;
        while (true) {
            if (pos >= n) {
                throw new IllegalArgumentException(
                    "NAME_TOKENIZED varint runs off end of stream at offset "
                        + offset);
            }
            int b = Byte.toUnsignedInt(buf[pos]);
            pos++;
            // Gotcha §114: ((long)(b & 0x7F)) << shift is required so
            // shifts of ≥ 32 don't lose the high bits.
            value |= ((long) (b & 0x7F)) << shift;
            if ((b & 0x80) == 0) {
                out[0] = value;
                return pos;
            }
            shift += 7;
            if (shift > 63) {
                throw new IllegalArgumentException(
                    "NAME_TOKENIZED varint overflow at offset " + offset);
            }
        }
    }

    /** Zigzag-encode a signed long into a non-negative long. */
    private static long zigzagEncode(long n) {
        return (n << 1) ^ (n >> 63);
    }

    /** Zigzag-decode a non-negative long back into a signed long. */
    private static long zigzagDecode(long n) {
        return (n >>> 1) ^ -(n & 1L);
    }

    private static void writeSvarint(ByteArrayOutputStream out, long n) {
        writeVarint(out, zigzagEncode(n));
    }

    private static int readSvarint(byte[] buf, int offset, long[] out) {
        int newOff = readVarint(buf, offset, out);
        out[0] = zigzagDecode(out[0]);
        return newOff;
    }

    // ── Header byte-order helpers ───────────────────────────────────

    private static void writeUInt32BE(ByteArrayOutputStream out, int val) {
        out.write((val >>> 24) & 0xFF);
        out.write((val >>> 16) & 0xFF);
        out.write((val >>> 8) & 0xFF);
        out.write(val & 0xFF);
    }

    private static long readUInt32BE(byte[] buf, int off) {
        return ((long) Byte.toUnsignedInt(buf[off]) << 24)
             | ((long) Byte.toUnsignedInt(buf[off + 1]) << 16)
             | ((long) Byte.toUnsignedInt(buf[off + 2]) << 8)
             | ((long) Byte.toUnsignedInt(buf[off + 3]));
    }

}
