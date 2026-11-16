# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Configuration file for the Sphinx documentation builder.
#
# Ventium — P5/P54C non-MMX microarchitecture replica documentation.
# Kept intentionally minimal and dependency-free so the build is reproducible:
# pure reStructuredText, no third-party extensions, and a Sphinx built-in theme.

# -- Project information -----------------------------------------------------

project = "Ventium"
author = "The Ventium Project"
copyright = "2026, The Ventium Project"

# Board-qualified RK-XCZU15EG-F public FPGA source release (c0e3fe43).
version = "0.2.0"
release = "0.2.0-c0e3fe43"

# -- General configuration ---------------------------------------------------

# Only first-party (Sphinx-bundled) extensions, so the build stays free of any
# pip-only dependency (no MyST, no third-party theme). `sphinx.ext.graphviz`
# ships with Sphinx itself; it renders the architecture block diagrams and needs
# only the system `dot` binary (Graphviz) at build time.
extensions = ["sphinx.ext.graphviz"]

# Render diagrams as SVG (crisp at any zoom) rather than the default PNG.
graphviz_output_format = "svg"

# Patterns to ignore when looking for source files. ``*.dot`` are diagram sources
# referenced by the graphviz directive, not standalone documents.
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store", "**/*.dot"]

# -- Options for HTML output -------------------------------------------------

# 'alabaster' ships with Sphinx itself, so it is always available — no
# sphinx_rtd_theme (or any other pip-only theme) that might be missing.
html_theme = "alabaster"

# A short, descriptive title shown in the browser tab / sidebar.
html_title = "Ventium — P5/P54C Replica Reference (v0.2.0-c0e3fe43)"

# Project logo, shown atop the alabaster sidebar. Path is relative to this
# configuration directory (docs/sphinx/), pointing at the single source of truth
# docs/ventium.png; Sphinx copies it into the output _static/ on build.
html_logo = "../ventium.png"

# alabaster: surface official GitHub repository & releases prominently in the
# sidebar and top banner without requiring third-party iframe buttons.
html_theme_options = {
    "logo_name": True,
    "description": "Synthesizable SystemVerilog Pentium P5/P54C Reconstruction",
    "github_user": "AL-255",
    "github_repo": "ventium",
    "github_banner": True,
    "github_button": False,
    "extra_nav_links": {
        "GitHub Source (AL-255/ventium)": "https://github.com/AL-255/ventium",
        "Official Releases (v0.2.0-c0e3fe43)": "https://github.com/AL-255/ventium/releases",
        "FPGA Build & Run Guide": "https://github.com/AL-255/ventium/blob/main/HOW_TO_RUN_FPGA.md",
    },
}
