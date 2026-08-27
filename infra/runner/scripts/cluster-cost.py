#!/usr/bin/env python3
"""Оценка времени и AWS-стоимости последнего штатного E2E-сценария."""

from __future__ import annotations

import csv
import json
import subprocess
from decimal import Decimal
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
RUNNER_DIR = SCRIPT_DIR.parent
REPO_ROOT = RUNNER_DIR.parent.parent
ARTIFACT_ROOT = REPO_ROOT / "artifacts" / "aws-runner"
LOCATION = "US East (N. Virginia)"
HOURS_PER_MONTH = Decimal("730")
SECONDS_PER_HOUR = Decimal("3600")


def run(*args: str) -> str:
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def terraform_output(name: str) -> str:
    return run("terraform", f"-chdir={RUNNER_DIR}", "output", "-raw", name)


def aws_json(*args: str) -> dict:
    return json.loads(run("aws", *args, "--output", "json"))


def term_filter(field: str, value: str) -> str:
    return f"Type=TERM_MATCH,Field={field},Value={value}"


def on_demand_dimensions(service_code: str, filters: list[str]) -> list[dict]:
    response = aws_json(
        "pricing",
        "get-products",
        "--region",
        "us-east-1",
        "--service-code",
        service_code,
        "--filters",
        *filters,
    )
    dimensions: list[dict] = []
    for raw_product in response.get("PriceList", []):
        product = json.loads(raw_product) if isinstance(raw_product, str) else raw_product
        for term in product.get("terms", {}).get("OnDemand", {}).values():
            dimensions.extend(term.get("priceDimensions", {}).values())
    return dimensions


def hourly_instance_price(instance_type: str) -> Decimal:
    dimensions = on_demand_dimensions(
        "AmazonEC2",
        [
            term_filter("instanceType", instance_type),
            term_filter("location", LOCATION),
            term_filter("operatingSystem", "Linux"),
            term_filter("tenancy", "Shared"),
            term_filter("preInstalledSw", "NA"),
            term_filter("capacitystatus", "Used"),
        ],
    )
    prices = {
        Decimal(item["pricePerUnit"]["USD"])
        for item in dimensions
        if item.get("unit") == "Hrs"
    }
    if len(prices) != 1:
        raise RuntimeError(f"Неоднозначная цена {instance_type}: {sorted(prices)}")
    return prices.pop()


def gp3_monthly_price() -> Decimal:
    dimensions = on_demand_dimensions(
        "AmazonEC2",
        [term_filter("location", LOCATION), term_filter("volumeApiName", "gp3")],
    )
    prices = {
        Decimal(item["pricePerUnit"]["USD"])
        for item in dimensions
        if item.get("unit") == "GB-Mo"
    }
    if len(prices) != 1:
        raise RuntimeError(f"Неоднозначная цена gp3: {sorted(prices)}")
    return prices.pop()


def public_ipv4_hourly_price() -> Decimal:
    dimensions = on_demand_dimensions(
        "AmazonVPC",
        [
            term_filter("location", LOCATION),
            term_filter("usagetype", "USE1-PublicIPv4:InUseAddress"),
        ],
    )
    prices = {
        Decimal(item["pricePerUnit"]["USD"])
        for item in dimensions
        if item.get("unit") == "Hrs"
    }
    if len(prices) != 1:
        raise RuntimeError(f"Неоднозначная цена public IPv4: {sorted(prices)}")
    return prices.pop()


def latest_timings() -> tuple[Path, dict[str, Decimal]]:
    candidates = sorted(ARTIFACT_ROOT.glob("e2e-*/timings.tsv"))
    if not candidates:
        raise RuntimeError("Не найден artifacts/aws-runner/e2e-*/timings.tsv")
    path = candidates[-1]
    with path.open(newline="", encoding="utf-8") as stream:
        rows = {
            row["phase"]: Decimal(row["duration_seconds"])
            for row in csv.DictReader(stream, delimiter="\t")
        }
    required = {
        "cold_create",
        "benchmark",
        "first_stop",
        "stopped_fetch",
        "warm_start",
        "final_stop",
    }
    missing = required - rows.keys()
    if missing:
        raise RuntimeError(f"E2E ещё не завершён, нет фаз: {sorted(missing)}")
    return path, rows


def money(value: Decimal) -> str:
    return f"${value.quantize(Decimal('0.0001'))}"


def seconds(value: Decimal) -> str:
    return f"{value.quantize(Decimal('0.001'))} s"


def main() -> None:
    timings_path, phases = latest_timings()
    runner_type = terraform_output("runner_instance_type")
    nat_type = terraform_output("nat_instance_type")
    runner_count = Decimal(terraform_output("benchmark_node_count"))
    total_ebs_gib = Decimal(terraform_output("total_ebs_gib"))

    runner_hourly = hourly_instance_price(runner_type)
    nat_hourly = hourly_instance_price(nat_type)
    ipv4_hourly = public_ipv4_hourly_price()
    gp3_gib_monthly = gp3_monthly_price()

    compute_hourly = runner_count * runner_hourly + nat_hourly
    running_hourly = compute_hourly + ipv4_hourly
    ebs_monthly = total_ebs_gib * gp3_gib_monthly
    ebs_hourly = ebs_monthly / HOURS_PER_MONTH

    cold_create = phases["cold_create"]
    warm_start = phases["warm_start"]
    time_saved = cold_create - warm_start
    time_saved_percent = time_saved / cold_create * Decimal("100")

    cold_active = phases["cold_create"] + phases["benchmark"] + phases["first_stop"]
    warm_active = phases["warm_start"] + phases["final_stop"]
    cold_cost_upper = running_hourly * cold_active / SECONDS_PER_HOUR
    warm_cost_upper = running_hourly * warm_active / SECONDS_PER_HOUR
    startup_saving_upper = running_hourly * time_saved / SECONDS_PER_HOUR
    storage_break_even_hours = startup_saving_upper / ebs_hourly

    print(f"Тайминги: {timings_path}")
    print(f"Cold create: {seconds(cold_create)}")
    print(f"Warm start:  {seconds(warm_start)}")
    print(
        "Экономия времени на start вместо recreate: "
        f"{seconds(time_saved)} ({time_saved_percent.quantize(Decimal('0.1'))}%)"
    )
    print()
    print(f"{runner_count} x {runner_type}: {money(runner_count * runner_hourly)}/h")
    print(f"1 x {nat_type}: {money(nat_hourly)}/h")
    print(f"1 x public IPv4: {money(ipv4_hourly)}/h")
    print(f"Итого во время running: {money(running_hourly)}/h без EBS и мелких S3/request charges")
    print(f"Stopped EBS {total_ebs_gib} GiB gp3: {money(ebs_monthly)}/month, {money(ebs_hourly)}/h")
    print()
    print(f"Верхняя оценка compute+IPv4 до первого stop: {money(cold_cost_upper)}")
    print(f"Верхняя оценка одного warm start+stop: {money(warm_cost_upper)}")
    print(f"Экономия startup compute+IPv4 против recreate: до {money(startup_saving_upper)}")
    print(
        "Денежный break-even хранения stopped EBS против этой экономии: "
        f"{storage_break_even_hours.quantize(Decimal('0.1'))} h"
    )
    print("Оценки консервативны: wall-clock create/start включает время до фактического запуска EC2.")


if __name__ == "__main__":
    main()
