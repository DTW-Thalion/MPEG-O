/* tools/perf/gpu_spike/v6_spike.c  (throwaway, Phase 2 spike)
 *
 * Runs the real V6 segment encoder on the GPU and checks it byte for
 * byte against the CPU coder, then times it. Answers the two questions
 * Phase 0 left open: whether a real range coder survives on the GPU,
 * and whether the GPU can hit the byte-identity the spec requires.
 *
 * Build on Windows (MSYS2 ucrt64), where the only Vulkan hardware is:
 *   glslangValidator -V v6_chain.comp --vn v6_spv -o v6_spv.h   (in WSL)
 *   gcc -O2 -o v6_spike.exe v6_spike.c -lvulkan-1
 *   ./v6_spike.exe lowcov.v6fx
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#include "v6_spv.h"

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
        VkResult r_ = (x);                                                 \
        if (r_ != VK_SUCCESS) {                                            \
            fprintf(stderr, "%s:%d %s -> %d\n", __FILE__, __LINE__, #x,    \
                    (int)r_);                                              \
            exit(1);                                                       \
        }                                                                  \
    } while (0)

#define SM_MAX_FREQ ((1u << 16) - 17u)

static VkInstance       inst;
static VkPhysicalDevice phys;
static VkDevice         dev;
static VkQueue          queue;
static uint32_t         qfam;
static VkCommandPool    pool;

typedef struct { VkBuffer buf; VkDeviceMemory mem; VkDeviceSize size; } buf_t;

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i))
            && (mp.memoryTypes[i].propertyFlags & want) == want)
            return i;
    fprintf(stderr, "no memory type 0x%x\n", (unsigned)want);
    exit(1);
}

static buf_t mk(VkDeviceSize size, VkBufferUsageFlags usage,
                VkMemoryPropertyFlags props)
{
    buf_t b;
    if (size == 0) size = 4;
    b.size = size;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = usage;
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

static void upload(buf_t *b, const void *src, size_t n)
{
    void *p;
    VKOK(vkMapMemory(dev, b->mem, 0, n ? n : 4, 0, &p));
    if (n) memcpy(p, src, n);
    vkUnmapMemory(dev, b->mem);
}

/* ---- fixture ---- */
typedef struct {
    uint32_t n_ch, ctx_bits, qbits, qshift, pbits, pshift, dbits;
    uint32_t nsym, seed_total, n_sym_total, n_reads, ref_bytes;
    uint32_t *seed, *first, *nread, *qoff, *nqual, *roff, *rlen, *lens;
    uint8_t  *qidx, *ref;
} fixture;

static uint32_t rd32(FILE *f)
{
    uint32_t v;
    if (fread(&v, 4, 1, f) != 1) { fprintf(stderr, "short fixture\n"); exit(1); }
    return v;
}

static void *rdn(FILE *f, size_t n)
{
    void *p = malloc(n ? n : 1);
    if (n && fread(p, 1, n, f) != n) { fprintf(stderr, "short fixture\n"); exit(1); }
    return p;
}

static void load_fixture(const char *path, fixture *fx)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    char magic[4];
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "V6FX", 4) != 0) {
        fprintf(stderr, "not a V6FX fixture\n");
        exit(1);
    }
    fx->n_ch = rd32(f);
    fx->ctx_bits = rd32(f);
    fx->qbits = rd32(f);
    fx->qshift = rd32(f);
    fx->pbits = rd32(f);
    fx->pshift = rd32(f);
    fx->dbits = rd32(f);
    fx->nsym = rd32(f);
    fx->seed_total = rd32(f);
    fx->n_sym_total = rd32(f);
    fx->n_reads = rd32(f);
    fx->ref_bytes = rd32(f);
    fx->seed  = rdn(f, 4u * fx->nsym);
    fx->first = rdn(f, 4u * fx->n_ch);
    fx->nread = rdn(f, 4u * fx->n_ch);
    fx->qoff  = rdn(f, 4u * fx->n_ch);
    fx->nqual = rdn(f, 4u * fx->n_ch);
    fx->roff  = rdn(f, 4u * fx->n_ch);
    fx->rlen  = rdn(f, 4u * fx->n_ch);
    fx->lens  = rdn(f, 4u * fx->n_reads);
    fx->qidx  = rdn(f, fx->n_sym_total);
    fx->ref   = rdn(f, fx->ref_bytes);
    fclose(f);
}

typedef struct {
    uint32_t n_ctx, nsym, stride, seed_total;
    uint32_t qbits, qshift, pbits, pshift, dbits;
    uint32_t out_stride, n_chains;
} push_t;

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s fixture.v6fx [chains] [local_size]\n",
                argv[0]);
        return 2;
    }
    fixture fx;
    load_fixture(argv[1], &fx);

    uint32_t n_ch = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : fx.n_ch;
    uint32_t lsz  = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 32;
    if (n_ch > fx.n_ch) n_ch = fx.n_ch;

    uint32_t stride = fx.nsym + 2;
    uint32_t n_ctx = 1u << fx.ctx_bits;

    /* Model template, ordered exactly as native/src/m94z_v6.c
     * models_init does: heaviest first, ties to the lower symbol. */
    uint32_t *order = malloc(fx.nsym * 4);
    for (uint32_t i = 0; i < fx.nsym; i++) order[i] = i;
    for (uint32_t a = 0; a < fx.nsym; a++)
        for (uint32_t b = a + 1; b < fx.nsym; b++)
            if (fx.seed[order[b]] > fx.seed[order[a]]) {
                uint32_t t = order[a]; order[a] = order[b]; order[b] = t;
            }
    uint32_t *tmpl = calloc(stride, 4);
    tmpl[0] = SM_MAX_FREQ;                       /* sentinel: symbol 0 */
    for (uint32_t i = 0; i < fx.nsym; i++)
        tmpl[i + 1] = (order[i] << 16) | fx.seed[order[i]];
    /* tmpl[nsym+1] terminal stays 0 */

    uint64_t sym_total = 0, max_ref = 0;
    for (uint32_t c = 0; c < n_ch; c++) {
        sym_total += fx.nqual[c];
        if (fx.rlen[c] > max_ref) max_ref = fx.rlen[c];
    }
    uint32_t out_stride = (uint32_t)(max_ref + 4096);

    /* ---- Vulkan ---- */
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ii = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ii.pApplicationInfo = &app;
    VKOK(vkCreateInstance(&ii, NULL, &inst));

    uint32_t nd = 0;
    VKOK(vkEnumeratePhysicalDevices(inst, &nd, NULL));
    VkPhysicalDevice *pds = calloc(nd, sizeof *pds);
    VKOK(vkEnumeratePhysicalDevices(inst, &nd, pds));
    phys = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < nd; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(pds[i], &p);
        if (p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
            && phys == VK_NULL_HANDLE)
            phys = pds[i];
    }
    if (phys == VK_NULL_HANDLE) phys = pds[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(phys, &props);
    printf("# device: %s\n", props.deviceName);

    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, NULL);
    VkQueueFamilyProperties *qs = calloc(nq, sizeof *qs);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qs);
    qfam = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++)
        if (qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qfam = i; break; }

    VkPhysicalDeviceVulkan12Features f12 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    };
    f12.storageBuffer8BitAccess = VK_TRUE;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qi.queueFamilyIndex = qfam;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;
    VkDeviceCreateInfo di = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    di.pNext = &f12;
    di.queueCreateInfoCount = 1;
    di.pQueueCreateInfos = &qi;
    VKOK(vkCreateDevice(phys, &di, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    VkCommandPoolCreateInfo ci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    ci.queueFamilyIndex = qfam;
    VKOK(vkCreateCommandPool(dev, &ci, NULL, &pool));

    /* Host-visible throughout: the spike is about the kernel, and this
     * keeps the readback trivial. */
    VkMemoryPropertyFlags HV = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                             | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    VkBufferUsageFlags SB = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;

    uint64_t model_bytes = (uint64_t)n_ch * n_ctx * stride * 4u;
    uint64_t totf_bytes  = (uint64_t)n_ch * n_ctx * 4u;
    uint64_t out_bytes   = (uint64_t)n_ch * out_stride;
    printf("# chains %u, ctx %u, alphabet %u, model %.0f MiB, out %.0f MiB\n",
           n_ch, n_ctx, fx.nsym, (double)model_bytes / 1048576.0,
           (double)out_bytes / 1048576.0);

    buf_t b_q  = mk(fx.n_sym_total, SB, HV);
    buf_t b_l  = mk(4u * fx.n_reads, SB, HV);
    buf_t b_c  = mk(16u * n_ch, SB, HV);
    buf_t b_m  = mk(model_bytes, SB, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    buf_t b_tf = mk(totf_bytes, SB, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    buf_t b_o  = mk(out_bytes, SB, HV);
    buf_t b_ol = mk(4u * n_ch, SB, HV);
    buf_t b_t  = mk(4u * stride, SB, HV);

    upload(&b_q, fx.qidx, fx.n_sym_total);
    upload(&b_l, fx.lens, 4u * fx.n_reads);
    upload(&b_t, tmpl, 4u * stride);
    {
        uint32_t *ch = malloc(16u * n_ch);
        for (uint32_t c = 0; c < n_ch; c++) {
            ch[c * 4 + 0] = fx.first[c];
            ch[c * 4 + 1] = fx.nread[c];
            ch[c * 4 + 2] = fx.qoff[c];
            ch[c * 4 + 3] = fx.nqual[c];
        }
        upload(&b_c, ch, 16u * n_ch);
        free(ch);
    }

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
    VkDescriptorSetLayout dsl;
    VKOK(vkCreateDescriptorSetLayout(dev, &dli, NULL, &dsl));

    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 8 };
    VkDescriptorPoolCreateInfo dpi = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
    };
    dpi.maxSets = 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &ps;
    VkDescriptorPool dp;
    VKOK(vkCreateDescriptorPool(dev, &dpi, NULL, &dp));
    VkDescriptorSetAllocateInfo dsa = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
    };
    dsa.descriptorPool = dp;
    dsa.descriptorSetCount = 1;
    dsa.pSetLayouts = &dsl;
    VkDescriptorSet ds;
    VKOK(vkAllocateDescriptorSets(dev, &dsa, &ds));

    buf_t *all[8] = { &b_q, &b_l, &b_c, &b_m, &b_tf, &b_o, &b_ol, &b_t };
    VkDescriptorBufferInfo dbi[8];
    VkWriteDescriptorSet    w[8];
    for (int i = 0; i < 8; i++) {
        dbi[i].buffer = all[i]->buf;
        dbi[i].offset = 0;
        dbi[i].range = VK_WHOLE_SIZE;
        memset(&w[i], 0, sizeof w[i]);
        w[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        w[i].dstSet = ds;
        w[i].dstBinding = (uint32_t)i;
        w[i].descriptorCount = 1;
        w[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        w[i].pBufferInfo = &dbi[i];
    }
    vkUpdateDescriptorSets(dev, 8, w, 0, NULL);

    VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0,
                                sizeof(push_t) };
    VkPipelineLayoutCreateInfo pli = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    };
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    VkPipelineLayout pl;
    VKOK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));

    VkShaderModuleCreateInfo smi = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
    };
    smi.codeSize = sizeof v6_spv;
    smi.pCode = v6_spv;
    VkShaderModule sm;
    VKOK(vkCreateShaderModule(dev, &smi, NULL, &sm));

    VkSpecializationMapEntry sme = { 0, 0, 4 };
    VkSpecializationInfo spec = { 1, &sme, 4, &lsz };
    VkPipelineShaderStageCreateInfo ss = {
        VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
    };
    ss.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    ss.module = sm;
    ss.pName = "main";
    ss.pSpecializationInfo = &spec;
    VkComputePipelineCreateInfo cpi = {
        VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
    };
    cpi.stage = ss;
    cpi.layout = pl;
    VkPipeline pipe;
    VKOK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL, &pipe));

    push_t pcv = { n_ctx, fx.nsym, stride, fx.seed_total, fx.qbits,
                   fx.qshift, fx.pbits, fx.pshift, fx.dbits, out_stride,
                   n_ch };

    VkCommandBufferAllocateInfo cai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    };
    cai.commandPool = pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    VkCommandBuffer cb;
    VKOK(vkAllocateCommandBuffers(dev, &cai, &cb));
    VkCommandBufferBeginInfo cbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    };
    VKOK(vkBeginCommandBuffer(cb, &cbi));
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1,
                            &ds, 0, NULL);
    vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pcv,
                       &pcv);
    vkCmdDispatch(cb, (n_ch + lsz - 1) / lsz, 1, 1);
    VKOK(vkEndCommandBuffer(cb));

    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    VKOK(vkCreateFence(dev, &fi, NULL, &fence));
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;

    double best = 1e30;
    for (int it = 0; it < 3; it++) {
        double t0 = now_s();
        VKOK(vkQueueSubmit(queue, 1, &si, fence));
        VKOK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
        VKOK(vkResetFences(dev, 1, &fence));
        double dt = now_s() - t0;
        if (dt < best) best = dt;
    }

    /* ---- the contract: byte-identical to the CPU coder ---- */
    void *op = NULL, *olp = NULL;
    VKOK(vkMapMemory(dev, b_o.mem, 0, out_bytes, 0, &op));
    VKOK(vkMapMemory(dev, b_ol.mem, 0, 4u * n_ch, 0, &olp));
    const uint8_t  *gout = op;
    const uint32_t *glen = olp;

    uint32_t ok = 0, bad_len = 0, bad_bytes = 0, overflow = 0;
    long     first_bad = -1;
    for (uint32_t c = 0; c < n_ch; c++) {
        if (glen[c] == 0xFFFFFFFFu) { overflow++; continue; }
        if (glen[c] != fx.rlen[c]) {
            bad_len++;
            if (first_bad < 0) first_bad = c;
            continue;
        }
        if (memcmp(gout + (size_t)c * out_stride, fx.ref + fx.roff[c],
                   fx.rlen[c]) != 0) {
            bad_bytes++;
            if (first_bad < 0) first_bad = c;
            continue;
        }
        ok++;
    }

    printf("chains,identical,length_mismatch,byte_mismatch,overflow\n");
    printf("%u,%u,%u,%u,%u\n", n_ch, ok, bad_len, bad_bytes, overflow);

    if (first_bad >= 0) {
        uint32_t c = (uint32_t)first_bad;
        printf("# first divergent chain %u: gpu_len %u cpu_len %u\n", c,
               glen[c], fx.rlen[c]);
        const uint8_t *g = gout + (size_t)c * out_stride;
        const uint8_t *r = fx.ref + fx.roff[c];
        uint32_t n = glen[c] < fx.rlen[c] ? glen[c] : fx.rlen[c];
        for (uint32_t i = 0; i < n; i++) {
            if (g[i] != r[i]) {
                printf("# first differing byte at %u: gpu %02x cpu %02x\n",
                       i, g[i], r[i]);
                break;
            }
        }
    }

    double sps = (double)sym_total / best;
    printf("# %.3f ms, %.3e symbols/s, %.1f MB/s encode\n", best * 1000.0,
           sps, sps / 1.0e6);
    printf("# cpu reference total %u bytes over %u chains\n",
           fx.ref_bytes, fx.n_ch);
    return (ok == n_ch) ? 0 : 1;
}
