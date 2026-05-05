"""Sphinx configuration for TTI-O Python reference documentation."""
from __future__ import annotations

import sys
from pathlib import Path

# Ensure the package is importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

project = "TTI-O Python"
copyright = "2026, The Thalion Initiative"
release = "1.0.0"

extensions = [
    "sphinx.ext.napoleon",       # NumPy-style docstring rendering
    "sphinx.ext.viewcode",       # show source next to every entry
    "sphinx.ext.intersphinx",    # cross-ref to numpy / h5py
    "autoapi.extension",
]

# Napoleon
napoleon_numpy_docstring = True
napoleon_google_docstring = False
napoleon_include_init_with_doc = True
napoleon_use_rtype = False

# autoapi
autoapi_type = "python"
autoapi_dirs = ["../src/ttio"]
autoapi_options = [
    "members",
    "undoc-members",
    "show-inheritance",
    "show-module-summary",
    "special-members",
    "imported-members",
]
autoapi_keep_files = False
autoapi_python_class_content = "both"

# intersphinx — optional convenience
intersphinx_mapping = {
    "python": ("https://docs.python.org/3/", None),
    "numpy": ("https://numpy.org/doc/stable/", None),
    "h5py": ("https://docs.h5py.org/en/stable/", None),
}

# HTML output
html_theme = "furo"
html_title = "TTI-O Python API"
html_static_path = ["_static"]

# Exclude the private _numpress module etc. from the TOC if they're noisy.
autoapi_ignore = ["*/_numpress*", "*/_hdf5_io*", "*/_rwlock*", "*/__pycache__*"]
