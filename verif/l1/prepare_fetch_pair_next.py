"""Compose two independently tested timing cuts on their exact common parent.

The pair/next-only netlist remains limited by the fetch/fragment cone; the
fetch-only netlist was limited by next-read/pair arbitration. This composition
is an experiment, not an inherited timing, functional or hardware pass.
Neither latency nor feature selection changes. Do not use CURRENT_U_ONLY.
"""
import importlib.util
from pathlib import Path

import prepare_pair_next_disjoint as pair

_path = Path(__file__).resolve().parents[1]/'fe_pipe/prepare_fetch_fragment_extent.py'
_spec = importlib.util.spec_from_file_location('fetch_pair_extent_recipe', _path)
fetch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fetch)

PARENTS = {**pair.PARENTS, fetch.FILE: fetch.PARENT}


def transform(source, name):
    """Keep each exact qualified transformation; reject unknown files or drift."""
    if name not in PARENTS:
        raise ValueError('unknown fetch/pair composition input')
    if name == fetch.FILE:
        return fetch.transform(source)
    return pair.transform(source, name)
