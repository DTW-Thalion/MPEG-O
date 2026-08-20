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
#include "v6_spv.h"

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

/* ---- buffers ---------------------------------------------------- */

typedef struct {
    VkBuffer       buf;
    VkDeviceMemory mem;
    VkDeviceSize   size;
    void          *mapped;
} vk_buf;

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

/* Host-visible throughout: the working set is small enough that the
 * copy a device-local staging path would save is not worth the extra
 * failure modes in a first engine. */
static int buf_create(vk_buf *b, VkDeviceSize size) {
    memset(b, 0, sizeof *b);
    if (size == 0) size = 4;
    b->size = size;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(g_vk.dev, &bi, NULL, &b->buf) != VK_SUCCESS) return 0;

    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(g_vk.dev, b->buf, &mr);
    uint32_t type = 0;
    if (!mem_type(mr.memoryTypeBits,
                  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                      | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &type))
        return 0;
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = type;
    if (vkAllocateMemory(g_vk.dev, &ai, NULL, &b->mem) != VK_SUCCESS) return 0;
    if (vkBindBufferMemory(g_vk.dev, b->buf, b->mem, 0) != VK_SUCCESS) return 0;
    if (vkMapMemory(g_vk.dev, b->mem, 0, b->size, 0, &b->mapped) != VK_SUCCESS)
        return 0;
    return 1;
}

static void buf_destroy(vk_buf *b) {
    if (b->mapped) vkUnmapMemory(g_vk.dev, b->mem);
    if (b->buf) vkDestroyBuffer(g_vk.dev, b->buf, NULL);
    if (b->mem) vkFreeMemory(g_vk.dev, b->mem, NULL);
    memset(b, 0, sizeof *b);
}

typedef struct {
    uint32_t n_ctx, nsym, stride, seed_total;
    uint32_t qbits, qshift, pbits, pshift, dbits;
    uint32_t out_stride, n_chains, chain_base;
} vk_push;

static int g_last_dispatches;

static int vk_debug_stat(int which) {
    if (which == TTIO_ENGINE_STAT_DISPATCHES) return g_last_dispatches;
    return -1;
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

/* ---- encode ------------------------------------------------------ */

static int vk_encode(ttio_v6_job *job) {
    if (job == NULL || job->segs == NULL || job->n_segs == 0) return -1;
    if (!g_vk.healthy) return -1;

    const uint32_t nsym = job->ab->n;
    const uint32_t stride = 2u * nsym + 2u;
    const uint32_t n_ctx =
        1u << (job->pm->qbits + job->pm->pbits + job->pm->dbits);
    const uint32_t n_ch = (uint32_t)job->n_segs;

    uint32_t out_stride = 0;
    uint64_t sym_total = 0;
    for (uint32_t c = 0; c < n_ch; c++) {
        if (job->lens[c] > out_stride) out_stride = (uint32_t)job->lens[c];
        sym_total += job->segs[c].n_qual;
    }

    int      rc = -1;
    vk_buf   b_q, b_l, b_c, b_m, b_tf, b_o, b_ol, b_t;
    memset(&b_q, 0, sizeof b_q); memset(&b_l, 0, sizeof b_l);
    memset(&b_c, 0, sizeof b_c); memset(&b_m, 0, sizeof b_m);
    memset(&b_tf, 0, sizeof b_tf); memset(&b_o, 0, sizeof b_o);
    memset(&b_ol, 0, sizeof b_ol); memset(&b_t, 0, sizeof b_t);

    VkDescriptorSetLayout dsl = VK_NULL_HANDLE;
    VkDescriptorPool      dpool = VK_NULL_HANDLE;
    VkPipelineLayout      playout = VK_NULL_HANDLE;
    VkShaderModule        shader = VK_NULL_HANDLE;
    VkPipeline            pipe = VK_NULL_HANDLE;
    VkCommandPool         cpool = VK_NULL_HANDLE;
    VkFence               fence = VK_NULL_HANDLE;

    uint64_t model_bytes = (uint64_t)n_ch * n_ctx * stride * 2u;

    if (!buf_create(&b_q, job->n_qualities)
        || !buf_create(&b_l, 4ull * job->n_reads)
        || !buf_create(&b_c, 16ull * n_ch)
        || !buf_create(&b_m, model_bytes)
        || !buf_create(&b_tf, 4ull * n_ch * n_ctx)
        || !buf_create(&b_o, (uint64_t)n_ch * out_stride)
        || !buf_create(&b_ol, 4ull * n_ch)
        || !buf_create(&b_t, 2ull * stride))
        goto out;

    memcpy(b_q.mapped, job->qual, job->n_qualities);
    memcpy(b_l.mapped, job->read_lengths, 4ull * job->n_reads);
    {
        uint32_t *ch = b_c.mapped;
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
        uint16_t *t = b_t.mapped;
        memset(t, 0, 2ull * stride);
        for (uint32_t i = 0; i < nsym; i++) t[i] = job->ab->seed[i];
        for (uint32_t i = 1; i <= nsym; i++) t[nsym + i] = t[i - 1];
        for (uint32_t i = 1; i <= nsym; i++) {
            uint32_t j = i + (i & (~i + 1u));
            if (j <= nsym)
                t[nsym + j] = (uint16_t)(t[nsym + j] + t[nsym + i]);
        }
    }

    /* Descriptors: eight storage buffers in binding order. */
    VkDescriptorSetLayoutBinding bind[8];
    for (int i = 0; i < 8; i++) {
        memset(&bind[i], 0, sizeof bind[i]);
        bind[i].binding = (uint32_t)i;
        bind[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bind[i].descriptorCount = 1;
        bind[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
    };
    dli.bindingCount = 8;
    dli.pBindings = bind;
    if (vkCreateDescriptorSetLayout(g_vk.dev, &dli, NULL, &dsl) != VK_SUCCESS)
        goto out;

    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 8 };
    VkDescriptorPoolCreateInfo dpi = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
    };
    dpi.maxSets = 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &ps;
    if (vkCreateDescriptorPool(g_vk.dev, &dpi, NULL, &dpool) != VK_SUCCESS)
        goto out;

    VkDescriptorSetAllocateInfo dsa = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
    };
    dsa.descriptorPool = dpool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &dsl;
    VkDescriptorSet dset;
    if (vkAllocateDescriptorSets(g_vk.dev, &dsa, &dset) != VK_SUCCESS)
        goto out;

    vk_buf *all[8] = { &b_q, &b_l, &b_c, &b_m, &b_tf, &b_o, &b_ol, &b_t };
    VkDescriptorBufferInfo dbi[8];
    VkWriteDescriptorSet   w[8];
    for (int i = 0; i < 8; i++) {
        dbi[i].buffer = all[i]->buf;
        dbi[i].offset = 0;
        dbi[i].range = VK_WHOLE_SIZE;
        memset(&w[i], 0, sizeof w[i]);
        w[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        w[i].dstSet = dset;
        w[i].dstBinding = (uint32_t)i;
        w[i].descriptorCount = 1;
        w[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        w[i].pBufferInfo = &dbi[i];
    }
    vkUpdateDescriptorSets(g_vk.dev, 8, w, 0, NULL);

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0,
                                sizeof(vk_push) };
    VkPipelineLayoutCreateInfo pli = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    if (vkCreatePipelineLayout(g_vk.dev, &pli, NULL, &playout) != VK_SUCCESS)
        goto out;

    VkShaderModuleCreateInfo smi = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
    };
    smi.codeSize = sizeof v6_spv;
    smi.pCode = v6_spv;
    if (vkCreateShaderModule(g_vk.dev, &smi, NULL, &shader) != VK_SUCCESS)
        goto out;

    uint32_t lsz = 32;
    VkSpecializationMapEntry sme = { 0, 0, sizeof(uint32_t) };
    VkSpecializationInfo     spec = { 1, &sme, sizeof(uint32_t), &lsz };
    VkPipelineShaderStageCreateInfo ss = {
        VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
    };
    ss.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    ss.module = shader;
    ss.pName = "main";
    ss.pSpecializationInfo = &spec;
    VkComputePipelineCreateInfo cpi = {
        VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
    };
    cpi.stage = ss;
    cpi.layout = playout;
    if (vkCreateComputePipelines(g_vk.dev, VK_NULL_HANDLE, 1, &cpi, NULL,
                                 &pipe) != VK_SUCCESS)
        goto out;

    VkCommandPoolCreateInfo cpci = {
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    };
    cpci.queueFamilyIndex = g_vk.qfam;
    if (vkCreateCommandPool(g_vk.dev, &cpci, NULL, &cpool) != VK_SUCCESS)
        goto out;

    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (vkCreateFence(g_vk.dev, &fi, NULL, &fence) != VK_SUCCESS) goto out;

    {
        const uint32_t per = chains_per_dispatch(n_ch);
        const int      inject = env_int("TTIO_GPU_FAULT_INJECT", 0);
        g_last_dispatches = 0;

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

            VkCommandBufferAllocateInfo cai = {
                VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
            };
            cai.commandPool = cpool;
            cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            cai.commandBufferCount = 1;
            VkCommandBuffer cb;
            if (vkAllocateCommandBuffers(g_vk.dev, &cai, &cb) != VK_SUCCESS)
                goto out;
            VkCommandBufferBeginInfo cbi = {
                VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            };
            cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkBeginCommandBuffer(cb, &cbi);
            vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE,
                                    playout, 0, 1, &dset, 0, NULL);
            vkCmdPushConstants(cb, playout, VK_SHADER_STAGE_COMPUTE_BIT, 0,
                               sizeof pc, &pc);
            vkCmdDispatch(cb, (count + lsz - 1) / lsz, 1, 1);
            vkEndCommandBuffer(cb);

            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            si.commandBufferCount = 1;
            si.pCommandBuffers = &cb;

            VkResult sr;
            if (inject && g_last_dispatches == 0) {
                sr = VK_ERROR_DEVICE_LOST;   /* exercise the loss path */
            } else {
                sr = vkQueueSubmit(g_vk.queue, 1, &si, fence);
                if (sr == VK_SUCCESS)
                    sr = vkWaitForFences(g_vk.dev, 1, &fence, VK_TRUE,
                                         UINT64_MAX);
                if (sr == VK_SUCCESS) vkResetFences(g_vk.dev, 1, &fence);
            }
            g_last_dispatches++;

            if (sr == VK_ERROR_DEVICE_LOST) {
                /* Gone for this process. Stop offering slots so later
                 * blocks go straight to the CPU rather than retrying a
                 * device that is not coming back. */
                pthread_mutex_lock(&g_vk.slot_mu);
                g_vk.healthy = 0;
                pthread_mutex_unlock(&g_vk.slot_mu);
                goto out;
            }
            if (sr != VK_SUCCESS) goto out;
        }
    }

    {
        const uint32_t *ol = b_ol.mapped;
        const uint8_t  *ob = b_o.mapped;
        for (uint32_t c = 0; c < n_ch; c++) {
            if (ol[c] == 0xFFFFFFFFu || ol[c] > job->lens[c]) goto out;
            memcpy(job->bufs[c], ob + (size_t)c * out_stride, ol[c]);
            job->lens[c] = ol[c];
            job->errs[c] = 0;
        }
    }
    rc = 0;

out:
    if (fence) vkDestroyFence(g_vk.dev, fence, NULL);
    if (cpool) vkDestroyCommandPool(g_vk.dev, cpool, NULL);
    if (pipe) vkDestroyPipeline(g_vk.dev, pipe, NULL);
    if (shader) vkDestroyShaderModule(g_vk.dev, shader, NULL);
    if (playout) vkDestroyPipelineLayout(g_vk.dev, playout, NULL);
    if (dpool) vkDestroyDescriptorPool(g_vk.dev, dpool, NULL);
    if (dsl) vkDestroyDescriptorSetLayout(g_vk.dev, dsl, NULL);
    buf_destroy(&b_t); buf_destroy(&b_ol); buf_destroy(&b_o);
    buf_destroy(&b_tf); buf_destroy(&b_m); buf_destroy(&b_c);
    buf_destroy(&b_l); buf_destroy(&b_q);
    (void)sym_total;
    return rc;
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

    g_vk.slots_total = env_int("TTIO_GPU_SLOTS", default_slots());
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
    if (g_vk.dev != VK_NULL_HANDLE) vkDestroyDevice(g_vk.dev, NULL);
    if (g_vk.inst != VK_NULL_HANDLE) vkDestroyInstance(g_vk.inst, NULL);
    pthread_mutex_destroy(&g_vk.slot_mu);
    memset(&g_vk, 0, sizeof g_vk);
    g_result = NULL;
    g_created = 0;
}
