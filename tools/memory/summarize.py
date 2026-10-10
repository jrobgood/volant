#!/usr/bin/env python3
"""Summarize completed opt-in profiles; no machine-dependent CI thresholds."""
import csv
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
scenarios = [name for name in ("idle", "emoji", "clipboard", "image-decode", "notes", "notes-small", "acp")
             if (root / f"{name}-1.csv").exists()]
assert scenarios, "No profile output"
print("| Workload | Phase | Footprint MiB | Live heap MiB | Sampled peak MiB | Time ms |")
print("| --- | --- | ---: | ---: | ---: | ---: |")
for scenario in scenarios:
    runs = []
    for repetition in range(1, 4):
        with (root / f"{scenario}-{repetition}.csv").open() as stream:
            rows = list(csv.DictReader(stream))
        assert rows and rows[-1]["phase"] == "after_relief", "Incomplete profile"
        assert all(row["scenario"] == scenario for row in rows)
        for row in rows:
            assert int(row["sampled_peak_bytes"]) >= int(row["footprint_bytes"])
        runs.append({row["phase"]: row for row in rows})
    assert all(run.keys() == runs[0].keys() for run in runs)
    for phase in runs[0]:
        def median(field, divisor=1):
            return statistics.median(float(run[phase][field]) / divisor for run in runs)
        print(f"| {scenario} | {phase} | {median('footprint_bytes', 1048576):.2f} | "
              f"{median('heap_in_use_bytes', 1048576):.2f} | "
              f"{median('sampled_peak_bytes', 1048576):.2f} | {median('elapsed_ms'):.2f} |")
