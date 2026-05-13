"""Dataset walker — produces transport-stream events from a
:class:`SpectralDataset` filtered through an :class:`AUFilter`.

This is the Python equivalent of the ObjC ``TTIODatasetWalker`` and
Java ``DatasetWalker``. Where ObjC/Java use a visitor protocol, the
Python form is a generator that yields :class:`WalkerEvent`
instances — more idiomatic and trivially composable with ``async``
producers via ``async for`` adapters.

Used by:
  * :func:`ttio.transport.server._emit_stream` — encodes each event
    as a transport packet.
  * Workbench Server S3 (out-of-tree) — drives binary, stats-only,
    and stats-with-payload download modes from the same iteration.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator, Optional

from .codec import _spectrum_to_access_unit
from .filters import AUFilter
from .packets import AccessUnit
from ..spectral_dataset import SpectralDataset


# ── Event types ────────────────────────────────────────────────────


class WalkerEvent:
    """Marker base class for walker events. Use ``isinstance`` /
    pattern matching in consumers."""


@dataclass(frozen=True, slots=True)
class StreamHeaderEvent(WalkerEvent):
    format_version: str
    title: str
    isa_investigation: str
    features: list[str]
    n_datasets: int


@dataclass(frozen=True, slots=True)
class DatasetHeaderEvent(WalkerEvent):
    dataset_id: int
    name: str
    acquisition_mode: int
    spectrum_class: str
    channel_names: list[str]
    instrument_json: str
    expected_au_count: int


@dataclass(frozen=True, slots=True)
class AccessUnitEvent(WalkerEvent):
    au: AccessUnit
    dataset_id: int
    au_sequence: int


@dataclass(frozen=True, slots=True)
class EndOfDatasetEvent(WalkerEvent):
    dataset_id: int
    final_au_sequence: int


@dataclass(frozen=True, slots=True)
class EndOfStreamEvent(WalkerEvent):
    pass


# ── Walker ─────────────────────────────────────────────────────────


def walk_dataset(
    dataset: SpectralDataset,
    filter: Optional[AUFilter] = None,
) -> Iterator[WalkerEvent]:
    """Generator that yields the canonical transport-stream event
    sequence for the given dataset:

      1. :class:`StreamHeaderEvent` once.
      2. :class:`DatasetHeaderEvent` per matched dataset.
      3. :class:`AccessUnitEvent` per matched AU.
      4. :class:`EndOfDatasetEvent` per matched dataset.
      5. :class:`EndOfStreamEvent` once.

    Iteration order matches :meth:`TransportWriter.write_dataset` —
    the byte form emitted by encoding the events one-by-one is
    identical to the unfiltered writer output (mod filter cuts).

    :param dataset: A :class:`SpectralDataset` to walk.
    :param filter:  Optional :class:`AUFilter`. ``None`` emits every
                    AU in dataset iteration order.
    """
    from .codec import _instrument_config_json

    flt = filter or AUFilter()
    runs = list(dataset.all_runs.items())
    features = list(dataset.feature_flags.features)

    # 1. StreamHeader
    yield StreamHeaderEvent(
        format_version="1.2",
        title=dataset.title or "",
        isa_investigation=dataset.isa_investigation_id or "",
        features=features,
        n_datasets=len(runs),
    )

    # 2. DatasetHeaders
    for i, (name, run) in enumerate(runs, start=1):
        if flt.dataset_id is not None and i != flt.dataset_id:
            continue
        yield DatasetHeaderEvent(
            dataset_id=i,
            name=name,
            acquisition_mode=int(run.acquisition_mode),
            spectrum_class=run.spectrum_class,
            channel_names=list(run.channel_names),
            instrument_json=_instrument_config_json(run),
            expected_au_count=len(run),
        )

    # 3. AccessUnits
    emitted = 0
    max_au = flt.max_au
    for i, (_name, run) in enumerate(runs, start=1):
        if flt.dataset_id is not None and i != flt.dataset_id:
            continue
        for j, spectrum in enumerate(run):
            if max_au is not None and emitted >= max_au:
                break
            au = _spectrum_to_access_unit(spectrum, run)
            if not flt.matches(au, i):
                continue
            yield AccessUnitEvent(au=au, dataset_id=i, au_sequence=j)
            emitted += 1
        if max_au is not None and emitted >= max_au:
            break

    # 4. EndOfDataset per dataset
    for i, (_name, run) in enumerate(runs, start=1):
        if flt.dataset_id is not None and i != flt.dataset_id:
            continue
        yield EndOfDatasetEvent(dataset_id=i, final_au_sequence=len(run))

    # 5. EndOfStream
    yield EndOfStreamEvent()
