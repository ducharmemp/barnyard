default:
        @just --list

deps:
        corral fetch

build target="debug": deps
        @echo "Building the application..."
        corral run -- ponyc src -o out -b stable {{ if target == "debug" { "-d" } else { "--strip" } }} -Dopenssl_3.0.x
        @echo "Build completed."

run: (build "debug")
        @echo "Running the application..."
        ./out/stable

release: (build "release")

test: deps
        @echo "Building the test binary..."
        corral run -- ponyc src/stable -o out -b stable-tests -d -Dopenssl_3.0.x
        @echo "Running tests..."
        ./out/stable-tests

clean:
        rm -rf ./out
