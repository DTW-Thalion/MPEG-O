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
#include <time.h>
#include <vulkan/vulkan.h>

#include "vk_engine.h"
#include "v6_spv.h"

typedef struct {
    VkInstance       inst;
    VkPhysicalDevice phys;
    VkDevice         dev;
    VkQueue          queue;
    uint32_t         qfam;
    /* VK_MAX_PHYSICAL_DEVICE_NAME_SIZE plus room for the prefix. */
    char             name[288];

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

static uint64_t device_local_bytes(void) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(g_vk.phys, &mp);
    uint64_t best = 0;
    for (uint32_t i = 0; i < mp.memoryHeapCount; i++) {
        if ((mp.memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT)
            && mp.memoryHeaps[i].size > best)
            best = mp.memoryHeaps[i].size;
    }
    return best;
}

/* How much memory one in-flight block needs, near enough to size the
 * slot count before any job has arrived: a 64 MiB block of qualities,
 * its compressed output, and one model per segment. At the shipped
 * defaults that is 256 segments of 2^11 contexts over a 64-symbol
 * alphabet, which is about 68 MB of model. Half the device-local heap
 * is left for the display and other processes. */
#define VK_EST_BLOCK_WORKING_SET (256ull * 1024ull * 1024ull)

static int default_slots(void) {
    uint64_t usable = device_local_bytes() / 2;
    uint64_t n = usable / VK_EST_BLOCK_WORKING_SET;
    if (n < 1) n = 1;
    if (n > 64) n = 64;
    return (int)n;
}

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

/* ---- buffers ------------------------------------------------------ */

typedef struct {
    VkBuffer       buf;
    VkDeviceMemory mem;
    VkDeviceSize   size;
    void          *mapped;
} vk_buf;

enum { VK_BUF_Q = 0, VK_BUF_L, VK_BUF_C, VK_BUF_M, VK_BUF_TF, VK_BUF_O,
       VK_BUF_OL, VK_BUF_T, VK_BUF_QM, VK_BUF_COUNT };

#define VK_MAX_SLOTS 8

/* One slot is one block in flight. A 64 MiB block yields only 256
 * chains at the default segment size, which does not fill this class of
 * device; running several blots at once is the way to raise the chain
 * count without shrinking segments and paying for it in ratio.
 *
 * Everything a block touches while encoding lives here, because none of
 * it can be shared between concurrent blocks: buffers hold that block's
 * data, and command pools are not thread safe. */
typedef struct {
    vk_buf          buf[VK_BUF_COUNT];
    VkDescriptorSet dset;
    VkCommandPool   cpool;
    VkCommandBuffer cb;
    VkFence         fence;
    int             busy;
} vk_slot;

/* Immutable once built, so every slot shares them. */
typedef struct {
    VkDescriptorSetLayout dsl;
    VkDescriptorPool      dpool;
    VkPipelineLayout      playout;
    VkShaderModule        shader;
    VkPipeline            pipe;
    uint32_t              lsz;
    int                   ready;
} vk_shared;

static vk_shared       g_sh;
static vk_slot         g_slot[VK_MAX_SLOTS];
static pthread_mutex_t g_slot_pick = PTHREAD_MUTEX_INITIALIZER;
/* vkQueueSubmit on one queue is not thread safe, but waiting is: submit
 * under the lock, then wait on the slot's own fence outside it, so the
 * device can run several blocks at once. */
static pthread_mutex_t g_submit_mu = PTHREAD_MUTEX_INITIALIZER;

static int             g_last_dispatches;
static long long       g_upload_us, g_kernel_us, g_readback_us;
static long long       g_total_us;
static int             g_calls, g_ok;
static const char     *g_fail = "none";
static int             g_fail_code;

static long long now_us(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (long long)ts.tv_sec * 1000000ll + ts.tv_nsec / 1000;
}

typedef struct {
    uint32_t n_ctx, nsym, stride, seed_total;
    uint32_t qbits, qshift, pbits, pshift, dbits;
    uint32_t out_stride, n_chains, chain_base;
} vk_push;

static int vk_debug_stat(int which) {
    switch (which) {
    case TTIO_ENGINE_STAT_DISPATCHES:  return g_last_dispatches;
    case TTIO_ENGINE_STAT_UPLOAD_US:   return (int)g_upload_us;
    case TTIO_ENGINE_STAT_KERNEL_US:   return (int)g_kernel_us;
    case TTIO_ENGINE_STAT_READBACK_US: return (int)g_readback_us;
    case TTIO_ENGINE_STAT_CALLS:       return g_calls;
    case TTIO_ENGINE_STAT_OK:          return g_ok;
    case TTIO_ENGINE_STAT_TOTAL_US:    return (int)g_total_us;
    default:                           return -1;
    }
}

const char *ttio_vk_last_failure(int *code) {
    if (code) *code = g_fail_code;
    return g_fail;
}

/* A block is split into several dispatches so no single one runs long
 * enough to trip a display driver's timeout watchdog. The split is
 * invisible in the output: each dispatch covers a disjoint range of
 * chains and they share no state. */
static uint32_t chains_per_dispatch(uint32_t n_ch) {
    int v = env_int("TTIO_GPU_MAX_CHAINS_PER_DISPATCH", 0);
    if (v > 0) return (uint32_t)v < n_ch ? (uint32_t)v : n_ch;
    return n_ch;
}

static int mem_type(uint32_t bits, VkMemoryPropertyFlags want,
                    uint32_t *out) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(g_vk.phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        if ((bits & (1u << i))
            && (mp.memoryTypes[i].propertyFlags & want) == want) {
            *out = i;
            return 1;
        }
    }
    return 0;
}

static void buf_destroy(vk_buf *b) {
    if (b->mapped) vkUnmapMemory(g_vk.dev, b->mem);
    if (b->buf) vkDestroyBuffer(g_vk.dev, b->buf, NULL);
    if (b->mem) vkFreeMemory(g_vk.dev, b->mem, NULL);
    memset(b, 0, sizeof *b);
}

/* Buffers the host reads or writes are host-visible; the rest are
 * device-local. That distinction matters more than it looks: the model
 * and its running totals are pure device-side scratch, touched two or
 * three times per coded symbol and never by the host, so leaving them
 * in host memory puts a PCIe round trip in the coder's inner loop.
 *
 * Grows on demand and never shrinks, so a steady stream of equal-sized
 * blocks allocates once. */
static int buf_ensure(vk_buf *b, VkDeviceSize size, int host_visible) {
    if (size == 0) size = 4;
    if (b->buf != VK_NULL_HANDLE && b->size >= size) return 1;
    buf_destroy(b);

    b->size = size;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(g_vk.dev, &bi, NULL, &b->buf) != VK_SUCCESS) return 0;

    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(g_vk.dev, b->buf, &mr);
    uint32_t type = 0;
    VkMemoryPropertyFlags want =
        host_visible ? (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                        | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
                     : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    if (!mem_type(mr.memoryTypeBits, want, &type)) {
        if (host_visible
            || !mem_type(mr.memoryTypeBits,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                             | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &type))
            return 0;
        host_visible = 1;
    }
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = type;
    if (vkAllocateMemory(g_vk.dev, &ai, NULL, &b->mem) != VK_SUCCESS) return 0;
    if (vkBindBufferMemory(g_vk.dev, b->buf, b->mem, 0) != VK_SUCCESS) return 0;
    if (host_visible
        && vkMapMemory(g_vk.dev, b->mem, 0, b->size, 0, &b->mapped)
               != VK_SUCCESS)
        return 0;
    return 1;
}

/* ---- shared and per-slot objects ---------------------------------- */

static void shared_destroy(void) {
    for (int i = 0; i < VK_MAX_SLOTS; i++) {
        vk_slot *sl = &g_slot[i];
        if (sl->fence) vkDestroyFence(g_vk.dev, sl->fence, NULL);
        if (sl->cpool) vkDestroyCommandPool(g_vk.dev, sl->cpool, NULL);
        for (int b = 0; b < VK_BUF_COUNT; b++) buf_destroy(&sl->buf[b]);
        memset(sl, 0, sizeof *sl);
    }
    if (g_sh.pipe) vkDestroyPipeline(g_vk.dev, g_sh.pipe, NULL);
    if (g_sh.shader) vkDestroyShaderModule(g_vk.dev, g_sh.shader, NULL);
    if (g_sh.playout) vkDestroyPipelineLayout(g_vk.dev, g_sh.playout, NULL);
    if (g_sh.dpool) vkDestroyDescriptorPool(g_vk.dev, g_sh.dpool, NULL);
    if (g_sh.dsl) vkDestroyDescriptorSetLayout(g_vk.dev, g_sh.dsl, NULL);
    memset(&g_sh, 0, sizeof g_sh);
}

static int shared_create(int n_slots) {
    memset(&g_sh, 0, sizeof g_sh);
    memset(g_slot, 0, sizeof g_slot);
    g_sh.lsz = 32;

    VkDescriptorSetLayoutBinding bind[VK_BUF_COUNT];
    for (int i = 0; i < VK_BUF_COUNT; i++) {
        memset(&bind[i], 0, sizeof bind[i]);
        bind[i].binding = (uint32_t)i;
        bind[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bind[i].descriptorCount = 1;
        bind[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
    };
    dli.bindingCount = VK_BUF_COUNT;
    dli.pBindings = bind;
    if (vkCreateDescriptorSetLayout(g_vk.dev, &dli, NULL, &g_sh.dsl)
        != VK_SUCCESS)
        return 0;

    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                (uint32_t)(VK_BUF_COUNT * n_slots) };
    VkDescriptorPoolCreateInfo dpi = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
    };
    dpi.maxSets = (uint32_t)n_slots;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &ps;
    if (vkCreateDescriptorPool(g_vk.dev, &dpi, NULL, &g_sh.dpool) != VK_SUCCESS)
        return 0;

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0,
                                sizeof(vk_push) };
    VkPipelineLayoutCreateInfo pli = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &g_sh.dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    if (vkCreatePipelineLayout(g_vk.dev, &pli, NULL, &g_sh.playout)
        != VK_SUCCESS)
        return 0;

    VkShaderModuleCreateInfo smi = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
    };
    smi.codeSize = sizeof v6_spv;
    smi.pCode = v6_spv;
    if (vkCreateShaderModule(g_vk.dev, &smi, NULL, &g_sh.shader) != VK_SUCCESS)
        return 0;

    VkSpecializationMapEntry sme = { 0, 0, sizeof(uint32_t) };
    VkSpecializationInfo     spec = { 1, &sme, sizeof(uint32_t), &g_sh.lsz };
    VkPipelineShaderStageCreateInfo ss = {
        VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
    };
    ss.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    ss.module = g_sh.shader;
    ss.pName = "main";
    ss.pSpecializationInfo = &spec;
    VkComputePipelineCreateInfo cpi = {
        VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
    };
    cpi.stage = ss;
    cpi.layout = g_sh.playout;
    if (vkCreateComputePipelines(g_vk.dev, VK_NULL_HANDLE, 1, &cpi, NULL,
                                 &g_sh.pipe) != VK_SUCCESS)
        return 0;

    for (int i = 0; i < n_slots; i++) {
        vk_slot *sl = &g_slot[i];

        VkDescriptorSetAllocateInfo dsa = {
            VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
        };
        dsa.descriptorPool = g_sh.dpool;
        dsa.descriptorSetCount = 1;
        dsa.pSetLayouts = &g_sh.dsl;
        if (vkAllocateDescriptorSets(g_vk.dev, &dsa, &sl->dset) != VK_SUCCESS)
            return 0;

        VkCommandPoolCreateInfo cpci = {
            VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        };
        cpci.queueFamilyIndex = g_vk.qfam;
        cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        if (vkCreateCommandPool(g_vk.dev, &cpci, NULL, &sl->cpool)
            != VK_SUCCESS)
            return 0;

        VkCommandBufferAllocateInfo cai = {
            VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        };
        cai.commandPool = sl->cpool;
        cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(g_vk.dev, &cai, &sl->cb) != VK_SUCCESS)
            return 0;

        VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        if (vkCreateFence(g_vk.dev, &fi, NULL, &sl->fence) != VK_SUCCESS)
            return 0;
    }

    g_sh.ready = 1;
    return 1;
}

static vk_slot *slot_claim(void) {
    vk_slot *sl = NULL;
    pthread_mutex_lock(&g_slot_pick);
    for (int i = 0; i < g_vk.slots_total; i++) {
        if (!g_slot[i].busy) {
            g_slot[i].busy = 1;
            sl = &g_slot[i];
            break;
        }
    }
    pthread_mutex_unlock(&g_slot_pick);
    return sl;
}

static void slot_free(vk_slot *sl) {
    pthread_mutex_lock(&g_slot_pick);
    sl->busy = 0;
    pthread_mutex_unlock(&g_slot_pick);
}

/* ---- encode -------------------------------------------------------- */

static int vk_encode(ttio_v6_job *job) {
    long long t_all = now_us();
    g_calls++;
    if (job == NULL || job->segs == NULL || job->n_segs == 0) return -1;
    if (!g_vk.healthy || !g_sh.ready) return -1;

    vk_slot *sl = slot_claim();
    if (sl == NULL) return -1;

    const uint32_t nsym = job->ab->n;
    const uint32_t stride = 2u * nsym + 2u;
    const uint32_t n_ctx =
        1u << (job->pm->qbits + job->pm->pbits + job->pm->dbits);
    const uint32_t n_ch = (uint32_t)job->n_segs;

    uint32_t out_stride = 0;
    for (uint32_t c = 0; c < n_ch; c++)
        if (job->lens[c] > out_stride) out_stride = (uint32_t)job->lens[c];

    int rc = -1;

    g_fail = "buffers";
    if (!buf_ensure(&sl->buf[VK_BUF_Q], job->n_qualities, 1)
        || !buf_ensure(&sl->buf[VK_BUF_L], 4ull * job->n_reads, 1)
        || !buf_ensure(&sl->buf[VK_BUF_C], 16ull * n_ch, 1)
        || !buf_ensure(&sl->buf[VK_BUF_M],
                       (uint64_t)n_ch * n_ctx * stride * 2u, 0)
        || !buf_ensure(&sl->buf[VK_BUF_TF], 4ull * n_ch * n_ctx, 0)
        || !buf_ensure(&sl->buf[VK_BUF_O], (uint64_t)n_ch * out_stride, 1)
        || !buf_ensure(&sl->buf[VK_BUF_OL], 4ull * n_ch, 1)
        || !buf_ensure(&sl->buf[VK_BUF_T], 2ull * stride, 1)
        || !buf_ensure(&sl->buf[VK_BUF_QM], 256, 1))
        goto out;

    long long t_up = now_us();
    memcpy(sl->buf[VK_BUF_Q].mapped, job->qual, job->n_qualities);
    memcpy(sl->buf[VK_BUF_QM].mapped, job->ab->map, 256);
    memcpy(sl->buf[VK_BUF_L].mapped, job->read_lengths, 4ull * job->n_reads);
    {
        uint32_t *ch = sl->buf[VK_BUF_C].mapped;
        for (uint32_t c = 0; c < n_ch; c++) {
            ch[c * 4 + 0] = (uint32_t)job->segs[c].first_read;
            ch[c * 4 + 1] = (uint32_t)job->segs[c].n_reads;
            ch[c * 4 + 2] = (uint32_t)job->segs[c].qual_off;
            ch[c * 4 + 3] = (uint32_t)job->segs[c].n_qual;
        }
    }
    /* The seeded model, built exactly as v6_model_init does so the
     * kernel starts from the state the CPU coder starts from. */
    {
        uint16_t *t = sl->buf[VK_BUF_T].mapped;
        memset(t, 0, 2ull * stride);
        for (uint32_t i = 0; i < nsym; i++) t[i] = job->ab->seed[i];
        for (uint32_t i = 1; i <= nsym; i++) t[nsym + i] = t[i - 1];
        for (uint32_t i = 1; i <= nsym; i++) {
            uint32_t j = i + (i & (~i + 1u));
            if (j <= nsym)
                t[nsym + j] = (uint16_t)(t[nsym + j] + t[nsym + i]);
        }
    }
    g_upload_us += now_us() - t_up;

    {
        VkDescriptorBufferInfo dbi[VK_BUF_COUNT];
        VkWriteDescriptorSet   w[VK_BUF_COUNT];
        for (int i = 0; i < VK_BUF_COUNT; i++) {
            dbi[i].buffer = sl->buf[i].buf;
            dbi[i].offset = 0;
            dbi[i].range = VK_WHOLE_SIZE;
            memset(&w[i], 0, sizeof w[i]);
            w[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            w[i].dstSet = sl->dset;
            w[i].dstBinding = (uint32_t)i;
            w[i].descriptorCount = 1;
            w[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            w[i].pBufferInfo = &dbi[i];
        }
        vkUpdateDescriptorSets(g_vk.dev, VK_BUF_COUNT, w, 0, NULL);
    }
    g_fail = "dispatch";

    {
        long long      t_k = now_us();
        const uint32_t per = chains_per_dispatch(n_ch);
        const int      inject = env_int("TTIO_GPU_FAULT_INJECT", 0);
        int            dispatches = 0;

        for (uint32_t base = 0; base < n_ch; base += per) {
            uint32_t count = n_ch - base < per ? n_ch - base : per;

            vk_push pc;
            pc.n_ctx = n_ctx;
            pc.nsym = nsym;
            pc.stride = stride;
            pc.seed_total = job->ab->seed_total;
            pc.qbits = job->pm->qbits;
            pc.qshift = job->pm->qshift;
            pc.pbits = job->pm->pbits;
            pc.pshift = job->pm->pshift;
            pc.dbits = job->pm->dbits;
            pc.out_stride = out_stride;
            pc.n_chains = n_ch;
            pc.chain_base = base;

            vkResetCommandBuffer(sl->cb, 0);
            VkCommandBufferBeginInfo cbi = {
                VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            };
            cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkBeginCommandBuffer(sl->cb, &cbi);
            vkCmdBindPipeline(sl->cb, VK_PIPELINE_BIND_POINT_COMPUTE,
                              g_sh.pipe);
            vkCmdBindDescriptorSets(sl->cb, VK_PIPELINE_BIND_POINT_COMPUTE,
                                    g_sh.playout, 0, 1, &sl->dset, 0, NULL);
            vkCmdPushConstants(sl->cb, g_sh.playout,
                               VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
            vkCmdDispatch(sl->cb, (count + g_sh.lsz - 1) / g_sh.lsz, 1, 1);
            vkEndCommandBuffer(sl->cb);

            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            si.commandBufferCount = 1;
            si.pCommandBuffers = &sl->cb;

            VkResult sr;
            if (inject && dispatches == 0) {
                sr = VK_ERROR_DEVICE_LOST;   /* exercise the loss path */
            } else {
                /* Submission to one queue is not thread safe; waiting
                 * is, and waiting is where the time goes. */
                pthread_mutex_lock(&g_submit_mu);
                sr = vkQueueSubmit(g_vk.queue, 1, &si, sl->fence);
                pthread_mutex_unlock(&g_submit_mu);
                if (sr == VK_SUCCESS)
                    sr = vkWaitForFences(g_vk.dev, 1, &sl->fence, VK_TRUE,
                                         UINT64_MAX);
                if (sr == VK_SUCCESS) vkResetFences(g_vk.dev, 1, &sl->fence);
            }
            dispatches++;
            g_fail_code = (int)sr;

            if (sr == VK_ERROR_DEVICE_LOST) {
                g_fail = "device lost";
                pthread_mutex_lock(&g_vk.slot_mu);
                g_vk.healthy = 0;
                pthread_mutex_unlock(&g_vk.slot_mu);
                goto out;
            }
            if (sr != VK_SUCCESS) {
                g_fail = "submit or wait";
                goto out;
            }
        }
        g_last_dispatches = dispatches;
        g_kernel_us += now_us() - t_k;
    }

    {
        long long       t_r = now_us();
        const uint32_t *ol = sl->buf[VK_BUF_OL].mapped;
        const uint8_t  *ob = sl->buf[VK_BUF_O].mapped;
        for (uint32_t c = 0; c < n_ch; c++) {
            if (ol[c] == 0xFFFFFFFFu || ol[c] > job->lens[c]) {
                g_fail = "output overflow";
                g_fail_code = (int)ol[c];
                goto out;
            }
            memcpy(job->bufs[c], ob + (size_t)c * out_stride, ol[c]);
            job->lens[c] = ol[c];
            job->errs[c] = 0;
        }
        g_readback_us += now_us() - t_r;
    }
    rc = 0;
    g_fail = "none";

out:
    slot_free(sl);
    g_total_us += now_us() - t_all;
    if (rc == 0) g_ok++;
    return rc;
}

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

    g_vk.slots_total = env_int("TTIO_GPU_SLOTS", default_slots());
    if (g_vk.slots_total > VK_MAX_SLOTS) g_vk.slots_total = VK_MAX_SLOTS;
    if (g_vk.slots_total < 1) g_vk.slots_total = 1;

    if (!shared_create(g_vk.slots_total)) {
        shared_destroy();
        vkDestroyDevice(g_vk.dev, NULL);
        vkDestroyInstance(g_vk.inst, NULL);
        memset(&g_vk, 0, sizeof g_vk);
        return NULL;
    }

    g_vk.slots_free = g_vk.slots_total;
    g_vk.healthy = 1;

    g_engine.name = g_vk.name;
    g_engine.slots = vk_slots;
    g_engine.try_acquire = vk_try_acquire;
    g_engine.release = vk_release;
    g_engine.qual_v6_encode = vk_encode;
    g_engine.debug_stat = vk_debug_stat;
    g_result = &g_engine;
    return g_result;
}

void ttio_vk_engine_destroy(void) {
    if (!g_created) return;
    shared_destroy();
    if (g_vk.dev != VK_NULL_HANDLE) vkDestroyDevice(g_vk.dev, NULL);
    if (g_vk.inst != VK_NULL_HANDLE) vkDestroyInstance(g_vk.inst, NULL);
    pthread_mutex_destroy(&g_vk.slot_mu);
    memset(&g_vk, 0, sizeof g_vk);
    g_result = NULL;
    g_created = 0;
}
