#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner_dir="$(cd -- "$script_dir/.." && pwd)"
repo_root="$(cd -- "$runner_dir/../.." && pwd)"
region="${AWS_RUNNER_REGION:-us-east-1}"
runtime_minutes="${AWS_RUNNER_TTL_MINUTES:-15}"

terraform_cmd=(terraform -chdir="$runner_dir")
approval_args=()
if [[ "${AWS_RUNNER_AUTO_APPROVE:-0}" == "1" ]]; then
  approval_args=(-auto-approve)
fi

usage() {
  cat <<'USAGE'
Использование: cluster.sh <up|start|stop|update|extend|run|fetch|status|audit|down|e2e>

Переменные окружения:
  AWS_RUNNER_PACKAGE       путь к .deb; иначе нужен ровно один dist/*.deb
  AWS_RUNNER_TTL_MINUTES   TTL от up/extend, по умолчанию 15
  AWS_RUNNER_AUTO_APPROVE  1 добавляет -auto-approve к Terraform
  AWS_RUNNER_MESSAGE_COUNT число сообщений, по умолчанию 1000000
  AWS_RUNNER_MESSAGE_RATE  скорость producer, по умолчанию 200000
  AWS_RUNNER_RUN_ID        run для fetch; иначе выбирается последний в S3
USAGE
}

require_tools() {
  local tool
  for tool in aws jq terraform; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Не найдена обязательная команда: $tool" >&2
      exit 1
    fi
  done
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name должен быть положительным целым числом: $value" >&2
    exit 2
  fi
}

state_package_path() {
  local path
  path="$(${terraform_cmd[@]} state show -no-color aws_s3_object.package 2>/dev/null |
    awk -F' = ' '$1 ~ /^[[:space:]]*source$/ { gsub(/"/, "", $2); print $2; exit }')"
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"
  fi
}

resolve_package() {
  local prefer_state="${1:-1}"
  local state_path
  local -a packages
  if [[ -n "${AWS_RUNNER_PACKAGE:-}" ]]; then
    if [[ ! -f "$AWS_RUNNER_PACKAGE" ]]; then
      echo "Не найден AWS_RUNNER_PACKAGE: $AWS_RUNNER_PACKAGE" >&2
      exit 1
    fi
    realpath -- "$AWS_RUNNER_PACKAGE"
    return
  fi

  if [[ "$prefer_state" == "1" ]]; then
    state_path="$(state_package_path)"
    if [[ -n "$state_path" ]]; then
      realpath -- "$state_path"
      return
    fi
  fi

  shopt -s nullglob
  packages=("$repo_root"/dist/*.deb)
  shopt -u nullglob
  if (( ${#packages[@]} != 1 )); then
    echo "Нужен ровно один dist/*.deb или явный AWS_RUNNER_PACKAGE" >&2
    exit 1
  fi
  realpath -- "${packages[0]}"
}

current_runtime_minutes() {
  local value
  value="$(${terraform_cmd[@]} output -raw runtime_minutes 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$runtime_minutes"
  fi
}

current_paused() {
  local value
  value="$(${terraform_cmd[@]} output -raw cluster_paused 2>/dev/null || true)"
  if [[ "$value" == "true" ]]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

current_power_state() {
  local value
  value="$(${terraform_cmd[@]} output -raw cluster_power_state 2>/dev/null || true)"
  case "$value" in
    running|stopped) printf '%s\n' "$value" ;;
    *) printf '%s\n' running ;;
  esac
}

current_bootstrap_association_enabled() {
  local value
  value="$(${terraform_cmd[@]} output -raw bootstrap_association_enabled 2>/dev/null || true)"
  [[ "$value" == "false" ]] && printf '%s\n' false || printf '%s\n' true
}

current_ttl_association_enabled() {
  local value
  value="$(${terraform_cmd[@]} output -raw ttl_association_enabled 2>/dev/null || true)"
  [[ "$value" == "false" ]] && printf '%s\n' false || printf '%s\n' true
}

terraform_init() {
  "${terraform_cmd[@]}" init -input=true
}

run_terraform() {
  local log_dir log_path status
  if [[ "${AWS_RUNNER_COMPACT_OUTPUT:-0}" != "1" ]]; then
    "$@"
    return
  fi

  log_dir="${terraform_log_dir:-$repo_root/artifacts/aws-runner/terraform}"
  mkdir -p "$log_dir"
  log_path="$log_dir/$(date -u +%Y%m%dT%H%M%S)-$RANDOM.log"
  echo "Terraform: полный вывод сохраняется в $log_path"
  set +e
  "$@" >"$log_path" 2>&1
  status=$?
  set -e
  if (( status != 0 )); then
    echo "Terraform завершился с кодом $status; последние 120 строк:" >&2
    tail -n 120 "$log_path" >&2
    return "$status"
  fi
  tail -n 20 "$log_path"
}

terraform_apply() {
  local package_path="$1"
  local ttl="$2"
  local paused="$3"
  local power_state="$4"
  local bootstrap_enabled="$5"
  local ttl_enabled="$6"
  shift 6
  run_terraform "${terraform_cmd[@]}" apply -no-color "${approval_args[@]}" \
    -var="package_path=$package_path" \
    -var="max_runtime_minutes=$ttl" \
    -var="cluster_paused=$paused" \
    -var="cluster_power_state=$power_state" \
    -var="bootstrap_association_enabled=$bootstrap_enabled" \
    -var="ttl_association_enabled=$ttl_enabled" \
    "$@"
}

latest_association_execution() {
  local association_id="$1"
  aws ssm describe-association-executions \
    --region "$region" \
    --association-id "$association_id" \
    --max-results 1 \
    --query 'AssociationExecutions[0].ExecutionId' \
    --output text 2>/dev/null || true
}

wait_association_execution() {
  local association_id="$1"
  local execution_id="$2"
  local status detailed
  local attempt
  for attempt in $(seq 1 100); do
    read -r status detailed < <(
      aws ssm describe-association-executions \
        --region "$region" \
        --association-id "$association_id" \
        --max-results 20 \
        --query "AssociationExecutions[?ExecutionId=='$execution_id']|[0].[Status,DetailedStatus]" \
        --output text 2>/dev/null || true
    )
    case "$status" in
      Success)
        echo "SSM association $association_id: execution $execution_id завершён успешно"
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        echo "SSM association $association_id: $status ($detailed)" >&2
        aws ssm describe-association-execution-targets \
          --region "$region" \
          --association-id "$association_id" \
          --execution-id "$execution_id" \
          --output json >&2 || true
        return 1
        ;;
    esac
    sleep 3
  done
  echo "SSM association $association_id не завершился за 5 минут" >&2
  return 1
}

wait_new_association_execution() {
  local association_id="$1"
  local previous_id="${2:-}"
  local current_id=""
  local attempt

  # Любой штатный сценарий меняет параметры association через Terraform:
  # SHA пакета, абсолютный expires_at или cluster_paused. Поэтому нового
  # execution ждём, но не обходим Terraform через start-associations-once.
  for attempt in $(seq 1 100); do
    current_id="$(latest_association_execution "$association_id")"
    if [[ -n "$current_id" && "$current_id" != "None" && \
          "$current_id" != "$previous_id" ]]; then
      wait_association_execution "$association_id" "$current_id"
      return
    fi
    sleep 3
  done
  echo "У association $association_id не появился новый execution за 5 минут" >&2
  return 1
}

wait_command() {
  local command_id="$1"
  local expected="$2"
  local quiet_failures="${3:-0}"
  local invocations total active failed
  local attempt
  for attempt in $(seq 1 80); do
    invocations="$(aws ssm list-command-invocations \
      --region "$region" --command-id "$command_id" --details --output json)"
    total="$(jq '.CommandInvocations | length' <<<"$invocations")"
    active="$(jq '[.CommandInvocations[] | select(
      .Status == "Pending" or .Status == "InProgress" or .Status == "Delayed"
    )] | length' <<<"$invocations")"
    failed="$(jq '[.CommandInvocations[] | select(
      .Status == "Failed" or .Status == "TimedOut" or
      .Status == "Cancelled" or .Status == "Cancelling"
    )] | length' <<<"$invocations")"
    if (( failed > 0 )); then
      if [[ "$quiet_failures" != "1" ]]; then
        jq '.CommandInvocations[] | {
          InstanceId, Status, StatusDetails,
          Plugins: [.CommandPlugins[] | {Name, Status, ResponseCode, Output}]
        }' <<<"$invocations" >&2
      fi
      return 1
    fi
    if (( total == expected && active == 0 )); then
      return 0
    fi
    sleep 2
  done
  echo "SSM command $command_id не завершилась за отведённое время" >&2
  return 1
}

runner_ids() {
  "${terraform_cmd[@]}" output -json runner_instance_ids | jq -r '.[]'
}

all_instance_ids() {
  printf '%s\n' "$("${terraform_cmd[@]}" output -raw nat_instance_id)"
  runner_ids
}

wait_nodes_ssm() {
  local -a ids=("$@")
  local params command_id
  local attempt
  params='{"commands":["true"]}'
  for attempt in $(seq 1 60); do
    if ! command_id="$(aws ssm send-command \
        --region "$region" \
        --instance-ids "${ids[@]}" \
        --document-name AWS-RunShellScript \
        --timeout-seconds 30 \
        --parameters "$params" \
        --query 'Command.CommandId' --output text 2>/dev/null)"; then
      sleep 3
      continue
    fi
    if wait_command "$command_id" "${#ids[@]}" 1; then
      echo "Все узлы отвечают через SSM"
      return 0
    fi
    sleep 3
  done
  echo "Не все узлы стали доступны через SSM" >&2
  return 1
}

wait_runners_ready() {
  local -a ids
  local params command_id
  local attempt
  mapfile -t ids < <(runner_ids)
  params="$(jq -nc '{commands:[
    "set -eu",
    "dpkg-query -W spectral-task >/dev/null",
    "grep -qw nohz_full=2-3 /proc/cmdline",
    "grep -qw rcu_nocbs=2-3 /proc/cmdline",
    "grep -qw irqaffinity=0-1 /proc/cmdline",
    "test \"$(cat /sys/devices/system/cpu/isolated)\" = 2-3",
    "systemctl is-active --quiet spectral-runner-ttl.timer"
  ]}')"

  for attempt in $(seq 1 40); do
    if ! command_id="$(aws ssm send-command \
        --region "$region" \
        --instance-ids "${ids[@]}" \
        --document-name AWS-RunShellScript \
        --timeout-seconds 60 \
        --parameters "$params" \
        --query 'Command.CommandId' --output text 2>/dev/null)"; then
      sleep 3
      continue
    fi
    if wait_command "$command_id" "${#ids[@]}" 1; then
      echo "Все runner-узлы готовы: пакет, CPU isolation и TTL проверены"
      return 0
    fi
    sleep 3
  done
  echo "Runner-узлы не перешли в готовое состояние" >&2
  return 1
}

preflight_results_boundary() {
  local account_id boundary_arn version_id policy
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  boundary_arn="arn:aws:iam::$account_id:policy/spectral-workload-boundary"
  version_id="$(aws iam get-policy \
    --policy-arn "$boundary_arn" \
    --query 'Policy.DefaultVersionId' --output text)"
  policy="$(aws iam get-policy-version \
    --policy-arn "$boundary_arn" \
    --version-id "$version_id" \
    --query 'PolicyVersion.Document' --output json)"
  if ! jq -e '
    any(.Statement[];
      .Effect == "Allow" and
      ((.Action == "s3:PutObject") or
       ((.Action | type) == "array" and (.Action | index("s3:PutObject")))) and
      (.Resource | tostring | contains("/results/*")))
  ' >/dev/null <<<"$policy"; then
    echo "Permissions boundary не разрешает s3:PutObject в results/*." >&2
    echo "Сначала примените infra/bootstrap под временным root-профилем." >&2
    return 1
  fi
}

cmd_up() {
  local package_path bootstrap_id ttl_id state bootstrap_enabled ttl_enabled
  local -a ids
  package_path="$(resolve_package 0)"
  validate_positive_integer AWS_RUNNER_TTL_MINUTES "$runtime_minutes"
  terraform_init

  state="$(${terraform_cmd[@]} state list)"
  bootstrap_enabled="$(current_bootstrap_association_enabled)"
  ttl_enabled="$(current_ttl_association_enabled)"

  # Фаза 1 создаёт только сеть, EC2 и две независимые линии аварийного TTL.
  # Повторный up завершает прерванный apply, но не откатывает уже созданные
  # associations: bootstrap/reboot дорогие и должны выполняться ровно один раз.
  if [[ -z "$state" ]] || \
      ! "${terraform_cmd[@]}" output -json runner_instance_ids >/dev/null 2>&1; then
    terraform_apply "$package_path" "$runtime_minutes" false running false false
    bootstrap_enabled=false
    ttl_enabled=false
  elif [[ "$(current_paused)" == "true" || "$(current_power_state)" != "running" ]]; then
    echo "Существующий кластер нужно запускать через make aws-cluster-start" >&2
    return 1
  fi

  mapfile -t ids < <(all_instance_ids)
  wait_nodes_ssm "${ids[@]}"

  # Фаза 2 ставит пакет и kernel config на уже доступные runner targets.
  if [[ "$bootstrap_enabled" != "true" ]]; then
    terraform_apply "$package_path" "$runtime_minutes" false running true false
    bootstrap_id="$(${terraform_cmd[@]} output -raw bootstrap_association_id)"
    wait_new_association_execution "$bootstrap_id" ""
    wait_runners_ready
    bootstrap_enabled=true
  else
    echo "Bootstrap уже применён; повторная установка пакета и reboot не нужны"
  fi

  # Фаза 3 после reboot выдаёт новый полный TTL и синхронизирует его на всех
  # пяти доступных targets.
  if [[ "$ttl_enabled" != "true" ]]; then
    terraform_apply "$package_path" "$runtime_minutes" false running true true \
      -replace=time_offset.expires
    ttl_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
    wait_new_association_execution "$ttl_id" ""
  else
    echo "Общий TTL уже вооружён"
  fi
  wait_runners_ready
  "${terraform_cmd[@]}" output
}

cmd_update() {
  local package_path old_id association_id current_ttl
  if [[ "$(current_paused)" == "true" ]]; then
    echo "Сначала выполните make aws-cluster-start" >&2
    return 1
  fi
  if [[ "$(current_power_state)" != "running" ]]; then
    echo "EC2 кластера не находятся в желаемом состоянии running" >&2
    return 1
  fi
  package_path="$(resolve_package 0)"
  current_ttl="$(current_runtime_minutes)"
  association_id="$(${terraform_cmd[@]} output -raw bootstrap_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_init
  terraform_apply "$package_path" "$current_ttl" false running true true
  wait_new_association_execution "$association_id" "$old_id"
  wait_runners_ready
}

cmd_extend() {
  local package_path association_id old_id
  if [[ "$(current_paused)" == "true" ]]; then
    echo "Paused-кластер не продлевается; используйте make aws-cluster-start" >&2
    return 1
  fi
  if [[ "$(current_power_state)" != "running" ]]; then
    echo "EC2 кластера не находятся в желаемом состоянии running" >&2
    return 1
  fi
  package_path="$(resolve_package)"
  validate_positive_integer AWS_RUNNER_TTL_MINUTES "$runtime_minutes"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_init
  terraform_apply "$package_path" "$runtime_minutes" false running true true \
    -replace=time_offset.expires
  wait_new_association_execution "$association_id" "$old_id"
  echo "Новый общий TTL: $(${terraform_cmd[@]} output -raw expires_at)"
}

cmd_stop() {
  local package_path ttl association_id old_id
  if [[ "$(current_paused)" == "true" ]]; then
    # Даже если сохранённый output уже равен stopped, apply обязателен: после
    # прерванного start живой EC2 мог успеть перейти в running, а output остаться
    # от предыдущего завершённого apply. Идемпотентный apply устраняет этот drift.
    package_path="$(resolve_package)"
    ttl="$(current_runtime_minutes)"
    terraform_init
    terraform_apply "$package_path" "$ttl" true stopped true true
    echo "Кластер остановлен. Compute не тарифицируется; EBS продолжает храниться."
    return 0
  fi

  # Фаза 1: на ещё работающих узлах Terraform отключает Scheduler и через SSM
  # снимает локальные timers. Фаза 2: Terraform переводит все EC2 в stopped.
  # Свежее защитное окно не даёт старому TTL сработать между этими фазами.
  cmd_extend
  package_path="$(resolve_package)"
  ttl="$(current_runtime_minutes)"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_apply "$package_path" "$ttl" true running true true
  wait_new_association_execution "$association_id" "$old_id"
  terraform_apply "$package_path" "$ttl" true stopped true true
  echo "Кластер остановлен. Compute не тарифицируется; EBS продолжает храниться."
}

cmd_start() {
  local package_path association_id old_id
  local -a ids
  if [[ "$(current_paused)" != "true" ]]; then
    if [[ "$(current_power_state)" == "running" ]]; then
      echo "Кластер уже запущен"
      return 0
    fi
    echo "Неконсистентное состояние: EC2 stopped при включённом TTL" >&2
    return 1
  fi

  package_path="$(resolve_package)"
  terraform_init
  # Фаза 1 поднимает EC2, но оставляет TTL paused: stopped targets не могут
  # выполнить SSM association. После появления всех узлов в SSM фаза 2 одним
  # apply создаёт новый expires_at и вооружает обе линии аварийного завершения.
  if [[ "$(current_power_state)" == "stopped" ]]; then
    terraform_apply "$package_path" "$runtime_minutes" true running true true
  fi
  mapfile -t ids < <(all_instance_ids)
  wait_nodes_ssm "${ids[@]}"
  association_id="$(${terraform_cmd[@]} output -raw ttl_association_id)"
  old_id="$(latest_association_execution "$association_id")"
  terraform_apply "$package_path" "$runtime_minutes" false running true true \
    -replace=time_offset.expires
  wait_new_association_execution "$association_id" "$old_id"
  wait_runners_ready
  echo "Кластер запущен. Общий TTL: $(${terraform_cmd[@]} output -raw expires_at)"
}

fetch_run_artifacts() {
  local run_id="$1"
  local bucket artifact_dir encoded_archive archive_path
  local -a encoded_archives

  if [[ ! "$run_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Некорректный AWS_RUNNER_RUN_ID: $run_id" >&2
    return 2
  fi

  bucket="$(${terraform_cmd[@]} output -raw artifact_bucket)"
  artifact_dir="$repo_root/artifacts/aws-runner/$run_id"
  mkdir -p "$artifact_dir"
  aws s3 cp "s3://$bucket/results/$run_id" "$artifact_dir" --recursive

  mapfile -t encoded_archives < <(
    find "$artifact_dir/artifact" -type f \
      -path '*/awsrunShellScript/0.awsrunShellScript/stdout' -print 2>/dev/null
  )
  if (( ${#encoded_archives[@]} != 1 )); then
    echo "Ожидался ровно один архив SSM для run $run_id, найдено: ${#encoded_archives[@]}" >&2
    return 1
  fi

  encoded_archive="${encoded_archives[0]}"
  archive_path="$artifact_dir/results.tar.gz"
  base64 --decode "$encoded_archive" >"$archive_path"
  tar -xzf "$archive_path" -C "$artifact_dir"
  echo "Результаты run $run_id сохранены в $artifact_dir"
}

cmd_fetch() {
  local run_id="${AWS_RUNNER_RUN_ID:-}"
  local bucket listing

  if [[ -z "$(${terraform_cmd[@]} state list)" ]]; then
    echo "Кластер отсутствует: вместе с ним удалён временный artifact bucket" >&2
    return 1
  fi

  if [[ -z "$run_id" ]]; then
    bucket="$(${terraform_cmd[@]} output -raw artifact_bucket)"
    listing="$(aws s3api list-objects-v2 \
      --region "$region" \
      --bucket "$bucket" \
      --prefix 'results/' \
      --delimiter '/' \
      --output json)"
    run_id="$(jq -r '
      [.CommonPrefixes[]?.Prefix |
       capture("^results/(?<id>[^/]+)/$").id] |
      sort | last // empty
    ' <<<"$listing")"
  fi

  if [[ -z "$run_id" ]]; then
    echo "В artifact bucket ещё нет benchmark runs" >&2
    return 1
  fi
  fetch_run_artifacts "$run_id"
}

cmd_run() {
  local message_count="${AWS_RUNNER_MESSAGE_COUNT:-1000000}"
  local message_rate="${AWS_RUNNER_MESSAGE_RATE:-200000}"
  local source_id receiver_id receiver_ip bucket run_id
  local receiver_params receiver_command_id ready_params ready_command_id
  local ready_status source_params source_command_id artifact_params
  local artifact_command_id artifact_key
  local ready=0
  local attempt
  local -a ids ips

  validate_positive_integer AWS_RUNNER_MESSAGE_COUNT "$message_count"
  validate_positive_integer AWS_RUNNER_MESSAGE_RATE "$message_rate"
  preflight_results_boundary
  cmd_extend

  mapfile -t ids < <(runner_ids)
  mapfile -t ips < <("${terraform_cmd[@]}" output -json runner_private_ips | jq -r '.[]')
  source_id="${ids[0]}"
  receiver_id="${ids[1]}"
  receiver_ip="${ips[1]}"
  bucket="$(${terraform_cmd[@]} output -raw artifact_bucket)"
  run_id="unicast-$(date -u +%Y%m%dT%H%M%SZ)"

  receiver_params="$(jq -Rs \
    --arg count "$message_count" \
    '{commands:[
      "export MESSAGE_COUNT=" + $count + "\n" + .
    ]}' "$script_dir/unicast-receiver.sh")"
  receiver_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$receiver_id" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/receiver" \
    --parameters "$receiver_params" \
    --query 'Command.CommandId' --output text)"

  trap 'if [[ -n "${receiver_command_id:-}" ]]; then
    aws ssm cancel-command --region "$region" \
      --command-id "$receiver_command_id" >/dev/null 2>&1 || true
  fi' EXIT

  ready_params='{"commands":["test -s /tmp/spectral-unicast/READY && cat /tmp/spectral-unicast/READY"]}'
  for attempt in $(seq 1 20); do
    ready_command_id="$(aws ssm send-command \
      --region "$region" \
      --instance-ids "$receiver_id" \
      --document-name AWS-RunShellScript \
      --timeout-seconds 30 \
      --parameters "$ready_params" \
      --query 'Command.CommandId' --output text)"
    if wait_command "$ready_command_id" 1; then
      ready_status="$(aws ssm get-command-invocation \
        --region "$region" --command-id "$ready_command_id" \
        --instance-id "$receiver_id" --query Status --output text)"
      if [[ "$ready_status" == "Success" ]]; then
        ready=1
        break
      fi
    fi
    sleep 1
  done
  if (( ready != 1 )); then
    echo "Receiver и consumer не перешли в READY" >&2
    return 1
  fi

  source_params="$(jq -Rs \
    --arg destination "$receiver_ip" \
    --arg count "$message_count" \
    --arg rate "$message_rate" \
    '{commands:[
      "export DESTINATION=" + $destination + "\n" +
      "export MESSAGE_COUNT=" + $count + "\n" +
      "export MESSAGE_RATE=" + $rate + "\n" + .
    ]}' "$script_dir/unicast-source.sh")"
  source_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$source_id" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/source" \
    --parameters "$source_params" \
    --query 'Command.CommandId' --output text)"

  wait_command "$source_command_id" 1
  wait_command "$receiver_command_id" 1

  echo "--- receiver ---"
  aws ssm get-command-invocation \
    --region "$region" --command-id "$receiver_command_id" \
    --instance-id "$receiver_id" \
    --query StandardOutputContent --output text
  echo "--- source ---"
  aws ssm get-command-invocation \
    --region "$region" --command-id "$source_command_id" \
    --instance-id "$source_id" \
    --query StandardOutputContent --output text
  receiver_command_id=""

  artifact_params='{"commands":["tar -C /tmp -czf - spectral-unicast | base64 -w 76"]}'
  artifact_command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$receiver_id" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 120 \
    --output-s3-bucket-name "$bucket" \
    --output-s3-key-prefix "results/$run_id/artifact" \
    --parameters "$artifact_params" \
    --query 'Command.CommandId' --output text)"
  wait_command "$artifact_command_id" 1

  artifact_key="results/$run_id/artifact/$artifact_command_id/$receiver_id/awsrunShellScript/0.awsrunShellScript/stdout"
  for attempt in $(seq 1 30); do
    if aws s3api head-object --region "$region" \
      --bucket "$bucket" --key "$artifact_key" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if ! aws s3api head-object --region "$region" \
    --bucket "$bucket" --key "$artifact_key" >/dev/null 2>&1; then
    echo "SSM не записал benchmark-артефакт в s3://$bucket/$artifact_key" >&2
    return 1
  fi

  fetch_run_artifacts "$run_id"
  trap - EXIT
}

cmd_status() {
  local state resources
  state="$(${terraform_cmd[@]} state list)"
  if [[ -z "$state" ]]; then
    echo "Кластер отсутствует: Terraform state пуст"
    return
  fi
  "${terraform_cmd[@]}" output
  resources="$(aws ec2 describe-instances \
    --region "$region" \
    --filters \
      Name=tag:Project,Values=spectral-task \
      Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output json)"
  jq . <<<"$resources"
}

cmd_audit() {
  local account_id bucket_name live volumes buckets schedules associations
  local role role_json roles='[]'

  account_id="$(aws sts get-caller-identity --query Account --output text)"
  bucket_name="spectral-runner-source-$account_id-$region"
  live="$(aws ec2 describe-instances \
    --region "$region" \
    --filters \
      Name=tag:Project,Values=spectral-task \
      Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].InstanceId' --output json)"
  volumes="$(aws ec2 describe-volumes \
    --region "$region" \
    --filters Name=tag:Project,Values=spectral-task \
    --query 'Volumes[?State!=`deleted`].VolumeId' --output json)"
  buckets="$(aws s3api list-buckets --query \
    "Buckets[?Name=='$bucket_name'].Name" --output json)"
  schedules="$(aws scheduler list-schedules \
    --region "$region" \
    --name-prefix spectral-runner-expiry- \
    --query 'Schedules[].Name' --output json)"
  associations="$(aws ssm list-associations \
    --region "$region" --output json | jq '[
      .Associations[]? |
      select((.AssociationName // "") | startswith("spectral-runner-")) |
      .AssociationId
    ]')"

  for role in spectral-runner spectral-runner-nat spectral-runner-expiry; do
    if role_json="$(aws iam get-role --role-name "$role" \
        --query 'Role.RoleName' --output json 2>/dev/null)"; then
      roles="$(jq --argjson role "$role_json" '. + [$role]' <<<"$roles")"
    fi
  done

  if jq -e -n \
      --argjson live "$live" \
      --argjson volumes "$volumes" \
      --argjson buckets "$buckets" \
      --argjson schedules "$schedules" \
      --argjson associations "$associations" \
      --argjson roles "$roles" \
      '([$live, $volumes, $buckets, $schedules, $associations, $roles] |
        map(length) | add) == 0' >/dev/null; then
    echo "AWS audit чист: EC2, EBS, S3, Scheduler, SSM Associations и runner IAM roles отсутствуют"
    return 0
  fi

  echo "После destroy найдены AWS-хвосты" >&2
  jq -n \
    --argjson instances "$live" \
    --argjson volumes "$volumes" \
    --argjson buckets "$buckets" \
    --argjson schedules "$schedules" \
    --argjson associations "$associations" \
    --argjson roles "$roles" \
    '{instances:$instances, volumes:$volumes, buckets:$buckets,
      schedules:$schedules, associations:$associations, roles:$roles}' >&2
  return 1
}

cmd_down() {
  local package_path ttl paused power_state bootstrap_enabled ttl_enabled
  local state
  package_path="$(resolve_package)"
  ttl="$(current_runtime_minutes)"
  paused="$(current_paused)"
  power_state="$(current_power_state)"
  bootstrap_enabled="$(current_bootstrap_association_enabled)"
  ttl_enabled="$(current_ttl_association_enabled)"
  run_terraform "${terraform_cmd[@]}" destroy -no-color "${approval_args[@]}" \
    -var="package_path=$package_path" \
    -var="max_runtime_minutes=$ttl" \
    -var="cluster_paused=$paused" \
    -var="cluster_power_state=$power_state" \
    -var="bootstrap_association_enabled=$bootstrap_enabled" \
    -var="ttl_association_enabled=$ttl_enabled"

  state="$(${terraform_cmd[@]} state list)"
  if [[ -n "$state" ]]; then
    echo "Terraform state после destroy не пуст:" >&2
    printf '%s\n' "$state" >&2
    return 1
  fi
  cmd_audit
  echo "Кластер и все проверяемые AWS-ресурсы уничтожены"
}

measure_e2e_phase() {
  local label="$1"
  shift
  local started_at finished_at start_ns finish_ns duration_seconds

  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  start_ns="$(date +%s%N)"
  "$@"
  finish_ns="$(date +%s%N)"
  finished_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  duration_seconds="$(awk -v start="$start_ns" -v finish="$finish_ns" \
    'BEGIN { printf "%.3f", (finish - start) / 1000000000 }')"
  printf '%s\t%s\t%s\t%s\n' \
    "$label" "$started_at" "$finished_at" "$duration_seconds" \
    >>"$e2e_timings_path"
  echo "E2E $label: ${duration_seconds}s"
}

cmd_e2e() {
  local scenario_id
  scenario_id="e2e-$(date -u +%Y%m%dT%H%M%SZ)"
  e2e_timings_path="$repo_root/artifacts/aws-runner/$scenario_id/timings.tsv"
  terraform_log_dir="$repo_root/artifacts/aws-runner/$scenario_id/terraform"
  mkdir -p "$(dirname "$e2e_timings_path")"
  printf 'phase\tstarted_at\tfinished_at\tduration_seconds\n' \
    >"$e2e_timings_path"

  # Cold create измеряется с уже собранным .deb: Make выполняет prerequisite
  # deb до входа сюда. Второй fetch доказывает доступность S3 при stopped EC2.
  measure_e2e_phase down cmd_down
  measure_e2e_phase cold_create cmd_up
  measure_e2e_phase benchmark cmd_run
  measure_e2e_phase first_stop cmd_stop
  measure_e2e_phase stopped_fetch cmd_fetch
  measure_e2e_phase warm_start cmd_start
  measure_e2e_phase final_stop cmd_stop
  cmd_status
  echo "Тайминги E2E сохранены в $e2e_timings_path"
}

require_tools
validate_positive_integer AWS_RUNNER_TTL_MINUTES "$runtime_minutes"

case "${1:-}" in
  up) cmd_up ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  update) cmd_update ;;
  extend) cmd_extend ;;
  run) cmd_run ;;
  fetch) cmd_fetch ;;
  status) cmd_status ;;
  audit) cmd_audit ;;
  down) cmd_down ;;
  e2e) cmd_e2e ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
