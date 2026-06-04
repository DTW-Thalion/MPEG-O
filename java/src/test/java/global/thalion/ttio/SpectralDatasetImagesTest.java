package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** JIT2: exercises the uniform {@link SpectralDataset#imageForKind} /
 *  {@link SpectralDataset#images()} accessors that replace the typed
 *  {@code image()}/{@code ramanImage()}/{@code irImage()} trio. */
class SpectralDatasetImagesTest {
    @Test
    void imageForKindAndImagesExposeOnlyPresentModalities(@TempDir Path tmp)
            throws Exception {
        int w = 3, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i + 1;
        double[] mzAxis = {100.0, 101.0, 102.0, 103.0};
        MSImage img = new MSImage(
            w, h, sp, 0, 1.0, 1.0,
            "flyback", cube, mzAxis, "imgtitle", "",
            List.of(), List.of(), List.of());
        Path out = tmp.resolve("img.tio");
        SpectralDataset.createWithImages(out.toString(), "imgtitle", "TTIO:img",
            img, null, null);

        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            Image ms = ds.imageForKind(Enums.ImageKind.MS);
            assertNotNull(ms, "MS image must be present");
            assertTrue(ms instanceof MSImage, "imageForKind(MS) returns an MSImage");
            assertEquals(w, ((MSImage) ms).width());
            assertEquals(h, ((MSImage) ms).height());

            assertNull(ds.imageForKind(Enums.ImageKind.RAMAN),
                "imageForKind(RAMAN) is null when no raman cube present");
            assertNull(ds.imageForKind(Enums.ImageKind.IR),
                "imageForKind(IR) is null when no ir cube present");

            Map<Enums.ImageKind, Image> images = ds.images();
            assertEquals(1, images.size(),
                "images() contains exactly the present kinds");
            assertTrue(images.containsKey(Enums.ImageKind.MS));
            assertSame(ms, images.get(Enums.ImageKind.MS));
            assertFalse(images.containsKey(Enums.ImageKind.RAMAN));
            assertFalse(images.containsKey(Enums.ImageKind.IR));
        }
    }
}
