/* native/src/ttio_engine.h
 *
 * Where a block of V6 qualities gets encoded.
 *
 * There are two implementations. The CPU engine is the segment pool in
 * m94z_v6.c. The GPU engine lives in a separate shared library that is
 * loaded only on explicit opt-in, and is absent on most machines. The
 * codec layer asks the GPU engine for a slot per block and falls back
 * to the CPU engine the moment it cannot get one, so a saturated,
 * missing or unhealthy GPU degrades to today's behaviour rather than
 * stalling or failing.
 *
 * Both engines produce identical bytes for the same job. That is what
 * makes spilling between them safe, and it is enforced as a build gate
 * rather than assumed.
 *
 * Spec: docs/superpowers/specs/2026-08-20-gpu-v6-phase2-encode.md
 */
#ifndef TTIO_ENGINE_H
#define TTIO_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#include "m94z_v6.h"

/* One segment: a run of whole reads. Both engines are handed the same
 * plan rather than deriving it, so they cannot disagree about where
 * segments begin. */
typedef struct {
    size_t   first_read;
    size_t   n_reads;
    uint64_t qual_off;
    uint64_t n_qual;
} v6_seg;

/* One block of work. The segment plan is derived from the read lengths
 * and S by v6_plan, so both engines see the same segmentation and
 * neither re-derives it. bufs/lens are caller-allocated, one entry per
 * segment; lens carries the capacity in and the byte count out. */
typedef struct {
    const ttio_v6_param    *pm;
    const ttio_v6_alphabet *ab;
    const uint8_t          *qual;
    const uint32_t         *read_lengths;
    size_t                  n_reads;
    size_t                  n_qualities;
    uint32_t                seg_symbols;
    int                     threads;
    const v6_seg           *segs;
    size_t                  n_segs;
    uint8_t               **bufs;
    size_t                 *lens;
    int                    *errs;
} ttio_v6_job;

typedef struct ttio_engine {
    const char *name;              /* "cpu" or "vulkan:<device>" */
    int  (*slots)(void);           /* concurrent block slots */
    int  (*try_acquire)(void);     /* nonblocking; 1 = got a slot */
    void (*release)(void);
    int  (*qual_v6_encode)(ttio_v6_job *job);
} ttio_engine;

/* TTIO_GPU selects the engine. It is off unless the caller asks for
 * the GPU explicitly: presence of a device is not evidence that using
 * it is an improvement, and on some machines it is a regression in
 * both speed and output size. Any unrecognised value reads as off,
 * because a typo in a knob should not change how files are written. */
typedef enum {
    TTIO_GPU_OFF   = 0,
    TTIO_GPU_FORCE = 1
} ttio_gpu_mode;

ttio_gpu_mode ttio_gpu_mode_get(void);

/* Tests only: forget the cached value so the environment is read
 * again. Nothing in the library calls this. */
void ttio_gpu_mode_reset(void);

const ttio_engine *ttio_engine_cpu(void);

/* NULL unless the GPU engine was asked for and came up healthy. */
const ttio_engine *ttio_engine_gpu(void);

/* Tests only: stand an engine in for the GPU one, so selection and
 * spill can be exercised without a device. Pass NULL to clear. */
void ttio_engine_set_test_gpu(const ttio_engine *e);

/* The CPU engine's encode entry, implemented in m94z_v6.c next to the
 * segment pool it drives. Declared here rather than in m94z_v6.h so
 * that header does not have to know what a job is. */
int ttio_v6_encode_job_cpu(ttio_v6_job *job);

#endif /* TTIO_ENGINE_H */
