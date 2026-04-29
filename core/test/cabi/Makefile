CORE_DIR := ../..
BUILD := $(CORE_DIR)/build

.PHONY: smoke clean

smoke: $(BUILD)/libvkb.dylib smoke.c
	clang -o smoke smoke.c -I$(BUILD) -L$(BUILD) -lvkb -Wl,-rpath,$(BUILD)
	./smoke

$(BUILD)/libvkb.dylib:
	$(MAKE) -C $(CORE_DIR) build-dylib

clean:
	rm -f smoke
