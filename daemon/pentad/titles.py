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
    # Launchable but kept off the dashboard. A console shows games, not the
    # store client that happens to run them.
    hidden: bool = False

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

# Steam installation roots, not steamapps dirs — the library folders are
# discovered from inside them.
STEAM_ROOTS = [
    # Linux
    "~/.steam/steam",
    "~/.local/share/Steam",
    "~/.steam/root",
    "~/.steam/debian-installation",
    "~/.var/app/com.valvesoftware.Steam/data/Steam",       # flatpak
    "/usr/lib/steam",
    # macOS — so the real library is testable on the dev machine
    "~/Library/Application Support/Steam",
]

# libraryfolders.vdf lists every drive Steam installs to. Without parsing it we
# would only ever see games on the boot disk, which is exactly the case people
# with a second SSD care about.
_VDF_PATH = re.compile(r'"path"\s+"([^"]+)"')


def steam_install_roots() -> List[Path]:
    """Every Steam installation directory present on this machine."""
    out = []
    for root in STEAM_ROOTS:
        p = Path(os.path.expanduser(root))
        if p.is_dir() and (p / "steamapps").is_dir():
            resolved = p.resolve()
            if resolved not in out:
                out.append(resolved)
    return out


def steam_library_dirs() -> List[Path]:
    """Every steamapps/ directory, including libraries on other drives."""
    libs: List[Path] = []

    def add(p: Path) -> None:
        if p.is_dir() and p not in libs:
            libs.append(p)

    for root in steam_install_roots():
        add(root / "steamapps")
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if not vdf.is_file():
            continue
        try:
            text = vdf.read_text(errors="replace")
        except OSError as exc:
            log.warning("unreadable %s: %s", vdf, exc)
            continue
        for raw in _VDF_PATH.findall(text):
            # Paths in the vdf are escaped Windows-style even on Unix.
            add(Path(raw.replace("\\\\", "/")) / "steamapps")
    return libs

# Steam serves cover art publicly, no API key and no account needed. This is
# what makes the dashboard look like a console instead of a file browser, and
# it removes the SteamGridDB key that M2 was going to need.
STEAM_CDN = "https://cdn.cloudflare.steamstatic.com/steam/apps"


def _steam_url_argv(url: str) -> List[str]:
    """argv that hands a steam:// URL to Steam on this platform."""
    import shutil
    import sys
    if shutil.which("steam"):
        return ["steam", url]
    if sys.platform == "darwin":
        return ["open", url]           # macOS resolves the scheme itself
    return ["xdg-open", url]


def steam_art(appid: str) -> Dict[str, str]:
    return {
        # 600x900 portrait, centre-cropped into the square tile by the menu.
        "cover": f"{STEAM_CDN}/{appid}/library_600x900.jpg",
        "hero":  f"{STEAM_CDN}/{appid}/library_hero.jpg",
        "logo":  f"{STEAM_CDN}/{appid}/logo.png",
        # Not every title has a portrait capsule; header always exists.
        "fallback": f"{STEAM_CDN}/{appid}/header.jpg",
    }

# Runtimes and redistributables live in the same folder as real games.
STEAM_SKIP = {"228980", "1070560", "1391110", "1493710", "1628350"}


class SteamProvider(Provider):
    name = "steam"

    def scan(self) -> List[Title]:
        out: List[Title] = []
        seen = set()
        libs = steam_library_dirs()
        for base in libs:
            for acf in base.glob("appmanifest_*.acf"):
                t = self._parse(acf)
                if t and t.uid not in seen:
                    seen.add(t.uid)
                    out.append(t)
        log.info("steam: %d install(s), %d library folder(s), %d games",
                 len(steam_install_roots()), len(libs), len(out))
        return out

    @staticmethod
    def status() -> dict:
        """What we actually found — so the UI can say 'Steam installed, no
        games' instead of showing an empty list and leaving you guessing."""
        roots = steam_install_roots()
        libs = steam_library_dirs()
        games = 0
        for base in libs:
            games += len(list(base.glob("appmanifest_*.acf")))
        return {
            "installed": bool(roots),
            "roots": [str(p) for p in roots],
            "libraries": [str(p) for p in libs],
            "games": games,
        }

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
            # Proton selection, per-game launch options and cloud saves. The
            # rungameid URL goes straight into the game — Steam's own UI never
            # appears, exactly like a desktop shortcut.
            launch=_steam_url_argv(f"steam://rungameid/{appid}"),
            accent=accent_for(name),
            last_played=float(last) if last and last.isdigit() and int(last) else None,
            art=steam_art(appid),
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
    """Launchable system apps, deliberately hidden from the dashboard.

    A console shows games, not the store client that runs them — so Steam does
    not get a tile. But a fresh install still needs a way in to sign in and
    install something, so these stay launchable and Settings exposes them.
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

    @staticmethod
    def _find(binary: str) -> Optional[List[str]]:
        """Launch argv for a system app, or None if it isn't installed.

        macOS keeps apps in bundles rather than on PATH, so `which steam` finds
        nothing on a Mac that plainly has Steam. Being able to run the daemon in
        real mode on the dev machine is worth the six lines.
        """
        import shutil
        import sys
        if shutil.which(binary):
            return None            # caller uses its own argv
        if sys.platform == "darwin":
            app = {"steam": "/Applications/Steam.app",
                   "retroarch": "/Applications/RetroArch.app"}.get(binary)
            if app and os.path.isdir(app):
                return ["open", "-a", app]
        return ["__missing__"]

    def scan(self) -> List[Title]:
        out = []
        for e in self.ENTRIES:
            mac = self._find(e["bin"])
            if mac == ["__missing__"]:
                continue
            launch = mac if mac else e["launch"]
            out.append(Title(
                uid=e["uid"],
                name=e["name"],
                provider=self.name,
                launch=launch,
                accent=e["accent"],
                last_played=None,
                hidden=True,
            ))
        return out


# --- Mock ---------------------------------------------------------------------

class MockProvider(Provider):
    """Fake library for developing the menu on macOS with no console attached.

    Deliberately part of the daemon rather than a separate script: one
    implementation of the protocol means it cannot drift from the real thing.
    """

    name = "mock"

    # Real Steam appids: the mock then pulls genuine cover art from Steam's CDN,
    # so what you see on the dev machine is what the console will look like.
    _GAMES = [
        ("Elden Ring",             "1245620", 412_000, 3_600),
        ("Cyberpunk 2077",         "1091500", 190_000, 86_400),
        ("The Witcher 3",          "292030",  530_000, 250_000),
        ("Red Dead Redemption 2",  "1174180",  88_000, 600_000),
        ("Baldur's Gate 3",        "1086940", 305_000, 5_400),
        ("Hades",                  "1145360",  42_000, 900_000),
        ("Hollow Knight",          "367520",   18_000, None),
        ("Stardew Valley",         "413150",   96_000, 12_000),
        ("DOOM Eternal",           "782330",   31_000, None),
        ("Disco Elysium",          "632470",   27_000, 300_000),
    ]

    def scan(self) -> List[Title]:
        now = time.time()
        out = []
        for name, appid, playtime, ago in self._GAMES:
            out.append(Title(
                uid=f"steam:{appid}",
                name=name,
                provider="steam",
                launch=["true"],
                accent=accent_for(name),
                last_played=None if ago is None else now - ago,
                playtime_s=playtime,
                art=steam_art(appid),
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
