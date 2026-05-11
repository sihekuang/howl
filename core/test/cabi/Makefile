CORE_DIR := ../..
BUILD := $(CORE_DIR)/build

.PHONY: smoke clean

smoke: $(BUILD)/libhowl.dylib smoke.c
	clang -o smoke smoke.c -I$(BUILD) -L$(BUILD) -lhowl -Wl,-rpath,$(BUILD)
	./smoke

$(BUILD)/libhowl.dylib:
	$(MAKE) -C $(CORE_DIR) build-dylib

clean:
	rm -f smoke
