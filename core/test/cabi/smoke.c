#include <stdio.h>
#include <stdlib.h>
#include "libhowl.h"

int main(int argc, char** argv) {
    int rc = howl_init();
    if (rc != 0) {
        fprintf(stderr, "howl_init failed: %d\n", rc);
        return 1;
    }

    const char* config_json =
        "{"
        "\"whisper_model_path\":\"/tmp/nonexistent.bin\","
        "\"whisper_model_size\":\"tiny\","
        "\"language\":\"en\","
        "\"disable_noise_suppression\":true,"
        "\"llm_provider\":\"anthropic\","
        "\"llm_model\":\"claude-sonnet-4-6\","
        "\"llm_api_key\":\"sk-ant-test\","
        "\"custom_dict\":[]"
        "}";

    rc = howl_configure((char*)config_json);
    if (rc == 0) {
        fprintf(stderr, "howl_configure unexpectedly succeeded with bogus model path\n");
        return 2;
    }
    char* err = howl_last_error();
    if (err == NULL) {
        fprintf(stderr, "expected non-null howl_last_error, got NULL\n");
        return 3;
    }
    printf("expected error from configure: %s\n", err);
    howl_free_string(err);
    howl_destroy();
    printf("ABI smoke test OK\n");
    return 0;
}
