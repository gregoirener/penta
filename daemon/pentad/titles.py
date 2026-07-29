"""Title providers.

Each provider turns one source of games into `Title` records. The menu never
learns where a title came from — it gets a uid, a name, a colour and a launch
command, and that's the whole contract.

Adding a store later means adding a provider here and nothing else.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List, Optional

log = logging.getLogger("pentad.titles")


@dataclass
class Title:
    uid: str
    name: str
    provider: str
    launch: List[str] = field(default_factory=list)
    accent: str = "#2f6fe4"
    last_played: Optional[float] = None
    playtime_s: int = 0
    art: Dict[str, str] = field(default_factory=dict)

    def to_json(self) -> dict:
        return asdict(self)


class Provider:
    name = "base"

    def scan(self) -> List[Title]:
        raise NotImplementedError


# --- Accent colours -----------------------------------------------------------
# Until SteamGridDB art lands (M2), a title's colour is derived from its name.
# Deterministic, so a game keeps the same colour across restarts — which matters
# more than the colour being "right", because the lightbar and background use it.

_PALETTE = [
    "#c9a227", "#3f6fd4", "#b3352b", "#4fd6c0", "#9b3fd4",
    "#e06a1f", "#5f8c3a", "#d4407f", "#2f8fb0", "#a8562e",
]


def accent_for(name: str) -> str:
    h = 0
    for ch in name:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return _PALETTE[h % len(_PALETTE)]


# --- Steam --------------------------------------------------------------------

_ACF_KEY = re.compile(r'"(\w+)"\s+"([^"]*)"')

STEAM_ROOTS = [
    "~/.steam/steam/steamapps",
    "~/.local/share/Steam/steamapps",
    "~/.var/app/com.valvesoftware.Steam/data/Steam/steamapps",
]

# Runtimes and redistributables live in the same folder as real games.
STEAM_SKIP = {"228980", "1070560", "1391110", "1493710", "1628350"}


class SteamProvider(Provider):
    name = "steam"

    def scan(self) -> List[Title]:
        out: List[Title] = []
        for root in STEAM_ROOTS:
            base = Path(os.path.expanduser(root))
            if not base.is_dir():
                continue
            for acf in base.glob("appmanifest_*.acf"):
                t = self._parse(acf)
                if t:
                    out.append(t)
        return out

    def _parse(self, path: Path) -> Optional[Title]:
        try:
            fields = dict(_ACF_KEY.findall(path.read_text(errors="replace")))
        except OSError as exc:
            log.warning("unreadable manifest %s: %s", path, exc)
            return None

        appid = fields.get("appid")
        name = fields.get("name")
        if not appid or not name or appid in STEAM_SKIP:
            return None

        last = fields.get("LastPlayed")
        return Title(
            uid=f"steam:{appid}",
            name=name,
            provider=self.name,
            # Hand off to Steam rather than exec'ing the binary: Steam owns
            # Proton selection, per-game launch options and the cloud sync.
            launch=["steam", f"steam://rungameid/{appid}"],
            accent=accent_for(name),
            last_played=float(last) if last and last.isdigit() and int(last) else None,
        )


# --- Native / homebrew --------------------------------------------------------

class NativeProvider(Provider):
    """`/games/native/<slug>/penta.json` — six lines and it's on the dashboard."""

    name = "native"

    def __init__(self, root: str = "/games/native") -> None:
        self.root = Path(root)

    def scan(self) -> List[Title]:
        out: List[Title] = []
        if not self.root.is_dir():
            return out
        for manifest in sorted(self.root.glob("*/penta.json")):
            try:
                data = json.loads(manifest.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                log.warning("bad manifest %s: %s", manifest, exc)
                continue
            name = data.get("name") or manifest.parent.name
            exe = data.get("exec")
            if not exe:
                log.warning("%s has no 'exec'", manifest)
                continue
            cmd = exe if isinstance(exe, list) else [exe]
            # Relative paths resolve against the title's own directory.
            if cmd and not cmd[0].startswith("/"):
                cmd[0] = str(manifest.parent / cmd[0])
            out.append(Title(
                uid=f"native:{manifest.parent.name}",
                name=name,
                provider=self.name,
                launch=cmd,
                accent=data.get("accent") or accent_for(name),
            ))
        return out


# --- ROMs ---------------------------------------------------------------------

RETRO_CORES = {
    "snes": "snes9x", "nes": "nestopia", "gb": "gambatte", "gba": "mgba",
    "n64": "mupen64plus_next", "gc": "dolphin", "wii": "dolphin",
    "ps1": "pcsx_rearmed", "genesis": "genesis_plus_gx", "arcade": "fbneo",
}
ROM_EXT = {".sfc", ".smc", ".nes", ".gb", ".gbc", ".gba", ".z64", ".n64",
           ".iso", ".chd", ".bin", ".md", ".zip"}


class RomProvider(Provider):
    """`/games/roms/<system>/<rom>` — the system is the directory name."""

    name = "rom"

    def __init__(self, root: str = "/games/roms") -> None:
        self.root = Path(root)

    def scan(self) -> List[Title]:
        out: List[Title] = []
        if not self.root.is_dir():
            return out
        for system_dir in sorted(self.root.iterdir()):
            if not system_dir.is_dir():
                continue
            core = RETRO_CORES.get(system_dir.name.lower())
            if not core:
                log.warning("no core mapped for system %r", system_dir.name)
                continue
            for rom in sorted(system_dir.iterdir()):
                if rom.suffix.lower() not in ROM_EXT:
                    continue
                name = rom.stem.replace("_", " ")
                out.append(Title(
                    uid=f"rom:{system_dir.name}:{rom.stem}",
                    name=name,
                    provider=self.name,
                    launch=["retroarch", "-L",
                            f"/usr/lib/libretro/{core}_libretro.so", str(rom)],
                    accent=accent_for(name),
                ))
        return out


# --- Built-in system entries --------------------------------------------------

class SystemProvider(Provider):
    """Entries the console always offers, independent of any library.

    Without this a fresh install shows an empty dashboard and no way to fix it:
    the Steam provider reads Steam's manifests, but nothing would ever launch
    Steam so you could sign in and install something. Chicken and egg.
    """

    name = "system"

    ENTRIES = [
        {
            "uid": "system:steam",
            "name": "Steam",
            "bin": "steam",
            # Big Picture is controller-navigable, which matters because there
            # is no mouse and no desktop to fall back to.
            "launch": ["steam", "-tenfoot", "-steamos"],
            "accent": "#1b2838",
        },
        {
            "uid": "system:retroarch",
            "name": "RetroArch",
            "bin": "retroarch",
            "launch": ["retroarch"],
            "accent": "#2f6fe4",
        },
    ]

    def scan(self) -> List[Title]:
        import shutil
        out = []
        for e in self.ENTRIES:
            if not shutil.which(e["bin"]):
                continue
            out.append(Title(
                uid=e["uid"],
                name=e["name"],
                provider=self.name,
                launch=e["launch"],
                accent=e["accent"],
                # Sorts last among never-played, so real games outrank it once
                # the library has anything in it.
                last_played=None,
            ))
        return out


# --- Mock ---------------------------------------------------------------------

class MockProvider(Provider):
    """Fake library for developing the menu on macOS with no console attached.

    Deliberately part of the daemon rather than a separate script: one
    implementation of the protocol means it cannot drift from the real thing.
    """

    name = "mock"

    _GAMES = [
        ("Elden Ring", "steam", 412_000, 3_600),
        ("Cyberpunk 2077", "steam", 190_000, 86_400),
        ("The Witcher 3", "steam", 530_000, 250_000),
        ("Red Dead Redemption 2", "steam", 88_000, 600_000),
        ("Baldur's Gate 3", "steam", 305_000, 5_400),
        ("Chrono Trigger", "rom", 21_000, 900_000),
        ("Metroid Prime", "rom", 0, None),
        ("Orbitfall", "native", 1_400, 120),
        ("Fallout 4", "steam", 64_000, None),
    ]

    def scan(self) -> List[Title]:
        now = time.time()
        out = []
        for i, (name, provider, playtime, ago) in enumerate(self._GAMES):
            slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
            out.append(Title(
                uid=f"{provider}:{slug}",
                name=name,
                provider=provider,
                launch=["true"],
                accent=accent_for(name),
                last_played=None if ago is None else now - ago,
                playtime_s=playtime,
            ))
        return out


# --- Library ------------------------------------------------------------------

class Library:
    """Aggregates providers and caches the result."""

    def __init__(self, providers: List[Provider]) -> None:
        self.providers = providers
        self._titles: Dict[str, Title] = {}

    def refresh(self) -> List[Title]:
        found: Dict[str, Title] = {}
        for p in self.providers:
            try:
                for t in p.scan():
                    found[t.uid] = t
            except Exception as exc:                               # noqa: BLE001
                # One broken provider must not empty the whole dashboard.
                log.error("provider %s failed: %s", p.name, exc)
        self._titles = found
        log.info("library: %d titles from %d providers",
                 len(found), len(self.providers))
        return self.sorted()

    def sorted(self) -> List[Title]:
        # Recently played first, never-played next, system entries last — so
        # Steam is always reachable but never in the way once you own games.
        return sorted(
            self._titles.values(),
            key=lambda t: (t.provider == "system",
                           t.last_played is None,
                           -(t.last_played or 0)))

    def get(self, uid: str) -> Title:
        if uid not in self._titles:
            raise KeyError(f"unknown title {uid!r}")
        return self._titles[uid]

    def touch(self, uid: str, played_s: int = 0) -> None:
        t = self._titles.get(uid)
        if t:
            t.last_played = time.time()
            t.playtime_s += played_s
