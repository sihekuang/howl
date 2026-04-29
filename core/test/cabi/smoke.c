#include <stdio.h>
#include <stdlib.h>
#include "libvkb.h"

int main(int argc, char** argv) {
    int rc = vkb_init();
    if (rc != 0) {
        fprintf(stderr, "vkb_init failed: %d\n", rc);
        return 1;
    }

    const char* config_json =
        "{"
        "\"whisper_model_path\":\"/tmp/nonexistent.bin\","
        "\"whisper_model_size\":\"tiny\","
        "\"language\":\"en\","
        "\"noise_suppression\":false,"
        "\"llm_provider\":\"anthropic\","
        "\"llm_model\":\"claude-sonnet-4-6\","
        "\"llm_api_key\":\"sk-ant-test\","
        "\"custom_dict\":[]"
        "}";

    rc = vkb_configure((char*)config_json);
    if (rc == 0) {
        fprintf(stderr, "vkb_configure unexpectedly succeeded with bogus model path\n");
        return 2;
    }
    char* err = vkb_last_error();
    if (err == NULL) {
        fprintf(stderr, "expected non-null vkb_last_error, got NULL\n");
        return 3;
    }
    printf("expected error from configure: %s\n", err);
    vkb_free_string(err);
    vkb_destroy();
    printf("ABI smoke test OK\n");
    return 0;
}
