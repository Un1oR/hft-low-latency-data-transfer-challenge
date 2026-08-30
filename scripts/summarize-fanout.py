#!/usr/bin/env python3

"""Validate and summarize one AWS fan-out run without external packages."""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import re
from array import array
from pathlib import Path
from typing import Iterable


PERCENTILES = (0.50, 0.99, 0.999, 0.9999)


def percentile_summary(values: Iterable[int]) -> dict[str, int]:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("cannot summarize an empty latency series")

    result = {"min_ns": ordered[0], "max_ns": ordered[-1]}
    for percentile in PERCENTILES:
        rank = max(0, math.ceil(percentile * len(ordered)) - 1)
        label = {
            0.50: "p50_ns",
            0.99: "p99_ns",
            0.999: "p99_9_ns",
            0.9999: "p99_99_ns",
        }[percentile]
        result[label] = ordered[rank]
    return result


def load_csv(path: Path) -> tuple[array, array, dict[str, int]]:
    sequences = array("Q")
    latencies = array("q")
    gaps = 0
    duplicates = 0
    reordered = 0
    previous: int | None = None

    with path.open(newline="", encoding="utf-8") as source:
        rows = csv.reader(source)
        if next(rows, None) != ["seq", "latency_ns"]:
            raise ValueError(f"unexpected CSV header in {path}")
        for row_number, row in enumerate(rows, start=2):
            if len(row) != 2:
                raise ValueError(f"malformed row {row_number} in {path}")
            sequence = int(row[0])
            latency = int(row[1])
            if sequence < 0 or latency < 0:
                raise ValueError(f"negative value at row {row_number} in {path}")
            if previous is not None:
                if sequence == previous:
                    duplicates += 1
                elif sequence < previous:
                    reordered += 1
                elif sequence > previous + 1:
                    gaps += sequence - previous - 1
            previous = sequence
            sequences.append(sequence)
            latencies.append(latency)

    sequence_stats = {
        "received": len(sequences),
        "first_seq": sequences[0] if sequences else 0,
        "last_seq": sequences[-1] if sequences else 0,
        "gaps": gaps,
        "duplicates": duplicates,
        "reordered": reordered,
    }
    return sequences, latencies, sequence_stats


def receiver_artifact_dir(
    run_dir: Path, receiver_count: int, instance_id: str
) -> Path:
    if receiver_count == 1:
        return run_dir / "spectral-unicast"
    return (
        run_dir
        / "receivers"
        / instance_id
        / "spectral-unicast"
    )


def load_stage_csv(
    path: Path,
) -> tuple[array, dict[str, array], dict[str, array]]:
    legacy_intervals = [
        "e2e_latency_ns",
        "source_to_transport_ns",
        "transport_to_receiver_ns",
        "transport_to_hardware_receiver_ns",
        "hardware_to_software_receiver_ns",
        "receiver_to_consumer_ns",
    ]
    split_intervals = [
        "hardware_to_dpdk_burst_ns",
        "dpdk_burst_to_software_receiver_ns",
    ]
    receiver_raw = ["receiver_software_realtime_ns"]
    burst_raw = ["dpdk_rx_burst_return_realtime_ns"]
    legacy_header = ["seq"] + legacy_intervals
    interpolated_header = legacy_header + receiver_raw
    split_header = (
        ["seq"]
        + legacy_intervals[:-1]
        + split_intervals
        + legacy_intervals[-1:]
        + receiver_raw
        + burst_raw
    )
    sequences = array("Q")
    with path.open(newline="", encoding="utf-8") as source:
        rows = csv.reader(source)
        header = next(rows, None)
        if header == legacy_header:
            interval_names = legacy_intervals
            raw_names: list[str] = []
        elif header == interpolated_header:
            interval_names = legacy_intervals
            raw_names = receiver_raw
        elif header == split_header:
            interval_names = (
                legacy_intervals[:-1]
                + split_intervals
                + legacy_intervals[-1:]
            )
            raw_names = receiver_raw + burst_raw
        else:
            raise ValueError(f"unexpected stage CSV header in {path}")
        series = {name: array("q") for name in interval_names}
        raw_series = {
            name: array("Q")
            for name in receiver_raw + burst_raw
        }
        for row_number, row in enumerate(rows, start=2):
            if len(row) != len(header):
                raise ValueError(f"malformed row {row_number} in {path}")
            sequence = int(row[0])
            if sequence < 0:
                raise ValueError(
                    f"negative sequence at row {row_number} in {path}"
                )
            sequences.append(sequence)
            interval_end = 1 + len(interval_names)
            for name, value in zip(
                interval_names, row[1:interval_end], strict=True
            ):
                series[name].append(int(value))
            for name, value in zip(
                raw_names, row[interval_end:], strict=True
            ):
                parsed = int(value)
                if parsed < 0:
                    raise ValueError(
                        f"negative raw timestamp at row {row_number} in {path}"
                    )
                raw_series[name].append(parsed)
    return sequences, series, raw_series


def load_phc_calibration(path: Path) -> dict[str, object] | None:
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    before = re.search(
        r"receiver: PHC calibration before method=(\S+) "
        r"realtime_minus_phc_ns=(-?\d+) "
        r"(?:realtime_midpoint_ns=(\d+) )?uncertainty_ns=(\d+) "
        r"bracket_ns=(\d+) samples=(\d+)",
        text,
    )
    after = re.search(
        r"receiver: PHC calibration after method=(\S+) "
        r"realtime_minus_phc_ns=(-?\d+) "
        r"(?:realtime_midpoint_ns=(\d+) )?uncertainty_ns=(\d+) "
        r"bracket_ns=(\d+) samples=(\d+) drift_ns=(-?\d+) "
        r"run_uncertainty_ns=(\d+)",
        text,
    )
    if before is None or after is None:
        return None
    periodic = [
        {
            "index": int(match.group(1)),
            "method": match.group(2),
            "realtime_minus_phc_ns": int(match.group(3)),
            "realtime_midpoint_ns": int(match.group(4)),
            "uncertainty_ns": int(match.group(5)),
            "bracket_ns": int(match.group(6)),
            "samples": int(match.group(7)),
        }
        for match in re.finditer(
            r"receiver: PHC calibration periodic index=(\d+) method=(\S+) "
            r"realtime_minus_phc_ns=(-?\d+) "
            r"realtime_midpoint_ns=(\d+) uncertainty_ns=(\d+) "
            r"bracket_ns=(\d+) samples=(\d+)",
            text,
        )
    ]
    periodic_status = re.search(
        r"receiver: PHC periodic calibration samples=(\d+) failures=(\d+) "
        r"period_ms=(\d+)",
        text,
    )
    return {
        "before": {
            "method": before.group(1),
            "realtime_minus_phc_ns": int(before.group(2)),
            "realtime_midpoint_ns": (
                int(before.group(3)) if before.group(3) else None
            ),
            "uncertainty_ns": int(before.group(4)),
            "bracket_ns": int(before.group(5)),
            "samples": int(before.group(6)),
        },
        "after": {
            "method": after.group(1),
            "realtime_minus_phc_ns": int(after.group(2)),
            "realtime_midpoint_ns": (
                int(after.group(3)) if after.group(3) else None
            ),
            "uncertainty_ns": int(after.group(4)),
            "bracket_ns": int(after.group(5)),
            "samples": int(after.group(6)),
            "drift_ns": int(after.group(7)),
            "run_uncertainty_ns": int(after.group(8)),
        },
        "periodic": periodic,
        "periodic_status": (
            {
                "samples": int(periodic_status.group(1)),
                "failures": int(periodic_status.group(2)),
                "period_ms": int(periodic_status.group(3)),
            }
            if periodic_status is not None
            else None
        ),
    }


def rounded_fraction(numerator: int, denominator: int) -> int:
    magnitude = (abs(numerator) + denominator // 2) // denominator
    return -magnitude if numerator < 0 else magnitude


def interpolate_phc_intervals(
    stage_series: dict[str, array],
    raw_series: dict[str, array],
    calibration: dict[str, object],
) -> dict[str, object] | None:
    receiver_times = raw_series["receiver_software_realtime_ns"]
    if not receiver_times:
        return None
    before = calibration["before"]
    after = calibration["after"]
    points = [before, *calibration.get("periodic", []), after]
    points = sorted(
        (point for point in points if point["realtime_midpoint_ns"] is not None),
        key=lambda point: int(point["realtime_midpoint_ns"]),
    )
    if len(points) < 2:
        return None

    point_times = [int(point["realtime_midpoint_ns"]) for point in points]
    if any(
        right <= left
        for left, right in zip(point_times, point_times[1:])
    ):
        return None
    point_offsets = [int(point["realtime_minus_phc_ns"]) for point in points]
    start_time = point_times[0]
    end_time = point_times[-1]

    start_offset = int(before["realtime_minus_phc_ns"])
    drift = point_offsets[-1] - start_offset
    duration = end_time - start_time
    clamped_before = 0
    clamped_after = 0
    hardware_to_software = stage_series[
        "hardware_to_software_receiver_ns"
    ]
    transport_to_hardware = stage_series[
        "transport_to_hardware_receiver_ns"
    ]
    hardware_to_burst = stage_series.get("hardware_to_dpdk_burst_ns")
    for index, receiver_time in enumerate(receiver_times):
        if receiver_time <= start_time:
            offset = point_offsets[0]
            clamped_before += 1
        elif receiver_time >= end_time:
            offset = point_offsets[-1]
            clamped_after += 1
        else:
            right_index = bisect.bisect_right(point_times, receiver_time)
            left_index = right_index - 1
            segment_duration = (
                point_times[right_index] - point_times[left_index]
            )
            segment_elapsed = receiver_time - point_times[left_index]
            segment_drift = (
                point_offsets[right_index] - point_offsets[left_index]
            )
            offset = point_offsets[left_index] + rounded_fraction(
                segment_drift * segment_elapsed, segment_duration
            )
        offset_delta = offset - start_offset
        # The receiver stored hardware timestamps using the initial offset.
        # Move that timestamp by the interpolated offset delta and adjust the
        # two adjacent intervals in opposite directions; their sum stays equal
        # to the unchanged transport_to_receiver interval.
        hardware_to_software[index] -= offset_delta
        transport_to_hardware[index] += offset_delta
        if hardware_to_burst is not None:
            hardware_to_burst[index] -= offset_delta

    return {
        "method": "piecewise-linear-between-calibration-midpoints",
        "start_realtime_ns": start_time,
        "end_realtime_ns": end_time,
        "duration_ns": duration,
        "offset_drift_ns": drift,
        "offset_min_ns": min(point_offsets),
        "offset_max_ns": max(point_offsets),
        "calibration_points": len(points),
        "periodic_points": max(0, len(points) - 2),
        "max_calibration_gap_ns": max(
            right - left
            for left, right in zip(point_times, point_times[1:])
        ),
        "max_calibration_uncertainty_ns": max(
            int(point["uncertainty_ns"]) for point in points
        ),
        "max_adjacent_offset_change_ns": max(
            abs(right - left)
            for left, right in zip(point_offsets, point_offsets[1:])
        ),
        "samples_clamped_before": clamped_before,
        "samples_clamped_after": clamped_after,
    }


def summarize_dpdk_rx_bursts(
    stage_series: dict[str, array], raw_series: dict[str, array]
) -> dict[str, object] | None:
    burst_returns = raw_series["dpdk_rx_burst_return_realtime_ns"]
    receiver_times = raw_series["receiver_software_realtime_ns"]
    if not burst_returns or not receiver_times:
        return None

    hardware_to_burst = stage_series["hardware_to_dpdk_burst_ns"]
    burst_to_software = stage_series[
        "dpdk_burst_to_software_receiver_ns"
    ]
    size_histogram: dict[int, int] = {}
    hardware_to_burst_by_position: dict[int, array] = {}
    burst_to_software_by_position: dict[int, array] = {}
    burst_count = 0
    current_burst: int | None = None
    current_receiver: int | None = None
    current_position = -1
    current_datagram_count = 0

    for index, (burst_return, receiver_time) in enumerate(
        zip(burst_returns, receiver_times, strict=True)
    ):
        if burst_return != current_burst:
            if current_burst is not None:
                size_histogram[current_datagram_count] = (
                    size_histogram.get(current_datagram_count, 0) + 1
                )
            current_burst = burst_return
            current_receiver = None
            current_position = -1
            current_datagram_count = 0
            burst_count += 1
        if receiver_time != current_receiver:
            current_receiver = receiver_time
            current_position += 1
            current_datagram_count += 1
            # Every frame from one wire datagram carries the same receiver
            # timestamps. Count that datagram once so denser wire batches do
            # not receive extra statistical weight here.
            hardware_to_burst_by_position.setdefault(
                current_position, array("q")
            ).append(hardware_to_burst[index])
            burst_to_software_by_position.setdefault(
                current_position, array("q")
            ).append(burst_to_software[index])
    if current_burst is not None:
        size_histogram[current_datagram_count] = (
            size_histogram.get(current_datagram_count, 0) + 1
        )

    return {
        "burst_count": burst_count,
        "burst_size_datagrams_histogram": {
            str(size): count
            for size, count in sorted(size_histogram.items())
        },
        "hardware_to_burst_by_datagram_position": {
            str(position): {
                "samples": len(values),
                **percentile_summary(values),
            }
            for position, values in sorted(
                hardware_to_burst_by_position.items()
            )
        },
        "burst_to_software_by_datagram_position": {
            str(position): {
                "samples": len(values),
                **percentile_summary(values),
            }
            for position, values in sorted(
                burst_to_software_by_position.items()
            )
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()

    manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
    receiver_count = int(manifest["receiver_count"])
    message_count = int(manifest["message_count"])
    warmup_events = int(manifest.get("warmup_events", 0))
    instance_ids = manifest["runner_instance_ids"][1 : receiver_count + 1]
    private_ips = manifest["runner_private_ips"][1 : receiver_count + 1]

    reference_sequences: array | None = None
    sequence_series: list[array] = []
    raw_series: list[array] = []
    corrected_series: list[array] = []
    receiver_summaries: list[dict[str, object]] = []
    delivery_valid = True

    for index, (instance_id, private_ip) in enumerate(
        zip(instance_ids, private_ips, strict=True), start=1
    ):
        label = f"receiver-{index}"
        artifact_dir = receiver_artifact_dir(
            run_dir, receiver_count, instance_id
        )
        csv_path = artifact_dir / "latency.csv"
        sequences, raw_latencies, sequence_stats = load_csv(csv_path)
        bracket = json.loads(
            (run_dir / f"clock-bracket-{label}.json").read_text(encoding="utf-8")
        )
        legacy_probe_bracket = (
            bracket.get("method") == "udp_bidirectional_probe"
            and "probe_method" not in bracket
        )
        primary_correction_ns = 0 if legacy_probe_bracket else int(
            bracket.get("correction_ns", 0)
        )
        probe_correction_ns = int(
            bracket.get("probe_correction_ns", bracket.get("correction_ns", 0))
        )
        clock_uncertainty_ns = (
            None
            if legacy_probe_bracket
            else int(bracket["uncertainty_ns"])
        )
        probe_method = bracket.get("probe_method")
        if legacy_probe_bracket:
            probe_method = bracket["method"]
        probe_uncertainty_ns = bracket.get("probe_uncertainty_ns")
        if legacy_probe_bracket:
            probe_uncertainty_ns = bracket["uncertainty_ns"]
        # The UDP probe uses the control ENI and kernel sockets, including for
        # DPDK runs. Keep that correction as a diagnostic series only: applying
        # its path asymmetry to the DPDK data path would manufacture precision.
        corrected = array(
            "q", (value - probe_correction_ns for value in raw_latencies)
        )
        primary = array(
            "q", (value - primary_correction_ns for value in raw_latencies)
        )

        sequence_matches = (
            reference_sequences is None or sequences == reference_sequences
        )
        if reference_sequences is None:
            reference_sequences = sequences
        sequence_series.append(sequences)
        receiver_valid = (
            sequence_stats["received"] == message_count
            and sequence_stats["first_seq"] == warmup_events + 1
            and sequence_stats["last_seq"] == warmup_events + message_count
            and sequence_stats["gaps"] == 0
            and sequence_stats["duplicates"] == 0
            and sequence_stats["reordered"] == 0
            and sequence_matches
        )
        delivery_valid = delivery_valid and receiver_valid
        raw_series.append(raw_latencies)
        corrected_series.append(corrected)
        receiver_summary: dict[str, object] = {
            "label": label,
            "instance_id": instance_id,
            "private_ip": private_ip,
            **sequence_stats,
            "sequence_matches_receiver_1": sequence_matches,
            "delivery_valid": receiver_valid,
            "clock_correction_ns": primary_correction_ns,
            "clock_method": "aws_ena_phc",
            "clock_uncertainty_ns": clock_uncertainty_ns,
            "clock_probe_correction_ns": probe_correction_ns,
            "clock_probe_method": probe_method,
            "clock_probe_uncertainty_ns": probe_uncertainty_ns,
            "clock_status": bracket["status"],
            "latency_raw": percentile_summary(raw_latencies),
            "latency_primary": percentile_summary(primary),
            "latency_corrected": percentile_summary(corrected),
        }
        if manifest.get("stage_timestamps", False):
            stage_sequences, stage_series, stage_raw_series = load_stage_csv(
                artifact_dir / "stage-latency.csv"
            )
            stage_matches_latency = stage_sequences == sequences
            calibration = None
            interpolation = None
            dpdk_rx_bursts = None
            if manifest.get("dpdk_rx_hardware_timestamps", False):
                calibration = load_phc_calibration(
                    artifact_dir / "receiver.log"
                )
                if calibration is not None:
                    interpolation = interpolate_phc_intervals(
                        stage_series, stage_raw_series, calibration
                    )
                if "hardware_to_dpdk_burst_ns" in stage_series:
                    dpdk_rx_bursts = summarize_dpdk_rx_bursts(
                        stage_series, stage_raw_series
                    )
            stage_summary: dict[str, object] = {
                "samples": len(stage_sequences),
                "sequence_matches_latency": stage_matches_latency,
                "intervals": {
                    name: percentile_summary(values)
                    for name, values in stage_series.items()
                },
                "negative_samples": {
                    name: sum(value < 0 for value in values)
                    for name, values in stage_series.items()
                },
            }
            if manifest.get("dpdk_rx_hardware_timestamps", False):
                stage_summary["phc_calibration"] = calibration
                stage_summary["phc_calibration_valid"] = calibration is not None
                stage_summary["phc_interpolation"] = interpolation
                stage_summary["phc_interpolation_applied"] = (
                    interpolation is not None
                )
                stage_summary["dpdk_rx_bursts"] = dpdk_rx_bursts
            receiver_summary["stage"] = stage_summary
        receiver_summaries.append(receiver_summary)

    if reference_sequences is None:
        raise ValueError("run has no receivers")

    worst_receiver_latency_primary = array("q")
    worst_receiver_latency_corrected = array("q")
    delivery_skew_primary = array("q")
    delivery_skew_corrected = array("q")

    def append_aligned_sample(sample_indexes: list[int]) -> None:
        raw_sample = [
            series[sample_index]
            for series, sample_index in zip(
                raw_series, sample_indexes, strict=True
            )
        ]
        corrected_sample = [
            series[sample_index]
            for series, sample_index in zip(
                corrected_series, sample_indexes, strict=True
            )
        ]
        worst_receiver_latency_primary.append(max(raw_sample))
        worst_receiver_latency_corrected.append(max(corrected_sample))
        delivery_skew_primary.append(max(raw_sample) - min(raw_sample))
        delivery_skew_corrected.append(
            max(corrected_sample) - min(corrected_sample)
        )

    sequences_identical = all(
        sequences == reference_sequences for sequences in sequence_series
    )
    sequences_monotonic_unique = all(
        int(receiver["duplicates"]) == 0
        and int(receiver["reordered"]) == 0
        for receiver in receiver_summaries
    )
    if sequences_identical:
        for sample_index in range(len(reference_sequences)):
            append_aligned_sample([sample_index] * receiver_count)
    elif sequences_monotonic_unique:
        # Lossy diagnostic runs have different sequence ranges. Align only
        # sequence IDs present on every receiver; never compare equal indexes,
        # because one missing datagram would shift the rest of the series.
        indexes = [0] * receiver_count
        while all(
            sample_index < len(sequences)
            for sample_index, sequences in zip(
                indexes, sequence_series, strict=True
            )
        ):
            current = [
                sequences[sample_index]
                for sequences, sample_index in zip(
                    sequence_series, indexes, strict=True
                )
            ]
            target = max(current)
            if all(sequence == target for sequence in current):
                append_aligned_sample(indexes)
                indexes = [sample_index + 1 for sample_index in indexes]
                continue
            indexes = [
                (
                    bisect.bisect_left(sequences, target, sample_index)
                    if sequence < target
                    else sample_index
                )
                for sequences, sample_index, sequence in zip(
                    sequence_series, indexes, current, strict=True
                )
            ]

    aligned_samples = len(worst_receiver_latency_primary)
    alignment_available = aligned_samples > 0

    summary = {
        "run_id": manifest["run_id"],
        "receiver_count": receiver_count,
        "message_count": message_count,
        "message_rate": manifest["message_rate"],
        "delivery_valid": delivery_valid,
        "fanout_alignment_available": alignment_available,
        "common_sequence_samples": aligned_samples,
        "receivers": receiver_summaries,
        "worst_receiver_latency_corrected": (
            percentile_summary(worst_receiver_latency_corrected)
            if alignment_available
            else None
        ),
        "worst_receiver_latency_primary": (
            percentile_summary(worst_receiver_latency_primary)
            if alignment_available
            else None
        ),
        "inter_receiver_delivery_skew": (
            percentile_summary(delivery_skew_primary)
            if alignment_available
            else None
        ),
        "inter_receiver_delivery_skew_corrected": (
            percentile_summary(delivery_skew_corrected)
            if alignment_available
            else None
        ),
    }
    summary_path = run_dir / "fanout-summary.json"
    summary_path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"Fan-out summary saved to {summary_path}")
    return 0 if delivery_valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
