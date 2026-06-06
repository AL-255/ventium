# Configuration file for the Sphinx documentation builder.
#
# Ventium — P5/P54C non-MMX microarchitecture replica documentation.
# Kept intentionally minimal and dependency-free so the build is reproducible:
# pure reStructuredText, no third-party extensions, and a Sphinx built-in theme.

# -- Project information -----------------------------------------------------

project = "Ventium"
author = "The Ventium Project"
copyright = "2026, The Ventium Project"

# The Ventium replica targets the P5/P54C (i586) generation.
version = "0.1"
release = "0.1"

# -- General configuration ---------------------------------------------------

# No extensions: the docs are written in plain reStructuredText, which Sphinx
# parses natively. This avoids any pip-only dependency (e.g. MyST) so the
# build is reproducible from a bare Sphinx install.
extensions = []

# Patterns to ignore when looking for source files.
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

# -- Options for HTML output -------------------------------------------------

# 'alabaster' ships with Sphinx itself, so it is always available — no
# sphinx_rtd_theme (or any other pip-only theme) that might be missing.
html_theme = "alabaster"

# A short, descriptive title shown in the browser tab / sidebar.
html_title = "Ventium — P5/P54C Replica Reference"

# Project logo, shown atop the alabaster sidebar. Path is relative to this
# configuration directory (docs/sphinx/), pointing at the single source of truth
# docs/ventium.png; Sphinx copies it into the output _static/ on build.
html_logo = "../ventium.png"

# alabaster: keep the project name visible beneath the logo (logo_name) rather
# than letting the image replace the title text entirely.
html_theme_options = {
    "logo_name": True,
}
