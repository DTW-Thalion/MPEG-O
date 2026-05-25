package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

/** Parameterised over every {@link AccessorSpec}. For each accessor:
 *  builds a fixture .tio containing only that accessor's content,
 *  round-trips it through TransportWriter -&gt; TransportReader -&gt; .tio,
 *  and asserts content equality via the accessor's matcher. */
class AccessorMatrixConformanceTest {

    @ParameterizedTest
    @EnumSource(AccessorSpec.class)
    void roundTripPreservesAccessor(AccessorSpec accessor,
                                      @TempDir Path tmp) throws Exception {
        Path src = accessor.buildFixture(tmp);
        Path tis = tmp.resolve(accessor.name() + ".tis");
        Path rt  = tmp.resolve(accessor.name() + "-roundtrip.tio");

        // .tio -> .tis
        try (SpectralDataset s = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(s);
        }

        // .tis -> .tio
        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
            // close immediately so we can re-open via the canonical reader
        }

        // Re-open both and compare via the accessor's matcher
        try (SpectralDataset a = SpectralDataset.open(src.toString());
             SpectralDataset b = SpectralDataset.open(rt.toString())) {
            accessor.assertContentEquals(a, b);
        }
    }
}
