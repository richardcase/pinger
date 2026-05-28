BINARY   := pinger
MODULE   := github.com/richardcase/pinger
GOFLAGS  := -trimpath
LDFLAGS  := -s -w

.PHONY: all build lint test coverage clean

all: build

build:
	go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BINARY) ./cmd/pinger

lint:
	golangci-lint run ./...

test:
	go test ./...

coverage:
	go test -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out

clean:
	rm -f $(BINARY) coverage.out
