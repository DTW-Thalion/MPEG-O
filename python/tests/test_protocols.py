"""Parity tests for the domain protocols defined in
``mpeg_o.protocols``. Mirrors Objective-C ``MPGOCVAnnotatable.h``,
``MPGOEncryptable.h``, ``MPGOIndexable.h``, ``MPGOProvenanceable.h``,
``MPGOStreamable.h``.
"""
from __future__ import annotations

from mpeg_o.protocols import (
    CVAnnotatable,
    Encryptable,
    Indexable,
    Provenanceable,
    Streamable,
)


def test_cv_annotatable_surface():
    # Every ObjC MPGOCVAnnotatable method has a Python counterpart.
    assert hasattr(CVAnnotatable, "add_cv_param")
    assert hasattr(CVAnnotatable, "remove_cv_param")
    assert hasattr(CVAnnotatable, "all_cv_params")
    assert hasattr(CVAnnotatable, "cv_params_for_accession")
    assert hasattr(CVAnnotatable, "cv_params_for_ontology_ref")
    assert hasattr(CVAnnotatable, "has_cv_param_with_accession")


def test_encryptable_surface():
    assert hasattr(Encryptable, "encrypt_with_key")
    assert hasattr(Encryptable, "decrypt_with_key")
    assert hasattr(Encryptable, "access_policy")
    assert hasattr(Encryptable, "set_access_policy")

def test_indexable_surface():
    # Required
    assert hasattr(Indexable, "object_at_index")
    assert hasattr(Indexable, "count")
    # Optional
    assert hasattr(Indexable, "object_for_key")
    assert hasattr(Indexable, "objects_in_range")

def test_provenanceable_surface():
    assert hasattr(Provenanceable, "add_processing_step")
    assert hasattr(Provenanceable, "provenance_chain")
    assert hasattr(Provenanceable, "input_entities")
    assert hasattr(Provenanceable, "output_entities")

def test_streamable_surface():
    assert hasattr(Streamable, "next_object")
    assert hasattr(Streamable, "has_more")
    assert hasattr(Streamable, "current_position")
    assert hasattr(Streamable, "seek_to_position")
    assert hasattr(Streamable, "reset")
