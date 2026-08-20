/* native/gpu/vk_engine.c
 *
 * Vulkan engine for M94.Z V6 qualities encode.
 *
 * Every failure path here returns NULL or a nonzero result rather than
 * aborting: the caller always has the CPU engine to fall back on, and a
 * machine without a usable device must behave exactly as it does today.
 *
 * Spec: docs/superpowers/specs/2026-08-20-gpu-v6-phase2-encode.md
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#include "vk_engine.h"

typedef struct {
    VkInstance       inst;
    VkPhysicalDevice phys;
    VkDevice         dev;
    VkQueue          queue;
    uint32_t         qfam;
    char             name[256];

    pthread_mutex_t  slot_mu;
    int              slots_total;
    int              slots_free;

    int              healthy;
} vk_state;

static vk_state          g_vk;
static ttio_engine       g_engine;
static int               g_created;
static const ttio_engine *g_result;

/* ------------------------------------------------------------------ */

static int env_int(const char *name, int dflt) {
    const char *v = getenv(name);
    if (v == NULL || *v == '\0') return dflt;
    int n = atoi(v);
    return n > 0 ? n : dflt;
}

/* The kernel stores 8-bit quality indices and 16-bit model entries, so
 * a device without those storage classes cannot run it at all. */
static int device_supports_storage(VkPhysicalDevice pd) {
    VkPhysicalDeviceVulkan12Features f12 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    };
    VkPhysicalDeviceVulkan11Features f11 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    };
    f11.pNext = &f12;
    VkPhysicalDeviceFeatures2 f2 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
    };
    f2.pNext = &f11;
    vkGetPhysicalDeviceFeatures2(pd, &f2);
    return f12.storageBuffer8BitAccess && f11.storageBuffer16BitAccess;
}

static uint32_t compute_family(VkPhysicalDevice pd) {
    uint32_t n = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, NULL);
    VkQueueFamilyProperties *qs = calloc(n ? n : 1, sizeof *qs);
    if (qs == NULL) return UINT32_MAX;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, qs);
    uint32_t found = UINT32_MAX;
    for (uint32_t i = 0; i < n; i++) {
        if (qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
            found = i;
            break;
        }
    }
    free(qs);
    return found;
}

/* Prefers a discrete GPU, but falls back to whatever is there. The
 * fallback is what lets a software rasteriser run the byte-identity
 * gate on machines with no hardware at all. */
static int pick_device(void) {
    uint32_t n = 0;
    if (vkEnumeratePhysicalDevices(g_vk.inst, &n, NULL) != VK_SUCCESS || n == 0)
        return 0;
    VkPhysicalDevice *pds = calloc(n, sizeof *pds);
    if (pds == NULL) return 0;
    if (vkEnumeratePhysicalDevices(g_vk.inst, &n, pds) != VK_SUCCESS) {
        free(pds);
        return 0;
    }

    int override_idx = env_int("TTIO_GPU_DEVICE", -1);
    VkPhysicalDevice chosen = VK_NULL_HANDLE;

    if (override_idx >= 0 && (uint32_t)override_idx < n) {
        if (device_supports_storage(pds[override_idx]))
            chosen = pds[override_idx];
    } else {
        for (uint32_t i = 0; i < n && chosen == VK_NULL_HANDLE; i++) {
            VkPhysicalDeviceProperties p;
            vkGetPhysicalDeviceProperties(pds[i], &p);
            if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
                && device_supports_storage(pds[i]))
                chosen = pds[i];
        }
        for (uint32_t i = 0; i < n && chosen == VK_NULL_HANDLE; i++) {
            if (device_supports_storage(pds[i]))
                chosen = pds[i];
        }
    }
    free(pds);
    if (chosen == VK_NULL_HANDLE) return 0;

    g_vk.phys = chosen;
    VkPhysicalDeviceProperties p;
    vkGetPhysicalDeviceProperties(g_vk.phys, &p);
    snprintf(g_vk.name, sizeof g_vk.name, "vulkan:%s", p.deviceName);
    g_vk.qfam = compute_family(g_vk.phys);
    return g_vk.qfam != UINT32_MAX;
}

static int create_device(void) {
    VkPhysicalDeviceVulkan12Features f12 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    };
    f12.storageBuffer8BitAccess = VK_TRUE;
    VkPhysicalDeviceVulkan11Features f11 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    };
    f11.storageBuffer16BitAccess = VK_TRUE;
    f11.pNext = &f12;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qi.queueFamilyIndex = g_vk.qfam;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;

    VkDeviceCreateInfo di = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    di.pNext = &f11;
    di.queueCreateInfoCount = 1;
    di.pQueueCreateInfos = &qi;

    if (vkCreateDevice(g_vk.phys, &di, NULL, &g_vk.dev) != VK_SUCCESS)
        return 0;
    vkGetDeviceQueue(g_vk.dev, g_vk.qfam, 0, &g_vk.queue);
    return 1;
}

/* ------------------------------------------------------------------ */

static int vk_slots(void) { return g_vk.slots_total; }

static int vk_try_acquire(void) {
    int got = 0;
    pthread_mutex_lock(&g_vk.slot_mu);
    if (g_vk.healthy && g_vk.slots_free > 0) {
        g_vk.slots_free--;
        got = 1;
    }
    pthread_mutex_unlock(&g_vk.slot_mu);
    return got;
}

static void vk_release(void) {
    pthread_mutex_lock(&g_vk.slot_mu);
    if (g_vk.slots_free < g_vk.slots_total) g_vk.slots_free++;
    pthread_mutex_unlock(&g_vk.slot_mu);
}

static int vk_encode(ttio_v6_job *job) {
    (void)job;
    /* The kernel arrives with the encode task. Until then the engine
     * exists and reports itself but declines work, which the caller
     * handles by encoding on the CPU. */
    return -1;
}

/* ------------------------------------------------------------------ */

const ttio_engine *ttio_vk_engine_create(void) {
    if (g_created) return g_result;
    g_created = 1;

    memset(&g_vk, 0, sizeof g_vk);
    pthread_mutex_init(&g_vk.slot_mu, NULL);

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "ttio";
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ii = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ii.pApplicationInfo = &app;
    if (vkCreateInstance(&ii, NULL, &g_vk.inst) != VK_SUCCESS) return NULL;

    if (!pick_device() || !create_device()) {
        vkDestroyInstance(g_vk.inst, NULL);
        g_vk.inst = VK_NULL_HANDLE;
        return NULL;
    }

    /* Slot sizing from the device's memory arrives with the kernel. */
    g_vk.slots_total = env_int("TTIO_GPU_SLOTS", 1);
    g_vk.slots_free = g_vk.slots_total;
    g_vk.healthy = 1;

    g_engine.name = g_vk.name;
    g_engine.slots = vk_slots;
    g_engine.try_acquire = vk_try_acquire;
    g_engine.release = vk_release;
    g_engine.qual_v6_encode = vk_encode;
    g_result = &g_engine;
    return g_result;
}

void ttio_vk_engine_destroy(void) {
    if (!g_created) return;
    if (g_vk.dev != VK_NULL_HANDLE) vkDestroyDevice(g_vk.dev, NULL);
    if (g_vk.inst != VK_NULL_HANDLE) vkDestroyInstance(g_vk.inst, NULL);
    pthread_mutex_destroy(&g_vk.slot_mu);
    memset(&g_vk, 0, sizeof g_vk);
    g_result = NULL;
    g_created = 0;
}
