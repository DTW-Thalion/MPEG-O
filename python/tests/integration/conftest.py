"""Auto-tag every test under ``tests/integration/`` with the ``integration``
marker so pytest's default filter ``-m 'not integration'`` excludes them.

The directory layout already segregates these tests, but pytest does not
infer markers from paths. Without this hook, tests like
``test_m87_cross_language.py`` and ``test_m88_cross_language.py`` —
which depend on Java/ObjC sibling builds being present — run under the
default suite on jobs that don't compile those siblings (e.g. the
``python-test`` GHA job) and then fail with subprocess errors.

Tagging them ``integration`` puts them in the explicit opt-in suite that
``Cross-language parity`` and ``Python — vendor-format fixture round-trips``
jobs can pick up via ``-m integration``.
"""
import pytest


def pytest_collection_modifyitems(config, items):
    for item in items:
        if "tests/integration/" in str(item.fspath).replace("\\", "/"):
            item.add_marker(pytest.mark.integration)
