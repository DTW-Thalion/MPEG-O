package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ImageWriteTest {
    @Test
    void writesAndReadsBackAnMsImage(@TempDir Path tmp) throws Exception {
        int w = 3, h = 2, sp = 4;
        double[] cube = new double[w * h * sp];
        for (int i = 0; i < cube.length; i++) cube[i] = i + 1;
        double[] mzAxis = {100.0, 101.0, 102.0, 103.0};
        MSImage img = new MSImage(
            w, h, sp, 0, 1.0, 1.0,
            "flyback", cube, mzAxis, "imgtitle", "", List.of(), List.of(), List.of());
        Path out = tmp.resolve("img.tio");
        SpectralDataset.createWithImages(out.toString(), "imgtitle", "TTIO:img",
            img, null, null);
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            MSImage read = (MSImage) ds.imageForKind(Enums.ImageKind.MS);
            assertNotNull(read);
            assertEquals(w, read.width());
            assertEquals(h, read.height());
        }
    }
}
