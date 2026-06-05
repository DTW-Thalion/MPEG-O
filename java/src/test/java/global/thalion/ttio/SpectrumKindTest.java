package global.thalion.ttio;
import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class SpectrumKindTest {
    @Test void knownStringsRoundTrip() {
        for (String s : new String[]{
            "TTIOMassSpectrum","TTIONMRSpectrum","TTIONMR2DSpectrum","TTIOIRSpectrum",
            "TTIORamanSpectrum","TTIOUVVisSpectrum","TTIOFreeInductionDecay",
            "TTIOMSImagePixel"}) {
            Enums.SpectrumKind k = Enums.SpectrumKind.fromPersisted(s);
            assertNotEquals(Enums.SpectrumKind.UNKNOWN, k);
            assertEquals(s, k.persisted());
        }
    }
    @Test void absentDefaultsToMass() {
        assertEquals(Enums.SpectrumKind.MASS, Enums.SpectrumKind.fromPersisted(null));
        assertEquals(Enums.SpectrumKind.MASS, Enums.SpectrumKind.fromPersisted(""));
    }
    @Test void unknownIsUnknown() {
        assertEquals(Enums.SpectrumKind.UNKNOWN,
            Enums.SpectrumKind.fromPersisted("TTIOFutureSpectrum"));
    }
}
