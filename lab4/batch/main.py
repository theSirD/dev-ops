"""Stand-in for nightly analytics: burns CPU and holds MEMORY_MB of RAM."""

from __future__ import annotations

import atexit
import os
import subprocess
import sys
import threading
import time

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

MEMORY_MB = max(1, int(os.getenv("MEMORY_MB", "64")))
CPU_WORK = max(1, int(os.getenv("CPU_WORK", "100000")))
# percent of each 100 ms the burner is busy; keeps the real burn small
CPU_DUTY = min(100, max(1, int(os.getenv("CPU_DUTY", "100"))))

_chunks: list[bytearray] = []
_resident_mb = 0


def _grow_memory() -> None:
    global _resident_mb
    remaining = MEMORY_MB
    while remaining > 0:
        piece = min(64, remaining)
        block = bytearray(piece * 1024 * 1024)
        # touch every page so the cgroup charges it
        for offset in range(0, len(block), 4096):
            block[offset] = 1
        _chunks.append(block)
        remaining -= piece
        _resident_mb += piece
        time.sleep(0.1)


_BURN = (
    "import time\n"
    "x = 0\n"
    "while True:\n"
    f"    end = time.perf_counter() + {CPU_DUTY} / 1000\n"
    "    while time.perf_counter() < end:\n"
    f"        for i in range({CPU_WORK}):\n"
    "            x ^= i * i\n"
    f"    time.sleep({(100 - CPU_DUTY) / 1000})\n"
)
_burners: list[subprocess.Popen] = []


def _start_burners() -> None:
    _burners.append(subprocess.Popen([sys.executable, "-c", _BURN]))


@atexit.register
def _stop_burners() -> None:
    for proc in _burners:
        proc.kill()


threading.Thread(target=_grow_memory, name="mem-grow", daemon=True).start()
_start_burners()

app = FastAPI(title="shop-batch")


@app.get("/health")
def health() -> PlainTextResponse:
    return PlainTextResponse(f"ok resident_mb={_resident_mb} duty={CPU_DUTY}%")
