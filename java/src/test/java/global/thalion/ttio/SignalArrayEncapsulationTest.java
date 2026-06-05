package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class SignalArrayEncapsulationTest {
    @Test void asDoublesReturnsDefensiveCopy() {
        SignalArray sa = SignalArray.ofDoubles(new double[]{1.0, 2.0, 3.0});
        double[] a = sa.asDoubles();
        a[0] = 999.0;
        assertEquals(1.0, sa.asDoubles()[0], 0.0,
            "mutating the returned array must not affect the SignalArray");
    }

    @Test void asFloatsReturnsDefensiveCopy() {
        SignalArray sa = SignalArray.ofFloats(new float[]{1.0f, 2.0f});
        float[] a = sa.asFloats();
        a[0] = 9.0f;
        assertEquals(1.0f, sa.asFloats()[0], 0.0f);
    }
}
