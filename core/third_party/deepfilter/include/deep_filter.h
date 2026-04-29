// SPDX-License-Identifier: MIT OR Apache-2.0

#ifndef DEEP_FILTER_H
#define DEEP_FILTER_H

/* Generated with cbindgen:0.29.2 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct DFState DFState;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Create a DeepFilterNet Model
 *
 * Args:
 *     - path: File path to a DeepFilterNet tar.gz onnx model
 *     - atten_lim: Attenuation limit in dB.
 *
 * Returns:
 *     - DF state doing the full processing: stft, DNN noise reduction, istft.
 */
DFState *df_create(const char *path, float atten_lim);

/**
 * Get DeepFilterNet frame size in samples.
 */
uintptr_t df_get_frame_length(DFState *st);

/**
 * Set DeepFilterNet attenuation limit.
 *
 * Args:
 *     - lim_db: New attenuation limit in dB.
 */
void df_set_atten_lim(DFState *st, float lim_db);

/**
 * Set DeepFilterNet post filter beta. A beta of 0 disables the post filter.
 *
 * Args:
 *     - beta: Post filter attenuation. Suitable range between 0.05 and 0;
 */
void df_set_post_filter_beta(DFState *st, float beta);

/**
 * Processes a chunk of samples.
 *
 * Args:
 *     - df_state: Created via df_create()
 *     - input: Input buffer of length df_get_frame_length()
 *     - output: Output buffer of length df_get_frame_length()
 *
 * Returns:
 *     - Local SNR of the current frame.
 */
float df_process_frame(DFState *st, float *input, float *output);

/**
 * Processes a filter bank sample and return raw gains and DF coefs.
 *
 * Args:
 *     - df_state: Created via df_create()
 *     - input: Spectrum of shape `[n_freqs, 2]`.
 *     - out_gains_p: Output buffer of real-valued ERB gains of shape `[nb_erb]`. This function
 *         may set this pointer to NULL if the local SNR is greater 30 dB. No gains need to be
 *         applied then.
 *     - out_coefs_p: Output buffer of complex-valued DF coefs of shape `[df_order, nb_df_freqs, 2]`.
 *         This function may set this pointer to NULL if the local SNR is greater 20 dB. No DF
 *         coefficients need to be applied.
 *
 * Returns:
 *     - Local SNR of the current frame.
 */
float df_process_frame_raw(DFState *st,
                           float *input,
                           float **out_gains_p,
                           float **out_coefs_p);

/**
 * Free a DeepFilterNet Model
 */
void df_free(DFState *model);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* DEEP_FILTER_H */
