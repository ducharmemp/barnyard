default:
        @just --list

deps:
        corral fetch

build target="debug": deps
        @echo "Building the application..."
        corral run -- ponyc src -o out -b barnyard {{ if target == "debug" { "-d" } else { "--strip" } }} -Dopenssl_3.0.x
        @echo "Build completed."

run: (build "debug")
        @echo "Running the application..."
        ./out/barnyard

release: (build "release")

test: deps
        @echo "Building the test binary..."
        corral run -- ponyc src/barnyard -o out -b barnyard-tests -d -Dopenssl_3.0.x
        @echo "Running tests..."
        ./out/barnyard

clean:
        rm -rf ./out
