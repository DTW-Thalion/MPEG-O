/* Throwaway Vulkan microbenchmark for the M94.Z V6 GPU engine spike.
 * Measures the memory and control-flow shape of a segmented adaptive
 * coder: one sequential chain per invocation, a private context-model
 * bank per chain, one read-modify-write per symbol. No entropy coding.
 * Results feed docs/superpowers/plans/2026-08-20-gpu-v6-phase0-findings.md.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#include "chain_spv.h"

#ifdef _WIN32
#include <windows.h>
static double now_s(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}
#else
#include <time.h>
static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
#endif

#define VKOK(x)                                                            \
    do {                                                                   \
        VkResult vk_r_ = (x);                                              \
        if (vk_r_ != VK_SUCCESS) {                                         \
            fprintf(stderr, "%s:%d: %s failed (%d)\n", __FILE__, __LINE__, \
                    #x, (int)vk_r_);                                       \
            exit(1);                                                       \
        }                                                                  \
    } while (0)

#define N_CTX         4096u
#define TOTAL_SYMBOLS (64u * 1024u * 1024u)
#define MAX_CHAINS    8192u
#define ITERS         10

/* nsym 48 is the spike default; 256 is the real V6 alphabet, whose
 * per-chain model bank is 2 MiB instead of 384 KiB. */
static const struct {
    const char *label;
    uint32_t    local_size;
    uint32_t    chains;
    uint32_t    stripe;
    uint32_t    nsym;
    uint32_t    feedback;
} runs[] = {
    { "control", 1, 512, 0, 48, 1 },
    { "encode", 1, 256, 0, 48, 0 },
    { "encode", 1, 512, 0, 48, 0 },
    { "encode", 1, 2048, 0, 48, 0 },
    { "encode", 1, 8192, 0, 48, 0 },
    { "decode", 1, 256, 0, 48, 1 },
    { "decode", 1, 512, 0, 48, 1 },
    { "decode", 1, 2048, 0, 48, 1 },
    { "decode", 1, 8192, 0, 48, 1 },
    { "encode-256sym", 1, 512, 0, 256, 0 },
    { "encode-256sym", 1, 2048, 0, 256, 0 },
    { "decode-256sym", 1, 512, 0, 256, 1 },
    { "decode-256sym", 1, 2048, 0, 256, 1 },
    { "encode-256sym-lane", 32, 2048, 0, 256, 0 },
    { "decode-256sym-lane", 32, 2048, 0, 256, 1 },
    { "decode", 1, 4096, 0, 48, 1 },
    { "decode-lane", 32, 2048, 0, 48, 1 },
    { "decode-lane", 32, 4096, 0, 48, 1 },
    { "decode-lane", 32, 8192, 0, 48, 1 },
    { "decode-lane-striped", 32, 8192, 1, 48, 1 },
    { "control", 1, 512, 0, 48, 1 },
};
#define N_RUNS ((int)(sizeof runs / sizeof runs[0]))

static VkInstance       inst;
static VkPhysicalDevice phys;
static VkDevice         dev;
static VkQueue          queue;
static uint32_t         qfam;
static VkCommandPool    cmdpool;

typedef struct {
    VkBuffer       buf;
    VkDeviceMemory mem;
    VkDeviceSize   size;
} buffer;

typedef struct {
    uint32_t seg_symbols;
    uint32_t n_ctx_mask;
    uint32_t stripe;
} push_block;

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        if ((bits & (1u << i)) &&
            (mp.memoryTypes[i].propertyFlags & want) == want)
            return i;
    }
    fprintf(stderr, "no memory type for 0x%x\n", (unsigned)want);
    exit(1);
}

static buffer make_buffer(VkDeviceSize size, VkBufferUsageFlags usage,
                          VkMemoryPropertyFlags props)
{
    buffer b;
    b.size = size;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VKOK(vkCreateBuffer(dev, &bi, NULL, &b.buf));

    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, b.buf, &mr);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = mem_type(mr.memoryTypeBits, props);
    VKOK(vkAllocateMemory(dev, &ai, NULL, &b.mem));
    VKOK(vkBindBufferMemory(dev, b.buf, b.mem, 0));
    return b;
}

static VkCommandBuffer begin_once(void)
{
    VkCommandBufferAllocateInfo ai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    };
    ai.commandPool = cmdpool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    VkCommandBuffer cb;
    VKOK(vkAllocateCommandBuffers(dev, &ai, &cb));
    VkCommandBufferBeginInfo bi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    VKOK(vkBeginCommandBuffer(cb, &bi));
    return cb;
}

static void end_once(VkCommandBuffer cb)
{
    VKOK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    VKOK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    VKOK(vkQueueWaitIdle(queue));
    vkFreeCommandBuffers(dev, cmdpool, 1, &cb);
}

static void pick_device(void)
{
    uint32_t n = 0;
    VKOK(vkEnumeratePhysicalDevices(inst, &n, NULL));
    if (n == 0) {
        fprintf(stderr, "no vulkan device\n");
        exit(1);
    }
    VkPhysicalDevice *pds = calloc(n, sizeof *pds);
    VKOK(vkEnumeratePhysicalDevices(inst, &n, pds));

    phys = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(pds[i], &p);
        printf("# device %u: %s (type %d, api %u.%u.%u)\n", i, p.deviceName,
               (int)p.deviceType, VK_VERSION_MAJOR(p.apiVersion),
               VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion));
        if (phys == VK_NULL_HANDLE &&
            p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)
            phys = pds[i];
    }
    if (phys == VK_NULL_HANDLE)
        phys = pds[0];

    VkPhysicalDeviceProperties p;
    vkGetPhysicalDeviceProperties(phys, &p);
    printf("# using: %s\n", p.deviceName);
    printf("# maxComputeWorkGroupInvocations = %u\n",
           p.limits.maxComputeWorkGroupInvocations);
    free(pds);

    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, NULL);
    VkQueueFamilyProperties *qs = calloc(nq, sizeof *qs);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qs);
    qfam = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++) {
        if (qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
            qfam = i;
            break;
        }
    }
    free(qs);
    if (qfam == UINT32_MAX) {
        fprintf(stderr, "no compute queue\n");
        exit(1);
    }
}

int main(void)
{
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "v6-gpu-spike";
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ii = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ii.pApplicationInfo = &app;
    VKOK(vkCreateInstance(&ii, NULL, &inst));

    pick_device();

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
    qi.queueFamilyIndex = qfam;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;
    VkDeviceCreateInfo di = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    di.pNext = &f11;
    di.queueCreateInfoCount = 1;
    di.pQueueCreateInfos = &qi;
    VKOK(vkCreateDevice(phys, &di, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    VkCommandPoolCreateInfo ci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    ci.queueFamilyIndex = qfam;
    ci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VKOK(vkCreateCommandPool(dev, &ci, NULL, &cmdpool));

    VkDeviceSize quals_bytes = TOTAL_SYMBOLS;
    VkDeviceSize model_bytes = 0;
    for (int r = 0; r < N_RUNS; r++) {
        VkDeviceSize need =
            (VkDeviceSize)runs[r].chains * N_CTX * runs[r].nsym * 2u;
        if (need > model_bytes)
            model_bytes = need;
    }
    VkDeviceSize out_bytes = MAX_CHAINS * 4u;
    printf("# buffers: quals %.0f MiB, models %.0f MiB\n",
           (double)quals_bytes / 1048576.0, (double)model_bytes / 1048576.0);

    buffer quals = make_buffer(quals_bytes,
                               VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                                   VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                               VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    buffer models = make_buffer(model_bytes,
                                VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                                    VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    buffer out = make_buffer(out_bytes,
                             VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                                 VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                 VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                             VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    buffer back = make_buffer(out_bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                              VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                  VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    buffer stage = make_buffer(quals_bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                   VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    void *map = NULL;
    VKOK(vkMapMemory(dev, stage.mem, 0, quals_bytes, 0, &map));
    uint8_t *qp = map;
    uint32_t rng = 12345u;
    for (VkDeviceSize i = 0; i < quals_bytes; i++) {
        rng = rng * 1664525u + 1013904223u;
        qp[i] = (uint8_t)(rng >> 24);
    }
    vkUnmapMemory(dev, stage.mem);

    VkCommandBuffer cb = begin_once();
    VkBufferCopy cp = { 0, 0, quals_bytes };
    vkCmdCopyBuffer(cb, stage.buf, quals.buf, 1, &cp);
    vkCmdFillBuffer(cb, models.buf, 0, model_bytes, 0x00200020u);
    vkCmdFillBuffer(cb, out.buf, 0, out_bytes, 0);
    end_once(cb);

    {
        double best = 1e9;
        for (int it = 0; it < 10; it++) {
            VkCommandBuffer tb = begin_once();
            VkBufferCopy    tc = { 0, 0, quals_bytes };
            double          t0 = now_s();
            vkCmdCopyBuffer(tb, stage.buf, quals.buf, 1, &tc);
            end_once(tb);
            double dt = now_s() - t0;
            if (dt < best)
                best = dt;
        }
        printf("# host-to-device: %.0f MiB in %.3f ms = %.2f GB/s\n",
               (double)quals_bytes / 1048576.0, best * 1000.0,
               (double)quals_bytes / best / 1.0e9);
    }

    VkDescriptorSetLayoutBinding binds[3];
    for (int i = 0; i < 3; i++) {
        memset(&binds[i], 0, sizeof binds[i]);
        binds[i].binding = (uint32_t)i;
        binds[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        binds[i].descriptorCount = 1;
        binds[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
    };
    dli.bindingCount = 3;
    dli.pBindings = binds;
    VkDescriptorSetLayout dsl;
    VKOK(vkCreateDescriptorSetLayout(dev, &dli, NULL, &dsl));

    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 3 };
    VkDescriptorPoolCreateInfo dpi = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
    };
    dpi.maxSets = 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &ps;
    VkDescriptorPool dpool;
    VKOK(vkCreateDescriptorPool(dev, &dpi, NULL, &dpool));

    VkDescriptorSetAllocateInfo dsa = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
    };
    dsa.descriptorPool = dpool;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &dsl;
    VkDescriptorSet dset;
    VKOK(vkAllocateDescriptorSets(dev, &dsa, &dset));

    VkDescriptorBufferInfo bufinfo[3] = {
        { quals.buf, 0, VK_WHOLE_SIZE },
        { models.buf, 0, VK_WHOLE_SIZE },
        { out.buf, 0, VK_WHOLE_SIZE },
    };
    VkWriteDescriptorSet writes[3];
    for (int i = 0; i < 3; i++) {
        memset(&writes[i], 0, sizeof writes[i]);
        writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet = dset;
        writes[i].dstBinding = (uint32_t)i;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[i].pBufferInfo = &bufinfo[i];
    }
    vkUpdateDescriptorSets(dev, 3, writes, 0, NULL);

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0,
                                sizeof(push_block) };
    VkPipelineLayoutCreateInfo pli = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    VkPipelineLayout playout;
    VKOK(vkCreatePipelineLayout(dev, &pli, NULL, &playout));

    VkShaderModuleCreateInfo smi = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
    };
    smi.codeSize = sizeof chain_spv;
    smi.pCode = chain_spv;
    VkShaderModule shader;
    VKOK(vkCreateShaderModule(dev, &smi, NULL, &shader));

    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    VKOK(vkCreateFence(dev, &fi, NULL, &fence));

    printf("mode,local_size,chains,workgroups,seg_symbols,stripe,nsym,"
           "feedback,bank_KiB,min_ms,median_ms,min_symbols_per_s,"
           "proj_MBps,checksum\n");

    for (int r = 0; r < N_RUNS; r++) {
        uint32_t lsz = runs[r].local_size;
        uint32_t chains = runs[r].chains;
        uint32_t groups = chains / lsz;
        uint32_t seg = TOTAL_SYMBOLS / chains;
        uint32_t spec_data[3] = { lsz, runs[r].nsym, runs[r].feedback };

        VkSpecializationMapEntry sme[3] = {
            { 0, 0, sizeof(uint32_t) },
            { 1, sizeof(uint32_t), sizeof(uint32_t) },
            { 2, 2 * sizeof(uint32_t), sizeof(uint32_t) },
        };
        VkSpecializationInfo spec = { 3, sme, sizeof spec_data, spec_data };
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
        VkPipeline pipe;
        VKOK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL,
                                      &pipe));

        push_block                  pb = { seg, N_CTX - 1u, runs[r].stripe };
        VkCommandBufferAllocateInfo cai = {
            VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        };
        cai.commandPool = cmdpool;
        cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cai.commandBufferCount = 1;
        VkCommandBuffer rcb;
        VKOK(vkAllocateCommandBuffers(dev, &cai, &rcb));
        VkCommandBufferBeginInfo cbi = {
            VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        };
        VKOK(vkBeginCommandBuffer(rcb, &cbi));
        vkCmdBindPipeline(rcb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vkCmdBindDescriptorSets(rcb, VK_PIPELINE_BIND_POINT_COMPUTE, playout, 0,
                                1, &dset, 0, NULL);
        vkCmdPushConstants(rcb, playout, VK_SHADER_STAGE_COMPUTE_BIT, 0,
                           sizeof pb, &pb);
        vkCmdDispatch(rcb, groups, 1, 1);
        VKOK(vkEndCommandBuffer(rcb));

        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1;
        si.pCommandBuffers = &rcb;

        double ms[ITERS];
        for (int it = -1; it < ITERS; it++) {
            double t0 = now_s();
            VKOK(vkQueueSubmit(queue, 1, &si, fence));
            VKOK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
            VKOK(vkResetFences(dev, 1, &fence));
            double dt = (now_s() - t0) * 1000.0;
            if (it >= 0)
                ms[it] = dt;
        }
        for (int a = 0; a < ITERS; a++) {
            for (int b = a + 1; b < ITERS; b++) {
                if (ms[b] < ms[a]) {
                    double t = ms[a];
                    ms[a] = ms[b];
                    ms[b] = t;
                }
            }
        }
        double best = ms[0], med = ms[ITERS / 2];
        double sps = (double)TOTAL_SYMBOLS / (best / 1000.0);

        VkCommandBuffer rb = begin_once();
        VkBufferCopy    rcp = { 0, 0, out_bytes };
        vkCmdCopyBuffer(rb, out.buf, back.buf, 1, &rcp);
        end_once(rb);
        void *bm = NULL;
        VKOK(vkMapMemory(dev, back.mem, 0, out_bytes, 0, &bm));
        uint32_t *ap = bm;
        uint32_t  chk = 0;
        for (uint32_t i = 0; i < chains; i++)
            chk = chk * 31u + ap[i];
        vkUnmapMemory(dev, back.mem);
        if (chk == 0) {
            fprintf(stderr, "row %d produced no work\n", r);
            exit(1);
        }

        printf("%s,%u,%u,%u,%u,%u,%u,%u,%u,%.3f,%.3f,%.3e,%.1f,0x%08x\n",
               runs[r].label, lsz, chains, groups, seg, runs[r].stripe,
               runs[r].nsym, runs[r].feedback,
               N_CTX * runs[r].nsym * 2u / 1024u, best, med, sps,
               sps / 3.0 / 1.0e6, chk);
        fflush(stdout);

        vkFreeCommandBuffers(dev, cmdpool, 1, &rcb);
        vkDestroyPipeline(dev, pipe, NULL);
    }

    vkDeviceWaitIdle(dev);
    return 0;
}
