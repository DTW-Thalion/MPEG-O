package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;

import java.util.Objects;

public final class OpenDataset {

    private final String path;
    private final boolean readOnly;
    private final SpectralDataset dataset;

    public OpenDataset(String path, boolean readOnly, SpectralDataset dataset) {
        this.path = Objects.requireNonNull(path);
        this.readOnly = readOnly;
        this.dataset = Objects.requireNonNull(dataset);
    }

    public String path()                     { return path; }
    public boolean readOnly()                { return readOnly; }
    public SpectralDataset dataset()         { return dataset; }
    public int msRunCount()                  { return dataset.msRuns().size(); }
    public int genomicRunCount()             { return dataset.genomicRuns().size(); }
    public int referenceCount()              { return dataset.references().size(); }
    public int identificationCount()         { return dataset.identifications().size(); }
    public int quantificationCount()         { return dataset.quantifications().size(); }
    public int provenanceCount()             { return dataset.provenanceRecords().size(); }
    public boolean isEncrypted()             { return dataset.isEncrypted(); }
    public String encryptionAlgorithm()      { return dataset.encryptedAlgorithm(); }
    public String formatVersion()            { return dataset.featureFlags().formatVersion(); }

    public void close() {
        dataset.close();
    }
}
