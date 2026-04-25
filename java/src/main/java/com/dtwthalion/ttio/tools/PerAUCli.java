/*
 * TTI-O Java Implementation — v1.0 per-AU encryption CLI.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.tools;

import com.dtwthalion.ttio.protection.EncryptedTransport;
import com.dtwthalion.ttio.protection.PerAUEncryption.AUHeaderPlaintext;
import com.dtwthalion.ttio.protection.PerAUFile;
import com.dtwthalion.ttio.transport.TransportWriter;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.TreeMap;

/**
 * Cross-language conformance CLI for v1.0 per-AU encryption. The
 * Python driver ({@code tests/integration/
 * test_per_au_cross_language.py}) invokes this, the ObjC
 * {@code TtioPerAU} tool, and the Python {@code
 * ttio.tools.per_au_cli} to verify byte-equivalent outputs across
 * implementations.
 *
 * <p>Usage:
 * <pre>
 *   java -cp ... PerAUCli encrypt  in.tio out.tio key [--headers]
 *   java -cp ... PerAUCli decrypt  in.tio out.npz_like key
 *   java -cp ... PerAUCli send     in.tio out.tis
 *   java -cp ... PerAUCli recv     in.tis out.tio
 * </pre>
 *
 * <p>Decryption emits a minimal, language-agnostic binary dump
 * compatible with the Python side's NPZ convention so cross-language
 * byte-equality checks work without depending on the Python
 * interpreter to read Java output. Layout:
 * <pre>
 *   MAGIC "MPAD" (4 bytes) | u32 n_entries
 *   per entry: u16 key_len | utf8 key bytes | u32 byte_len | bytes
 * </pre>
 * Keys are sorted lexicographically.
 *
 * @since 1.0
 */
public final class PerAUCli {

    private static final byte[] MAGIC = {'M', 'P', 'A', 'D'};

    public static void main(String[] args) throws Exception {
        if (args.length < 1) usageAndExit();
        String cmd = args[0];
        switch (cmd) {
            case "encrypt" -> encrypt(args);
            case "decrypt" -> decrypt(args);
            case "send" -> send(args);
            case "recv" -> recv(args);
            default -> usageAndExit();
        }
    }

    private static void encrypt(String[] args) throws Exception {
        if (args.length < 4) usageAndExit();
        boolean headers = args.length > 4 && "--headers".equals(args[4]);
        Files.copy(Path.of(args[1]), Path.of(args[2]),
                   java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        PerAUFile.encryptFile(args[2], readKey(args[3]), headers, "hdf5");
    }

    private static void decrypt(String[] args) throws Exception {
        if (args.length < 4) usageAndExit();
        Map<String, PerAUFile.DecryptedRun> plain =
            PerAUFile.decryptFile(args[1], readKey(args[3]), "hdf5");

        TreeMap<String, byte[]> entries = new TreeMap<>();
        for (Map.Entry<String, PerAUFile.DecryptedRun> e : plain.entrySet()) {
            String runName = e.getKey();
            for (Map.Entry<String, byte[]> c : e.getValue().channels().entrySet()) {
                entries.put(runName + "__" + c.getKey(), c.getValue());
            }
            if (e.getValue().auHeaders() != null) {
                entries.put(runName + "__au_headers_json",
                             auHeadersJson(e.getValue().auHeaders())
                                .getBytes(StandardCharsets.UTF_8));
            }
        }

        try (OutputStream fos = new BufferedOutputStream(new FileOutputStream(args[2]));
             DataOutputStream out = new DataOutputStream(fos)) {
            fos.write(MAGIC);
            writeU32LE(out, entries.size());
            for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                byte[] k = e.getKey().getBytes(StandardCharsets.UTF_8);
                writeU16LE(out, k.length);
                out.write(k);
                writeU32LE(out, e.getValue().length);
                out.write(e.getValue());
            }
        }
    }

    private static void send(String[] args) throws Exception {
        if (args.length < 3) usageAndExit();
        try (OutputStream fos = new BufferedOutputStream(new FileOutputStream(args[2]));
             TransportWriter tw = new TransportWriter(fos)) {
            EncryptedTransport.writeEncryptedDataset(args[1], tw, "hdf5");
        }
    }

    private static void recv(String[] args) throws Exception {
        if (args.length < 3) usageAndExit();
        byte[] stream = Files.readAllBytes(Path.of(args[1]));
        EncryptedTransport.readEncryptedToPath(args[2], stream, "hdf5");
    }

    // ─────────────────────────────────────────── helpers

    private static byte[] readKey(String path) throws Exception {
        byte[] k = Files.readAllBytes(Path.of(path));
        if (k.length != 32) {
            throw new IllegalArgumentException(
                "key file must be 32 bytes, got " + k.length);
        }
        return k;
    }

    private static String auHeadersJson(java.util.List<AUHeaderPlaintext> rows) {
        // Tiny sorted-key JSON emitter that matches what the Python
        // cross-language test expects from ``per_au_cli decrypt``'s
        // __au_headers_json artefact.
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < rows.size(); i++) {
            if (i > 0) sb.append(',');
            AUHeaderPlaintext r = rows.get(i);
            sb.append("{");
            sb.append("\"acquisition_mode\":").append(r.acquisitionMode());
            sb.append(",\"base_peak_intensity\":").append(jsonDouble(r.basePeakIntensity()));
            sb.append(",\"ion_mobility\":").append(jsonDouble(r.ionMobility()));
            sb.append(",\"ms_level\":").append(r.msLevel());
            sb.append(",\"polarity\":").append(r.polarity());
            sb.append(",\"precursor_charge\":").append(r.precursorCharge());
            sb.append(",\"precursor_mz\":").append(jsonDouble(r.precursorMz()));
            sb.append(",\"retention_time\":").append(jsonDouble(r.retentionTime()));
            sb.append("}");
        }
        sb.append(']');
        return sb.toString();
    }

    private static String jsonDouble(double d) {
        if (d == Math.floor(d) && !Double.isInfinite(d)) {
            return String.format(java.util.Locale.ROOT, "%.1f", d);
        }
        return Double.toString(d);
    }

    private static void writeU16LE(OutputStream out, int v) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN);
        b.putShort((short) (v & 0xFFFF));
        out.write(b.array());
    }

    private static void writeU32LE(OutputStream out, int v) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(v);
        out.write(b.array());
    }

    private static void usageAndExit() {
        System.err.println(
            "usage: PerAUCli <encrypt|decrypt|send|recv> <in> <out> [<key>] [--headers]");
        System.exit(2);
    }
}
