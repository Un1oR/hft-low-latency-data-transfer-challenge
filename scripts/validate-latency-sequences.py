#!/usr/bin/env python3
"""Validate delivery invariants in harness latency CSV files."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


def validate(path: Path, drop: int, expected_samples: int | None) -> dict:
    rows_total = 0
    rows_analyzed = 0
    first_seq: int | None = None
    last_seq: int | None = None
    previous_seq: int | None = None
    gaps = 0
    duplicates = 0
    reordered = 0
    seen: set[int] = set()

    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames is None or "seq" not in reader.fieldnames:
            raise ValueError(f"{path}: expected a CSV column named seq")
        for row in reader:
            rows_total += 1
            if rows_total <= drop:
                continue
            sequence = int(row["seq"])
            rows_analyzed += 1
            if first_seq is None:
                first_seq = sequence
            if sequence in seen:
                duplicates += 1
            seen.add(sequence)
            if previous_seq is not None:
                if sequence < previous_seq:
                    reordered += 1
                elif sequence > previous_seq + 1:
                    gaps += sequence - previous_seq - 1
            previous_seq = sequence
            last_seq = sequence

    sample_count_valid = expected_samples is None or rows_analyzed == expected_samples
    valid = (
        rows_analyzed > 0
        and sample_count_valid
        and gaps == 0
        and duplicates == 0
        and reordered == 0
    )
    return {
        "path": path.as_posix(),
        "rows_total": rows_total,
        "dropped_prefix": min(drop, rows_total),
        "rows_analyzed": rows_analyzed,
        "expected_samples": expected_samples,
        "sample_count_valid": sample_count_valid,
        "first_seq": first_seq,
        "last_seq": last_seq,
        "gaps": gaps,
        "duplicates": duplicates,
        "reordered": reordered,
        "valid": valid,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--drop", type=int, default=0)
    parser.add_argument("--expected-samples", type=int)
    args = parser.parse_args()
    if args.drop < 0:
        parser.error("--drop must be non-negative")
    if args.expected_samples is not None and args.expected_samples <= 0:
        parser.error("--expected-samples must be positive")

    files = [
        validate(path, args.drop, args.expected_samples)
        for path in sorted(args.paths)
    ]
    result = {
        "valid": bool(files) and all(item["valid"] for item in files),
        "files": files,
        "totals": {
            "files": len(files),
            "rows_analyzed": sum(item["rows_analyzed"] for item in files),
            "gaps": sum(item["gaps"] for item in files),
            "duplicates": sum(item["duplicates"] for item in files),
            "reordered": sum(item["reordered"] for item in files),
        },
    }
    print(json.dumps(result, indent=2))
    if not result["valid"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
