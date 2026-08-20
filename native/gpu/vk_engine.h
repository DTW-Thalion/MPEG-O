/* native/gpu/vk_engine.h
 *
 * Entry points of the Vulkan engine module. This builds as a separate
 * shared library that libttio_rans loads only when TTIO_GPU=force, so
 * a deployment that never asks for a GPU ships nothing extra and links
 * against no Vulkan loader.
 */
#ifndef TTIO_VK_ENGINE_H
#define TTIO_VK_ENGINE_H

#include "../src/ttio_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Brings up Vulkan and returns an engine, or NULL if there is no
 * usable device. Returning NULL is a normal outcome, not an error:
 * the caller encodes on the CPU instead. Safe to call more than once;
 * the engine is created at most once. */
const ttio_engine *ttio_vk_engine_create(void);

void ttio_vk_engine_destroy(void);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_VK_ENGINE_H */
