/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

/**
 * CPython-compatible {@code random.Random} subset.
 *
 * <p>Reproduces, byte-for-byte, the values that Python's
 * {@code random.Random(seed)} would emit for the methods used by the
 * M94 fixture builders ({@link #random()}, {@link #gauss(double, double)},
 * {@link #randrange(int, int)}).
 *
 * <p>Algorithm references:
 * <ul>
 *   <li>MT19937 — Matsumoto/Nishimura, 1997. Uses CPython's
 *       {@code init_by_array} seeding (Lib/random.py
 *       {@code Random.seed(a, version=2)} with integer argument).</li>
 *   <li>{@link #random()} — emits a 53-bit IEEE-754 double via the
 *       {@code (a*67108864.0+b)*(1.0/9007199254740992.0)} pattern
 *       used by CPython's {@code _randommodule.c}.</li>
 *   <li>{@link #gauss(double, double)} — Box-Muller polar variant
 *       matching CPython's {@code Lib/random.py:gauss()}, including the
 *       stashed-second-normal optimisation.</li>
 *   <li>{@link #randrange(int, int)} — uses {@link #_randbelow(int)}
 *       with bit-rejection sampling matching CPython's
 *       {@code _randbelow_with_getrandbits}.</li>
 * </ul>
 *
 * <p>Used only by FQZCOMP_NX16 fixture-builder unit tests; not part of
 * the public codec API.
 */
final class PyRandom {

    private static final int N = 624;
    private static final int M = 397;
    private static final int MATRIX_A = 0x9908b0df;
    private static final int UPPER_MASK = 0x80000000;
    private static final int LOWER_MASK = 0x7fffffff;

    private final int[] mt = new int[N];
    private int mti = N + 1;

    // gauss() stashed second normal (matches CPython's gauss_next).
    private boolean gaussNextValid = false;
    private double gaussNext = 0.0;

    PyRandom(long seed) {
        seed(seed);
    }

    /** Reproduce CPython's {@code Random.seed(int_seed, version=2)}.
     *
     *  <p>For a non-negative integer seed, CPython splits it into 32-bit
     *  little-endian limbs and feeds them into the standard MT19937
     *  {@code init_by_array(key)} routine. For seed=0, the key is [0]. */
    void seed(long seed) {
        gaussNextValid = false;
        long abs = (seed < 0) ? -seed : seed;
        // Split into 32-bit limbs (little-endian).
        java.util.ArrayList<Integer> limbs = new java.util.ArrayList<>();
        if (abs == 0L) {
            limbs.add(0);
        } else {
            while (abs > 0) {
                limbs.add((int) (abs & 0xFFFFFFFFL));
                abs >>>= 32;
            }
        }
        int[] key = new int[limbs.size()];
        for (int i = 0; i < key.length; i++) key[i] = limbs.get(i);
        initByArray(key);
    }

    private void initGenrand(int s) {
        mt[0] = s;
        for (int i = 1; i < N; i++) {
            mt[i] = (1812433253 * (mt[i - 1] ^ (mt[i - 1] >>> 30)) + i);
        }
        mti = N;
    }

    private void initByArray(int[] key) {
        initGenrand(19650218);
        int i = 1, j = 0;
        int k = Math.max(N, key.length);
        for (; k != 0; k--) {
            // mt[i] = (mt[i] ^ ((mt[i-1] ^ (mt[i-1] >> 30)) * 1664525)) + key[j] + j
            long lhs = (long) mt[i]
                ^ ((long) (mt[i - 1] ^ (mt[i - 1] >>> 30)) & 0xFFFFFFFFL) * 1664525L;
            mt[i] = (int) ((lhs & 0xFFFFFFFFL)
                + (key[j] & 0xFFFFFFFFL) + j);
            i++;
            j++;
            if (i >= N) { mt[0] = mt[N - 1]; i = 1; }
            if (j >= key.length) j = 0;
        }
        for (k = N - 1; k != 0; k--) {
            long lhs = (long) mt[i]
                ^ ((long) (mt[i - 1] ^ (mt[i - 1] >>> 30)) & 0xFFFFFFFFL) * 1566083941L;
            mt[i] = (int) ((lhs & 0xFFFFFFFFL) - i);
            i++;
            if (i >= N) { mt[0] = mt[N - 1]; i = 1; }
        }
        mt[0] = 0x80000000;
        mti = N;
    }

    /** MT19937 word generator, returns a uint32 in {@code [0, 2^32)}
     *  packed into the low 32 bits of a long. */
    private long genrandUint32() {
        if (mti >= N) {
            int kk;
            for (kk = 0; kk < N - M; kk++) {
                int y = (mt[kk] & UPPER_MASK) | (mt[kk + 1] & LOWER_MASK);
                mt[kk] = mt[kk + M] ^ (y >>> 1) ^ ((y & 1) != 0 ? MATRIX_A : 0);
            }
            for (; kk < N - 1; kk++) {
                int y = (mt[kk] & UPPER_MASK) | (mt[kk + 1] & LOWER_MASK);
                mt[kk] = mt[kk + (M - N)] ^ (y >>> 1)
                    ^ ((y & 1) != 0 ? MATRIX_A : 0);
            }
            int y = (mt[N - 1] & UPPER_MASK) | (mt[0] & LOWER_MASK);
            mt[N - 1] = mt[M - 1] ^ (y >>> 1) ^ ((y & 1) != 0 ? MATRIX_A : 0);
            mti = 0;
        }
        int y = mt[mti++];
        y ^= y >>> 11;
        y ^= (y << 7) & 0x9d2c5680;
        y ^= (y << 15) & 0xefc60000;
        y ^= y >>> 18;
        return y & 0xFFFFFFFFL;
    }

    /** CPython {@code random()}: 53-bit double in {@code [0.0, 1.0)}. */
    double random() {
        long a = genrandUint32() >>> 5;   // 27 bits
        long b = genrandUint32() >>> 6;   // 26 bits
        return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0);
    }

    /** CPython {@code getrandbits(k)} for {@code k <= 32} returning a
     *  java {@code long} in {@code [0, 2^k)}. */
    private long getrandbitsSmall(int k) {
        if (k <= 0 || k > 32) {
            throw new IllegalArgumentException("k must be in [1, 32], got " + k);
        }
        return genrandUint32() >>> (32 - k);
    }

    /** CPython {@code _randbelow_with_getrandbits(n)}: uniform integer
     *  in {@code [0, n)} via bit-rejection sampling. */
    private int _randbelow(int n) {
        if (n <= 0) {
            throw new IllegalArgumentException("n must be positive");
        }
        int k = bitLength(n);
        while (true) {
            long r = getrandbitsK(k);
            if (r < n) return (int) r;
        }
    }

    /** {@code getrandbits(k)} for any positive {@code k} returning a
     *  long when {@code k <= 32} (sufficient for our randrange uses). */
    private long getrandbitsK(int k) {
        if (k <= 32) {
            return getrandbitsSmall(k);
        }
        // For k > 32 we'd need to chain multiple genrand calls; not
        // required for our fixture sizes (k for n=31 is 5, etc.).
        throw new IllegalArgumentException(
            "k > 32 not supported in this minimal port");
    }

    private static int bitLength(int n) {
        return 32 - Integer.numberOfLeadingZeros(n);
    }

    /** CPython {@code randrange(start, stop)}: uniform integer in
     *  {@code [start, stop)}. */
    int randrange(int start, int stop) {
        int width = stop - start;
        if (width <= 0) {
            throw new IllegalArgumentException(
                "empty range randrange(" + start + ", " + stop + ")");
        }
        return start + _randbelow(width);
    }

    /** CPython {@code gauss(mu, sigma)} — Box-Muller polar method with
     *  stashed second normal. Mirrors {@code Lib/random.py:gauss()}.
     *
     *  <p>Algorithm:
     *  <pre>
     *  z = self.gauss_next
     *  self.gauss_next = None
     *  if z is None:
     *      x2pi = self.random() * 2 * pi
     *      g2rad = sqrt(-2.0 * log(1.0 - self.random()))
     *      z = cos(x2pi) * g2rad
     *      self.gauss_next = sin(x2pi) * g2rad
     *  return mu + z * sigma
     *  </pre>
     */
    double gauss(double mu, double sigma) {
        double z;
        if (gaussNextValid) {
            z = gaussNext;
            gaussNextValid = false;
        } else {
            double x2pi = random() * 2.0 * Math.PI;
            double g2rad = Math.sqrt(-2.0 * Math.log(1.0 - random()));
            z = Math.cos(x2pi) * g2rad;
            gaussNext = Math.sin(x2pi) * g2rad;
            gaussNextValid = true;
        }
        return mu + z * sigma;
    }
}
