/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.*;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.util.*;

/**
 * An ordered collection of spectra from one acquisition, with instrument
 * config, spectrum index, and optional chromatograms.
 *
 * <p>HDF5 layout: {@code /study/ms_runs/<name>/} with subgroups
 * {@code spectrum_index/}, {@code signal_channels/}, {@code instrument_config/},
 * {@code chromatograms/} (optional), and {@code provenance/} (optional).</p>
 *
 * <p>Conforms to {@link global.thalion.ttio.protocols.Indexable},
 * {@link global.thalion.ttio.protocols.Streamable}, and
 * {@link global.thalion.ttio.protocols.Provenanceable}.
 * {@code Encryptable} conformance is deferred to M41.5.</p>
 *
 * <p>I/O routed through {@link StorageGroup} /
 * {@link StorageDataset}; this class no longer references the low-level
 * {@code Hdf5Group} / {@code Hdf5Dataset} types.</p>
 *
 * <p><b>API status:</b> Stable (Encryptable surface pending).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOAcquisitionRun}, Python
 * {@code ttio.acquisition_run.AcquisitionRun}.</p>
 *
 *
 */
public class AcquisitionRun implements
        global.thalion.ttio.protocols.Indexable<Spectrum>,
        global.thalion.ttio.protocols.Streamable<Spectrum>,
        global.thalion.ttio.protocols.Provenanceable,
        global.thalion.ttio.protocols.Encryptable,
        global.thalion.ttio.protocols.Run,
        AutoCloseable {

    private static final int CHUNK_SIZE = 65536;
    private static final int COMPRESSION_LEVEL = 6;

    private final String name;
    private final AcquisitionMode acquisitionMode;
    private final SpectrumIndex spectrumIndex;
    private final InstrumentConfig instrumentConfig;
    private final List<Chromatogram> chromatograms;
    private final List<ProvenanceRecord> provenanceRecords;

    // NMR-specific
    private final String nucleusType;
    private final double spectrometerFrequencyMHz;
    /** Optional solvent label (e.g. "CDCl3", "DMSO-d6", "D2O"). Empty
     *  string when not specified or when the run is not NMR. Stored as
     *  the {@code @solvent} string attribute on the run group. */
    private final String solvent;

    // omics modality this run carries. Storage attribute
    // {@code @modality} (UTF-8 string). Defaults to
    // {@code "mass_spectrometry"}; pre-v0.11 files lack the attribute
    // and are interpreted as mass-spec runs. will introduce
    // {@code "genomics"} for genomic-read runs.
    private final String modality;

    // Channel data (concatenated across all spectra)
    private final Map<String, double[]> channels;

    // Streamable cursor and Provenanceable cache.
    private int cursor = 0;
    private java.util.List<ProvenanceRecord> provenanceCache;
    // Encryptable conformance.
    private global.thalion.ttio.protection.AccessPolicy accessPolicy;
    private String persistenceFilePath;
    private String persistenceRunName;
    // plaintext channels recovered via decryptWithKey. The
    // on-disk file is untouched (decrypt is read-only), so after
    // open-on-encrypted + decrypt the in-memory {@link #channels} map is
    // still missing the encrypted channel — spectra need to fall back
    // to this overlay to see real intensities.
    private final Map<String, double[]> decryptedChannels =
            new java.util.LinkedHashMap<>();

    // Vibrational-spectrum run metadata (IR / Raman / UV-Vis), parity
    // with Python's WrittenRun fields. When spectrumClassOverride is one
    // of the vibrational class names it drives both the @spectrum_class
    // attribute on write and the subclass produced by objectAtIndex;
    // otherwise the run behaves as MS / NMR as before. Set via
    // setIRMetadata / setRamanMetadata / setUVVisMetadata (used by
    // readFrom and by callers authoring vibrational runs).
    private String spectrumClassOverride = null;
    private Enums.IRMode irMode = Enums.IRMode.TRANSMITTANCE;
    private double irResolutionCmInv = 0.0;
    private long irNumberOfScans = 0;
    private double ramanExcitationWavelengthNm = 0.0;
    private double ramanLaserPowerMw = 0.0;
    private double ramanIntegrationTimeSec = 0.0;
    private double uvvisPathLengthCm = 0.0;

    /** Mark this run as IR and attach its metadata. The wavenumber +
     *  intensity channels supply the spectrum payload; UV-Vis solvent is
     *  carried by the {@code solvent} constructor arg. */
    public void setIRMetadata(Enums.IRMode mode, double resolutionCmInv,
                              long numberOfScans) {
        this.spectrumClassOverride = "TTIOIRSpectrum";
        this.irMode = mode != null ? mode : Enums.IRMode.TRANSMITTANCE;
        this.irResolutionCmInv = resolutionCmInv;
        this.irNumberOfScans = numberOfScans;
    }

    /** Mark this run as Raman and attach its metadata. */
    public void setRamanMetadata(double excitationWavelengthNm,
                                 double laserPowerMw,
                                 double integrationTimeSec) {
        this.spectrumClassOverride = "TTIORamanSpectrum";
        this.ramanExcitationWavelengthNm = excitationWavelengthNm;
        this.ramanLaserPowerMw = laserPowerMw;
        this.ramanIntegrationTimeSec = integrationTimeSec;
    }

    /** Mark this run as UV-Vis and attach its metadata (the solvent label
     *  reuses the {@code solvent} field / {@code @solvent} attribute). */
    public void setUVVisMetadata(double pathLengthCm) {
        this.spectrumClassOverride = "TTIOUVVisSpectrum";
        this.uvvisPathLengthCm = pathLengthCm;
    }

    /**
     * Pre-modality overload retained for backward compatibility.
     * Forwards to the full constructor with
     * {@code modality = "mass_spectrometry"} and an empty solvent.
     */
    public AcquisitionRun(String name, AcquisitionMode acquisitionMode,
                          SpectrumIndex spectrumIndex,
                          InstrumentConfig instrumentConfig,
                          Map<String, double[]> channels,
                          List<Chromatogram> chromatograms,
                          List<ProvenanceRecord> provenanceRecords,
                          String nucleusType, double spectrometerFrequencyMHz) {
        this(name, acquisitionMode, spectrumIndex, instrumentConfig, channels,
                chromatograms, provenanceRecords, nucleusType,
                spectrometerFrequencyMHz, "mass_spectrometry", "");
    }

    /** Constructor with {@code modality} (pre-solvent overload retained
     *  for backward compatibility; defaults solvent to empty). */
    public AcquisitionRun(String name, AcquisitionMode acquisitionMode,
                          SpectrumIndex spectrumIndex,
                          InstrumentConfig instrumentConfig,
                          Map<String, double[]> channels,
                          List<Chromatogram> chromatograms,
                          List<ProvenanceRecord> provenanceRecords,
                          String nucleusType, double spectrometerFrequencyMHz,
                          String modality) {
        this(name, acquisitionMode, spectrumIndex, instrumentConfig, channels,
                chromatograms, provenanceRecords, nucleusType,
                spectrometerFrequencyMHz, modality, "");
    }

    /** Full constructor including {@code modality} and NMR {@code solvent}. */
    public AcquisitionRun(String name, AcquisitionMode acquisitionMode,
                          SpectrumIndex spectrumIndex,
                          InstrumentConfig instrumentConfig,
                          Map<String, double[]> channels,
                          List<Chromatogram> chromatograms,
                          List<ProvenanceRecord> provenanceRecords,
                          String nucleusType, double spectrometerFrequencyMHz,
                          String modality, String solvent) {
        this.name = name;
        this.acquisitionMode = acquisitionMode;
        this.spectrumIndex = spectrumIndex;
        this.instrumentConfig = instrumentConfig;
        this.channels = channels != null ? Map.copyOf(channels) : Map.of();
        this.chromatograms = chromatograms != null ? List.copyOf(chromatograms) : List.of();
        this.provenanceRecords = provenanceRecords != null ? List.copyOf(provenanceRecords) : List.of();
        this.nucleusType = nucleusType;
        this.spectrometerFrequencyMHz = spectrometerFrequencyMHz;
        this.modality = (modality == null || modality.isEmpty())
                ? "mass_spectrometry" : modality;
        this.solvent = solvent != null ? solvent : "";
    }

    /** @return The run's identifier, unique within its parent {@link SpectralDataset}. */
    public String name() { return name; }

    /** @return The mode used to acquire the spectra (DDA, DIA, NMR_1D, etc.). */
    public AcquisitionMode acquisitionMode() { return acquisitionMode; }

    /** @return The per-spectrum index columns (offsets, retention times, MS levels, polarities). */
    public SpectrumIndex spectrumIndex() { return spectrumIndex; }

    /** @return The instrument configuration that recorded this run. */
    public InstrumentConfig instrumentConfig() { return instrumentConfig; }

    /** @return Unmodifiable view of the run's concatenated channel buffers keyed by channel name. */
    public Map<String, double[]> channels() { return channels; }

    /** @return Unmodifiable list of chromatograms attached to this run. */
    public List<Chromatogram> chromatograms() { return chromatograms; }

    /** @return Unmodifiable list of provenance records for the run-level processing chain. */
    public List<ProvenanceRecord> provenanceRecords() { return provenanceRecords; }

    /** @return The NMR nucleus type (e.g. {@code "1H"}, {@code "13C"}); empty for non-NMR runs. */
    public String nucleusType() { return nucleusType; }

    /** @return Spectrometer Larmor frequency in MHz for NMR runs; zero for non-NMR runs. */
    public double spectrometerFrequencyMHz() { return spectrometerFrequencyMHz; }
    /** omics modality (e.g. {@code "mass_spectrometry"}). */
    public String modality() { return modality; }
    /** Optional NMR solvent label (e.g. "CDCl3"). Empty when not
     *  specified or when the run is not NMR.
     *
     *  <p><b>Cross-language equivalents:</b> Python
     *  {@code AcquisitionRun.solvent}, Objective-C
     *  {@code -[TTIOAcquisitionRun solvent]}.</p> */
    public String solvent() { return solvent; }

    /**
     * @return Number of spectra in the run. Convenience over
     *         {@code spectrumIndex().count()} for callers that don't
     *         need the full index object.
     */
    public int spectrumCount() { return spectrumIndex.count(); }

    /** Read a single spectrum's channel data by index (hyperslab). */
    public double[] channelSlice(String channelName, int spectrumIdx) {
        double[] data = decryptedChannels.getOrDefault(channelName,
                channels.get(channelName));
        if (data == null) return null;
        long offset = spectrumIndex.offsetAt(spectrumIdx);
        int length = spectrumIndex.lengthAt(spectrumIdx);
        return Arrays.copyOfRange(data, (int) offset, (int) offset + length);
    }

    /** Channel array that prefers the post-decrypt overlay, falling
     *  back to the on-disk-loaded channels. v1.1 Issue B. */
    private double[] effectiveChannel(String name) {
        double[] overlay = decryptedChannels.get(name);
        return overlay != null ? overlay : channels.getOrDefault(name, new double[0]);
    }

    /** Hyperslab a concatenated channel buffer; empty when the channel
     *  is absent or too short (e.g. an encrypted channel not yet
     *  decrypted). */
    private static double[] slice(double[] arr, long offset, int length) {
        int o = (int) offset;
        if (arr == null || arr.length < o + length) return new double[0];
        return Arrays.copyOfRange(arr, o, o + length);
    }

    /** Get the spectrum class name for HDF5 @spectrum_class attribute. */
    public String spectrumClassName() {
        if (spectrumClassOverride != null) return spectrumClassOverride;
        return switch (acquisitionMode) {
            case NMR_1D -> "TTIONMRSpectrum";
            case NMR_2D -> "TTIONMR2DSpectrum";
            default -> "TTIOMassSpectrum";
        };
    }

    // ── Protocol conformances ────────────────────────────────────────

    // ---- Indexable conformance ----

    /**
     * Materialize the spectrum at the given index.
     *
     * <p>Dispatches on the stored {@code @spectrum_class} override
     * (IR/Raman/UV-Vis) and falls back to NMR when a
     * {@code chemical_shift} channel is present; otherwise returns a
     * {@link MassSpectrum}. Hyperslabs the run's concatenated channel
     * buffers using {@link SpectrumIndex#offsetAt(int)} +
     * {@link SpectrumIndex#lengthAt(int)}.</p>
     *
     * @param index spectrum index in {@code [0, count())}
     * @return      newly constructed {@link Spectrum} of the appropriate subtype
     */
    @Override
    public Spectrum objectAtIndex(int index) {
        long offset = spectrumIndex.offsetAt(index);
        int length = spectrumIndex.lengthAt(index);

        double[] mz = effectiveChannel("mz");
        double[] intensity = effectiveChannel("intensity");
        double[] chemShift = effectiveChannel("chemical_shift");

        double scanTime = spectrumIndex.retentionTimeAt(index);
        double precursorMz = spectrumIndex.precursorMzAt(index);
        int precursorCharge = spectrumIndex.precursorChargeAt(index);

        // Vibrational types dispatch on the stored @spectrum_class
        // (parity with Python's _materialize_spectrum); their channels
        // are wavenumber/intensity (IR/Raman) or wavelength/absorbance
        // (UV-Vis), not mz/chemical_shift.
        if (spectrumClassOverride != null) {
            switch (spectrumClassOverride) {
                case "TTIOIRSpectrum" -> {
                    return new IRSpectrum(
                        slice(effectiveChannel("wavenumber"), offset, length),
                        slice(effectiveChannel("intensity"), offset, length),
                        index, scanTime, irMode, irResolutionCmInv,
                        irNumberOfScans);
                }
                case "TTIORamanSpectrum" -> {
                    return new RamanSpectrum(
                        slice(effectiveChannel("wavenumber"), offset, length),
                        slice(effectiveChannel("intensity"), offset, length),
                        index, scanTime, ramanExcitationWavelengthNm,
                        ramanLaserPowerMw, ramanIntegrationTimeSec);
                }
                case "TTIOUVVisSpectrum" -> {
                    return new UVVisSpectrum(
                        slice(effectiveChannel("wavelength"), offset, length),
                        slice(effectiveChannel("absorbance"), offset, length),
                        index, scanTime, uvvisPathLengthCm, solvent);
                }
                default -> { /* fall through to NMR / MS */ }
            }
        }

        if (chemShift.length > 0) {
            double[] cs = java.util.Arrays.copyOfRange(chemShift, (int) offset, (int) offset + length);
            double[] it = java.util.Arrays.copyOfRange(intensity, (int) offset, (int) offset + length);
            return new NMRSpectrum(cs, it, index, scanTime,
                nucleusType != null ? nucleusType : "",
                spectrometerFrequencyMHz);
        }

        double[] mzSlice = java.util.Arrays.copyOfRange(mz, (int) offset, (int) offset + length);
        double[] intSlice = java.util.Arrays.copyOfRange(intensity, (int) offset, (int) offset + length);
        return new MassSpectrum(mzSlice, intSlice, index, scanTime,
            precursorMz, precursorCharge,
            spectrumIndex.msLevelAt(index),
            spectrumIndex.polarityAt(index),
            null,
            spectrumIndex.activationMethodAt(index),
            spectrumIndex.isolationWindowAt(index),
            spectrumIndex.centroidedAt(index));
    }

    /**
     * @return Number of spectra in the run; equivalent to
     *         {@link #spectrumCount()}.
     */
    @Override
    public int count() { return spectrumIndex.count(); }

    /**
     * Materialize all spectra in this run into a list. Convenience over the
     * {@link #count()} + {@link #objectAtIndex(int)} pair for stream-based
     * consumers; the returned list is unmodifiable.
     *
     * <p><b>Cross-language equivalents:</b> Python {@code AcquisitionRun.spectra()}
     * (also iterable via {@code __iter__}), Objective-C
     * {@code -[TTIOAcquisitionRun spectra]}.</p>
     *
     * @return immutable view of the run's spectra in index order
     */
    public List<Spectrum> spectra() {
        List<Spectrum> out = new ArrayList<>(count());
        for (int i = 0; i < count(); i++) out.add(objectAtIndex(i));
        return Collections.unmodifiableList(out);
    }

    // ---- Run conformance ----

    /** Phase 1: modality-agnostic accessor required by
     *  {@link global.thalion.ttio.protocols.Run}. Delegates to
     *  {@link #objectAtIndex(int)}; the typed return is widened to
     *  {@code Object} so callers iterating uniformly over
     *  AcquisitionRun + GenomicRun see a single signature. */
    @Override
    public Object get(int index) { return objectAtIndex(index); }

    // ---- Streamable conformance ----

    /**
     * Advance the stream cursor and return the next spectrum.
     *
     * @return the next spectrum in iteration order
     * @throws java.util.NoSuchElementException when the cursor has
     *         already reached the end of the run
     */
    @Override
    public Spectrum nextObject() {
        if (cursor >= count()) throw new java.util.NoSuchElementException();
        Spectrum s = objectAtIndex(cursor);
        cursor++;
        return s;
    }

    /** @return {@code true} when {@link #nextObject()} has further spectra to return. */
    @Override
    public boolean hasMore() { return cursor < count(); }

    /** @return Current zero-based stream cursor position. */
    @Override
    public int currentPosition() { return cursor; }

    /**
     * Reposition the stream cursor.
     *
     * @param position zero-based target position in {@code [0, count()]};
     *                 {@code count()} parks the cursor at end-of-stream
     * @return         {@code true} when the position was accepted,
     *                 {@code false} when out of range
     */
    @Override
    public boolean seekToPosition(int position) {
        if (position < 0 || position > count()) return false;
        cursor = position;
        return true;
    }

    /** Reset the stream cursor to the beginning of the run. */
    @Override
    public void reset() { cursor = 0; }

    // ---- Provenanceable conformance ----

    /**
     * Append a processing step to the run's in-memory provenance chain.
     *
     * <p>Persisted to {@code /study/runs/<name>/@provenance_json} the
     * next time the dataset is saved.</p>
     *
     * @param step provenance record describing the processing step
     */
    @Override
    public void addProcessingStep(ProvenanceRecord step) {
        ensureProvenanceCache().add(step);
    }

    /**
     * @return Immutable view of the run's provenance chain — the
     *         on-disk records concatenated with any
     *         {@link #addProcessingStep} additions made in memory.
     */
    @Override
    public java.util.List<ProvenanceRecord> provenanceChain() {
        if (provenanceCache != null) return java.util.List.copyOf(provenanceCache);
        return provenanceRecords;
    }

    /**
     * @return Deduplicated input entity URIs across every record in the
     *         provenance chain, in first-seen order.
     */
    @Override
    public java.util.List<String> inputEntities() {
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        for (ProvenanceRecord r : provenanceChain()) seen.addAll(r.inputRefs());
        return new java.util.ArrayList<>(seen);
    }

    /**
     * @return Deduplicated output entity URIs across every record in
     *         the provenance chain, in first-seen order.
     */
    @Override
    public java.util.List<String> outputEntities() {
        java.util.Set<String> seen = new java.util.LinkedHashSet<>();
        for (ProvenanceRecord r : provenanceChain()) seen.addAll(r.outputRefs());
        return new java.util.ArrayList<>(seen);
    }

    private java.util.List<ProvenanceRecord> ensureProvenanceCache() {
        if (provenanceCache == null) {
            provenanceCache = new java.util.ArrayList<>(provenanceRecords);
        }
        return provenanceCache;
    }

    // ---- Encryptable conformance ----

    /**
     * Attach the persistence context after loading — used by
     * {@link SpectralDataset} so {@link #encryptWithKey} can delegate.
     */
    public void setPersistenceContext(String filePath, String runName) {
        this.persistenceFilePath = filePath;
        this.persistenceRunName = runName;
    }

    /**
     * Encrypt this run's intensity channel in place on disk using
     * AES-256-GCM.
     *
     * @param key   32-byte AES-256 key material
     * @param level Encryption granularity hint (run/dataset/per-AU)
     * @throws IllegalStateException when the run was not obtained from a
     *         {@link SpectralDataset} (no persistence context)
     * @throws Exception             on I/O or cipher failure
     */
    @Override
    public void encryptWithKey(byte[] key, global.thalion.ttio.Enums.EncryptionLevel level)
            throws Exception {
        if (persistenceFilePath == null || persistenceRunName == null) {
            throw new IllegalStateException(
                "AcquisitionRun.encryptWithKey requires a persistence " +
                "context; call via a run obtained from SpectralDataset.open");
        }
        global.thalion.ttio.protection.EncryptionManager
            .encryptIntensityChannelInRun(persistenceFilePath, persistenceRunName, key);
    }

    /**
     * In-process decrypt overlay: rehydrates the run's intensity
     * channel into an in-memory buffer that subsequent
     * {@link #objectAtIndex(int)} / {@link #channelSlice(String, int)}
     * calls read from. The on-disk file is left untouched.
     *
     * @param key 32-byte AES-256 key matching the encrypt key
     * @throws IllegalStateException when the run was not obtained from a
     *         {@link SpectralDataset} (no persistence context)
     * @throws Exception             on I/O failure or AES-GCM tag mismatch
     */
    @Override
    public void decryptWithKey(byte[] key) throws Exception {
        // The protocol declares void return; plaintext is rehydrated into
        // an in-memory overlay so spectra can read real intensities after
        // open-on-encrypted + decrypt. The on-disk file is untouched.
        // Callers that need raw bytes can still use
        // EncryptionManager.decryptIntensityChannelInRun directly.
        if (persistenceFilePath == null || persistenceRunName == null) {
            throw new IllegalStateException(
                "AcquisitionRun.decryptWithKey requires a persistence context");
        }
        byte[] plaintext = global.thalion.ttio.protection.EncryptionManager
            .decryptIntensityChannelInRun(persistenceFilePath, persistenceRunName, key);
        // stash the recovered plaintext as a double[] so
        // objectAtIndex / channelSlice can materialise spectra without
        // re-decrypting per access. Little-endian matches the encode
        // path in EncryptionManager.encryptChannel.
        int n = plaintext.length / Double.BYTES;
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(plaintext)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN);
        double[] intensity = new double[n];
        for (int i = 0; i < n; i++) intensity[i] = bb.getDouble();
        decryptedChannels.put("intensity", intensity);
    }

    /**
     * @return The attached access policy, or {@code null} when none is
     *         set. Typed as {@code Object} to keep the
     *         {@code Encryptable} protocol free of the protection
     *         package dependency.
     */
    @Override
    public Object accessPolicy() { return accessPolicy; }

    /**
     * Attach an access policy to the run.
     *
     * @param policy a {@code global.thalion.ttio.protection.AccessPolicy}
     *               instance, or {@code null} to clear
     * @throws ClassCastException when {@code policy} is non-null and
     *         not an {@code AccessPolicy}
     */
    @Override
    public void setAccessPolicy(Object policy) {
        this.accessPolicy = (global.thalion.ttio.protection.AccessPolicy) policy;
    }

    // ── Storage I/O ─────────────────────────────────────────────────
    //
    // everything below is routed through the StorageGroup /
    // StorageDataset protocols. HDF5, SQLite, and Memory providers all
    // satisfy the same contract.

    /** Write this run to a parent group (creates <name>/ subgroup). */
    public void writeTo(StorageGroup parentGroup) {
        try (StorageGroup runGroup = parentGroup.createGroup(name)) {
            runGroup.setAttribute("acquisition_mode", (long) acquisitionMode.ordinal());
            runGroup.setAttribute("spectrum_count", (long) spectrumIndex.count());
            runGroup.setAttribute("spectrum_class", spectrumClassName());

            if (nucleusType != null) {
                runGroup.setAttribute("nucleus_type", nucleusType);
            }
            if (solvent != null && !solvent.isEmpty()) {
                runGroup.setAttribute("solvent", solvent);
            }
            // Vibrational-spectrum run metadata (parity with Python's
            // _write_run). Emitted only for the matching class so MS/NMR
            // runs stay byte-identical. ir_mode is always written for IR
            // (0 = TRANSMITTANCE is meaningful); the float/scan fields are
            // written only when non-zero, matching the Python writer.
            if ("TTIOIRSpectrum".equals(spectrumClassOverride)) {
                runGroup.setAttribute("ir_mode", (long) irMode.ordinal());
                if (irResolutionCmInv != 0.0) {
                    runGroup.setAttribute("ir_resolution_cm_inv", irResolutionCmInv);
                }
                if (irNumberOfScans != 0) {
                    runGroup.setAttribute("ir_number_of_scans", irNumberOfScans);
                }
            } else if ("TTIORamanSpectrum".equals(spectrumClassOverride)) {
                if (ramanExcitationWavelengthNm != 0.0) {
                    runGroup.setAttribute("raman_excitation_wavelength_nm",
                                          ramanExcitationWavelengthNm);
                }
                if (ramanLaserPowerMw != 0.0) {
                    runGroup.setAttribute("raman_laser_power_mw", ramanLaserPowerMw);
                }
                if (ramanIntegrationTimeSec != 0.0) {
                    runGroup.setAttribute("raman_integration_time_sec",
                                          ramanIntegrationTimeSec);
                }
            } else if ("TTIOUVVisSpectrum".equals(spectrumClassOverride)) {
                if (uvvisPathLengthCm != 0.0) {
                    runGroup.setAttribute("uvvis_path_length_cm", uvvisPathLengthCm);
                }
            }
            if (spectrometerFrequencyMHz > 0) {
                try (StorageDataset ds = runGroup.createDataset(
                        "_spectrometer_freq_mhz", Precision.FLOAT64, 1, 0,
                        Compression.NONE, 0)) {
                    ds.writeAll(new double[]{ spectrometerFrequencyMHz });
                }
            }

            // Spectrum index
            spectrumIndex.writeTo(runGroup);

            // Signal channels
            writeSignalChannels(runGroup);

            // Instrument config
            if (instrumentConfig != null) {
                writeInstrumentConfig(runGroup);
            }

            // Chromatograms
            if (!chromatograms.isEmpty()) {
                writeChromatograms(runGroup);
            }

            // Per-run provenance
            if (!provenanceRecords.isEmpty()) {
                writeProvenance(runGroup);
            }
        }
    }

    /** Read a run from an existing storage group. */
    public static AcquisitionRun readFrom(StorageGroup parentGroup, String runName) {
        try (StorageGroup runGroup = parentGroup.openGroup(runName)) {
            AcquisitionMode mode = AcquisitionMode.values()[
                    ((Number) runGroup.getAttribute("acquisition_mode")).intValue()];

            String nucleusType = runGroup.hasAttribute("nucleus_type")
                    ? (String) runGroup.getAttribute("nucleus_type") : null;

            String solvent = runGroup.hasAttribute("solvent")
                    ? (String) runGroup.getAttribute("solvent") : "";

            // optional @modality attribute. Pre-v0.11 runs
            // lack it and read back as mass-spec.
            String modality = "mass_spectrometry";
            if (runGroup.hasAttribute("modality")) {
                Object m = runGroup.getAttribute("modality");
                if (m instanceof String s && !s.isEmpty()) modality = s;
            }

            double freqMHz = 0;
            if (runGroup.hasChild("_spectrometer_freq_mhz")) {
                try (StorageDataset ds = runGroup.openDataset("_spectrometer_freq_mhz")) {
                    freqMHz = ((double[]) ds.readAll())[0];
                }
            }

            SpectrumIndex index = SpectrumIndex.readFrom(runGroup);
            Map<String, double[]> channels = readSignalChannels(runGroup);
            InstrumentConfig config = readInstrumentConfig(runGroup);
            List<Chromatogram> chroms = readChromatograms(runGroup);
            List<ProvenanceRecord> provenance = readProvenance(runGroup);

            AcquisitionRun run = new AcquisitionRun(runName, mode, index, config,
                    channels, chroms, provenance, nucleusType, freqMHz,
                    modality, solvent);

            // Vibrational runs (IR / Raman / UV-Vis) carry a
            // @spectrum_class that the acquisition-mode switch can't
            // derive; restore it + the per-class metadata so
            // objectAtIndex produces the right subclass (parity with
            // Python's AcquisitionRun.open).
            String spectrumClass = runGroup.hasAttribute("spectrum_class")
                    ? (String) runGroup.getAttribute("spectrum_class") : null;
            if ("TTIOIRSpectrum".equals(spectrumClass)) {
                int ord = runGroup.hasAttribute("ir_mode")
                        ? ((Number) runGroup.getAttribute("ir_mode")).intValue() : 0;
                Enums.IRMode[] vals = Enums.IRMode.values();
                run.setIRMetadata(
                        vals[ord >= 0 && ord < vals.length ? ord : 0],
                        attrDouble(runGroup, "ir_resolution_cm_inv"),
                        (long) attrDouble(runGroup, "ir_number_of_scans"));
            } else if ("TTIORamanSpectrum".equals(spectrumClass)) {
                run.setRamanMetadata(
                        attrDouble(runGroup, "raman_excitation_wavelength_nm"),
                        attrDouble(runGroup, "raman_laser_power_mw"),
                        attrDouble(runGroup, "raman_integration_time_sec"));
            } else if ("TTIOUVVisSpectrum".equals(spectrumClass)) {
                run.setUVVisMetadata(attrDouble(runGroup, "uvvis_path_length_cm"));
            }
            return run;
        }
    }

    /** Read a numeric run attribute as a double, defaulting to 0.0 when
     *  absent (vibrational metadata is sparse — only non-default fields
     *  are written). */
    private static double attrDouble(StorageGroup g, String name) {
        if (!g.hasAttribute(name)) return 0.0;
        Object v = g.getAttribute(name);
        return v instanceof Number n ? n.doubleValue() : 0.0;
    }

    private void writeSignalChannels(StorageGroup runGroup) {
        try (StorageGroup sc = runGroup.createGroup("signal_channels")) {
            StringBuilder channelNames = new StringBuilder();
            boolean first = true;
            // some providers (ZarrProvider Java v0.8) don't
            // implement compression. Probe on the first channel and
            // reuse the decision for the rest so the loop is
            // consistent rather than half-compressed/half-not.
            Compression codec = Compression.ZLIB;
            for (var entry : channels.entrySet()) {
                if (!first) channelNames.append(",");
                channelNames.append(entry.getKey());

                String dsName = entry.getKey() + "_values";
                double[] data = entry.getValue();
                StorageDataset ds;
                try {
                    ds = sc.createDataset(dsName, Precision.FLOAT64,
                            data.length, CHUNK_SIZE, codec, COMPRESSION_LEVEL);
                } catch (UnsupportedOperationException e) {
                    if (codec != Compression.NONE) {
                        codec = Compression.NONE;
                        ds = sc.createDataset(dsName, Precision.FLOAT64,
                                data.length, CHUNK_SIZE, codec, 0);
                    } else {
                        throw e;
                    }
                }
                try (StorageDataset closeMe = ds) {
                    closeMe.writeAll(data);
                }
                first = false;
            }
            sc.setAttribute("channel_names", channelNames.toString());
        }
    }

    private static Map<String, double[]> readSignalChannels(StorageGroup runGroup) {
        Map<String, double[]> channels = new LinkedHashMap<>();
        if (!runGroup.hasChild("signal_channels")) return channels;

        try (StorageGroup sc = runGroup.openGroup("signal_channels")) {
            String namesStr = (String) sc.getAttribute("channel_names");
            for (String ch : namesStr.split(",")) {
                String dsName = ch.strip() + "_values";
                if (sc.hasChild(dsName)) {
                    try (StorageDataset ds = sc.openDataset(dsName)) {
                        // route through the storage protocol, not
                        // Hdf5Dataset directly. Providers decide how to
                        // materialise the underlying array.
                        channels.put(ch.strip(), (double[]) ds.readAll());
                    }
                }
            }
        }
        return channels;
    }

    private void writeInstrumentConfig(StorageGroup runGroup) {
        try (StorageGroup ic = runGroup.createGroup("instrument_config")) {
            if (instrumentConfig.manufacturer() != null)
                ic.setAttribute("manufacturer", instrumentConfig.manufacturer());
            if (instrumentConfig.model() != null)
                ic.setAttribute("model", instrumentConfig.model());
            if (instrumentConfig.serialNumber() != null)
                ic.setAttribute("serial_number", instrumentConfig.serialNumber());
            if (instrumentConfig.sourceType() != null)
                ic.setAttribute("source_type", instrumentConfig.sourceType());
            if (instrumentConfig.analyzerType() != null)
                ic.setAttribute("analyzer_type", instrumentConfig.analyzerType());
            if (instrumentConfig.detectorType() != null)
                ic.setAttribute("detector_type", instrumentConfig.detectorType());
        }
    }

    private static InstrumentConfig readInstrumentConfig(StorageGroup runGroup) {
        if (!runGroup.hasChild("instrument_config")) return null;
        try (StorageGroup ic = runGroup.openGroup("instrument_config")) {
            return new InstrumentConfig(
                readOptionalAttr(ic, "manufacturer"),
                readOptionalAttr(ic, "model"),
                readOptionalAttr(ic, "serial_number"),
                readOptionalAttr(ic, "source_type"),
                readOptionalAttr(ic, "analyzer_type"),
                readOptionalAttr(ic, "detector_type")
            );
        }
    }

    /** Write the chromatograms group. The mathematically redundant
     *  {@code chromatogram_index/offsets} column is omitted; readers
     *  synthesize it from {@code cumsum(lengths)}. */
    private void writeChromatograms(StorageGroup runGroup) {
        try (StorageGroup cg = runGroup.createGroup("chromatograms")) {
            cg.setAttribute("count", (long) chromatograms.size());

            // Concatenate time and intensity arrays
            int totalPoints = chromatograms.stream().mapToInt(Chromatogram::length).sum();
            double[] allTime = new double[totalPoints];
            double[] allIntensity = new double[totalPoints];
            int[] lengths = new int[chromatograms.size()];
            int[] types = new int[chromatograms.size()];
            double[] targetMzs = new double[chromatograms.size()];
            double[] precursorMzs = new double[chromatograms.size()];
            double[] productMzs = new double[chromatograms.size()];

            int pos = 0;
            for (int i = 0; i < chromatograms.size(); i++) {
                Chromatogram c = chromatograms.get(i);
                lengths[i] = c.length();
                types[i] = c.type().ordinal();
                targetMzs[i] = c.targetMz();
                precursorMzs[i] = c.precursorMz();
                productMzs[i] = c.productMz();
                System.arraycopy(c.timeValues(), 0, allTime, pos, c.length());
                System.arraycopy(c.intensityValues(), 0, allIntensity, pos, c.length());
                pos += c.length();
            }

            writeDoubleDs(cg, "time_values", allTime);
            writeDoubleDs(cg, "intensity_values", allIntensity);

            try (StorageGroup idx = cg.createGroup("chromatogram_index")) {
                writeIntDs(idx, "lengths", lengths);
                writeIntDs(idx, "types", types);
                writeDoubleDs(idx, "target_mzs", targetMzs);
                writeDoubleDs(idx, "precursor_mzs", precursorMzs);
                writeDoubleDs(idx, "product_mzs", productMzs);
            }
        }
    }

    private static List<Chromatogram> readChromatograms(StorageGroup runGroup) {
        if (!runGroup.hasChild("chromatograms")) return List.of();
        List<Chromatogram> result = new ArrayList<>();

        try (StorageGroup cg = runGroup.openGroup("chromatograms")) {
            double[] allTime = readDoubleDs(cg, "time_values");
            double[] allIntensity = readDoubleDs(cg, "intensity_values");

            try (StorageGroup idx = cg.openGroup("chromatogram_index")) {
                int[] lengths = readIntDs(idx, "lengths");
                // offsets omitted from disk by default;
                // synthesize from cumsum(lengths). Pre-v1.10 files have
                // the column on disk (read directly).
                long[] offsets = idx.hasChild("offsets")
                    ? readLongDs(idx, "offsets")
                    : global.thalion.ttio.genomics.GenomicIndex.offsetsFromLengths(lengths);
                int[] types = readIntDs(idx, "types");
                double[] targetMzs = readDoubleDs(idx, "target_mzs");
                double[] precursorMzs = readDoubleDs(idx, "precursor_mzs");
                double[] productMzs = readDoubleDs(idx, "product_mzs");

                for (int i = 0; i < offsets.length; i++) {
                    int off = (int) offsets[i];
                    int len = lengths[i];
                    double[] time = Arrays.copyOfRange(allTime, off, off + len);
                    double[] intensity = Arrays.copyOfRange(allIntensity, off, off + len);
                    ChromatogramType type = ChromatogramType.values()[types[i]];
                    result.add(new Chromatogram(time, intensity, type,
                            targetMzs[i], precursorMzs[i], productMzs[i]));
                }
            }
        }
        return result;
    }

    private void writeProvenance(StorageGroup runGroup) {
        // Per-run provenance. On the HDF5 fast path we write the
        // canonical compound dataset {@code provenance/steps} matching
        // Python's writer (cross-language round-trip). The JSON
        // attribute is also written so non-HDF5 providers
        // (memory/sqlite/zarr) and legacy Java readers can still
        // recover the chain.
        try (StorageGroup prov = runGroup.createGroup("provenance")) {
            global.thalion.ttio.hdf5.Hdf5Group h5 =
                global.thalion.ttio.providers.Hdf5Provider
                    .tryUnwrapHdf5Group(prov);
            if (h5 != null) {
                global.thalion.ttio.hdf5.Hdf5CompoundIO.writeCompoundDataset(
                    h5, "steps",
                    global.thalion.ttio.hdf5.Hdf5CompoundIO.provenanceSchema(),
                    provenanceRecords.size(),
                    (row, pool) -> {
                        ProvenanceRecord r = provenanceRecords.get(row);
                        return new Object[]{
                            r.timestampUnix(),
                            pool.addString(r.software()),
                            pool.addString(r.parametersJson()),
                            pool.addString(r.inputRefsJson()),
                            pool.addString(r.outputRefsJson())
                        };
                    });
            }
            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < provenanceRecords.size(); i++) {
                if (i > 0) json.append(",");
                ProvenanceRecord r = provenanceRecords.get(i);
                json.append("{\"timestamp_unix\":").append(r.timestampUnix())
                    .append(",\"software\":\"").append(r.software()).append("\"")
                    .append(",\"parameters\":").append(r.parametersJson())
                    .append(",\"input_refs\":").append(r.inputRefsJson())
                    .append(",\"output_refs\":").append(r.outputRefsJson())
                    .append("}");
            }
            json.append("]");
            runGroup.setAttribute("provenance_json", json.toString());
        }
    }

    private static List<ProvenanceRecord> readProvenance(StorageGroup runGroup) {
        // Phase 2 (post-M91): prefer the canonical compound dataset
        // {@code provenance/steps} (matches Python's writer). Fall
        // back to the {@code provenance_json} attribute so files
        // written by older Java versions and non-HDF5 providers
        // (memory/sqlite/zarr) still round-trip cleanly.
        if (runGroup.hasChild("provenance")) {
            try (StorageGroup prov = runGroup.openGroup("provenance")) {
                global.thalion.ttio.hdf5.Hdf5Group h5 =
                    global.thalion.ttio.providers.Hdf5Provider
                        .tryUnwrapHdf5Group(prov);
                if (h5 != null && h5.hasChild("steps")) {
                    List<Object[]> rows = global.thalion.ttio.hdf5.Hdf5CompoundIO
                        .readCompoundFull(h5, "steps",
                            global.thalion.ttio.hdf5.Hdf5CompoundIO
                                .provenanceSchema());
                    List<ProvenanceRecord> out = new ArrayList<>(rows.size());
                    for (Object[] r : rows) {
                        out.add(new ProvenanceRecord(
                            ((Number) r[0]).longValue(),
                            (String) r[1],
                            MiniJson.parseStringMap((String) r[2]),
                            MiniJson.parseArrayOfStrings((String) r[3]),
                            MiniJson.parseArrayOfStrings((String) r[4])));
                    }
                    return out;
                }
            }
        }
        if (!runGroup.hasAttribute("provenance_json")) return List.of();
        Object v = runGroup.getAttribute("provenance_json");
        if (v == null) return List.of();
        String json = v instanceof String s ? s
                    : v instanceof byte[] b ? new String(b,
                          java.nio.charset.StandardCharsets.UTF_8)
                    : v.toString();
        return ProvenanceJsonParse.parseArray(json);
    }

    // ── Dataset helpers ─────────────────────────────────────────────

    private static void writeDoubleDs(StorageGroup g, String name, double[] data) {
        try (StorageDataset ds = g.createDataset(name, Precision.FLOAT64,
                data.length, CHUNK_SIZE, Compression.ZLIB, COMPRESSION_LEVEL)) {
            ds.writeAll(data);
        }
    }

    private static void writeLongDs(StorageGroup g, String name, long[] data) {
        try (StorageDataset ds = g.createDataset(name, Precision.INT64,
                data.length, 0, Compression.NONE, 0)) {
            ds.writeAll(data);
        }
    }

    private static void writeIntDs(StorageGroup g, String name, int[] data) {
        try (StorageDataset ds = g.createDataset(name, Precision.INT32,
                data.length, 0, Compression.NONE, 0)) {
            ds.writeAll(data);
        }
    }

    private static double[] readDoubleDs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (double[]) ds.readAll();
        }
    }

    private static long[] readLongDs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (long[]) ds.readAll();
        }
    }

    private static int[] readIntDs(StorageGroup g, String name) {
        try (StorageDataset ds = g.openDataset(name)) {
            return (int[]) ds.readAll();
        }
    }

    private static String readOptionalAttr(StorageGroup g, String name) {
        return g.hasAttribute(name) ? (String) g.getAttribute(name) : null;
    }

    /**
     * {@code AutoCloseable} hook. A no-op for {@link AcquisitionRun}:
     * all storage handles are opened and closed inside the
     * {@link #writeTo(StorageGroup)} / {@link #read(StorageGroup, String)}
     * boundaries, so nothing remains to release.
     */
    @Override
    public void close() {
        // No storage handles held — all closed after read/write
    }
}
