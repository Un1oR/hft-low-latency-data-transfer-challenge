#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runner_dir="$repo_root/infra/runner"
resume_dir="${COMPARISON_RESUME_DIR:-}"
if [[ -n "$resume_dir" ]]; then
  comparison_dir="$(realpath "$resume_dir")"
  comparison_id="$(basename "$comparison_dir")"
else
  comparison_id="comparison-$(date -u +%Y%m%dT%H%M%SZ)"
  comparison_dir="$repo_root/artifacts/aws-runner/$comparison_id"
fi
rates="${COMPARISON_RATES:-200000 2000000}"
receiver_counts="${COMPARISON_RECEIVER_COUNTS:-1 3}"
blocks="${COMPARISON_BLOCKS:-6}"
measured_samples="${COMPARISON_SAMPLES:-1000000}"
warmup_ms="${COMPARISON_WARMUP_MS:-2000}"
claude_package="${CLAUDE_BASELINE_PACKAGE:-$repo_root/dist/claude-baseline_0.1.0+gitc86cc26ab2e8_amd64.deb}"

for tool in aws jq terraform sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Не найдена обязательная команда: $tool" >&2
    exit 1
  }
done
for value in "$blocks" "$measured_samples" "$warmup_ms"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "Параметры числа повторов/событий должны быть целыми" >&2
    exit 2
  }
done
for receivers in $receiver_counts; do
  [[ "$receivers" =~ ^[1-3]$ ]] || {
    echo "COMPARISON_RECEIVER_COUNTS допускает только 1, 2 или 3: $receivers" >&2
    exit 2
  }
done
(( blocks >= 2 && measured_samples > 0 )) || {
  echo "Нужны хотя бы два блока и одно измеряемое событие" >&2
  exit 2
}
if (( blocks < 6 )); then
  echo "Предупреждение: меньше шести блоков не позволяют exact sign test достичь p < 0.05" >&2
fi
[[ -f "$claude_package" ]] || {
  echo "Не найден пакет Claude: $claude_package" >&2
  exit 1
}

mkdir -p "$comparison_dir/logs"
matrix_tsv="$comparison_dir/matrix.tsv"
invalid_attempts_tsv="$comparison_dir/invalid-attempts.tsv"
if [[ -n "$resume_dir" ]]; then
  [[ -f "$matrix_tsv" ]] || {
    echo "В каталоге возобновления нет matrix.tsv: $comparison_dir" >&2
    exit 1
  }
  [[ "$(head -n 1 "$matrix_tsv")" == $'order\tblock\tarm_position\tstarted_at_utc\tfinished_at_utc\timplementation\treceivers\trate_events_s\trun_id' ]] || {
    echo "matrix.tsv имеет старую схему без receivers; продолжить её как multi-N нельзя" >&2
    exit 1
  }
else
  printf 'order\tblock\tarm_position\tstarted_at_utc\tfinished_at_utc\timplementation\treceivers\trate_events_s\trun_id\n' >"$matrix_tsv"
fi
if [[ ! -f "$invalid_attempts_tsv" ]]; then
  printf 'order\tblock\tarm_position\tstarted_at_utc\tfinished_at_utc\timplementation\treceivers\trate_events_s\trun_id\tstatus\treason\n' >"$invalid_attempts_tsv"
fi

# Блок является единицей сравнения. Если прошлый запуск успел записать только
# одно плечо, оставлять его и доснимать второе через большой перерыв нельзя:
# переносим плечо в историю невалидных попыток и переснимаем весь блок рядом.
if [[ -n "$resume_dir" ]]; then
  while IFS=$'\t' read -r receivers rate block count; do
    if (( count > 2 )); then
      echo "В matrix.tsv больше двух плеч: N=$receivers rate=$rate block=$block count=$count" >&2
      exit 1
    fi
    if (( count == 1 )); then
      awk -F '\t' -v receivers="$receivers" -v rate="$rate" -v block="$block" \
        'BEGIN {OFS="\t"} NR > 1 && $7 == receivers && $8 == rate && $2 == block {
          print $0, "invalid", "incomplete-block-on-resume"
        }' "$matrix_tsv" >>"$invalid_attempts_tsv"
      temporary_matrix="$(mktemp "$comparison_dir/matrix.tsv.XXXXXX")"
      awk -F '\t' -v receivers="$receivers" -v rate="$rate" -v block="$block" \
        'NR == 1 || !($7 == receivers && $8 == rate && $2 == block)' "$matrix_tsv" \
        >"$temporary_matrix"
      mv "$temporary_matrix" "$matrix_tsv"
      echo "Неполный блок исключён и будет переснят целиком: N=$receivers rate=$rate block=$block"
    fi
  done < <(
    awk -F '\t' 'NR > 1 {count[$7 FS $8 FS $2]++} END {
      for (key in count) {split(key, parts, FS); print parts[1], parts[2], parts[3], count[key]}
    }' OFS=$'\t' "$matrix_tsv" | sort -n -k1,1 -k2,2 -k3,3
  )
fi

expected_spectral_sha="$(terraform -chdir="$runner_dir" output -raw package_sha256)"
spectral_package=""
for candidate in "$repo_root"/dist/spectral-task_*.deb; do
  [[ -f "$candidate" ]] || continue
  if [[ "$(sha256sum "$candidate" | awk '{print $1}')" == "$expected_spectral_sha" ]]; then
    spectral_package="$candidate"
    break
  fi
done
[[ -n "$spectral_package" ]] || {
  echo "В dist/ нет основного пакета SHA256=$expected_spectral_sha" >&2
  exit 1
}

mapfile -t expected_instance_ids < <(
  terraform -chdir="$runner_dir" output -json runner_instance_ids | jq -r '.[]'
)
(( ${#expected_instance_ids[@]} == 4 )) || {
  echo "Сравнение требует четыре benchmark-узла" >&2
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
  echo "Сравнение требует available cluster placement group с precision-time parent" >&2
  exit 1
fi

echo "Устанавливаем неизменённый Claude на свежие узлы"
CLAUDE_BASELINE_PACKAGE="$claude_package" \
  "$repo_root/scripts/claude-baseline.sh" install

order=$(( $(wc -l <"$matrix_tsv") - 1 ))
record_run() {
  local block="$1" arm_position="$2" implementation="$3" receivers="$4"
  local rate="$5" run_id="$6" started_at="$7" finished_at="$8"
  order=$((order + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$order" "$block" "$arm_position" "$started_at" "$finished_at" \
    "$implementation" "$receivers" "$rate" "$run_id" \
    >>"$matrix_tsv"
}

validate_claude_run() {
  local run_id="$1" receivers="$2" rate="$3" warmup_samples="$4" run_dir
  run_dir="$repo_root/artifacts/aws-runner/$run_id"
  jq -e \
    --argjson receivers "$receivers" \
    --argjson rate "$rate" \
    --argjson samples "$measured_samples" \
    --argjson warmup_samples "$warmup_samples" \
    --argjson ids "$expected_ids_json" \
    --arg placement_group "$expected_placement_group" \
    --arg placement_group_id "$expected_placement_group_id" \
    --arg precision_time_group "$expected_precision_time_group" \
    --arg precision_time_group_id "$expected_precision_time_group_id" '
      .baseline_commit == "c86cc26ab2e84996137f922cf175d33e9a622c29" and
      .rate == $rate and .receivers == $receivers and .reps == 1 and
      .measured_samples_per_rep == $samples and
      .dropped_prefix_per_rep == $warmup_samples and
      .clock_method == "aws_ena_phc" and .clock_correction_ns == 0 and
      ([.source_instance_id] + .receiver_instance_ids) == $ids[0:($receivers + 1)] and
      .placement_group == $placement_group and
      .placement_group_id == $placement_group_id and
      .placement_strategy == "cluster" and
      .precision_time_placement_group == $precision_time_group and
      .precision_time_placement_group_id == $precision_time_group_id
    ' "$run_dir/manifest.json" >/dev/null
  jq -e '
    .delivery_valid == true and
    .delivery_validation.totals.gaps == 0 and
    .delivery_validation.totals.duplicates == 0 and
    .delivery_validation.totals.reordered == 0
  ' "$run_dir/summary.json" >/dev/null
}

validate_dpdk_run() {
  local run_id="$1" receivers="$2" rate="$3" run_dir
  run_dir="$repo_root/artifacts/aws-runner/$run_id"
  jq -e \
    --argjson receivers "$receivers" \
    --argjson rate "$rate" \
    --argjson samples "$measured_samples" \
    --argjson warmup_ms "$warmup_ms" \
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
      .warmup_ms == $warmup_ms and .clock_method == "aws_ena_phc" and
      .package_sha256 == $sha and .runner_instance_ids == $ids and
      .placement_group == $placement_group and
      .placement_group_id == $placement_group_id and
      .placement_strategy == "cluster" and
      .precision_time_placement_group == $precision_time_group and
      .precision_time_placement_group_id == $precision_time_group_id
    ' "$run_dir/manifest.json" >/dev/null
  jq -e '
    .delivery_valid == true and
    ([.receivers[] | .gaps, .duplicates, .reordered] | all(. == 0))
  ' "$run_dir/fanout-summary.json" >/dev/null
}

completed_run_id() {
  local block="$1" arm_position="$2" implementation="$3" receivers="$4" rate="$5"
  awk -F '\t' \
    -v block="$block" -v arm="$arm_position" -v implementation="$implementation" \
    -v receivers="$receivers" -v rate="$rate" '
      NR > 1 && $2 == block && $3 == arm && $6 == implementation &&
      $7 == receivers && $8 == rate {
        print $9
      }
    ' "$matrix_tsv"
}

run_claude() {
  local receivers="$1" rate="$2" block="$3" arm_position="$4"
  local started_at finished_at log run_id warmup_samples total_samples existing
  (( (rate * warmup_ms) % 1000 == 0 )) || {
    echo "Частота $rate и прогрев ${warmup_ms} мс дают нецелое число событий" >&2
    exit 2
  }
  warmup_samples=$((rate * warmup_ms / 1000))
  total_samples=$((measured_samples + warmup_samples))
  existing="$(completed_run_id "$block" "$arm_position" claude-c86cc26 "$receivers" "$rate")"
  if [[ -n "$existing" ]]; then
    [[ "$(wc -l <<<"$existing")" == 1 ]] || {
      echo "Несколько Claude-плеч для rate=$rate block=$block arm=$arm_position" >&2
      exit 1
    }
    validate_claude_run "$existing" "$receivers" "$rate" "$warmup_samples"
    echo "Пропускаем уже валидное Claude-плечо: N=$receivers rate=$rate block=$block arm=$arm_position run=$existing"
    return
  fi
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log="$comparison_dir/logs/n${receivers}-b${block}-a${arm_position}-claude-r${rate}.log"
  CLAUDE_BASELINE_PACKAGE="$claude_package" \
  CLAUDE_BASELINE_RATE="$rate" \
  CLAUDE_BASELINE_RECEIVERS="$receivers" \
  CLAUDE_BASELINE_REPS=1 \
  CLAUDE_BASELINE_SAMPLES="$total_samples" \
  CLAUDE_BASELINE_DROP="$warmup_samples" \
  CLAUDE_BASELINE_CLOCK_PROBE=0 \
    "$repo_root/scripts/claude-baseline.sh" run | tee "$log"
  run_id="$(sed -n 's/^Claude baseline run: //p' "$log" | tail -n 1)"
  [[ -n "$run_id" ]] || {
    echo "Не удалось определить run ID Claude" >&2
    exit 1
  }
  validate_claude_run "$run_id" "$receivers" "$rate" "$warmup_samples"
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record_run "$block" "$arm_position" claude-c86cc26 "$receivers" "$rate" "$run_id" \
    "$started_at" "$finished_at"
}

run_dpdk() {
  local receivers="$1" rate="$2" block="$3" arm_position="$4"
  local started_at finished_at log run_id existing
  existing="$(completed_run_id "$block" "$arm_position" spectral-task "$receivers" "$rate")"
  if [[ -n "$existing" ]]; then
    [[ "$(wc -l <<<"$existing")" == 1 ]] || {
      echo "Несколько DPDK-плеч для rate=$rate block=$block arm=$arm_position" >&2
      exit 1
    }
    validate_dpdk_run "$existing" "$receivers" "$rate"
    echo "Пропускаем уже валидное DPDK-плечо: N=$receivers rate=$rate block=$block arm=$arm_position run=$existing"
    return
  fi
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log="$comparison_dir/logs/n${receivers}-b${block}-a${arm_position}-dpdk-r${rate}.log"
  AWS_RUNNER_PACKAGE="$spectral_package" \
  AWS_RUNNER_NETWORKING_BACKEND=dpdk \
  AWS_RUNNER_COMPACT_WIRE=1 \
  AWS_RUNNER_DPDK_LLQ_POLICY=3 \
  AWS_RUNNER_RECEIVER_COUNT="$receivers" \
  AWS_RUNNER_MESSAGE_RATE="$rate" \
  AWS_RUNNER_MESSAGE_COUNT="$measured_samples" \
  AWS_RUNNER_WARMUP_MS="$warmup_ms" \
  AWS_RUNNER_STAGE_TIMESTAMPS=0 \
  AWS_RUNNER_DPDK_RX_HARDWARE_TIMESTAMPS=0 \
  AWS_RUNNER_CLOCK_PROBE=0 \
    "$runner_dir/scripts/cluster.sh" run | tee "$log"
  run_id="$(sed -n 's/^Результаты run \([^ ]*\) сохранены.*/\1/p' "$log" | tail -n 1)"
  [[ -n "$run_id" ]] || {
    echo "Не удалось определить run ID DPDK" >&2
    exit 1
  }
  validate_dpdk_run "$run_id" "$receivers" "$rate"
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record_run "$block" "$arm_position" spectral-task "$receivers" "$rate" "$run_id" \
    "$started_at" "$finished_at"
}

for receivers in $receiver_counts; do
  for rate in $rates; do
    [[ "$rate" =~ ^[1-9][0-9]*$ ]] || {
      echo "Некорректная частота: $rate" >&2
      exit 2
    }
    for block in $(seq 1 "$blocks"); do
      if (( block % 2 == 1 )); then
        run_claude "$receivers" "$rate" "$block" 1
        run_dpdk "$receivers" "$rate" "$block" 2
      else
        run_dpdk "$receivers" "$rate" "$block" 1
        run_claude "$receivers" "$rate" "$block" 2
      fi
    done
  done
done

invalid_attempts_json="$(jq -Rn '
  [inputs | split("\t")] as $rows |
  ($rows[1:] | map({
    order:(if .[0] == "" then null else (.[0]|tonumber) end),
    block:(.[1]|tonumber), arm_position:(.[2]|tonumber),
    started_at_utc:.[3], finished_at_utc:.[4], implementation:.[5],
    receivers:(.[6]|tonumber), rate_events_s:(.[7]|tonumber),
    run_id:.[8], status:.[9], reason:.[10]
  }))
' <"$invalid_attempts_tsv")"

jq -Rn \
  --arg comparison_id "$comparison_id" \
  --arg spectral_package_sha256 "$expected_spectral_sha" \
  --arg claude_package_sha256 "$(sha256sum "$claude_package" | awk '{print $1}')" \
  --argjson measured_samples "$measured_samples" \
  --argjson warmup_ms "$warmup_ms" \
  --argjson blocks "$blocks" \
  --argjson receiver_counts "$(printf '%s\n' $receiver_counts | jq -Rsc 'split("\n")[:-1] | map(tonumber)')" \
  --argjson invalid_attempts "$invalid_attempts_json" \
  --argjson runner_instance_ids "$expected_ids_json" \
  --arg placement_group "$expected_placement_group" \
  --arg placement_group_id "$expected_placement_group_id" \
  --arg precision_time_group "$expected_precision_time_group" \
  --arg precision_time_group_id "$expected_precision_time_group_id" '
    [inputs | split("\t")] as $rows |
    {
      comparison_id:$comparison_id,
      spectral_package_sha256:$spectral_package_sha256,
      claude_package_sha256:$claude_package_sha256,
      runner_instance_ids:$runner_instance_ids,
      placement:{
        strategy:"cluster",
        group_name:$placement_group,
        group_id:$placement_group_id,
        precision_time_parent_name:$precision_time_group,
        precision_time_parent_id:$precision_time_group_id
      },
      methodology:{
        design:"counterbalanced paired blocks",
        odd_block_order:["claude-c86cc26", "spectral-task"],
        even_block_order:["spectral-task", "claude-c86cc26"],
        blocks_per_rate:$blocks,
        measured_samples_per_receiver_per_run:$measured_samples,
        warmup_ms:$warmup_ms,
        clock_method:"aws_ena_phc",
        clock_correction_ns:0,
        receiver_counts:$receiver_counts
      },
      invalid_attempts:$invalid_attempts,
      runs:($rows[1:] | map({
        order:(.[0]|tonumber), block:(.[1]|tonumber), arm_position:(.[2]|tonumber),
        started_at_utc:.[3], finished_at_utc:.[4], implementation:.[5],
        receivers:(.[6]|tonumber), rate_events_s:(.[7]|tonumber), run_id:.[8]
      }))
    }
  ' <"$matrix_tsv" >"$comparison_dir/matrix.json"

echo "Контрсбалансированное сравнение завершено: $comparison_dir/matrix.json"
