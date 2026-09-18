FUNCTIONS := hello

.PHONY: build clean $(FUNCTIONS:%=build-%)

build: $(FUNCTIONS:%=build-%)

$(FUNCTIONS:%=build-%): build-%:
	cd cmd/$* && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build -tags lambda.norpc -trimpath -ldflags="-s -w" -o ../../build/$*/bootstrap .

clean:
	rm -rf build
