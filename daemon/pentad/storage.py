"""Storage reporting.

The console presents one pool — "Games 412 GB, Captures 8 GB, System 31 GB" —
not a partition table. btrfs subvolumes make that honest rather than cosmetic:
they genuinely share one allocation, so the numbers add up.
"""

from __future__ import annotations

import logging
import os
import shutil
from typing import Dict

log = logging.getLogger("pentad.storage")

CATEGORIES = {
    "games": "/games",
    "captures": "/var/lib/penta/captures",
    "art": "/var/lib/penta/art",
}

GB = 1024 ** 3


def _dir_bytes(path: str) -> int:
    total = 0
    try:
        for root, _dirs, files in os.walk(path, onerror=lambda _e: None):
            for f in files:
                try:
                    total += os.lstat(os.path.join(root, f)).st_size
                except OSError:
                    continue
    except OSError:
        pass
    return total


class StorageService:
    def __init__(self, mock: bool = False) -> None:
        self._mock = mock

    def usage(self) -> Dict[str, object]:
        if self._mock:
            return {"total_gb": 865, "free_gb": 414, "used_gb": 451,
                    "by_category": {"games": 412, "captures": 8, "system": 31}}

        root = "/games" if os.path.isdir("/games") else "/"
        total, used, free = shutil.disk_usage(root)

        by_category = {}
        for name, path in CATEGORIES.items():
            if os.path.isdir(path):
                by_category[name] = round(_dir_bytes(path) / GB, 1)

        accounted = sum(by_category.values())
        by_category["system"] = max(0.0, round(used / GB - accounted, 1))

        return {
            "total_gb": round(total / GB, 1),
            "free_gb": round(free / GB, 1),
            "used_gb": round(used / GB, 1),
            "by_category": by_category,
        }
