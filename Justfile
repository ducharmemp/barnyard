default:
        @just --list

deps:
        corral fetch

# target: debug (-d), release (--strip), or profile (optimized, symbols kept)
build target="debug": deps
        @echo "Building the application..."
        corral run -- ponyc src -o out -b barnyard {{ if target == "debug" { "-d" } else if target == "profile" { "" } else { "--strip" } }} -Dopenssl_3.0.x
        @echo "Build completed."

run: (build "debug")
        @echo "Running the application..."
        ./out/barnyard

release: (build "release")

test: deps
        @echo "Building the test binary..."
        corral run -- ponyc src/barnyard -o out -b barnyard-tests -d -Dopenssl_3.0.x
        @echo "Running tests..."
        ./out/barnyard-tests --sequential

# CPU-profile barnyard under pgbench load; knobs (PROFILE_DURATION,
# PROFILE_CONCURRENCY, PROFILE_MODE) live in bench/env.sh.
profile threads="4": (build "profile")
        bench/profile.sh {{threads}}

clean:
        rm -rf ./out

# Config (ports, pool size, pgbench knobs) lives in bench/env.sh; every value
# can be overridden from the environment, e.g. `DURATION=4 just bench`.
# Full pooler benchmark: direct postgres, barnyard thread sweep, pgbouncer, pgdog.
bench: release _bench-reset
        bench/direct.sh
        for t in ${BARNYARD_THREADS:-2 4 8}; do bench/barnyard.sh "$t"; done
        bench/pgbouncer.sh
        bench/pgdog.sh
        bench/report.sh

bench-direct:
        bench/direct.sh

bench-barnyard threads="4":
        bench/barnyard.sh {{threads}}

bench-pgbouncer:
        bench/pgbouncer.sh

bench-pgdog:
        bench/pgdog.sh

bench-report:
        bench/report.sh

_bench-reset:
        pkill -x barnyard || true
        . bench/env.sh && rm -rf "$OUT_DIR"

# Client-connection saturation: ramp client conns against a small fixed backend
# pool, measuring latency (avg/p50/p95/p99) + throughput per milestone. Reveals
# where each pooler model degrades. Config via SAT_* env vars (see bench/env.sh).
# target: barnyard | pgbouncer | pgdog | direct
bench-saturation target="barnyard": release
	bench/saturation.sh {{target}}
