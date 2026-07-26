.PHONY: clean boundary build run all

all: clean boundary build run

clean:
	rm -rf ./bin

boundary:
	./check_managed_space_provider_boundary.sh

build:
	mkdir -p ./bin
	clang ./src/tests.m -o ./bin/tests -DTESTS -DPROFILE=1 -F/System/Library/PrivateFrameworks -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight

run:
	./bin/tests
