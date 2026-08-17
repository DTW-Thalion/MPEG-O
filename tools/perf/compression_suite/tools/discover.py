# tools/perf/compression_suite/tools/discover.py
"""Print candidate corpora so accession choices are recorded in the manifest.

  python discover.py sra      # HG002 runs from ENA (Illumina + PacBio)
  python discover.py pride    # PRIDE projects with mzML files, Exploris / timsTOF
"""
import json, sys, urllib.parse, urllib.request

HG002 = "SAMN03283347"


def sra():
    q = f'sample_accession="{HG002}"'
    url = ("https://www.ebi.ac.uk/ena/portal/api/search?result=read_run&query="
           + urllib.parse.quote(q)
           + "&fields=run_accession,instrument_platform,instrument_model,library_layout,base_count,read_count,fastq_bytes&format=tsv&limit=0")
    print(urllib.request.urlopen(url).read().decode())


def pride():
    """Projects for the two instrument keywords that host an mzML of
    1 to 4.5 GB, with the three smallest such files and their FTP URLs
    (the v3 files endpoint; the v2 byProject endpoint returns nothing)."""
    for kw in ("Orbitrap Exploris 480", "timsTOF"):
        print("=====", kw)
        url = ("https://www.ebi.ac.uk/pride/ws/archive/v2/search/projects?keyword="
               + urllib.parse.quote(kw) + "&pageSize=40&page=0")
        rows = json.loads(urllib.request.urlopen(url).read().decode())
        shown = 0
        for r in rows if isinstance(rows, list) else rows.get("_embedded", {}).get("projects", []):
            acc = r.get("accession")
            try:
                files = json.loads(urllib.request.urlopen(
                    f"https://www.ebi.ac.uk/pride/ws/archive/v3/projects/{acc}/files?pageSize=500",
                    timeout=60).read().decode())
            except Exception as e:  # one project failing must not stop the listing
                print(acc, "files api error", e)
                continue
            mz = []
            for f in files if isinstance(files, list) else []:
                name = f.get("fileName", "")
                size = f.get("fileSizeBytes", 0)
                if name.lower().endswith((".mzml", ".mzml.gz")) and 1e9 <= size <= 4.5e9:
                    locs = f.get("publicFileLocations", [])
                    ftp = [l.get("value") for l in locs if l.get("name", "").lower().startswith("ftp")]
                    mz.append((size, name, (ftp or [None])[0]))
            if mz:
                shown += 1
                print(acc, "|", r.get("title", "")[:70], "|", ",".join(r.get("instruments", []) or []))
                for size, name, u in sorted(mz)[:3]:
                    print(f"   {size / 1e9:.2f} GB  {name}  {u}")
            if shown >= 4:
                break


if __name__ == "__main__":
    {"sra": sra, "pride": pride}[sys.argv[1]]()
