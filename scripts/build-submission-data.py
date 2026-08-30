#!/usr/bin/env python3
"""Build compact, reviewable data used by the submission notebook.

The raw AWS artifacts are intentionally not committed: one run contains millions
of per-event rows.  This script reduces the selected immutable runs to dense
empirical quantile curves, run-level summaries and a provenance JSON document.
The generated files are sufficient to execute ``analysis.ipynb`` from a clean
checkout.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from datetime import datetime
from math import comb
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd


def rate_slug(rate: int) -> str:
    if rate == 200_000:
        return "200k"
    if rate % 1_000_000 == 0:
        return f"{rate // 1_000_000}m"
    return str(rate)


def comparison_group(receivers: int, rate: int) -> str:
    return f"comparison-n{receivers}-{rate_slug(rate)}"


def discover_suite(artifacts: Path, explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit.resolve()
    candidates = sorted(artifacts.glob("submission-suite-*/suite.json"))
    if not candidates:
        raise FileNotFoundError(
            "не найдена suite.json; передайте --suite artifacts/aws-runner/"
            "submission-suite-.../suite.json"
        )
    return candidates[-1].resolve()


def suite_runs(
    suite_path: Path,
    epoch_profile: str,
) -> tuple[
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
    set[str],
    str,
    dict[str, Any],
    dict[str, Any],
]:
    """Resolve all report inputs from one immutable suite manifest."""
    repo_root = Path(__file__).resolve().parents[1]
    suite = read_json(suite_path)
    package_source_dirty = ".dirty." in Path(suite["spectral_package"]).name
    matrix_path = Path(suite["comparison_matrix"])
    if not matrix_path.is_absolute():
        matrix_path = repo_root / matrix_path
    matrix = read_json(matrix_path)

    expected_ids = suite["runner_instance_ids"]
    if matrix["runner_instance_ids"] != expected_ids:
        raise ValueError("suite и comparison matrix относятся к разным instance IDs")
    placement = suite.get("placement")
    if placement != matrix.get("placement"):
        raise ValueError("suite и comparison matrix относятся к разным placement group")
    if epoch_profile == "cluster":
        if not isinstance(placement, dict) or placement.get("strategy") != "cluster":
            raise ValueError("cluster-профиль должен быть снят в cluster placement group")
        for key in (
            "group_name",
            "group_id",
            "precision_time_parent_name",
            "precision_time_parent_id",
        ):
            if not placement.get(key):
                raise ValueError(f"в suite не зафиксирован placement.{key}")
    elif epoch_profile == "precision-time-only":
        if (
            suite.get("suite_id") != "submission-suite-20260829T161712Z"
            or matrix.get("comparison_id") != "comparison-20260829T161715Z"
        ):
            raise ValueError(
                "precision-time-only профиль закреплён за проверенной "
                "исторической suite/matrix"
            )
        if placement is not None:
            raise ValueError(
                "исторический precision-time-only профиль ожидает suite до "
                "добавления явного placement metadata"
            )
        placement = {
            "strategy": "precision-time",
            "group_name": "spectral-runner-precision-time",
            "group_id": None,
            "precision_time_parent_name": None,
            "precision_time_parent_id": None,
            "provenance": (
                "recovered from accepted DPDK manifests and common instance IDs; "
                "historical Claude manifests do not duplicate placement metadata"
            ),
        }
        suite["placement"] = placement
        matrix["placement"] = placement
    else:
        raise ValueError(f"неизвестный профиль эпохи: {epoch_profile}")
    if matrix["methodology"].get("design") != "counterbalanced paired blocks":
        raise ValueError("comparison matrix не использует контрсбалансированные блоки")
    blocks_per_rate = int(matrix["methodology"]["blocks_per_rate"])
    by_configuration_and_block: dict[tuple[int, int, int], list[dict[str, Any]]] = {}
    for run in matrix["runs"]:
        receivers = int(run.get("receivers", matrix["methodology"].get("receiver_count", 3)))
        by_configuration_and_block.setdefault(
            (receivers, int(run["rate_events_s"]), int(run["block"])), []
        ).append(run)
    for (receivers, rate, block), arms in by_configuration_and_block.items():
        arms = sorted(arms, key=lambda run: int(run["arm_position"]))
        expected_order = (
            ["claude-c86cc26", "spectral-task"]
            if block % 2 == 1
            else ["spectral-task", "claude-c86cc26"]
        )
        if [run["implementation"] for run in arms] != expected_order:
            raise ValueError(
                f"нарушен контрсбалансированный порядок: N={receivers}, "
                f"rate={rate}, block={block}"
            )
    configurations = {
        (receivers, rate)
        for receivers, rate, _ in by_configuration_and_block
    }
    receiver_counts = matrix["methodology"].get("receiver_counts")
    if not receiver_counts:
        receiver_counts = [matrix["methodology"]["receiver_count"]]
    expected_configurations = {
        (int(receivers), rate)
        for receivers in receiver_counts
        for rate in (200_000, 2_000_000)
    }
    if configurations != expected_configurations:
        raise ValueError(
            "comparison matrix должна содержать 200k и 2M для каждого "
            f"заявленного N: {sorted(configurations)}"
        )
    for receivers, rate in configurations:
        present_blocks = {
            block
            for candidate_receivers, candidate_rate, block
            in by_configuration_and_block
            if candidate_receivers == receivers and candidate_rate == rate
        }
        if present_blocks != set(range(1, blocks_per_rate + 1)):
            raise ValueError(
                f"неполный набор блоков N={receivers}, rate={rate}: "
                f"{sorted(present_blocks)}"
            )

    dpdk_runs: dict[str, dict[str, Any]] = {}
    claude_runs: dict[str, dict[str, Any]] = {}
    for run in matrix["runs"]:
        rate = int(run["rate_events_s"])
        receivers = int(run.get("receivers", matrix["methodology"].get("receiver_count", 3)))
        block = int(run["block"])
        metadata = {
            "groups": comparison_group(receivers, rate),
            "label_ru": (
                f"Claude c86cc26, N={receivers}, блок {block}"
                if run["implementation"] == "claude-c86cc26"
                else f"Наш DPDK, N={receivers}, блок {block}"
            ),
            "receivers": receivers,
            "pair_round": block,
            "block": block,
            "arm_position": int(run["arm_position"]),
            "comparison_order": int(run["order"]),
            "started_at_utc": run["started_at_utc"],
            "finished_at_utc": run["finished_at_utc"],
            # This column identifies the EC2 epoch, not only the subset used by
            # an N=1 arm.  The exact participating prefix remains in manifest.
            "runner_instance_ids": expected_ids,
        }
        if run["implementation"] == "spectral-task":
            metadata["package_source_dirty"] = package_source_dirty
        target = (
            claude_runs
            if run["implementation"] == "claude-c86cc26"
            else dpdk_runs
        )
        if run["run_id"] in target:
            raise ValueError(f"повторный run_id в comparison matrix: {run['run_id']}")
        target[run["run_id"]] = metadata

    stage_ids: list[str] = []
    for run in suite["dpdk_runs"]:
        metadata = {
            "groups": run["group"],
            "label_ru": run["label_ru"],
            "case_id": run["case_id"],
            "expected_saturation": bool(run.get("expected_saturation", False)),
            "package_source_dirty": package_source_dirty,
        }
        dpdk_runs[run["run_id"]] = metadata
        if run["group"] == "stage-breakdown":
            stage_ids.append(run["run_id"])
    if len(stage_ids) != 1:
        raise ValueError(f"suite должна содержать один stage run, найдено {stage_ids}")

    distribution_runs = set(claude_runs) | {
        run_id
        for run_id, metadata in dpdk_runs.items()
        if metadata["groups"].startswith("comparison-")
    }
    return (
        dpdk_runs,
        claude_runs,
        distribution_runs,
        stage_ids[0],
        suite,
        matrix,
    )
STAGE_INTERVALS = {
    "source_to_transport_ns": (
        "Producer → transport",
        "локально на source",
        "очередь producer и вход sender в сетевой backend",
    ),
    "transport_to_receiver_ns": (
        "Transport → receiver",
        "между хостами, с остаточным clock offset",
        "сборка/TX, ENA, Nitro/VPC, физическая сеть, ENA RX и возврат DPDK burst",
    ),
    "dpdk_burst_to_software_receiver_ns": (
        "Возврат DPDK burst → публикация receiver",
        "локально на receiver",
        "проверка пакета, wire decode и запись в SPSC",
    ),
    "receiver_to_consumer_ns": (
        "Receiver → consumer",
        "локально на receiver",
        "очередь receiver и наблюдение consumer",
    ),
}

TAIL_EXCESS_THRESHOLD_NS = 50_000
SEQUENCE_BIN_EVENTS = 1_000
DENSITY_BINS = 320
DENSITY_WINDOW_QUANTILES = (0.01, 0.99)


def read_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def stage_rows(run_dir: Path) -> list[dict[str, Any]]:
    summary = read_json(run_dir / "fanout-summary.json")
    rows: list[dict[str, Any]] = []
    for receiver in summary["receivers"]:
        interpolation = receiver["stage"]["phc_interpolation"]
        for key, (label, scope, meaning) in STAGE_INTERVALS.items():
            interval = receiver["stage"]["intervals"][key]
            rows.append(
                {
                    "run_id": run_dir.name,
                    "receiver": receiver["label"],
                    "receiver_instance_id": receiver["instance_id"],
                    "stage_key": key,
                    "stage_ru": label,
                    "scope_ru": scope,
                    "meaning_ru": meaning,
                    "hardware_rx_conversion_valid": False,
                    "hardware_rx_invalid_reason": (
                        "RX timestamp принадлежит PHC data ENI, а доступная "
                        "калибровка — PHC control ENI; ENA PMD 25.11 не "
                        "предоставляет read_clock для data ENI"
                    ),
                    "min_us": interval["min_ns"] / 1000,
                    "p50_us": interval["p50_ns"] / 1000,
                    "p99_us": interval["p99_ns"] / 1000,
                    "p999_us": interval["p99_9_ns"] / 1000,
                    "phc_calibration_max_uncertainty_us": (
                        interpolation["max_calibration_uncertainty_ns"] / 1000
                    ),
                }
            )
    return rows


def latency_values(path: Path) -> np.ndarray:
    values = pd.read_csv(path, usecols=["latency_ns"])["latency_ns"].to_numpy()
    if values.size == 0:
        raise ValueError(f"empty latency sample: {path}")
    return values


def latency_frame(path: Path, drop: int = 0) -> pd.DataFrame:
    frame = pd.read_csv(path, usecols=["seq", "latency_ns"])
    if drop:
        frame = frame.iloc[drop:]
    if frame.empty:
        raise ValueError(f"empty latency sample after drop={drop}: {path}")
    return frame.reset_index(drop=True)


def aligned_fanout(
    frames: list[pd.DataFrame], context: str
) -> dict[str, np.ndarray]:
    """Return raw and receiver-centered per-event fan-out measurements.

    Claude receivers can start recording a few events apart.  We permit trimming
    only those collection edges, require every individual range to be contiguous,
    and then require exact sequence equality on the common interval.  Internal
    loss therefore cannot disappear behind an inner join.
    """
    if not frames:
        raise ValueError(f"no receiver samples: {context}")
    for frame in frames:
        seq = frame["seq"].to_numpy()
        if seq.size > 1 and not np.all(np.diff(seq) == 1):
            raise ValueError(f"non-contiguous receiver sequence range: {context}")
    common_start = max(int(frame["seq"].iloc[0]) for frame in frames)
    common_end = min(int(frame["seq"].iloc[-1]) for frame in frames)
    if common_start > common_end:
        raise ValueError(f"receiver sequence ranges do not overlap: {context}")
    aligned = [
        frame[(frame["seq"] >= common_start) & (frame["seq"] <= common_end)]
        for frame in frames
    ]
    reference_seq = aligned[0]["seq"].to_numpy()
    for frame in aligned[1:]:
        if not np.array_equal(reference_seq, frame["seq"].to_numpy()):
            raise ValueError(f"receiver sequence ranges differ internally: {context}")
    latencies = np.stack(
        [frame["latency_ns"].to_numpy() for frame in aligned], axis=0
    )
    centered = latencies - np.median(latencies, axis=1, keepdims=True)
    return {
        "delivered-to-all": np.max(latencies, axis=0),
        # Equal receiver weight: the distribution of delivery time to a
        # uniformly selected destination.  This preserves the original
        # receiver observations instead of reducing every event to an
        # arbitrary two-of-three order statistic.
        "balanced-receiver": latencies.reshape(-1),
        # Per-event arithmetic mean answers a separate question: the average
        # cost of one delivery within this fan-out operation.
        "mean-receiver": np.mean(latencies, axis=0),
        "receiver-spread": np.ptp(latencies, axis=0),
        "delivered-to-all-centered": np.max(centered, axis=0),
        "receiver-spread-centered": np.ptp(centered, axis=0),
    }


def dpdk_latency_paths(run_dir: Path) -> list[tuple[str, Path]]:
    """Return receiver identity and latency CSV for both runner layouts.

    Historical and current N=1 runs use the flat spectral-unicast directory;
    fan-out runs use one directory per receiver instance.
    """
    nested = sorted(run_dir.glob("receivers/*/spectral-unicast/latency.csv"))
    flat = run_dir / "spectral-unicast" / "latency.csv"
    if nested:
        if flat.exists():
            raise ValueError(f"mixed DPDK artifact layouts: {run_dir}")
        return [(path.parents[1].name, path) for path in nested]
    if flat.exists():
        manifest = read_json(run_dir / "manifest.json")
        receiver_ids = manifest["runner_instance_ids"][1:2]
        if len(receiver_ids) != 1:
            raise ValueError(f"N=1 run has no receiver identity: {run_dir}")
        return [(receiver_ids[0], flat)]
    return []


def dense_quantiles() -> np.ndarray:
    body = np.linspace(0.01, 0.99, 240, endpoint=True)
    lower_tail = np.geomspace(1e-5, 1e-2, 240)
    upper_tail = 1.0 - lower_tail
    anchors = np.array([
        0.0, 1e-5, 1e-4, 1e-3, 0.01, 0.1, 0.25, 0.5,
        0.75, 0.9, 0.99, 0.999, 0.9999, 0.99999,
    ])
    return np.unique(np.concatenate([lower_tail, body, upper_tail, anchors]))


def dpdk_fanout_series(run_dir: Path) -> dict[str, np.ndarray]:
    receiver_paths = dpdk_latency_paths(run_dir)
    paths = [path for _, path in receiver_paths]
    frames = [latency_frame(path) for path in paths]
    reductions = aligned_fanout(frames, run_dir.name)
    series = {
        f"receiver:{receiver_id}": frame["latency_ns"].to_numpy()
        for (receiver_id, _), frame in zip(receiver_paths, frames, strict=True)
    }
    series.update(reductions)
    return series


def claude_fanout_series(run_dir: Path) -> dict[str, np.ndarray]:
    manifest = read_json(run_dir / "manifest.json")
    drop = int(manifest.get("dropped_prefix_per_rep", 0))
    receiver_dirs = sorted((run_dir / "receivers").glob("*"))
    if not receiver_dirs:
        raise FileNotFoundError(f"no Claude receiver CSV under {run_dir}")

    per_receiver: list[list[np.ndarray]] = [[] for _ in receiver_dirs]
    reduced_repetitions: dict[str, list[np.ndarray]] = {}
    repetition_names = sorted(path.name for path in receiver_dirs[0].glob("rep*_c0.csv"))
    for repetition_name in repetition_names:
        frames = [
            latency_frame(receiver_dir / repetition_name, drop)
            for receiver_dir in receiver_dirs
        ]
        for receiver_values, frame in zip(per_receiver, frames, strict=True):
            receiver_values.append(frame["latency_ns"].to_numpy())
        reductions = aligned_fanout(frames, f"{run_dir.name}/{repetition_name}")
        for metric, values in reductions.items():
            reduced_repetitions.setdefault(metric, []).append(values)

    if not reduced_repetitions:
        raise FileNotFoundError(f"no Claude repetitions under {run_dir}")
    series = {
        f"receiver:{receiver_dir.name}": np.concatenate(repetitions)
        for receiver_dir, repetitions in zip(
            receiver_dirs, per_receiver, strict=True
        )
    }
    series.update({
        metric: np.concatenate(repetitions)
        for metric, repetitions in reduced_repetitions.items()
    })
    return series


def comparison_receiver_frames(
    run_dir: Path, implementation: str
) -> list[tuple[str, int, pd.DataFrame]]:
    if implementation == "spectral-task":
        return [
            (receiver_id, 1, latency_frame(path))
            for receiver_id, path in dpdk_latency_paths(run_dir)
        ]

    manifest = read_json(run_dir / "manifest.json")
    drop = int(manifest.get("dropped_prefix_per_rep", 0))
    result = []
    for receiver_dir in sorted((run_dir / "receivers").glob("*")):
        for path in sorted(receiver_dir.glob("rep*_c0.csv")):
            match = re.search(r"rep([0-9]+)_", path.name)
            repetition = int(match.group(1)) if match else 1
            result.append(
                (receiver_dir.name, repetition, latency_frame(path, drop))
            )
    return result


def tail_diagnostics(
    run_dir: Path, implementation: str, metadata: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    bins: list[dict[str, Any]] = []
    bursts: list[dict[str, Any]] = []
    for receiver_id, repetition, frame in comparison_receiver_frames(
        run_dir, implementation
    ):
        latency = frame["latency_ns"].to_numpy()
        median = float(np.median(latency))
        excess = latency - median
        above = excess > TAIL_EXCESS_THRESHOLD_NS
        indexes = np.flatnonzero(above)
        if indexes.size:
            breaks = np.flatnonzero(np.diff(indexes) > 1) + 1
            episodes = np.split(indexes, breaks)
            episode_count = len(episodes)
            longest_episode = max(len(episode) for episode in episodes)
        else:
            episode_count = 0
            longest_episode = 0
        bursts.append(
            {
                "group": metadata["groups"],
                "run_id": run_dir.name,
                "implementation": implementation,
                "pair_round": metadata.get("pair_round"),
                "receiver_instance_id": receiver_id,
                "repetition": repetition,
                "threshold_over_p50_us": TAIL_EXCESS_THRESHOLD_NS / 1000,
                "events_above_threshold": int(indexes.size),
                "episode_count": episode_count,
                "longest_episode_events": longest_episode,
                "max_excess_us": float(np.max(excess)) / 1000,
            }
        )
        for start in range(0, len(frame), SEQUENCE_BIN_EVENTS):
            stop = min(start + SEQUENCE_BIN_EVENTS, len(frame))
            chunk = excess[start:stop]
            bins.append(
                {
                    "group": metadata["groups"],
                    "run_id": run_dir.name,
                    "implementation": implementation,
                    "pair_round": metadata.get("pair_round"),
                    "receiver_instance_id": receiver_id,
                    "repetition": repetition,
                    "seq_start": int(frame["seq"].iloc[start]),
                    "seq_end": int(frame["seq"].iloc[stop - 1]),
                    "p99_excess_us": float(np.quantile(chunk, 0.99)) / 1000,
                    "max_excess_us": float(np.max(chunk)) / 1000,
                }
            )
    return bins, bursts


def density_rows(
    inputs: dict[tuple[str, int], list[dict[str, Any]]]
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    gaussian_x = np.arange(-8, 9, dtype=float)
    gaussian_kernel = np.exp(-0.5 * (gaussian_x / 2.0) ** 2)
    gaussian_kernel /= gaussian_kernel.sum()
    for (group, pair_round), entries in sorted(inputs.items()):
        if len(entries) != 2:
            raise ValueError(
                f"density comparison needs exactly two adjacent runs: "
                f"{group}/{pair_round}, got {len(entries)}"
            )
        all_values = np.concatenate([entry["values_us"] for entry in entries])
        low_us, high_us = np.quantile(all_values, DENSITY_WINDOW_QUANTILES)
        if not high_us > low_us:
            raise ValueError(f"empty density range: {group}/{pair_round}")
        edges = np.linspace(low_us, high_us, DENSITY_BINS + 1)
        centers = (edges[:-1] + edges[1:]) / 2
        bin_width_us = edges[1] - edges[0]
        for entry in entries:
            counts, _ = np.histogram(entry["values_us"], bins=edges)
            density = counts / (counts.sum() * bin_width_us)
            smoothed = np.convolve(density, gaussian_kernel, mode="same")
            for latency_us, density_per_us in zip(
                centers, smoothed, strict=True
            ):
                rows.append(
                    {
                        "group": group,
                        "pair_round": pair_round,
                        "block": pair_round,
                        "run_id": entry["run_id"],
                        "implementation": entry["implementation"],
                        "label_ru": entry["label_ru"],
                        "latency_us": latency_us,
                        "density_per_us": density_per_us,
                        "window_low_us": low_us,
                        "window_high_us": high_us,
                        "window_low_quantile": DENSITY_WINDOW_QUANTILES[0],
                        "window_high_quantile": DENSITY_WINDOW_QUANTILES[1],
                    }
                )
    return rows


def frames_per_datagram(run_dir: Path) -> float | None:
    paths = list(run_dir.glob("receivers/*/spectral-unicast/receiver.log"))
    paths.extend(run_dir.glob("spectral-unicast/receiver.log"))
    for path in sorted(paths):
        match = re.search(r"frames_per_datagram=([0-9.]+)", path.read_text(encoding="utf-8"))
        if match:
            return float(match.group(1))
    return None


def dpdk_counter(run_dir: Path, key: str) -> int:
    """Read the largest reported ENA counter value from the run artifacts."""
    pattern = re.compile(rf"dpdk_{re.escape(key)}=([0-9]+)")
    values: list[int] = []
    for path in run_dir.rglob("*"):
        if not path.is_file() or path.name not in {"stdout", "sender.log", "receiver.log"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        values.extend(int(match) for match in pattern.findall(text))
    return max(values, default=0)


def dpdk_summary_row(run_dir: Path, metadata: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = read_json(run_dir / "manifest.json")
    summary = read_json(run_dir / "fanout-summary.json")
    if any(
        int(receiver["clock_correction_ns"]) != 0
        or receiver.get("clock_status") != "valid"
        for receiver in summary["receivers"]
    ):
        raise ValueError(f"невалидная шкала времени: {run_dir.name}")
    latency = summary["worst_receiver_latency_primary"]
    average_batch = frames_per_datagram(run_dir)
    rate = int(manifest["message_rate"])
    receivers = int(manifest["receiver_count"])
    estimated_pps = rate * receivers / average_batch if average_batch else None
    row = {
        "group": metadata["groups"],
        "run_id": manifest["run_id"],
        "implementation": "spectral-task",
        "label_ru": metadata["label_ru"],
        "case_id": metadata.get("case_id"),
        "expected_saturation": bool(metadata.get("expected_saturation", False)),
        "pair_round": metadata.get("pair_round"),
        "block": metadata.get("block"),
        "arm_position": metadata.get("arm_position"),
        "comparison_order": metadata.get("comparison_order"),
        "rate_events_s": rate,
        "receivers": receivers,
        "message_count": int(manifest["message_count"]),
        "batch_target_frames": manifest.get("batch_target_frames"),
        "batch_wait_ns": manifest.get("batch_wait_ns"),
        "frames_per_datagram": average_batch,
        "estimated_packets_s": estimated_pps,
        "p50_us": latency["p50_ns"] / 1000,
        "p99_us": latency["p99_ns"] / 1000,
        "p999_us": latency["p99_9_ns"] / 1000,
        "p9999_us": latency["p99_99_ns"] / 1000,
        "delivery_valid": bool(summary["delivery_valid"]),
        "gaps": sum(int(receiver["gaps"]) for receiver in summary["receivers"]),
        "duplicates": sum(int(receiver["duplicates"]) for receiver in summary["receivers"]),
        "reordered": sum(int(receiver["reordered"]) for receiver in summary["receivers"]),
        "pps_exceeded": dpdk_counter(run_dir, "pps_exceeded"),
        "bw_out_exceeded": dpdk_counter(run_dir, "bw_out_exceeded"),
        "clock_method": manifest["clock_method"],
        "max_clock_uncertainty_us": max(
            float(receiver["clock_uncertainty_ns"]) for receiver in summary["receivers"]
        ) / 1000,
        "package_sha256": manifest["package_sha256"],
        "source_commit": manifest["commit"],
        # The run manifest records the state of the orchestration checkout at
        # launch time.  The measured executable comes from the immutable .deb;
        # its `.dirty` version marker is the relevant source-cleanliness flag.
        "source_dirty": bool(metadata["package_source_dirty"]),
        "runner_dirty": bool(manifest["dirty"]),
        "runner_instance_ids": ";".join(manifest["runner_instance_ids"]),
    }
    return row, {"manifest": manifest, "summary": summary}


def claude_summary_row(run_dir: Path, metadata: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = read_json(run_dir / "manifest.json")
    summary = read_json(run_dir / "summary.json")
    receiver_summaries = summary.get("receivers", [summary])
    if any(
        int(receiver["clock_correction_ns"]) != 0
        or receiver.get("clock_method") != "aws_ena_phc"
        for receiver in receiver_summaries
    ):
        raise ValueError(f"невалидная шкала времени Claude: {run_dir.name}")
    latency = (
        summary["worst_receiver_primary_ns"]
        if "worst_receiver_primary_ns" in summary
        else summary["primary_ns"]
    )
    delivery = summary.get("delivery_validation", {})
    delivery_totals = delivery.get("totals", {})
    row = {
        "group": metadata["groups"],
        "run_id": manifest["run_id"],
        "implementation": "claude-c86cc26",
        "label_ru": metadata["label_ru"],
        "case_id": metadata.get("case_id"),
        "expected_saturation": False,
        "pair_round": metadata.get("pair_round"),
        "block": metadata.get("block"),
        "arm_position": metadata.get("arm_position"),
        "comparison_order": metadata.get("comparison_order"),
        "rate_events_s": int(manifest["rate"]),
        "receivers": int(manifest["receivers"]),
        "message_count": int(
            manifest.get(
                "measured_samples_per_rep",
                receiver_summaries[0]["raw"]["samples_per_run"],
            )
        ),
        "batch_target_frames": None,
        "batch_wait_ns": None,
        "frames_per_datagram": None,
        "estimated_packets_s": None,
        "p50_us": latency["p50"] / 1000,
        "p99_us": latency["p99"] / 1000,
        "p999_us": latency["p99_9"] / 1000,
        "p9999_us": latency["p99_99"] / 1000,
        "delivery_valid": bool(summary.get("delivery_valid", True)),
        "gaps": delivery_totals.get("gaps"),
        "duplicates": delivery_totals.get("duplicates"),
        "reordered": delivery_totals.get("reordered"),
        "pps_exceeded": None,
        "bw_out_exceeded": None,
        "clock_method": manifest["clock_method"],
        "max_clock_uncertainty_us": max(
            float(receiver["clock_uncertainty_ns"]) for receiver in receiver_summaries
        ) / 1000,
        "package_sha256": manifest["package_sha256"],
        "source_commit": manifest["baseline_commit"],
        "source_dirty": False,
        "runner_dirty": bool(manifest["runner_dirty"]),
        "runner_instance_ids": ";".join(metadata["runner_instance_ids"]),
    }
    return row, {"manifest": manifest, "summary": summary}


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise ValueError(f"no rows for {path}")
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=list(rows[0]), lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)


COMPARISON_QUANTILES = {
    "p50": 0.5,
    "p99": 0.99,
    "p99.9": 0.999,
    "p99.99": 0.9999,
}


def parse_utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def exact_sign_test(differences: list[float]) -> tuple[float, int]:
    positive = sum(value > 0 for value in differences)
    negative = sum(value < 0 for value in differences)
    n = positive + negative
    if n == 0:
        return 1.0, 0
    tail = sum(comb(n, index) for index in range(min(positive, negative) + 1))
    return min(1.0, 2 * tail / (2**n)), n


def comparison_block_rows(
    values: dict[tuple[str, int, str], np.ndarray],
    matrix: dict[str, Any],
) -> list[dict[str, Any]]:
    timing: dict[tuple[str, int], list[dict[str, Any]]] = {}
    for run in matrix["runs"]:
        receivers = int(run.get("receivers", matrix["methodology"].get("receiver_count", 3)))
        group = comparison_group(receivers, int(run["rate_events_s"]))
        timing.setdefault((group, int(run["block"])), []).append(run)

    rows: list[dict[str, Any]] = []
    groups_and_blocks = sorted({(group, block) for group, block, _ in values})
    for group, block in groups_and_blocks:
        claude = values.get((group, block, "claude-c86cc26"))
        spectral = values.get((group, block, "spectral-task"))
        if claude is None or spectral is None:
            raise ValueError(f"неполная пара сравнения: {group}, блок {block}")
        arm_runs = sorted(
            timing.get((group, block), []), key=lambda run: int(run["arm_position"])
        )
        if len(arm_runs) != 2:
            raise ValueError(f"не найдены времена двух плеч: {group}, блок {block}")
        first, second = arm_runs
        first_start = parse_utc(first["started_at_utc"])
        first_finish = parse_utc(first["finished_at_utc"])
        second_start = parse_utc(second["started_at_utc"])
        second_finish = parse_utc(second["finished_at_utc"])
        first_midpoint = first_start + (first_finish - first_start) / 2
        second_midpoint = second_start + (second_finish - second_start) / 2
        rate = int(first["rate_events_s"])
        receivers = int(first.get("receivers", matrix["methodology"].get("receiver_count", 3)))
        claude_quantiles = {
            metric: float(np.quantile(claude, quantile)) / 1000
            for metric, quantile in COMPARISON_QUANTILES.items()
        }
        spectral_quantiles = {
            metric: float(np.quantile(spectral, quantile)) / 1000
            for metric, quantile in COMPARISON_QUANTILES.items()
        }
        metric_values: dict[str, tuple[float | None, float, float]] = {
            metric: (quantile, claude_quantiles[metric], spectral_quantiles[metric])
            for metric, quantile in COMPARISON_QUANTILES.items()
        }
        for metric in ("p99", "p99.9", "p99.99"):
            metric_values[f"{metric}-p50"] = (
                None,
                claude_quantiles[metric] - claude_quantiles["p50"],
                spectral_quantiles[metric] - spectral_quantiles["p50"],
            )
        for metric, (quantile, claude_us, spectral_us) in metric_values.items():
            rows.append(
                {
                    "group": group,
                    "receivers": receivers,
                    "rate_events_s": rate,
                    "block": block,
                    "first_implementation": first["implementation"],
                    "claude_arm_position": next(
                        int(run["arm_position"])
                        for run in arm_runs
                        if run["implementation"] == "claude-c86cc26"
                    ),
                    "spectral_arm_position": next(
                        int(run["arm_position"])
                        for run in arm_runs
                        if run["implementation"] == "spectral-task"
                    ),
                    "midpoint_gap_s": abs(
                        (second_midpoint - first_midpoint).total_seconds()
                    ),
                    "idle_gap_s": max(
                        0.0, (second_start - first_finish).total_seconds()
                    ),
                    "metric": metric,
                    "quantile": quantile,
                    "claude_samples_aligned": len(claude),
                    "spectral_samples_aligned": len(spectral),
                    "claude_us": claude_us,
                    "spectral_us": spectral_us,
                    "difference_spectral_minus_claude_us": spectral_us - claude_us,
                }
            )
    return rows


def comparison_statistic_rows(
    block_rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    keys = sorted({(row["group"], row["metric"]) for row in block_rows})
    for group, metric in keys:
        rows = [
            row
            for row in block_rows
            if row["group"] == group and row["metric"] == metric
        ]
        differences = [
            float(row["difference_spectral_minus_claude_us"]) for row in rows
        ]
        claude_values = [float(row["claude_us"]) for row in rows]
        median_difference = float(statistics.median(differences))
        reference_spread = max(claude_values) - min(claude_values)
        sign_p, sign_n = exact_sign_test(differences)
        resolved = sign_p <= 0.05 and abs(median_difference) > reference_spread
        result.append(
            {
                "group": group,
                "receivers": rows[0]["receivers"],
                "rate_events_s": rows[0]["rate_events_s"],
                "metric": metric,
                "blocks": len(rows),
                "min_aligned_samples_per_arm": min(
                    min(
                        int(row["claude_samples_aligned"]),
                        int(row["spectral_samples_aligned"]),
                    )
                    for row in rows
                ),
                "spectral_faster_blocks": sum(value < 0 for value in differences),
                "claude_faster_blocks": sum(value > 0 for value in differences),
                "ties": sum(value == 0 for value in differences),
                "median_difference_spectral_minus_claude_us": median_difference,
                "min_difference_us": min(differences),
                "max_difference_us": max(differences),
                "sign_test_n": sign_n,
                "sign_test_two_sided_p": sign_p,
                "claude_between_block_spread_us": reference_spread,
                "resolved_by_claude_rule": resolved,
                "direction_ru": (
                    "наш DPDK быстрее"
                    if median_difference < 0
                    else "Claude быстрее"
                    if median_difference > 0
                    else "ничья"
                ),
                "median_midpoint_gap_s": float(
                    statistics.median(float(row["midpoint_gap_s"]) for row in rows)
                ),
                "max_midpoint_gap_s": max(float(row["midpoint_gap_s"]) for row in rows),
            }
        )
    return result


def pooled_quantile_rows(
    pooled: dict[tuple[str, str], list[np.ndarray]], quantiles: np.ndarray
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    rows: list[dict[str, Any]] = []
    density_inputs: dict[tuple[str, int], list[dict[str, Any]]] = {}
    for (group, implementation), chunks in sorted(pooled.items()):
        values = np.concatenate(chunks)
        curve = np.quantile(values, quantiles)
        p50 = float(np.quantile(values, 0.5))
        label = "Наш DPDK, все блоки" if implementation == "spectral-task" else "Claude c86cc26, все блоки"
        density_inputs.setdefault((group, 0), []).append(
            {
                "run_id": f"{group}-{implementation}-pooled",
                "implementation": implementation,
                "label_ru": label,
                "values_us": values / 1000,
            }
        )
        for quantile, latency_ns in zip(quantiles, curve, strict=True):
            rows.append(
                {
                    "group": group,
                    "implementation": implementation,
                    "label_ru": label,
                    "blocks_pooled": len(chunks),
                    "samples_pooled": len(values),
                    "quantile": quantile,
                    "tail_probability": 1.0 - quantile,
                    "latency_us": latency_ns / 1000,
                    "latency_minus_p50_us": (latency_ns - p50) / 1000,
                }
            )
    return rows, density_rows(density_inputs)


def pooled_fanout_quantile_rows(
    pooled: dict[tuple[str, str, str], list[np.ndarray]],
    quantiles: np.ndarray,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for (group, implementation, metric), chunks in sorted(pooled.items()):
        values = np.concatenate(chunks)
        curve = np.quantile(values, quantiles)
        p50 = float(np.quantile(values, 0.5))
        label = (
            "Наш DPDK, все блоки"
            if implementation == "spectral-task"
            else "Claude c86cc26, все блоки"
        )
        for quantile, latency_ns in zip(quantiles, curve, strict=True):
            rows.append(
                {
                    "group": group,
                    "implementation": implementation,
                    "label_ru": label,
                    "metric": metric,
                    "blocks_pooled": len(chunks),
                    "samples_pooled": len(values),
                    "quantile": quantile,
                    "tail_probability": 1.0 - quantile,
                    "latency_us": latency_ns / 1000,
                    "latency_minus_p50_us": (latency_ns - p50) / 1000,
                }
            )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path, default=Path("artifacts/aws-runner"))
    parser.add_argument("--output", type=Path, default=Path("data/submission"))
    parser.add_argument(
        "--suite",
        type=Path,
        help="suite.json единой измерительной эпохи; по умолчанию берётся последняя",
    )
    parser.add_argument(
        "--epoch-profile",
        choices=("cluster", "precision-time-only"),
        default="cluster",
        help=(
            "ожидаемая топология эпохи; precision-time-only предназначен только "
            "для зафиксированной исторической suite до появления cluster"
        ),
    )
    args = parser.parse_args()

    suite_path = discover_suite(args.artifacts, args.suite)
    (
        dpdk_runs,
        claude_runs,
        distribution_run_ids,
        stage_run_id,
        suite,
        comparison_matrix,
    ) = suite_runs(suite_path, args.epoch_profile)

    args.output.mkdir(parents=True, exist_ok=True)
    quantiles = dense_quantiles()
    summary_rows: list[dict[str, Any]] = []
    distribution_rows: list[dict[str, Any]] = []
    fanout_distribution_rows: list[dict[str, Any]] = []
    sequence_bin_rows: list[dict[str, Any]] = []
    tail_burst_rows: list[dict[str, Any]] = []
    density_inputs: dict[tuple[str, int], list[dict[str, Any]]] = {}
    comparison_values: dict[tuple[str, int, str], np.ndarray] = {}
    pooled_values: dict[tuple[str, str], list[np.ndarray]] = {}
    pooled_fanout_values: dict[
        tuple[str, str, str], list[np.ndarray]
    ] = {}
    provenance: dict[str, Any] = {
        "schema_version": 4,
        "epoch_profile": args.epoch_profile,
        "suite": suite,
        "comparison_matrix": comparison_matrix,
        "latency_metric": "receive_ts_ns - send_ts_ns",
        "clock_correction_ns": 0,
        "clock_method": "aws_ena_phc",
        "distribution_reduction": {
            "dpdk": "align receivers by seq, take maximum latency per event, then take percentiles",
            "claude": "drop the declared prefix, trim only unequal collection edges, align receivers by seq, take maximum latency per event, pool repetitions, then take percentiles",
            "quantile_method": "numpy linear",
            "fanout": "align receivers by seq; take max latency per event for delivery-to-all, pool receiver observations with equal receiver weight for a uniformly selected destination, take the per-event arithmetic mean for average delivery cost, and max-minus-min for receiver spread",
            "receiver_normalization": "for shape-only views subtract each run receiver's own median before reducing across receivers; never use centered values as absolute end-to-end latency",
        },
        "runs": {},
    }

    for run_id, metadata in dpdk_runs.items():
        run_dir = args.artifacts / run_id
        row, source = dpdk_summary_row(run_dir, metadata)
        summary_rows.append(row)
        provenance["runs"][run_id] = source
        if run_id in distribution_run_ids:
            fanout_series = dpdk_fanout_series(run_dir)
            comparison_values[
                (metadata["groups"], int(metadata["block"]), "spectral-task")
            ] = fanout_series["delivered-to-all"]
            pooled_values.setdefault(
                (metadata["groups"], "spectral-task"), []
            ).append(fanout_series["delivered-to-all"])
            pooled_metrics = {
                "delivered-to-all",
                "balanced-receiver",
                "mean-receiver",
                "delivered-to-all-centered",
            } | {
                metric for metric in fanout_series if metric.startswith("receiver:")
            }
            for metric in pooled_metrics:
                values = fanout_series[metric]
                pooled_fanout_values.setdefault(
                    (metadata["groups"], "spectral-task", metric), []
                ).append(values)
            density_inputs.setdefault(
                (metadata["groups"], int(metadata["pair_round"])), []
            ).append(
                {
                    "run_id": run_id,
                    "implementation": "spectral-task",
                    "label_ru": metadata["label_ru"],
                    "values_us": fanout_series["delivered-to-all"] / 1000,
                }
            )
            curve = np.quantile(fanout_series["delivered-to-all"], quantiles)
            p50 = float(np.interp(0.5, quantiles, curve))
            for quantile, latency_ns in zip(quantiles, curve, strict=True):
                distribution_rows.append(
                    {
                        "group": metadata["groups"],
                        "run_id": run_id,
                        "implementation": "spectral-task",
                        "label_ru": metadata["label_ru"],
                        "pair_round": metadata.get("pair_round"),
                        "block": metadata.get("block"),
                        "arm_position": metadata.get("arm_position"),
                        "quantile": quantile,
                        "tail_probability": 1.0 - quantile,
                        "latency_us": latency_ns / 1000,
                        "latency_minus_p50_us": (latency_ns - p50) / 1000,
                    }
                )
            for metric, values in fanout_series.items():
                metric_curve = np.quantile(values, quantiles)
                metric_p50 = float(np.quantile(values, 0.5))
                for quantile, latency_ns in zip(quantiles, metric_curve, strict=True):
                    fanout_distribution_rows.append(
                        {
                            "group": metadata["groups"],
                            "run_id": run_id,
                            "implementation": "spectral-task",
                            "label_ru": metadata["label_ru"],
                            "pair_round": metadata.get("pair_round"),
                            "block": metadata.get("block"),
                            "arm_position": metadata.get("arm_position"),
                            "metric": metric,
                            "quantile": quantile,
                            "tail_probability": 1.0 - quantile,
                            "latency_us": latency_ns / 1000,
                            "latency_minus_p50_us": (latency_ns - metric_p50) / 1000,
                        }
                    )
            bins, bursts = tail_diagnostics(run_dir, "spectral-task", metadata)
            sequence_bin_rows.extend(bins)
            tail_burst_rows.extend(bursts)

    for run_id, metadata in claude_runs.items():
        run_dir = args.artifacts / run_id
        row, source = claude_summary_row(run_dir, metadata)
        summary_rows.append(row)
        provenance["runs"][run_id] = source
        fanout_series = claude_fanout_series(run_dir)
        comparison_values[
            (metadata["groups"], int(metadata["block"]), "claude-c86cc26")
        ] = fanout_series["delivered-to-all"]
        pooled_values.setdefault(
            (metadata["groups"], "claude-c86cc26"), []
        ).append(fanout_series["delivered-to-all"])
        pooled_metrics = {
            "delivered-to-all",
            "balanced-receiver",
            "mean-receiver",
            "delivered-to-all-centered",
        } | {
            metric for metric in fanout_series if metric.startswith("receiver:")
        }
        for metric in pooled_metrics:
            values = fanout_series[metric]
            pooled_fanout_values.setdefault(
                (metadata["groups"], "claude-c86cc26", metric), []
            ).append(values)
        density_inputs.setdefault(
            (metadata["groups"], int(metadata["pair_round"])), []
        ).append(
            {
                "run_id": run_id,
                "implementation": "claude-c86cc26",
                "label_ru": metadata["label_ru"],
                "values_us": fanout_series["delivered-to-all"] / 1000,
            }
        )
        curve = np.quantile(fanout_series["delivered-to-all"], quantiles)
        p50 = float(np.interp(0.5, quantiles, curve))
        for quantile, latency_ns in zip(quantiles, curve, strict=True):
            distribution_rows.append(
                {
                    "group": metadata["groups"],
                    "run_id": run_id,
                    "implementation": "claude-c86cc26",
                    "label_ru": metadata["label_ru"],
                    "pair_round": metadata.get("pair_round"),
                    "block": metadata.get("block"),
                    "arm_position": metadata.get("arm_position"),
                    "quantile": quantile,
                    "tail_probability": 1.0 - quantile,
                    "latency_us": latency_ns / 1000,
                    "latency_minus_p50_us": (latency_ns - p50) / 1000,
                }
            )
        for metric, values in fanout_series.items():
            metric_curve = np.quantile(values, quantiles)
            metric_p50 = float(np.quantile(values, 0.5))
            for quantile, latency_ns in zip(quantiles, metric_curve, strict=True):
                fanout_distribution_rows.append(
                    {
                        "group": metadata["groups"],
                        "run_id": run_id,
                        "implementation": "claude-c86cc26",
                        "label_ru": metadata["label_ru"],
                        "pair_round": metadata.get("pair_round"),
                        "block": metadata.get("block"),
                        "arm_position": metadata.get("arm_position"),
                        "metric": metric,
                        "quantile": quantile,
                        "tail_probability": 1.0 - quantile,
                        "latency_us": latency_ns / 1000,
                        "latency_minus_p50_us": (latency_ns - metric_p50) / 1000,
                    }
                )
        bins, bursts = tail_diagnostics(run_dir, "claude-c86cc26", metadata)
        sequence_bin_rows.extend(bins)
        tail_burst_rows.extend(bursts)

    expected_ids = ";".join(suite["runner_instance_ids"])
    if any(row["runner_instance_ids"] != expected_ids for row in summary_rows):
        raise ValueError("в suite обнаружены запуски другой EC2-эпохи")
    placement = suite["placement"]
    expected_manifest_placement = {
        "placement_group": placement["group_name"],
        "placement_group_id": placement["group_id"],
        "placement_strategy": placement["strategy"],
        "precision_time_placement_group": placement["precision_time_parent_name"],
        "precision_time_placement_group_id": placement["precision_time_parent_id"],
    }
    for run_id, source in provenance["runs"].items():
        manifest = source["manifest"]
        if args.epoch_profile == "cluster":
            actual = {
                key: manifest.get(key) for key in expected_manifest_placement
            }
            if actual != expected_manifest_placement:
                raise ValueError(
                    f"запуск {run_id} снят вне зафиксированной вложенной "
                    "precision-time → cluster topology"
                )
        elif "runner_instance_ids" in manifest:
            if manifest.get("placement_group") != placement["group_name"]:
                raise ValueError(
                    f"DPDK-запуск {run_id} снят вне precision-time placement group"
                )
        if "source_instance_id" in manifest:
            participants = [
                manifest["source_instance_id"],
                *manifest["receiver_instance_ids"],
            ]
            expected_participants = suite["runner_instance_ids"][
                : int(manifest["receivers"]) + 1
            ]
        else:
            participants = manifest["runner_instance_ids"]
            expected_participants = suite["runner_instance_ids"]
        if participants != expected_participants:
            raise ValueError(
                f"запуск {run_id} использует неожиданный набор EC2: {participants}"
            )
    unexpected_invalid = [
        row["run_id"]
        for row in summary_rows
        if not row["delivery_valid"] and not row["expected_saturation"]
    ]
    if unexpected_invalid:
        raise ValueError(
            f"в suite обнаружены неожиданные невалидные запуски: {unexpected_invalid}"
        )
    saturation_rows = [
        row for row in summary_rows if row["expected_saturation"]
    ]
    saturation_ids = {row["case_id"] for row in saturation_rows}
    expected_saturation_ids = (
        {"rate-4m-forced-3", "rate-5m-auto"}
        if args.epoch_profile == "cluster"
        else {"rate-4m-forced-3"}
    )
    if saturation_ids != expected_saturation_ids or any(
        row["delivery_valid"] for row in saturation_rows
    ):
        raise ValueError(
            "suite содержит неожиданный набор контрольных точек насыщения: "
            f"{sorted(saturation_ids)}"
        )
    if any(
        not row["expected_saturation"]
        and (
            int(row["gaps"] or 0) != 0
            or int(row["duplicates"] or 0) != 0
            or int(row["reordered"] or 0) != 0
        )
        for row in summary_rows
    ):
        raise ValueError("в suite обнаружены дырки, дубли или перестановки событий")
    if any(
        row["implementation"] == "spectral-task"
        and row["package_sha256"] != suite["spectral_package_sha256"]
        for row in summary_rows
    ):
        raise ValueError("в suite смешаны разные spectral-task package SHA")
    if any(
        row["implementation"] == "claude-c86cc26"
        and row["package_sha256"] != suite["claude_package_sha256"]
        for row in summary_rows
    ):
        raise ValueError("в suite смешаны разные Claude package SHA")
    if any(bool(row["source_dirty"]) for row in summary_rows):
        raise ValueError("финальная suite содержит dirty source manifest")

    summary_rows.sort(key=lambda row: (row["group"], row["rate_events_s"], row["run_id"]))
    distribution_rows.sort(key=lambda row: (row["group"], row["run_id"], row["quantile"]))
    fanout_distribution_rows.sort(
        key=lambda row: (row["group"], row["run_id"], row["metric"], row["quantile"])
    )
    write_csv(args.output / "run-summary.csv", summary_rows)
    write_csv(args.output / "distribution-quantiles.csv", distribution_rows)
    write_csv(
        args.output / "fanout-distribution-quantiles.csv",
        fanout_distribution_rows,
    )
    write_csv(args.output / "latency-over-sequence.csv", sequence_bin_rows)
    write_csv(args.output / "tail-bursts.csv", tail_burst_rows)
    write_csv(args.output / "latency-density.csv", density_rows(density_inputs))

    block_rows = comparison_block_rows(comparison_values, comparison_matrix)
    statistic_rows = comparison_statistic_rows(block_rows)
    pooled_quantiles, pooled_density = pooled_quantile_rows(
        pooled_values, quantiles
    )
    pooled_fanout_quantiles = pooled_fanout_quantile_rows(
        pooled_fanout_values, quantiles
    )
    write_csv(args.output / "comparison-blocks.csv", block_rows)
    write_csv(args.output / "comparison-statistics.csv", statistic_rows)
    write_csv(
        args.output / "comparison-pooled-quantiles.csv", pooled_quantiles
    )
    write_csv(
        args.output / "comparison-pooled-fanout-quantiles.csv",
        pooled_fanout_quantiles,
    )
    write_csv(args.output / "comparison-pooled-density.csv", pooled_density)
    provenance["comparison_statistics"] = statistic_rows

    diagnostic_dir = args.artifacts / stage_run_id
    write_csv(args.output / "stage-breakdown.csv", stage_rows(diagnostic_dir))
    provenance["stage_run"] = {
        "run_id": stage_run_id,
        "manifest": read_json(diagnostic_dir / "manifest.json"),
        "summary": read_json(diagnostic_dir / "fanout-summary.json"),
    }

    with (args.output / "provenance.json").open("w", encoding="utf-8") as stream:
        json.dump(provenance, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")

    print(
        f"written {len(summary_rows)} run rows and "
        f"{len(distribution_rows)} delivery-to-all rows and "
        f"{len(fanout_distribution_rows)} aligned fan-out rows and "
        f"{len(block_rows)} paired block rows to {args.output}"
    )


if __name__ == "__main__":
    main()
