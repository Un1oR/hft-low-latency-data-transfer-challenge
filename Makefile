SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := all

CMAKE_PRESET ?= release

HARNESS_DIR := $(CURDIR)/harness
HARNESS_BIN := $(HARNESS_DIR)/bin
TRANSPORT_BIN := $(CURDIR)/build/$(CMAKE_PRESET)/bin
CMAKE_CACHE := $(CURDIR)/build/$(CMAKE_PRESET)/CMakeCache.txt
BENCH_GROUP := spectral-bench
NETNS_EXEC_SOURCE := $(CURDIR)/tools/spectral-netns-exec
NETNS_EXEC := /usr/local/libexec/spectral-netns-exec
SUDOERS_SOURCE := $(CURDIR)/config/sudoers.d/spectral-task
SUDOERS_DEST := /etc/sudoers.d/spectral-task
SUDO := sudo -n
IP := /usr/bin/ip
TC := /usr/sbin/tc
TASKSET := /usr/bin/taskset

TX_NAMESPACE := spectral-tx
RX_NAMESPACE := spectral-rx
TX_INTERFACE := veth-tx
RX_INTERFACE := veth-rx
TX_CIDR := 10.200.0.1/30
RX_CIDR := 10.200.0.2/30
TX_ADDRESS := 10.200.0.1
RX_ADDRESS := 10.200.0.2

PRODUCER_CPU ?= 4
SENDER_CPU ?= 5
RECEIVER_CPU ?= 6
CONSUMER_CPU ?= 7

TX_SHM ?= /spectral_tx
RX_SHM ?= /spectral_rx
SHM_SLOTS ?= 65536
MESSAGE_COUNT ?= 1000000
MESSAGE_RATE ?= 100000
MESSAGE_TYPE ?= mixed
UDP_PORT ?= 9000
IDLE_MS ?= 2000
LATENCY_CSV ?=
DIRECT_SHM ?= /spectral_direct
DIRECT_PINNED ?= 1

NETEM_DELAY ?= 0us
NETEM_JITTER ?= 0us
NETEM_LOSS ?= 0%
NETEM_LIMIT ?= 100000

define producer_command
$(TASKSET) -c "$(PRODUCER_CPU)" "$(HARNESS_BIN)/producer" \
	--shm "$(1)" --slots "$(2)" \
	--count "$(3)" --rate "$(4)" --type "$(5)"
endef

define sender_command
$(1) $(TASKSET) -c "$(SENDER_CPU)" "$(TRANSPORT_BIN)/sender" \
	--shm "$(2)" --slots "$(3)" \
	--dest "$(4)" --port "$(5)" \
	--count "$(6)" --from-edge --idle-ms "$(7)"
endef

define receiver_command
$(1) $(TASKSET) -c "$(RECEIVER_CPU)" "$(TRANSPORT_BIN)/receiver" \
	--shm "$(2)" --slots "$(3)" \
	--bind "$(4)" --port "$(5)" \
	--count "$(6)" --idle-ms "$(7)"
endef

define consumer_command
$(TASKSET) -c "$(CONSUMER_CPU)" "$(HARNESS_BIN)/consumer" \
	--shm "$(1)" --slots "$(2)" \
	--count "$(3)" --from-edge --idle-ms "$(4)" \
	$(if $(strip $(LATENCY_CSV)),--csv "$(LATENCY_CSV)")
endef

.PHONY: \
	all configure transport-build harness-build build test clean help setup-sudo \
	net-up net-status netem-set netem-clear net-down \
	run-test run-direct-test \
	run-producer run-sender run-receiver run-consumer \
	process-status shm-clean

all: build

configure: $(CMAKE_CACHE)

$(CMAKE_CACHE): CMakeLists.txt CMakePresets.json
	@cmake --preset "$(CMAKE_PRESET)"

transport-build: $(CMAKE_CACHE)
	@cmake --build --preset "$(CMAKE_PRESET)" --parallel

harness-build:
	@$(MAKE) --no-print-directory -C "$(HARNESS_DIR)" all

build: harness-build transport-build

test: build
	@$(MAKE) --no-print-directory -C "$(HARNESS_DIR)" test
	$(MAKE) --no-print-directory net-up
	$(MAKE) --no-print-directory run-test \
		MESSAGE_COUNT=5000 MESSAGE_RATE=5000 IDLE_MS=500
	grep -q 'dropped      : 0' "$(CURDIR)/build/run-test/consumer.log"

setup-sudo:
	@set -euo pipefail
	setup_user=$$(id -un)
	if [[ "$$setup_user" == "root" ]]; then
		echo "setup-sudo: run make as the user who will execute tests" >&2
		exit 2
	fi
	/bin/bash -n "$(NETNS_EXEC_SOURCE)"
	/usr/sbin/visudo -cf "$(SUDOERS_SOURCE)"
	sudo -v
	sudo /usr/sbin/groupadd --force "$(BENCH_GROUP)"
	sudo /usr/sbin/usermod --append --groups "$(BENCH_GROUP)" "$$setup_user"
	sudo /usr/bin/install -d -o root -g root -m 0755 "/usr/local/libexec"
	sudo /usr/bin/install -o root -g root -m 0755 \
		"$(NETNS_EXEC_SOURCE)" "$(NETNS_EXEC)"
	sudo /usr/bin/install -o root -g root -m 0440 \
		"$(SUDOERS_SOURCE)" "$(SUDOERS_DEST)"
	sudo /usr/sbin/visudo -cf "$(SUDOERS_DEST)"
	echo "setup-sudo: installed for group $(BENCH_GROUP)"
	if ! id -nG | tr ' ' '\n' | grep -Fxq "$(BENCH_GROUP)"; then
		echo "setup-sudo: log out and back in before running network targets"
	fi

clean:
	@$(MAKE) --no-print-directory -C "$(HARNESS_DIR)" clean
	if [[ -f "build/$(CMAKE_PRESET)/build.ninja" ]]; then
		cmake --build --preset "$(CMAKE_PRESET)" --target clean
	fi

net-up:
	@set -euo pipefail
	ns_exists() {
		$(IP) netns list | awk '{print $$1}' | grep -Fxq "$$1"
	}
	for namespace in "$(TX_NAMESPACE)" "$(RX_NAMESPACE)"; do
		if ! ns_exists "$$namespace"; then
			$(SUDO) $(IP) netns add "$$namespace"
		fi
	done
	tx_present=0
	rx_present=0
	if $(SUDO) $(NETNS_EXEC) "$(TX_NAMESPACE)" \
	   $(IP) link show dev "$(TX_INTERFACE)" >/dev/null 2>&1; then
		tx_present=1
	fi
	if $(SUDO) $(NETNS_EXEC) "$(RX_NAMESPACE)" \
	   $(IP) link show dev "$(RX_INTERFACE)" >/dev/null 2>&1; then
		rx_present=1
	fi
	if (( tx_present != rx_present )); then
		echo "net-up: incomplete veth pair; inspect with 'make net-status'" >&2
		exit 1
	fi
	if (( tx_present == 0 )); then
		for interface in "$(TX_INTERFACE)" "$(RX_INTERFACE)"; do
			if $(IP) link show dev "$$interface" >/dev/null 2>&1; then
				echo "net-up: interface $$interface already exists in the host namespace" >&2
				exit 1
			fi
		done
		$(SUDO) $(IP) link add "$(TX_INTERFACE)" type veth peer name "$(RX_INTERFACE)"
		$(SUDO) $(IP) link set "$(TX_INTERFACE)" netns "$(TX_NAMESPACE)"
		$(SUDO) $(IP) link set "$(RX_INTERFACE)" netns "$(RX_NAMESPACE)"
	fi
	$(SUDO) $(IP) -n "$(TX_NAMESPACE)" address replace "$(TX_CIDR)" dev "$(TX_INTERFACE)"
	$(SUDO) $(IP) -n "$(RX_NAMESPACE)" address replace "$(RX_CIDR)" dev "$(RX_INTERFACE)"
	$(SUDO) $(IP) -n "$(TX_NAMESPACE)" link set lo up
	$(SUDO) $(IP) -n "$(RX_NAMESPACE)" link set lo up
	$(SUDO) $(IP) -n "$(TX_NAMESPACE)" link set "$(TX_INTERFACE)" mtu 1500 up
	$(SUDO) $(IP) -n "$(RX_NAMESPACE)" link set "$(RX_INTERFACE)" mtu 1500 up
	for spec in \
		"$(TX_NAMESPACE) $(TX_INTERFACE)" \
		"$(RX_NAMESPACE) $(RX_INTERFACE)"; do
		read -r namespace interface <<<"$$spec"
		if $(SUDO) $(NETNS_EXEC) "$$namespace" \
		   $(TC) qdisc show dev "$$interface" | \
		   grep -q '^qdisc netem '; then
			$(SUDO) $(IP) netns exec "$$namespace" \
				$(TC) qdisc del dev "$$interface" root
		fi
	done
	$(SUDO) $(NETNS_EXEC) "$(TX_NAMESPACE)" \
		$(IP) route get "$(RX_ADDRESS)" >/dev/null
	$(SUDO) $(NETNS_EXEC) "$(RX_NAMESPACE)" \
		$(IP) route get "$(TX_ADDRESS)" >/dev/null
	echo "net-up: $(TX_ADDRESS) <-> $(RX_ADDRESS), clean profile"

net-status:
	@set -euo pipefail
	ns_exists() {
		$(IP) netns list | awk '{print $$1}' | grep -Fxq "$$1"
	}
	for spec in \
		"$(TX_NAMESPACE) $(TX_INTERFACE)" \
		"$(RX_NAMESPACE) $(RX_INTERFACE)"; do
		read -r namespace interface <<<"$$spec"
		echo "[$$namespace]"
		if ! ns_exists "$$namespace"; then
			echo "missing"
			continue
		fi
		$(SUDO) $(NETNS_EXEC) "$$namespace" \
			$(IP) -brief address show dev "$$interface"
		$(SUDO) $(NETNS_EXEC) "$$namespace" \
			$(TC) -s qdisc show dev "$$interface"
		pids=$$($(IP) netns pids "$$namespace")
		if [[ -n "$$pids" ]]; then
			echo "pids: $$(tr '\n' ' ' <<<"$$pids")"
		else
			echo "pids: none"
		fi
	done

netem-set:
	@set -euo pipefail
	delay='$(NETEM_DELAY)'
	jitter='$(NETEM_JITTER)'
	loss='$(NETEM_LOSS)'
	limit='$(NETEM_LIMIT)'
	duration_re='^([0-9]+([.][0-9]+)?)(ns|us|ms|s)$$'
	loss_re='^([0-9]+([.][0-9]+)?)%$$'
	zero_duration_re='^0+([.]0+)?(ns|us|ms|s)$$'
	zero_loss_re='^0+([.]0+)?%$$'
	if [[ ! "$$delay" =~ $$duration_re ]]; then
		echo "netem-set: invalid NETEM_DELAY=$$delay" >&2
		exit 2
	fi
	if [[ ! "$$jitter" =~ $$duration_re ]]; then
		echo "netem-set: invalid NETEM_JITTER=$$jitter" >&2
		exit 2
	fi
	if [[ ! "$$loss" =~ $$loss_re ]]; then
		echo "netem-set: invalid NETEM_LOSS=$$loss" >&2
		exit 2
	fi
	if [[ ! "$$limit" =~ ^[1-9][0-9]*$$ ]]; then
		echo "netem-set: invalid NETEM_LIMIT=$$limit" >&2
		exit 2
	fi
	loss_number="$${loss::-1}"
	if ! awk -v value="$$loss_number" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
		echo "netem-set: NETEM_LOSS must be in 0..100%" >&2
		exit 2
	fi
	if [[ ! "$$jitter" =~ $$zero_duration_re && "$$delay" =~ $$zero_duration_re ]]; then
		echo "netem-set: NETEM_JITTER requires a non-zero NETEM_DELAY" >&2
		exit 2
	fi
	if [[ "$$delay" =~ $$zero_duration_re && "$$jitter" =~ $$zero_duration_re && \
	      "$$loss" =~ $$zero_loss_re ]]; then
		echo "netem-set: use 'make netem-clear' for the clean profile" >&2
		exit 2
	fi
	netem_args=(limit "$$limit")
	if [[ ! "$$delay" =~ $$zero_duration_re ]]; then
		netem_args+=(delay "$$delay")
		if [[ ! "$$jitter" =~ $$zero_duration_re ]]; then
			netem_args+=("$$jitter")
		fi
	fi
	if [[ ! "$$loss" =~ $$zero_loss_re ]]; then
		netem_args+=(loss "$$loss")
	fi
	for spec in \
		"$(TX_NAMESPACE) $(TX_INTERFACE)" \
		"$(RX_NAMESPACE) $(RX_INTERFACE)"; do
		read -r namespace interface <<<"$$spec"
		if ! $(SUDO) $(NETNS_EXEC) "$$namespace" \
		     $(IP) link show dev "$$interface" >/dev/null 2>&1; then
			echo "netem-set: network is down; run 'make net-up'" >&2
			exit 1
		fi
	done
	for spec in \
		"$(TX_NAMESPACE) $(TX_INTERFACE)" \
		"$(RX_NAMESPACE) $(RX_INTERFACE)"; do
		read -r namespace interface <<<"$$spec"
		$(SUDO) $(IP) netns exec "$$namespace" \
			$(TC) qdisc replace dev "$$interface" root netem "$${netem_args[@]}"
	done
	echo "netem-set: delay=$$delay jitter=$$jitter loss=$$loss limit=$$limit"

netem-clear:
	@set -euo pipefail
	ns_exists() {
		$(IP) netns list | awk '{print $$1}' | grep -Fxq "$$1"
	}
	for spec in \
		"$(TX_NAMESPACE) $(TX_INTERFACE)" \
		"$(RX_NAMESPACE) $(RX_INTERFACE)"; do
		read -r namespace interface <<<"$$spec"
		if ns_exists "$$namespace" && \
		   $(SUDO) $(NETNS_EXEC) "$$namespace" \
		       $(IP) link show dev "$$interface" >/dev/null 2>&1 && \
		   $(SUDO) $(NETNS_EXEC) "$$namespace" \
		       $(TC) qdisc show dev "$$interface" | \
		       grep -q '^qdisc netem '; then
			$(SUDO) $(IP) netns exec "$$namespace" \
				$(TC) qdisc del dev "$$interface" root
		fi
	done
	echo "netem-clear: clean profile"

net-down:
	@set -euo pipefail
	ns_exists() {
		$(IP) netns list | awk '{print $$1}' | grep -Fxq "$$1"
	}
	active=0
	for namespace in "$(TX_NAMESPACE)" "$(RX_NAMESPACE)"; do
		if ns_exists "$$namespace"; then
			pids=$$($(IP) netns pids "$$namespace")
			if [[ -n "$$pids" ]]; then
				echo "net-down: $$namespace has active processes:" >&2
				ps -o pid,comm,args -p "$$(paste -sd, <<<"$$pids")" >&2
				active=1
			fi
		fi
	done
	if (( active != 0 )); then
		exit 1
	fi
	for namespace in "$(TX_NAMESPACE)" "$(RX_NAMESPACE)"; do
		if ns_exists "$$namespace"; then
			$(SUDO) $(IP) netns delete "$$namespace"
		fi
	done
	echo "net-down: removed $(TX_NAMESPACE) and $(RX_NAMESPACE)"

run-direct-test:
	@set -euo pipefail
	for binary in "$(HARNESS_BIN)/producer" "$(HARNESS_BIN)/consumer"; do
		if [[ ! -x "$$binary" ]]; then
			echo "run-direct-test: missing $$binary; run 'make build'" >&2
			exit 1
		fi
	done
	pinned="$(DIRECT_PINNED)"
	if [[ "$$pinned" != 0 && "$$pinned" != 1 ]]; then
		echo "run-direct-test: DIRECT_PINNED must be 0 or 1" >&2
		exit 2
	fi
	shm_name="$(DIRECT_SHM)"
	name_re='^/[A-Za-z0-9_.-]+$$'
	if [[ ! "$$shm_name" =~ $$name_re ]]; then
		echo "run-direct-test: invalid shared-memory name" >&2
		exit 2
	fi
	shm_file="/dev/shm/$${shm_name#/}"
	latency_csv="$(LATENCY_CSV)"
	if [[ -n "$$latency_csv" ]]; then
		mkdir -p "$$(dirname -- "$$latency_csv")"
		rm -f -- "$$latency_csv"
	fi
	consumer_args=(--shm "$$shm_name" --slots "$(SHM_SLOTS)" --from-edge \
		--count "$(MESSAGE_COUNT)" --idle-ms "$(IDLE_MS)")
	if [[ -n "$$latency_csv" ]]; then
		consumer_args+=(--csv "$$latency_csv")
	fi
	log_dir="$(CURDIR)/build/run-direct-test"
	mkdir -p "$$log_dir"
	rm -f -- "$$log_dir/producer.log" "$$log_dir/consumer.log" "$$shm_file"
	producer_prefix=()
	consumer_prefix=()
	if [[ "$$pinned" == 1 ]]; then
		producer_prefix=($(TASKSET) -c "$(PRODUCER_CPU)")
		consumer_prefix=($(TASKSET) -c "$(CONSUMER_CPU)")
	fi
	producer_pid=""
	cleanup() {
		if [[ -n "$$producer_pid" ]] && kill -0 "$$producer_pid" 2>/dev/null; then
			kill "$$producer_pid" 2>/dev/null || true
		fi
		if [[ -n "$$producer_pid" ]]; then
			wait "$$producer_pid" 2>/dev/null || true
		fi
		rm -f -- "$$shm_file"
	}
	trap cleanup EXIT INT TERM
	"$${producer_prefix[@]}" "$(HARNESS_BIN)/producer" \
		--shm "$$shm_name" --slots "$(SHM_SLOTS)" --count 0 \
		--rate "$(MESSAGE_RATE)" --type "$(MESSAGE_TYPE)" \
		>"$$log_dir/producer.log" 2>&1 &
	producer_pid=$$!
	for _ in $$(seq 1 200); do
		if grep -q '^producer: shm=' "$$log_dir/producer.log" 2>/dev/null; then break; fi
		if ! kill -0 "$$producer_pid" 2>/dev/null; then break; fi
		sleep 0.01
	done
	if ! grep -q '^producer: shm=' "$$log_dir/producer.log"; then
		sed -n '1,200p' "$$log_dir/producer.log" >&2
		exit 1
	fi
	set +e
	"$${consumer_prefix[@]}" "$(HARNESS_BIN)/consumer" \
		"$${consumer_args[@]}" \
		>"$$log_dir/consumer.log" 2>&1
	consumer_status=$$?
	set -e
	cleanup
	producer_pid=""
	trap - EXIT INT TERM
	if (( consumer_status != 0 )); then
		for log in producer consumer; do
			echo "--- $$log ---" >&2
			sed -n '1,200p' "$$log_dir/$$log.log" >&2
		done
		exit 1
	fi
	if [[ -n "$$latency_csv" && ! -s "$$latency_csv" ]]; then
		echo "run-direct-test: consumer did not write $$latency_csv" >&2
		exit 1
	fi
	sed -n '1,200p' "$$log_dir/consumer.log"
	if [[ -n "$$latency_csv" ]]; then
		echo "run-direct-test: latency samples saved in $$latency_csv"
	fi
	echo "run-direct-test: logs saved in $$log_dir"

run-test:
	@set -euo pipefail
	for binary in \
		"$(HARNESS_BIN)/producer" "$(HARNESS_BIN)/consumer" \
		"$(TRANSPORT_BIN)/sender" "$(TRANSPORT_BIN)/receiver"; do
		if [[ ! -x "$$binary" ]]; then
			echo "run-test: missing $$binary; run 'make build'" >&2
			exit 1
		fi
	done
	tx_name="$(TX_SHM)"
	rx_name="$(RX_SHM)"
	slots="$(SHM_SLOTS)"
	message_count="$(MESSAGE_COUNT)"
	message_rate="$(MESSAGE_RATE)"
	message_type="$(MESSAGE_TYPE)"
	bind_address="$(RX_ADDRESS)"
	destination="$(RX_ADDRESS)"
	port="$(UDP_PORT)"
	idle_ms="$(IDLE_MS)"
	latency_csv="$(LATENCY_CSV)"
	if [[ -n "$$latency_csv" ]]; then
		mkdir -p "$$(dirname -- "$$latency_csv")"
		rm -f -- "$$latency_csv"
	fi
	sender_exec=($(SUDO) $(NETNS_EXEC) "$(TX_NAMESPACE)")
	receiver_exec=($(SUDO) $(NETNS_EXEC) "$(RX_NAMESPACE)")
	for spec in \
		"$(TX_NAMESPACE) $(TX_INTERFACE)" \
		"$(RX_NAMESPACE) $(RX_INTERFACE)"; do
		read -r namespace interface <<<"$$spec"
		if ! $(SUDO) $(NETNS_EXEC) "$$namespace" \
		     $(IP) link show dev "$$interface" >/dev/null 2>&1; then
			echo "run-test: network is down; run 'make net-up'" >&2
			exit 1
		fi
	done
	name_re='^/[A-Za-z0-9_.-]+$$'
	if [[ ! "$$tx_name" =~ $$name_re || ! "$$rx_name" =~ $$name_re ]]; then
		echo "run-test: invalid shared-memory name" >&2
		exit 2
	fi
	tx_file="/dev/shm/$${tx_name#/}"
	rx_file="/dev/shm/$${rx_name#/}"
	rm -f -- "$$tx_file" "$$rx_file"
	log_dir="$(CURDIR)/build/run-test"
	mkdir -p "$$log_dir"
	rm -f -- \
		"$$log_dir/receiver.log" "$$log_dir/consumer.log" \
		"$$log_dir/producer.log" "$$log_dir/sender.log"
	receiver_pid=""
	consumer_pid=""
	producer_pid=""
	sender_pid=""
	cleanup() {
		for pid in "$$sender_pid" "$$producer_pid" "$$consumer_pid" "$$receiver_pid"; do
			if [[ -n "$$pid" ]] && kill -0 "$$pid" 2>/dev/null; then
				kill "$$pid" 2>/dev/null || true
			fi
		done
		for pid in "$$sender_pid" "$$producer_pid" "$$consumer_pid" "$$receiver_pid"; do
			if [[ -n "$$pid" ]]; then
				wait "$$pid" 2>/dev/null || true
			fi
		done
		rm -f -- "$$tx_file" "$$rx_file"
	}
	trap cleanup EXIT INT TERM
	$(call receiver_command,"$${receiver_exec[@]}",$$rx_name,$$slots,$$bind_address,$$port,$$message_count,$$idle_ms) \
		>"$$log_dir/receiver.log" 2>&1 &
	receiver_pid=$$!
	for _ in $$(seq 1 200); do
		if grep -q '^receiver: bind=' "$$log_dir/receiver.log" 2>/dev/null; then break; fi
		if ! kill -0 "$$receiver_pid" 2>/dev/null; then break; fi
		sleep 0.01
	done
	if ! grep -q '^receiver: bind=' "$$log_dir/receiver.log"; then
		sed -n '1,200p' "$$log_dir/receiver.log" >&2
		exit 1
	fi
	$(call consumer_command,$$rx_name,$$slots,$$message_count,$$idle_ms) \
		>"$$log_dir/consumer.log" 2>&1 &
	consumer_pid=$$!
	$(call producer_command,$$tx_name,$$slots,$$message_count,$$message_rate,$$message_type) \
		>"$$log_dir/producer.log" 2>&1 &
	producer_pid=$$!
	for _ in $$(seq 1 200); do
		if grep -q '^producer: shm=' "$$log_dir/producer.log" 2>/dev/null; then break; fi
		if ! kill -0 "$$producer_pid" 2>/dev/null; then break; fi
		sleep 0.01
	done
	if ! grep -q '^producer: shm=' "$$log_dir/producer.log"; then
		sed -n '1,200p' "$$log_dir/producer.log" >&2
		exit 1
	fi
	$(call sender_command,"$${sender_exec[@]}",$$tx_name,$$slots,$$destination,$$port,$$message_count,$$idle_ms) \
		>"$$log_dir/sender.log" 2>&1 &
	sender_pid=$$!
	set +e
	wait "$$producer_pid"; producer_status=$$?
	wait "$$sender_pid"; sender_status=$$?
	wait "$$receiver_pid"; receiver_status=$$?
	wait "$$consumer_pid"; consumer_status=$$?
	set -e
	producer_pid=""
	sender_pid=""
	receiver_pid=""
	consumer_pid=""
	if (( producer_status != 0 || sender_status != 0 || \
	      receiver_status != 0 || consumer_status != 0 )); then
		for log in producer sender receiver consumer; do
			echo "--- $$log ---" >&2
			sed -n '1,200p' "$$log_dir/$$log.log" >&2
		done
		exit 1
	fi
	received=$$(awk '/^received[[:space:]]*:/ { print $$3 }' "$$log_dir/consumer.log")
	if [[ -z "$$received" || "$$received" == 0 ]]; then
		echo "run-test: consumer received no frames" >&2
		for log in producer sender receiver consumer; do
			echo "--- $$log ---" >&2
			sed -n '1,200p' "$$log_dir/$$log.log" >&2
		done
		exit 1
	fi
	if [[ -n "$$latency_csv" && ! -s "$$latency_csv" ]]; then
		echo "run-test: consumer did not write $$latency_csv" >&2
		exit 1
	fi
	sed -n '1,200p' "$$log_dir/sender.log"
	sed -n '1,200p' "$$log_dir/receiver.log"
	sed -n '1,200p' "$$log_dir/consumer.log"
	if [[ -n "$$latency_csv" ]]; then
		echo "run-test: latency samples saved in $$latency_csv"
	fi
	echo "run-test: logs saved in $$log_dir"

run-producer:
	@$(call producer_command,$(TX_SHM),$(SHM_SLOTS),$(MESSAGE_COUNT),$(MESSAGE_RATE),$(MESSAGE_TYPE))

run-sender:
	@set -euo pipefail
	$(SUDO) $(NETNS_EXEC) "$(TX_NAMESPACE)" \
		$(IP) link show dev "$(TX_INTERFACE)" >/dev/null
	$(call sender_command,$(SUDO) $(NETNS_EXEC) "$(TX_NAMESPACE)",$(TX_SHM),$(SHM_SLOTS),$(RX_ADDRESS),$(UDP_PORT),$(MESSAGE_COUNT),$(IDLE_MS))

run-receiver:
	@set -euo pipefail
	$(SUDO) $(NETNS_EXEC) "$(RX_NAMESPACE)" \
		$(IP) link show dev "$(RX_INTERFACE)" >/dev/null
	$(call receiver_command,$(SUDO) $(NETNS_EXEC) "$(RX_NAMESPACE)",$(RX_SHM),$(SHM_SLOTS),$(RX_ADDRESS),$(UDP_PORT),$(MESSAGE_COUNT),$(IDLE_MS))

run-consumer:
	@$(call consumer_command,$(RX_SHM),$(SHM_SLOTS),$(MESSAGE_COUNT),$(IDLE_MS))

process-status:
	@set -euo pipefail
	for process_name in producer sender receiver consumer; do
		mapfile -t pids < <(pgrep -x "$$process_name" || true)
		if (( $${#pids[@]} == 0 )); then
			echo "[$$process_name] not running"
			continue
		fi
		for pid in "$${pids[@]}"; do
			echo "[$$process_name pid=$$pid]"
			for task in /proc/"$$pid"/task/*; do
				tid=$${task##*/}
				$(TASKSET) -pc "$$tid"
			done
		done
	done

shm-clean:
	@set -euo pipefail
	tx_name='$(TX_SHM)'
	rx_name='$(RX_SHM)'
	name_re='^/[A-Za-z0-9_.-]+$$'
	if [[ ! "$$tx_name" =~ $$name_re || ! "$$rx_name" =~ $$name_re ]]; then
		echo "shm-clean: invalid shared-memory name" >&2
		exit 2
	fi
	tx_file="/dev/shm/$${tx_name#/}"
	rx_file="/dev/shm/$${rx_name#/}"
	rm -f -- "$$tx_file" "$$rx_file"
	echo "shm-clean: removed $$tx_file and $$rx_file"

help:
	@echo "Build and verification:"
	echo "  make build                  build legacy harness and C++23 transport"
	echo "  make test                   build and run unit and clean-veth tests"
	echo
	echo "Machine setup:"
	echo "  make setup-sudo             install scoped passwordless network access"
	echo
	echo "Virtual network:"
	echo "  make net-up                 create clean namespace/veth link"
	echo "  make net-status             show addresses, qdisc counters, and PIDs"
	echo "  make netem-set NETEM_DELAY=50us NETEM_LOSS=0.1%"
	echo "  make netem-clear            remove emulation from the link"
	echo "  make net-down               remove the test network"
	echo
	echo "End-to-end tests (run 'make build' after code changes):"
	echo "  make run-direct-test        direct producer-to-consumer SHM path"
	echo "  make run-test               use the active veth/netem configuration"
	echo
	echo "Individual processes (one foreground command per terminal):"
	echo "  make run-receiver"
	echo "  make run-consumer"
	echo "  make run-producer"
	echo "  make run-sender"
	echo "  make process-status"
