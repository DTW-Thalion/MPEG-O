"""
Unit tests for `ttio.workbench.pipeline` -- Pipeline dataclass +
PipelinesClient structural behaviour. Pure data; no daemon.
"""
from __future__ import annotations

from ttio.workbench.pipeline import Pipeline, PipelinesClient


def test_pipeline_from_json_full():
    p = Pipeline.from_json({
        "pipeline_id":    "01HPL",
        "identifier":     "rnaseq",
        "version":        "1.0.0",
        "project":        "alpha",
        "owner":          "alice",
        "engine_pin":     "nextflow",
        "definition":     "process { ... }",
        "inputs_schema":  {"reads": {"type": "fastq"}},
        "outputs_schema": {"counts": {"type": "matrix"}},
    })
    assert p.pipeline_id == "01HPL"
    assert p.engine_pin == "nextflow"
    assert p.inputs_schema["reads"]["type"] == "fastq"


def test_pipeline_schema_as_string_round_trips():
    # Server emits inputs_schema as parsed JSON; some legacy paths
    # ship it as TEXT. Confirm we tolerate both.
    p = Pipeline.from_json({
        "pipeline_id": "01HPL",
        "identifier":  "rnaseq",
        "version":     "1.0.0",
        "project":     "alpha",
        "owner":       "alice",
        "engine_pin":  None,
        "definition":  "",
        "inputs_schema":  '{"reads": {"type": "fastq"}}',
        "outputs_schema": '{}',
    })
    assert p.inputs_schema == {"reads": {"type": "fastq"}}
    assert p.outputs_schema == {}


def test_pipeline_missing_optional_fields():
    p = Pipeline.from_json({
        "pipeline_id": "01HPL",
        "identifier":  "rnaseq",
        "version":     "1.0.0",
        "project":     "alpha",
        "owner":       "alice",
        "engine_pin":  None,
        "definition":  "",
    })
    assert p.inputs_schema == {}
    assert p.outputs_schema == {}


def test_pipelines_client_construction():
    client = PipelinesClient(
        host="localhost", port=8443, scheme="http", token="ttiowbs_abc")
    assert client._host == "localhost"
    assert client._port == 8443
