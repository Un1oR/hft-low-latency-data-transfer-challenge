# Standalone build for the fan-out benchmark harness. No external dependencies
# beyond a C++17 compiler and librt (POSIX shared memory).
CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Iinclude
TSAN_CXXFLAGS := -std=c++17 -O1 -g -Wall -Wextra -Iinclude \
	-fsanitize=thread -fno-omit-frame-pointer
LDLIBS   ?= -lrt -lpthread

BIN := bin
BINARIES := $(BIN)/producer $(BIN)/consumer

.PHONY: all clean test test-tsan benchmark

all: $(BINARIES)

$(BIN):
	mkdir -p $(BIN)

$(BIN)/producer: src/producer.cpp include/*.h | $(BIN)
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDLIBS)

$(BIN)/consumer: src/consumer.cpp include/*.h | $(BIN)
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDLIBS)

test: $(BIN)/test_harness
	./$(BIN)/test_harness

test-tsan: $(BIN)/test_harness_tsan $(BIN)/ring_handoff_benchmark_tsan
	TSAN_OPTIONS=halt_on_error=1 ./$(BIN)/test_harness_tsan
	TSAN_OPTIONS=halt_on_error=1 ./$(BIN)/ring_handoff_benchmark_tsan \
		--impl sequence-zero-copy --frame trade --slots 64 --count 10000 \
		--rate 50000 --producer-cpu 4 --consumer-cpu 7
	TSAN_OPTIONS=halt_on_error=1 ./$(BIN)/ring_handoff_benchmark_tsan \
		--impl spsc-zero-copy --frame trade --slots 64 --count 10000 \
		--rate 50000 --producer-cpu 4 --consumer-cpu 7
	TSAN_OPTIONS=halt_on_error=1 ./$(BIN)/ring_handoff_benchmark_tsan \
		--impl split-sequence-zero-copy --frame trade --slots 64 \
		--count 10000 --rate 50000 --producer-cpu 4 --consumer-cpu 7
	TSAN_OPTIONS=halt_on_error=1 ./$(BIN)/ring_handoff_benchmark_tsan \
		--impl dense-sequence-zero-copy --frame trade --slots 64 \
		--count 10000 --rate 50000 --producer-cpu 4 --consumer-cpu 7

benchmark: $(BIN)/ring_benchmark $(BIN)/metrics_benchmark
	./$(BIN)/ring_benchmark
	./$(BIN)/metrics_benchmark

$(BIN)/test_harness: test/test_harness.cpp include/*.h | $(BIN)
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDLIBS)

$(BIN)/test_harness_tsan: test/test_harness.cpp include/*.h | $(BIN)
	$(CXX) $(TSAN_CXXFLAGS) $< -o $@ $(LDLIBS)

$(BIN)/ring_benchmark: benchmark/ring_benchmark.cpp include/*.h | $(BIN)
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDLIBS)

$(BIN)/metrics_benchmark: benchmark/metrics_benchmark.cpp include/*.h | $(BIN)
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDLIBS)

$(BIN)/ring_handoff_benchmark: benchmark/ring_handoff_benchmark.cpp include/*.h | $(BIN)
	$(CXX) $(CXXFLAGS) $< -o $@ $(LDLIBS)

$(BIN)/ring_handoff_benchmark_tsan: benchmark/ring_handoff_benchmark.cpp include/*.h | $(BIN)
	$(CXX) $(TSAN_CXXFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -rf $(BIN)
