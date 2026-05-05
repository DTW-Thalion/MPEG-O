/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.protection.PostQuantumCrypto;
import global.thalion.ttio.protection.PostQuantumCrypto.KeyPair;
import global.thalion.ttio.protection.PostQuantumCrypto.KemEncapResult;
import global.thalion.ttio.protection.SignatureManager;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;

import hdf.hdf5lib.H5;
import hdf.hdf5lib.HDF5Constants;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Cross-language PQC conformance CLI
 *
 * <p>Invoked by the cross-language conformance harness
 * ({@code python/tests/test_m54_pqc_conformance.py}) via
 * {@code run-tool.sh global.thalion.ttio.tools.PQCTool ...}. All
 * subcommands read / write raw bytes (no hex wrapping) so round-trip
 * byte equality is exact.</p>
 *
 * <p>Subcommands:</p>
 * <ul>
 *   <li>{@code sig-keygen PK_OUT SK_OUT}</li>
 *   <li>{@code sig-sign SK_IN MSG_IN SIG_OUT}</li>
 *   <li>{@code sig-verify PK_IN MSG_IN SIG_IN} (exit 0 valid, 1 invalid,
 *       2 error)</li>
 *   <li>{@code kem-keygen PK_OUT SK_OUT}</li>
 *   <li>{@code kem-encaps PK_IN CT_OUT SS_OUT}</li>
 *   <li>{@code kem-decaps SK_IN CT_IN SS_OUT}</li>
 *   <li>{@code hdf5-sign FILE DATASET_PATH SK_IN} — sign an HDF5
 *       dataset with ml-dsa-87; stores {@code "v3:" + base64(sig)} in
 *       {@code @ttio_signature}.</li>
 *   <li>{@code hdf5-verify FILE DATASET_PATH PK_IN} (exit 0/1/2)</li>
 * </ul>
 *
 *
 */
public final class PQCTool {

    private PQCTool() {}

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            usage();
            System.exit(2);
        }
        String sub = args[0];
        try {
            switch (sub) {
                case "sig-keygen" -> sigKeygen(args);
                case "sig-sign"   -> sigSign(args);
                case "sig-verify" -> sigVerify(args);
                case "kem-keygen" -> kemKeygen(args);
                case "kem-encaps" -> kemEncaps(args);
                case "kem-decaps" -> kemDecaps(args);
                case "hdf5-sign"   -> hdf5Sign(args);
                case "hdf5-verify" -> hdf5Verify(args);
                case "provider-sign"   -> providerSign(args);
                case "provider-verify" -> providerVerify(args);
                default -> {
                    System.err.println("unknown subcommand: " + sub);
                    usage();
                    System.exit(2);
                }
            }
        } catch (Throwable t) {
            System.err.println("PQCTool " + sub + " failed: " + t);
            System.exit(2);
        }
    }

    private static void usage() {
        System.err.println(
            "usage: PQCTool <subcommand> [args...]\n"
            + "  sig-keygen  PK_OUT  SK_OUT\n"
            + "  sig-sign    SK_IN   MSG_IN  SIG_OUT\n"
            + "  sig-verify  PK_IN   MSG_IN  SIG_IN\n"
            + "  kem-keygen  PK_OUT  SK_OUT\n"
            + "  kem-encaps  PK_IN   CT_OUT  SS_OUT\n"
            + "  kem-decaps  SK_IN   CT_IN   SS_OUT\n"
            + "  hdf5-sign      FILE    DATASET_PATH  SK_IN\n"
            + "  hdf5-verify    FILE    DATASET_PATH  PK_IN\n"
            + "  provider-sign   URL     DATASET_PATH  SK_IN\n"
            + "  provider-verify URL     DATASET_PATH  PK_IN");
    }

    private static byte[] readBytes(String path) throws java.io.IOException {
        return Files.readAllBytes(Path.of(path));
    }

    private static void writeBytes(String path, byte[] bytes)
            throws java.io.IOException {
        Files.write(Path.of(path), bytes);
    }

    // ── Primitive subcommands ────────────────────────────────────────

    private static void sigKeygen(String[] args) throws java.io.IOException {
        require(args, 3, "sig-keygen PK_OUT SK_OUT");
        KeyPair kp = PostQuantumCrypto.sigKeygen();
        writeBytes(args[1], kp.publicKey());
        writeBytes(args[2], kp.privateKey());
    }

    private static void sigSign(String[] args) throws java.io.IOException {
        require(args, 4, "sig-sign SK_IN MSG_IN SIG_OUT");
        byte[] sk = readBytes(args[1]);
        byte[] msg = readBytes(args[2]);
        byte[] sig = PostQuantumCrypto.sigSign(sk, msg);
        writeBytes(args[3], sig);
    }

    private static void sigVerify(String[] args) throws java.io.IOException {
        require(args, 4, "sig-verify PK_IN MSG_IN SIG_IN");
        byte[] pk = readBytes(args[1]);
        byte[] msg = readBytes(args[2]);
        byte[] sig = readBytes(args[3]);
        boolean ok = PostQuantumCrypto.sigVerify(pk, msg, sig);
        System.exit(ok ? 0 : 1);
    }

    private static void kemKeygen(String[] args) throws java.io.IOException {
        require(args, 3, "kem-keygen PK_OUT SK_OUT");
        KeyPair kp = PostQuantumCrypto.kemKeygen();
        writeBytes(args[1], kp.publicKey());
        writeBytes(args[2], kp.privateKey());
    }

    private static void kemEncaps(String[] args) throws java.io.IOException {
        require(args, 4, "kem-encaps PK_IN CT_OUT SS_OUT");
        byte[] pk = readBytes(args[1]);
        KemEncapResult r = PostQuantumCrypto.kemEncapsulate(pk);
        writeBytes(args[2], r.ciphertext());
        writeBytes(args[3], r.sharedSecret());
    }

    private static void kemDecaps(String[] args) throws java.io.IOException {
        require(args, 4, "kem-decaps SK_IN CT_IN SS_OUT");
        byte[] sk = readBytes(args[1]);
        byte[] ct = readBytes(args[2]);
        byte[] ss = PostQuantumCrypto.kemDecapsulate(sk, ct);
        writeBytes(args[3], ss);
    }

    // ── HDF5 dataset v3 signature subcommands ────────────────────────
    //
    // The Python/Objective-C equivalents are algorithm-dispatched entry
    // points on their SignatureManager classes. On the Java side the
    // integration lives at the SignatureManager.sign/verify(data, key,
    // algorithm) level; we reach through Hdf5File + readCanonicalBytes
    // via Hdf5Dataset to reuse the canonical transcript path.

    private static void hdf5Sign(String[] args) throws Exception {
        require(args, 4, "hdf5-sign FILE DATASET_PATH SK_IN");
        byte[] sk = readBytes(args[3]);
        signOrVerifyHdf5(args[1], args[2], sk, /* sign= */ true);
    }

    private static void hdf5Verify(String[] args) throws Exception {
        require(args, 4, "hdf5-verify FILE DATASET_PATH PK_IN");
        byte[] pk = readBytes(args[3]);
        boolean ok = signOrVerifyHdf5(args[1], args[2], pk, /* sign= */ false);
        System.exit(ok ? 0 : 1);
    }

    // ── Provider-agnostic sign/verify (v0.8 M54.1) ───────────────────

    private static void providerSign(String[] args) throws Exception {
        require(args, 4, "provider-sign URL DATASET_PATH SK_IN");
        byte[] sk = readBytes(args[3]);
        signOrVerifyProvider(args[1], args[2], sk, /* sign= */ true);
    }

    private static void providerVerify(String[] args) throws Exception {
        require(args, 4, "provider-verify URL DATASET_PATH PK_IN");
        byte[] pk = readBytes(args[3]);
        boolean ok = signOrVerifyProvider(args[1], args[2], pk, /* sign= */ false);
        System.exit(ok ? 0 : 1);
    }

    /**
     * Provider-dispatched sign/verify. Uses the ProviderRegistry to
     * pick the backend by URL scheme, then drives the StorageDataset
     * contract for canonical bytes + attribute I/O. Works for any
     * provider that implements get/setAttribute on its datasets —
     * currently Zarr, Memory, SQLite, and HDF5 (v0.8).
     */
    private static boolean signOrVerifyProvider(String url, String dsPath,
                                                  byte[] key, boolean sign)
            throws Exception {
        String trimmed = dsPath.startsWith("/") ? dsPath.substring(1) : dsPath;
        String[] parts = trimmed.split("/");
        if (parts.length == 0) {
            throw new IllegalArgumentException("bad dataset path: " + dsPath);
        }
        StorageProvider.Mode mode = sign
                ? StorageProvider.Mode.READ_WRITE
                : StorageProvider.Mode.READ;
        try (StorageProvider p = ProviderRegistry.open(url, mode)) {
            StorageGroup cur = p.rootGroup();
            for (int i = 0; i < parts.length - 1; i++) {
                cur = cur.openGroup(parts[i]);
            }
            String dsName = parts[parts.length - 1];
            try (StorageDataset ds = cur.openDataset(dsName)) {
                byte[] canonical = ds.readCanonicalBytes();
                if (sign) {
                    String stored = SignatureManager.sign(canonical, key,
                            "ml-dsa-87");
                    ds.setAttribute("ttio_signature", stored);
                    return true;
                }
                Object stored = ds.getAttribute("ttio_signature");
                if (stored == null) {
                    throw new IllegalStateException(
                            "no @ttio_signature on " + dsPath);
                }
                return SignatureManager.verify(canonical, stored.toString(),
                        key, "ml-dsa-87");
            }
        }
    }

    /**
     * Shared sign / verify path for HDF5 dataset v3 signatures.
     *
     * <p>Uses direct JHI5 calls (H5A* + H5D*) instead of the provider
     * abstraction because the storage-provider layer's Hdf5DatasetAdapter
     * does not yet expose dataset-level attributes (see note in
     * {@link global.thalion.ttio.providers.Hdf5Provider}). Python writes
     * the signature attribute with {@code H5T_VARIABLE} and the existing
     * Hdf5Group fixed-string path can't read it; this helper handles
     * both VL and fixed-size string attributes explicitly so
     * Python↔Java fixtures round-trip.</p>
     */
    private static boolean signOrVerifyHdf5(String file, String dsPath,
                                              byte[] key, boolean sign)
            throws Exception {
        int flags = sign ? HDF5Constants.H5F_ACC_RDWR
                           : HDF5Constants.H5F_ACC_RDONLY;
        long fid = H5.H5Fopen(file, flags, HDF5Constants.H5P_DEFAULT);
        if (fid < 0) {
            throw new IllegalStateException("H5Fopen failed on " + file);
        }
        try {
            long did = H5.H5Dopen(fid, dsPath, HDF5Constants.H5P_DEFAULT);
            if (did < 0) {
                throw new IllegalStateException(
                        "H5Dopen failed on " + dsPath);
            }
            try {
                byte[] canonical = readCanonicalBytes(did);
                if (sign) {
                    String stored = SignatureManager.sign(canonical, key,
                            "ml-dsa-87");
                    writeVlStringAttribute(did, "ttio_signature", stored);
                    return true;
                }
                String stored = readStringAttributeAny(did, "ttio_signature");
                if (stored == null) {
                    throw new IllegalStateException(
                            "no @ttio_signature on " + dsPath);
                }
                return SignatureManager.verify(canonical, stored, key,
                        "ml-dsa-87");
            } finally {
                H5.H5Dclose(did);
            }
        } finally {
            H5.H5Fclose(fid);
        }
    }

    /** Read a 1-D primitive dataset as little-endian canonical bytes. */
    private static byte[] readCanonicalBytes(long did) throws Exception {
        long tid = H5.H5Dget_type(did);
        long sid = H5.H5Dget_space(did);
        int rank = H5.H5Sget_simple_extent_ndims(sid);
        long[] dims = new long[rank];
        H5.H5Sget_simple_extent_dims(sid, dims, null);
        long total = 1;
        for (long d : dims) total *= d;

        int tclass = H5.H5Tget_class(tid);
        long size = H5.H5Tget_size(tid);
        try {
            if (tclass == HDF5Constants.H5T_FLOAT && size == 8) {
                double[] data = new double[(int) total];
                H5.H5Dread(did, HDF5Constants.H5T_NATIVE_DOUBLE,
                        HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                        HDF5Constants.H5P_DEFAULT, data);
                ByteBuffer bb = ByteBuffer.allocate(data.length * 8)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (double d : data) bb.putDouble(d);
                return bb.array();
            }
            if (tclass == HDF5Constants.H5T_INTEGER && size == 8) {
                long[] data = new long[(int) total];
                H5.H5Dread(did, HDF5Constants.H5T_NATIVE_INT64,
                        HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                        HDF5Constants.H5P_DEFAULT, data);
                ByteBuffer bb = ByteBuffer.allocate(data.length * 8)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (long v : data) bb.putLong(v);
                return bb.array();
            }
            if (tclass == HDF5Constants.H5T_INTEGER && size == 4) {
                int[] data = new int[(int) total];
                H5.H5Dread(did, HDF5Constants.H5T_NATIVE_INT32,
                        HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                        HDF5Constants.H5P_DEFAULT, data);
                ByteBuffer bb = ByteBuffer.allocate(data.length * 4)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (int v : data) bb.putInt(v);
                return bb.array();
            }
            if (tclass == HDF5Constants.H5T_FLOAT && size == 4) {
                float[] data = new float[(int) total];
                H5.H5Dread(did, HDF5Constants.H5T_NATIVE_FLOAT,
                        HDF5Constants.H5S_ALL, HDF5Constants.H5S_ALL,
                        HDF5Constants.H5P_DEFAULT, data);
                ByteBuffer bb = ByteBuffer.allocate(data.length * 4)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (float v : data) bb.putFloat(v);
                return bb.array();
            }
            throw new UnsupportedOperationException(
                    "PQCTool canonical read: unsupported HDF5 class="
                    + tclass + " size=" + size);
        } finally {
            H5.H5Sclose(sid);
            H5.H5Tclose(tid);
        }
    }

    /** Write a variable-length UTF-8 string attribute (matches the
     *  Python h5py layout for {@code @ttio_signature}). JHI5 1.10
     *  exposes VL string I/O through the overloaded
     *  {@code H5Awrite(aid, tid, String[])} signature. */
    private static void writeVlStringAttribute(long locId, String name,
                                                 String value) throws Exception {
        long tid = H5.H5Tcopy(HDF5Constants.H5T_C_S1);
        H5.H5Tset_size(tid, HDF5Constants.H5T_VARIABLE);
        H5.H5Tset_strpad(tid, HDF5Constants.H5T_STR_NULLTERM);
        H5.H5Tset_cset(tid, HDF5Constants.H5T_CSET_UTF8);
        long sid = H5.H5Screate(HDF5Constants.H5S_SCALAR);
        try {
            if (H5.H5Aexists(locId, name)) H5.H5Adelete(locId, name);
            long aid = H5.H5Acreate(locId, name, tid, sid,
                    HDF5Constants.H5P_DEFAULT, HDF5Constants.H5P_DEFAULT);
            try {
                Object[] buf = new Object[]{value};
                H5.H5Awrite_VLStrings(aid, tid, buf);
            } finally {
                H5.H5Aclose(aid);
            }
        } finally {
            H5.H5Sclose(sid);
            H5.H5Tclose(tid);
        }
    }

    /** Read a string attribute that may be either VL or fixed-size
     *  (Python uses VL; the Hdf5Group helper emits fixed). */
    private static String readStringAttributeAny(long locId, String name)
            throws Exception {
        if (!H5.H5Aexists(locId, name)) return null;
        long aid = H5.H5Aopen(locId, name, HDF5Constants.H5P_DEFAULT);
        try {
            long tid = H5.H5Aget_type(aid);
            try {
                boolean vl = H5.H5Tis_variable_str(tid);
                if (vl) {
                    // JHI5 exposes two VL-string read APIs; H5Aread_VLStrings
                    // is the newer name and maps to the H5T_STR_NULLTERM /
                    // H5T_CSET_UTF8 case that h5py emits.
                    Object[] buf = new Object[1];
                    H5.H5Aread_VLStrings(aid, tid, buf);
                    Object v = buf[0];
                    if (v == null) return "";
                    if (v instanceof String s) return s;
                    if (v instanceof byte[] bytes) {
                        return new String(bytes, StandardCharsets.UTF_8);
                    }
                    return v.toString();
                }
                long size = H5.H5Tget_size(tid);
                byte[] bytes = new byte[(int) size];
                H5.H5Aread(aid, tid, bytes);
                int end = bytes.length;
                while (end > 0 && bytes[end - 1] == 0) end--;
                return new String(bytes, 0, end, StandardCharsets.UTF_8);
            } finally {
                H5.H5Tclose(tid);
            }
        } finally {
            H5.H5Aclose(aid);
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private static void require(String[] args, int n, String usage) {
        if (args.length < n) {
            throw new IllegalArgumentException("usage: " + usage);
        }
    }
}
