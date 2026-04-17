"""``AccessPolicy`` — who-may-decrypt-what policy dictionary."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True, slots=True)
class AccessPolicy:
    """Access policy describing who may decrypt which streams in an
    ``.mpgo`` file.

    Stored as a JSON string under ``/protection/access_policies`` on
    disk, so the policy is human-inspectable and recoverable
    independently of any key-management system.

    The policy is intentionally schema-free at this layer: the dict
    holds arbitrary key/value pairs that the application is free to
    interpret (typical fields: ``subjects``, ``streams``, ``expiry``,
    ``key_id``, ``audit_contact``).

    Parameters
    ----------
    policy : dict[str, Any], default {}
        Arbitrary key/value policy payload.

    Notes
    -----
    API status: Stable.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOAccessPolicy`` · Java:
    ``com.dtwthalion.mpgo.protection.AccessPolicy``.
    """

    policy: dict[str, Any] = field(default_factory=dict)
