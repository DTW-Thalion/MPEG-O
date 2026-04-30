# M92 Benchmark Datasets

The M92 compression benchmark report exercises four datasets,
all fetched on demand via DVC under `data/genomic/`. None are
checked into git.

> If you only want to validate the harness, run the synthetic
> dataset path — it has no external download.

## Layout

```
data/genomic/
├── reference/
│   ├── GRCh38.fa                  # full-genome FASTA + .fai
│   └── GRCh38.chr22.fa            # chr22-only slice + .fai
├── na12878/
│   ├── na12878.chr22.bam          # Iteration fixture (~50 MB)
│   ├── na12878.chr22.bam.bai
│   ├── na12878.wgs.0.05x.bam      # Headline WGS run
│   └── na12878.wgs.0.05x.bam.bai
├── err194147/
│   ├── err194147.bam              # Platinum Genomes WES
│   └── err194147.bam.bai
└── synthetic/
    ├── mixed_chrom.bam            # Deterministic, see synthetic.py
    ├── mixed_chrom.bam.bai
    └── mixed_chrom.fa             # Synthetic reference
```

## Sources

### NA12878 WGS

- **Provenance**: Genome in a Bottle (GIAB) HG001 / NA12878
  truth set v3.3.2 BAM, GRCh38-aligned. Public NIH ftp.
- **Full BAM size**: ~50 GB (50× coverage). Too large for direct
  benchmarking; we down-sample.
- **Downsample to 0.05x** (≈ 1 GB):

  ```bash
  samtools view -bs 42.001 \
      ftp://ftp-trace.ncbi.nlm.nih.gov/.../HG001.GRCh38.300x.bam \
      > data/genomic/na12878/na12878.wgs.0.05x.bam
  samtools index data/genomic/na12878/na12878.wgs.0.05x.bam
  ```

  The `42.001` token seeds samtools' subsample at fraction 0.001
  ≈ 0.05×; tweak the second component to retune.

- **chr22 slice** (≈ 50 MB):

  ```bash
  samtools view -b \
      data/genomic/na12878/na12878.wgs.0.05x.bam \
      chr22 > data/genomic/na12878/na12878.chr22.bam
  samtools index data/genomic/na12878/na12878.chr22.bam
  ```

### ERR194147 WES

- **Provenance**: Illumina Platinum Genomes ERR194147 (NA12878
  proband; WES capture against GRCh38).
- **Source**: ENA `ftp://ftp.sra.ebi.ac.uk/vol1/fastq/ERR194/ERR194147/`
- **Convert FASTQ → BAM**:

  ```bash
  bwa mem -t 8 GRCh38.fa ERR194147_1.fastq.gz ERR194147_2.fastq.gz \
      | samtools sort -O bam -o err194147.bam
  samtools index err194147.bam
  ```

### GRCh38 reference

- **Source**: Ensembl release 110 primary assembly. SHA-256 pinned
  in DVC.

  ```bash
  curl -L 'https://ftp.ensembl.org/.../GRCh38.primary_assembly.fa.gz' \
      | gunzip > data/genomic/reference/GRCh38.fa
  samtools faidx data/genomic/reference/GRCh38.fa
  ```

- **chr22 slice**:

  ```bash
  samtools faidx data/genomic/reference/GRCh38.fa chr22 \
      > data/genomic/reference/GRCh38.chr22.fa
  samtools faidx data/genomic/reference/GRCh38.chr22.fa
  ```

### Synthetic mixed-chromosome

Deterministic; no external download needed:

```bash
python -m tools.benchmarks.synthetic \
    --out data/genomic/synthetic/mixed_chrom.bam \
    --reference-out data/genomic/synthetic/mixed_chrom.fa \
    --reads-per-chrom 2000 \
    --seed 0xBEEF
```

## DVC pinning

After fetching/generating, pin via DVC so future benchmark runs
use the same bytes:

```bash
cd data/genomic
dvc add na12878/ err194147/ reference/ synthetic/
git add *.dvc .gitignore
git commit -m "data: pin M92 benchmark fixtures"
```

DVC remote configuration is project-private; coordinate with
@toddw before first `dvc push`.
