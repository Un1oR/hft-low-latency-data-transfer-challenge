#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runner_dir="$repo_root/infra/runner"
resume_dir="${SUBMISSION_RESUME_DIR:-}"
if [[ -n "$resume_dir" ]]; then
  suite_dir="$(realpath "$resume_dir")"
  suite_id="$(basename "$suite_dir")"
else
  suite_id="submission-suite-$(date -u +%Y%m%dT%H%M%SZ)"
  suite_dir="$repo_root/artifacts/aws-runner/$suite_id"
fi
comparison_rates="${SUBMISSION_COMPARISON_RATES:-200000 2000000}"
comparison_receiver_counts="${SUBMISSION_COMPARISON_RECEIVER_COUNTS:-1 3}"
comparison_blocks="${SUBMISSION_COMPARISON_BLOCKS:-6}"
samples="${SUBMISSION_SAMPLES:-1000000}"
warmup_ms="${SUBMISSION_WARMUP_MS:-2000}"
claude_package="${CLAUDE_BASELINE_PACKAGE:-$repo_root/dist/claude-baseline_0.1.0+gitc86cc26ab2e8_amd64.deb}"

for tool in aws jq rg terraform sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Не найдена обязательная команда: $tool" >&2
    exit 1
  }
done
for value in "$comparison_blocks" "$samples" "$warmup_ms"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "Числовые параметры suite должны быть целыми" >&2
    exit 2
  }
done
(( comparison_blocks >= 6 && samples > 0 )) || {
  echo "Финальная suite требует не менее шести блоков и одного события" >&2
  exit 2
}
[[ -f "$claude_package" ]] || {
  echo "Не найден пакет Claude: $claude_package" >&2
  exit 1
}

mkdir -p "$suite_dir/logs"
runs_tsv="$suite_dir/runs.tsv"
if [[ -n "$resume_dir" ]]; then
  [[ -f "$runs_tsv" ]] || {
    echo "В каталоге возобновления нет runs.tsv: $suite_dir" >&2
    exit 1
  }
else
  printf 'case_id\tgroup_name\tlabel_ru\trate_events_s\treceivers\tbatch_target\tstage_timestamps\thardware_rx_timestamps\trun_id\n' >"$runs_tsv"
fi

expected_spectral_sha="$(terraform -chdir="$runner_dir" output -raw package_sha256)"
spectral_package="${SUBMISSION_PACKAGE:-}"
if [[ -n "$spectral_package" ]]; then
  spectral_package="$(realpath "$spectral_package")"
  [[ -f "$spectral_package" ]] || {
    echo "Не найден SUBMISSION_PACKAGE=$spectral_package" >&2
    exit 1
  }
  [[ "$(sha256sum "$spectral_package" | awk '{print $1}')" == "$expected_spectral_sha" ]] || {
    echo "SUBMISSION_PACKAGE не совпадает с package SHA живого стенда" >&2
    exit 1
  }
else
  for candidate in "$repo_root"/dist/spectral-task_*.deb; do
    [[ -f "$candidate" ]] || continue
    if [[ "$(sha256sum "$candidate" | awk '{print $1}')" == "$expected_spectral_sha" ]]; then
      spectral_package="$candidate"
      break
    fi
  done
fi
[[ -n "$spectral_package" ]] || {
  echo "В dist/ нет основного пакета SHA256=$expected_spectral_sha" >&2
  exit 1
}

mapfile -t expected_instance_ids < <(
  terraform -chdir="$runner_dir" output -json runner_instance_ids | jq -r '.[]'
)
(( ${#expected_instance_ids[@]} == 4 )) || {
  echo "Suite требует четыре benchmark-узла" >&2
  exit 1
}
expected_ids_json="$(printf '%s\n' "${expected_instance_ids[@]}" | jq -Rsc 'split("\n")[:-1]')"
expected_placement_group="$(terraform -chdir="$runner_dir" output -raw benchmark_placement_group)"
expected_precision_time_group="$(terraform -chdir="$runner_dir" output -raw precision_time_placement_group)"
expected_precision_time_group_id="$(terraform -chdir="$runner_dir" output -raw precision_time_placement_group_id)"
expected_placement_json="$(aws ec2 describe-placement-groups \
  --region "${AWS_RUNNER_REGION:-us-east-1}" --group-names "$expected_placement_group" \
  --query 'PlacementGroups[0]' --output json)"
expected_placement_group_id="$(jq -r '.GroupId' <<<"$expected_placement_json")"
if [[ "$(jq -r '.State' <<<"$expected_placement_json")" != "available" ||
      "$(jq -r '.Strategy' <<<"$expected_placement_json")" != "cluster" ||
      "$(jq -r '.ParentGroupId' <<<"$expected_placement_json")" != "$expected_precision_time_group_id" ]]; then
  echo "Suite требует available cluster placement group с precision-time parent" >&2
  exit 1
fi

validate_dpdk_run() {
  local run_id="$1" rate="$2" receivers="$3" batch_target="$4"
  local stage="$5" hardware_rx="$6" expect_saturation="${7:-0}"
  local run_dir="$repo_root/artifacts/aws-runner/$run_id"
  [[ -f "$run_dir/manifest.json" && -f "$run_dir/fanout-summary.json" ]] ||
    return 1
  jq -e \
    --argjson rate "$rate" \
    --argjson receivers "$receivers" \
    --argjson samples "$samples" \
    --argjson warmup_ms "$warmup_ms" \
    --argjson stage "$stage" \
    --argjson hardware_rx "$hardware_rx" \
    --arg sha "$expected_spectral_sha" \
    --argjson ids "$expected_ids_json" \
    --arg placement_group "$expected_placement_group" \
    --arg placement_group_id "$expected_placement_group_id" \
    --arg precision_time_group "$expected_precision_time_group" \
    --arg precision_time_group_id "$expected_precision_time_group_id" '
      .implementation == "spectral-task" and
      .networking_backend == "dpdk" and .compact_wire == true and
      .dpdk_llq_policy == 3 and .receiver_count == $receivers and
      .message_rate == $rate and .message_count == $samples and
      .warmup_ms == $warmup_ms and .stage_timestamps == ($stage == 1) and
      .dpdk_rx_hardware_timestamps == ($hardware_rx == 1) and
      .clock_method == "aws_ena_phc" and
      .package_sha256 == $sha and .runner_instance_ids == $ids and
      .placement_group == $placement_group and
      .placement_group_id == $placement_group_id and
      .placement_strategy == "cluster" and
      .precision_time_placement_group == $precision_time_group and
      .precision_time_placement_group_id == $precision_time_group_id
    ' "$run_dir/manifest.json" >/dev/null || return 1
  if [[ "$batch_target" == "auto" ]]; then
    jq -e '.batch_target_frames_requested == "auto"' \
      "$run_dir/manifest.json" >/dev/null || return 1
  else
    jq -e --arg requested "$batch_target" --argjson target "$batch_target" \
      '.batch_target_frames_requested == $requested and .batch_target_frames == $target' \
      "$run_dir/manifest.json" >/dev/null || return 1
  fi
  if [[ "$expect_saturation" == 1 ]]; then
    jq -e '
      .delivery_valid == false and
      ([.receivers[] | .received] | all(. > 0)) and
      ([.receivers[] | .gaps] | any(. > 0)) and
      ([.receivers[] | .duplicates, .reordered, .clock_correction_ns] | all(. == 0))
    ' "$run_dir/fanout-summary.json" >/dev/null || return 1
    rg -n 'dpdk_(pps|bw_out)_exceeded=[1-9][0-9]*' "$run_dir/source" >/dev/null || {
      echo "Невалидная точка не подтверждена аппаратным saturation counter: $run_id" >&2
      return 1
    }
  else
    jq -e '
      .delivery_valid == true and
      ([.receivers[] | .gaps, .duplicates, .reordered, .clock_correction_ns] | all(. == 0))
    ' "$run_dir/fanout-summary.json" >/dev/null || return 1
  fi
  if rg -n 'dpdk_(imissed|ierrors|oerrors|rx_nombuf)=[1-9][0-9]*' "$run_dir" >/dev/null; then
    echo "Ненулевой DPDK error counter в $run_id" >&2
    return 1
  fi
  return 0
}

record_run() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$runs_tsv"
}

run_dpdk_case() {
  local case_id="$1" group_name="$2" label_ru="$3" rate="$4" receivers="$5"
  local batch_target="$6" stage="$7" hardware_rx="$8"
  local log="$suite_dir/logs/${case_id}.log" run_id existing recovered
  local expect_saturation=0
  [[ "$case_id" == "rate-4m-forced-3" || "$case_id" == "rate-5m-auto" ]] &&
    expect_saturation=1
  existing="$(awk -F '\t' -v case_id="$case_id" 'NR > 1 && $1 == case_id {print $9}' "$runs_tsv")"
  if [[ -n "$existing" ]]; then
    [[ "$(wc -l <<<"$existing")" == 1 ]] || {
      echo "Несколько запусков suite для case_id=$case_id" >&2
      exit 1
    }
    validate_dpdk_run "$existing" "$rate" "$receivers" "$batch_target" "$stage" "$hardware_rx" "$expect_saturation"
    echo "Пропускаем уже валидный suite case: $case_id run=$existing"
    return
  fi
  if [[ -f "$log" ]]; then
    recovered="$(sed -n 's/^Результаты run \([^ ]*\) сохранены.*/\1/p' "$log" | tail -n 1)"
    if [[ -n "$recovered" ]] &&
       validate_dpdk_run "$recovered" "$rate" "$receivers" "$batch_target" "$stage" "$hardware_rx" "$expect_saturation"; then
      record_run "$case_id" "$group_name" "$label_ru" "$rate" "$receivers" \
        "$batch_target" "$stage" "$hardware_rx" "$recovered"
      echo "Восстановлен уже измеренный suite case: $case_id run=$recovered"
      return
    fi
  fi
  echo "=== $case_id: $label_ru ==="
  AWS_RUNNER_PACKAGE="$spectral_package" \
  AWS_RUNNER_NETWORKING_BACKEND=dpdk \
  AWS_RUNNER_COMPACT_WIRE=1 \
  AWS_RUNNER_DPDK_LLQ_POLICY=3 \
  AWS_RUNNER_RECEIVER_COUNT="$receivers" \
  AWS_RUNNER_MESSAGE_RATE="$rate" \
  AWS_RUNNER_MESSAGE_COUNT="$samples" \
  AWS_RUNNER_WARMUP_MS="$warmup_ms" \
  AWS_RUNNER_BATCH_TARGET_FRAMES="$batch_target" \
  AWS_RUNNER_STAGE_TIMESTAMPS="$stage" \
  AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS="$hardware_rx" \
  AWS_RUNNER_ALLOW_INVALID_DELIVERY="$expect_saturation" \
  AWS_RUNNER_CLOCK_PROBE=0 \
    "$runner_dir/scripts/cluster.sh" run | tee "$log"
  run_id="$(sed -n 's/^Результаты run \([^ ]*\) сохранены.*/\1/p' "$log" | tail -n 1)"
  [[ -n "$run_id" ]] || {
    echo "Не удалось определить run ID для $case_id" >&2
    exit 1
  }
  validate_dpdk_run "$run_id" "$rate" "$receivers" "$batch_target" "$stage" "$hardware_rx" "$expect_saturation"
  record_run "$case_id" "$group_name" "$label_ru" "$rate" "$receivers" \
    "$batch_target" "$stage" "$hardware_rx" "$run_id"
}

comparison_log="$suite_dir/logs/comparison.log"
comparison_resume_dir="${SUBMISSION_COMPARISON_RESUME_DIR:-}"
COMPARISON_RATES="$comparison_rates" \
COMPARISON_RECEIVER_COUNTS="$comparison_receiver_counts" \
COMPARISON_BLOCKS="$comparison_blocks" \
COMPARISON_SAMPLES="$samples" \
COMPARISON_WARMUP_MS="$warmup_ms" \
COMPARISON_RESUME_DIR="$comparison_resume_dir" \
CLAUDE_BASELINE_PACKAGE="$claude_package" \
  "$repo_root/scripts/run-claude-dpdk-comparison.sh" | tee -a "$comparison_log"
comparison_matrix="$(sed -n 's/^Контрсбалансированное сравнение завершено: //p' "$comparison_log" | tail -n 1)"
[[ -f "$comparison_matrix" ]] || {
  echo "Не найдена итоговая matrix.json сравнения" >&2
  exit 1
}
jq -e \
  --arg sha "$expected_spectral_sha" \
  --argjson ids "$expected_ids_json" \
  --argjson blocks "$comparison_blocks" \
  --argjson receiver_counts "$(printf '%s\n' $comparison_receiver_counts | jq -Rsc 'split("\n")[:-1] | map(tonumber)')" '
    .spectral_package_sha256 == $sha and .runner_instance_ids == $ids and
    .placement.strategy == "cluster" and
    .methodology.design == "counterbalanced paired blocks" and
    .methodology.blocks_per_rate == $blocks and
    .methodology.receiver_counts == $receiver_counts
  ' "$comparison_matrix" >/dev/null

# Нагрузочный срез: один и тот же N=3, включая отрицательный контроль с
# заведомо недостаточной целью пачки при 4 млн событий/с.
run_dpdk_case rate-200k-auto rate-sweep "0,2 млн/с, авто" 200000 3 auto 0 0
run_dpdk_case rate-2m-auto rate-sweep "2 млн/с, авто" 2000000 3 auto 0 0
run_dpdk_case rate-4m-forced-3 rate-sweep "4 млн/с, цель 3" 4000000 3 3 0 0
run_dpdk_case rate-4m-auto rate-sweep "4 млн/с, авто" 4000000 3 auto 0 0
run_dpdk_case rate-4_5m-auto rate-sweep "4,5 млн/с, авто" 4500000 3 auto 0 0
run_dpdk_case rate-5m-auto rate-sweep "5 млн/с, авто" 5000000 3 auto 0 0

# Полный N-срез снимается отдельно и последовательно на той же эпохе, чтобы не
# выбирать удобный DPDK-блок из сравнения с Claude.
run_dpdk_case fanout-n1 receiver-sweep "N=1" 2000000 1 auto 0 0
run_dpdk_case fanout-n2 receiver-sweep "N=2" 2000000 2 auto 0 0
run_dpdk_case fanout-n3 receiver-sweep "N=3" 2000000 3 auto 0 0

# Разбивка пути диагностическая и поэтому отделена от основных запусков.
run_dpdk_case stage-2m-n3 stage-breakdown "Аппаратная RX-метка" 2000000 3 auto 1 1

suite_json="$suite_dir/suite.json"
jq -Rn \
  --arg suite_id "$suite_id" \
  --arg comparison_matrix "$(realpath --relative-to="$repo_root" "$comparison_matrix")" \
  --arg spectral_package "$(realpath --relative-to="$repo_root" "$spectral_package")" \
  --arg spectral_package_sha256 "$expected_spectral_sha" \
  --arg claude_package_sha256 "$(sha256sum "$claude_package" | awk '{print $1}')" \
  --argjson runner_instance_ids "$expected_ids_json" \
  --argjson samples "$samples" \
  --argjson warmup_ms "$warmup_ms" \
  --slurpfile comparison "$comparison_matrix" '
    [inputs | split("\t")] as $rows |
    {
      suite_id:$suite_id,
      comparison_matrix:$comparison_matrix,
      spectral_package:$spectral_package,
      spectral_package_sha256:$spectral_package_sha256,
      claude_package_sha256:$claude_package_sha256,
      runner_instance_ids:$runner_instance_ids,
      placement:$comparison[0].placement,
      measured_samples_per_receiver_per_run:$samples,
      warmup_ms:$warmup_ms,
      dpdk_runs:($rows[1:] | map({
        case_id:.[0], group:.[1], label_ru:.[2], rate_events_s:(.[3]|tonumber),
        receivers:(.[4]|tonumber), batch_target:.[5],
        stage_timestamps:(.[6] == "1"), hardware_rx_timestamps:(.[7] == "1"),
        expected_saturation:(.[0] == "rate-4m-forced-3" or .[0] == "rate-5m-auto"),
        run_id:.[8]
      }))
    }
  ' <"$runs_tsv" >"$suite_json"

echo "Полная одноэпоховая suite завершена: $suite_json"
