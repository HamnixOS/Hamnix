/* scripts/vk_hostgpu_bridge.c — HOST-GPU bridge for the Hamnix vk spine.
 *
 * GPU track: "Vulkan back into work on Linux" — route our composited
 * framebuffer through the dev host's REAL Vulkan (NVIDIA / Mesa / lavapipe)
 * so hambrowse + the DE + games can be host-verified with genuine hardware
 * 3D acceleration, complementing the in-VM virtio-gpu path.
 *
 * WHY A C BRIDGE (and not Adder host code):
 *   The Adder `x86_64-linux` host target links a STATIC, no-libc, no-PIE ELF
 *   with raw `syscall` wrappers (compiler/adder.py). It has no dynamic loader
 *   and no libc, so it cannot dlopen/dynamically-link libvulkan.so.1. The real
 *   GPU therefore lives behind this tiny C-ABI bridge; our Adder vk render
 *   (lib/vk/vk_2d.ad via lib/vk/vk_hostgpu.ad) composites the framebuffer, and
 *   we hand that RGBA8888 buffer across a file seam to this bridge, which
 *   uploads it to a real VkDevice, runs a real GPU op, and reads it back.
 *
 * NO VULKAN HEADERS are installed on this host (only libvulkan.so.1), so the
 * minimal, ABI-stable subset of the Vulkan API we use is hand-declared below.
 * We deliberately use ONLY fixed-function transfer ops (clear / buffer<->image
 * copy) so NO SPIR-V / glslc is required (none is installed either).
 *
 * BUILD:  gcc scripts/vk_hostgpu_bridge.c -o build/host/vk_hostgpu_bridge \
 *              /usr/lib/x86_64-linux-gnu/libvulkan.so.1
 *
 * MODES:
 *   vk_hostgpu_bridge info
 *       Enumerate the real Vulkan devices and print the selected one.
 *   vk_hostgpu_bridge clear W H 0xRRGGBBAA OUT.ppm
 *       Real GPU vkCmdClearColorImage into a WxH image, read back -> PPM.
 *   vk_hostgpu_bridge upload IN.ppm OUT.ppm
 *       Upload IN.ppm's pixels to a device image (vkCmdCopyBufferToImage),
 *       copy image->buffer (vkCmdCopyImageToBuffer), read back -> PPM.
 *       An identity round-trip: OUT must be byte-identical to IN, proving the
 *       composited-framebuffer marshalling through the real GPU is lossless.
 *
 * Device selection honours the standard VK_ICD_FILENAMES env (e.g. point it at
 * lvp_icd.json to validate the whole path on lavapipe / SW Vulkan). By default
 * we prefer a discrete GPU, then integrated, then anything.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ===================== minimal hand-rolled Vulkan ABI ===================== */
typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef uint64_t VkDeviceSize;
typedef int32_t  VkResult;

/* dispatchable handles are pointers; non-dispatchable are 64-bit ints */
typedef void*    VkInstance;
typedef void*    VkPhysicalDevice;
typedef void*    VkDevice;
typedef void*    VkQueue;
typedef void*    VkCommandBuffer;
typedef uint64_t VkDeviceMemory;
typedef uint64_t VkBuffer;
typedef uint64_t VkImage;
typedef uint64_t VkCommandPool;
typedef uint64_t VkFence;

#define VK_SUCCESS 0
#define VK_WHOLE_SIZE (~0ULL)
#define VK_QUEUE_FAMILY_IGNORED (~0U)
#define VK_TRUE 1

/* VkStructureType */
#define ST_APPLICATION_INFO           0
#define ST_INSTANCE_CREATE_INFO       1
#define ST_DEVICE_QUEUE_CREATE_INFO   2
#define ST_DEVICE_CREATE_INFO         3
#define ST_SUBMIT_INFO                4
#define ST_MEMORY_ALLOCATE_INFO       5
#define ST_FENCE_CREATE_INFO          8
#define ST_BUFFER_CREATE_INFO         12
#define ST_IMAGE_CREATE_INFO          14
#define ST_COMMAND_POOL_CREATE_INFO   39
#define ST_COMMAND_BUFFER_ALLOCATE_INFO 40
#define ST_COMMAND_BUFFER_BEGIN_INFO  42
#define ST_IMAGE_MEMORY_BARRIER       45

#define VK_FORMAT_R8G8B8A8_UNORM 37
#define VK_IMAGE_TYPE_2D 1
#define VK_IMAGE_TILING_OPTIMAL 0
#define VK_SHARING_MODE_EXCLUSIVE 0
#define VK_SAMPLE_COUNT_1_BIT 1
#define VK_IMAGE_LAYOUT_UNDEFINED 0
#define VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL 6
#define VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 7

#define VK_IMAGE_USAGE_TRANSFER_SRC_BIT 0x1
#define VK_IMAGE_USAGE_TRANSFER_DST_BIT 0x2
#define VK_BUFFER_USAGE_TRANSFER_SRC_BIT 0x1
#define VK_BUFFER_USAGE_TRANSFER_DST_BIT 0x2

#define VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT  0x1
#define VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT  0x2
#define VK_MEMORY_PROPERTY_HOST_COHERENT_BIT 0x4

#define VK_IMAGE_ASPECT_COLOR_BIT 0x1
#define VK_ACCESS_TRANSFER_READ_BIT  0x800
#define VK_ACCESS_TRANSFER_WRITE_BIT 0x1000
#define VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT 0x1
#define VK_PIPELINE_STAGE_TRANSFER_BIT    0x1000
#define VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT 0x2000
#define VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT 0x1
#define VK_COMMAND_BUFFER_LEVEL_PRIMARY 0
#define VK_QUEUE_GRAPHICS_BIT 0x1
#define VK_QUEUE_COMPUTE_BIT  0x2
#define VK_QUEUE_TRANSFER_BIT 0x4

#define VK_PHYSICAL_DEVICE_TYPE_OTHER          0
#define VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU 1
#define VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU   2
#define VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU    3
#define VK_PHYSICAL_DEVICE_TYPE_CPU            4

typedef struct { uint32_t x, y, z; } VkExtent3D;
typedef struct { int32_t x, y, z; } VkOffset3D;

typedef struct {
    uint32_t sType; const void* pNext;
    const char* pApplicationName; uint32_t applicationVersion;
    const char* pEngineName; uint32_t engineVersion; uint32_t apiVersion;
} VkApplicationInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    const VkApplicationInfo* pApplicationInfo;
    uint32_t enabledLayerCount; const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char* const* ppEnabledExtensionNames;
} VkInstanceCreateInfo;

/* only the head is read by us; pad covers limits+sparse so the driver's
 * full write never overflows our stack copy. real size ~824 bytes. */
typedef struct {
    uint32_t apiVersion; uint32_t driverVersion;
    uint32_t vendorID; uint32_t deviceID;
    uint32_t deviceType;              /* VkPhysicalDeviceType */
    char     deviceName[256];
    uint8_t  pipelineCacheUUID[16];
    uint8_t  _pad[1024];              /* limits + sparseProperties */
} VkPhysicalDeviceProperties;

typedef struct {
    VkFlags  queueFlags; uint32_t queueCount; uint32_t timestampValidBits;
    VkExtent3D minImageTransferGranularity;
} VkQueueFamilyProperties;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t queueFamilyIndex; uint32_t queueCount; const float* pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t queueCreateInfoCount; const VkDeviceQueueCreateInfo* pQueueCreateInfos;
    uint32_t enabledLayerCount; const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char* const* ppEnabledExtensionNames;
    const void* pEnabledFeatures;
} VkDeviceCreateInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t imageType; uint32_t format;
    VkExtent3D extent; uint32_t mipLevels; uint32_t arrayLayers;
    uint32_t samples; uint32_t tiling; VkFlags usage; uint32_t sharingMode;
    uint32_t queueFamilyIndexCount; const uint32_t* pQueueFamilyIndices;
    uint32_t initialLayout;
} VkImageCreateInfo;

typedef struct { VkDeviceSize size; VkDeviceSize alignment; uint32_t memoryTypeBits; } VkMemoryRequirements;
typedef struct { uint32_t sType; const void* pNext; VkDeviceSize allocationSize; uint32_t memoryTypeIndex; } VkMemoryAllocateInfo;

typedef struct { VkFlags propertyFlags; uint32_t heapIndex; } VkMemoryType;
typedef struct { VkDeviceSize size; VkFlags flags; } VkMemoryHeap;
typedef struct {
    uint32_t memoryTypeCount; VkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount; VkMemoryHeap memoryHeaps[16];
} VkPhysicalDeviceMemoryProperties;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    VkDeviceSize size; VkFlags usage; uint32_t sharingMode;
    uint32_t queueFamilyIndexCount; const uint32_t* pQueueFamilyIndices;
} VkBufferCreateInfo;

typedef struct { uint32_t sType; const void* pNext; VkFlags flags; uint32_t queueFamilyIndex; } VkCommandPoolCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkCommandPool commandPool; uint32_t level; uint32_t commandBufferCount; } VkCommandBufferAllocateInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags; const void* pInheritanceInfo; } VkCommandBufferBeginInfo;

typedef struct { VkFlags aspectMask; uint32_t baseMipLevel, levelCount, baseArrayLayer, layerCount; } VkImageSubresourceRange;
typedef struct { VkFlags aspectMask; uint32_t mipLevel, baseArrayLayer, layerCount; } VkImageSubresourceLayers;

typedef struct {
    uint32_t sType; const void* pNext;
    VkFlags srcAccessMask, dstAccessMask;
    uint32_t oldLayout, newLayout;
    uint32_t srcQueueFamilyIndex, dstQueueFamilyIndex;
    VkImage image; VkImageSubresourceRange subresourceRange;
} VkImageMemoryBarrier;

typedef union { float float32[4]; int32_t int32[4]; uint32_t uint32[4]; } VkClearColorValue;

typedef struct {
    VkDeviceSize bufferOffset; uint32_t bufferRowLength; uint32_t bufferImageHeight;
    VkImageSubresourceLayers imageSubresource; VkOffset3D imageOffset; VkExtent3D imageExtent;
} VkBufferImageCopy;

typedef struct {
    uint32_t sType; const void* pNext;
    uint32_t waitSemaphoreCount; const void* pWaitSemaphores; const VkFlags* pWaitDstStageMask;
    uint32_t commandBufferCount; const VkCommandBuffer* pCommandBuffers;
    uint32_t signalSemaphoreCount; const void* pSignalSemaphores;
} VkSubmitInfo;

typedef struct { uint32_t sType; const void* pNext; VkFlags flags; } VkFenceCreateInfo;

extern VkResult vkCreateInstance(const VkInstanceCreateInfo*, const void*, VkInstance*);
extern void     vkDestroyInstance(VkInstance, const void*);
extern VkResult vkEnumeratePhysicalDevices(VkInstance, uint32_t*, VkPhysicalDevice*);
extern void     vkGetPhysicalDeviceProperties(VkPhysicalDevice, VkPhysicalDeviceProperties*);
extern void     vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice, uint32_t*, VkQueueFamilyProperties*);
extern void     vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
extern VkResult vkCreateDevice(VkPhysicalDevice, const VkDeviceCreateInfo*, const void*, VkDevice*);
extern void     vkDestroyDevice(VkDevice, const void*);
extern void     vkGetDeviceQueue(VkDevice, uint32_t, uint32_t, VkQueue*);
extern VkResult vkCreateImage(VkDevice, const VkImageCreateInfo*, const void*, VkImage*);
extern void     vkDestroyImage(VkDevice, VkImage, const void*);
extern void     vkGetImageMemoryRequirements(VkDevice, VkImage, VkMemoryRequirements*);
extern VkResult vkCreateBuffer(VkDevice, const VkBufferCreateInfo*, const void*, VkBuffer*);
extern void     vkDestroyBuffer(VkDevice, VkBuffer, const void*);
extern void     vkGetBufferMemoryRequirements(VkDevice, VkBuffer, VkMemoryRequirements*);
extern VkResult vkAllocateMemory(VkDevice, const VkMemoryAllocateInfo*, const void*, VkDeviceMemory*);
extern void     vkFreeMemory(VkDevice, VkDeviceMemory, const void*);
extern VkResult vkBindImageMemory(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
extern VkResult vkBindBufferMemory(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize);
extern VkResult vkMapMemory(VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, void**);
extern void     vkUnmapMemory(VkDevice, VkDeviceMemory);
extern VkResult vkCreateCommandPool(VkDevice, const VkCommandPoolCreateInfo*, const void*, VkCommandPool*);
extern void     vkDestroyCommandPool(VkDevice, VkCommandPool, const void*);
extern VkResult vkAllocateCommandBuffers(VkDevice, const VkCommandBufferAllocateInfo*, VkCommandBuffer*);
extern VkResult vkBeginCommandBuffer(VkCommandBuffer, const VkCommandBufferBeginInfo*);
extern VkResult vkEndCommandBuffer(VkCommandBuffer);
extern void     vkCmdPipelineBarrier(VkCommandBuffer, VkFlags, VkFlags, VkFlags,
                                     uint32_t, const void*, uint32_t, const void*,
                                     uint32_t, const VkImageMemoryBarrier*);
extern void     vkCmdClearColorImage(VkCommandBuffer, VkImage, uint32_t,
                                     const VkClearColorValue*, uint32_t, const VkImageSubresourceRange*);
extern void     vkCmdCopyImageToBuffer(VkCommandBuffer, VkImage, uint32_t, VkBuffer, uint32_t, const VkBufferImageCopy*);
extern void     vkCmdCopyBufferToImage(VkCommandBuffer, VkBuffer, VkImage, uint32_t, uint32_t, const VkBufferImageCopy*);
extern VkResult vkCreateFence(VkDevice, const VkFenceCreateInfo*, const void*, VkFence*);
extern void     vkDestroyFence(VkDevice, VkFence, const void*);
extern VkResult vkQueueSubmit(VkQueue, uint32_t, const VkSubmitInfo*, VkFence);
extern VkResult vkWaitForFences(VkDevice, uint32_t, const VkFence*, VkBool32, uint64_t);
extern VkResult vkDeviceWaitIdle(VkDevice);

/* ============================ bridge helpers ============================= */
static VkInstance       g_inst = 0;
static VkPhysicalDevice g_phys = 0;
static VkDevice         g_dev  = 0;
static VkQueue          g_queue = 0;
static uint32_t         g_qfam = 0;
static VkCommandPool    g_pool = 0;
static char             g_devname[320] = "?";
static VkPhysicalDeviceMemoryProperties g_memprops;

#define CK(expr) do { VkResult _r = (expr); if (_r != VK_SUCCESS) { \
    fprintf(stderr, "[vk_hostgpu] %s -> VkResult %d\n", #expr, _r); return -1; } } while (0)

static const char* devtype_str(uint32_t t) {
    switch (t) {
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated-GPU";
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return "discrete-GPU";
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return "virtual-GPU";
    case VK_PHYSICAL_DEVICE_TYPE_CPU:            return "CPU (SW Vulkan)";
    default:                                     return "other";
    }
}

/* Rank a device: prefer discrete, then integrated/virtual, then CPU last. */
static int rank(uint32_t t) {
    switch (t) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return 4;
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 3;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return 2;
    case VK_PHYSICAL_DEVICE_TYPE_OTHER:          return 1;
    case VK_PHYSICAL_DEVICE_TYPE_CPU:            return 0;
    default:                                     return 0;
    }
}

static int find_mem(uint32_t typeBits, VkFlags want) {
    for (uint32_t i = 0; i < g_memprops.memoryTypeCount; i++) {
        if ((typeBits & (1u << i)) &&
            (g_memprops.memoryTypes[i].propertyFlags & want) == want)
            return (int)i;
    }
    return -1;
}

static int vk_init(void) {
    VkApplicationInfo app = { .sType = ST_APPLICATION_INFO,
        .pApplicationName = "hamnix-vk-hostgpu", .apiVersion = (1u<<22) };
    VkInstanceCreateInfo ici = { .sType = ST_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    CK(vkCreateInstance(&ici, 0, &g_inst));

    uint32_t n = 0;
    CK(vkEnumeratePhysicalDevices(g_inst, &n, 0));
    if (n == 0) { fprintf(stderr, "[vk_hostgpu] no Vulkan physical devices\n"); return -1; }
    if (n > 16) n = 16;
    VkPhysicalDevice devs[16];
    CK(vkEnumeratePhysicalDevices(g_inst, &n, devs));

    int best = -1, bestrank = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        memset(&p, 0, sizeof p);
        vkGetPhysicalDeviceProperties(devs[i], &p);
        fprintf(stderr, "[vk_hostgpu]   device[%u] %s [%s] api %u.%u.%u\n",
                i, p.deviceName, devtype_str(p.deviceType),
                (p.apiVersion>>22)&0x7f, (p.apiVersion>>12)&0x3ff, p.apiVersion&0xfff);
        int r = rank(p.deviceType);
        if (r > bestrank) { bestrank = r; best = (int)i; }
    }
    g_phys = devs[best];
    VkPhysicalDeviceProperties p; memset(&p, 0, sizeof p);
    vkGetPhysicalDeviceProperties(g_phys, &p);
    snprintf(g_devname, sizeof g_devname, "%s [%s]", p.deviceName, devtype_str(p.deviceType));
    fprintf(stderr, "[vk_hostgpu] selected: %s\n", g_devname);

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &qn, 0);
    if (qn > 32) qn = 32;
    VkQueueFamilyProperties qf[32];
    vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &qn, qf);
    int qfam = -1;
    for (uint32_t i = 0; i < qn; i++) {
        if (qf[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT|VK_QUEUE_TRANSFER_BIT)) {
            qfam = (int)i; break;
        }
    }
    if (qfam < 0) { fprintf(stderr, "[vk_hostgpu] no transfer-capable queue family\n"); return -1; }
    g_qfam = (uint32_t)qfam;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = ST_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = g_qfam, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = ST_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    CK(vkCreateDevice(g_phys, &dci, 0, &g_dev));
    vkGetDeviceQueue(g_dev, g_qfam, 0, &g_queue);
    vkGetPhysicalDeviceMemoryProperties(g_phys, &g_memprops);

    VkCommandPoolCreateInfo pci = { .sType = ST_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = g_qfam };
    CK(vkCreateCommandPool(g_dev, &pci, 0, &g_pool));
    return 0;
}

static void vk_shutdown(void) {
    if (g_dev) { vkDeviceWaitIdle(g_dev); }
    if (g_pool) vkDestroyCommandPool(g_dev, g_pool, 0);
    if (g_dev) vkDestroyDevice(g_dev, 0);
    if (g_inst) vkDestroyInstance(g_inst, 0);
}

/* Create a device-local RGBA8888 2D image usable as transfer src+dst. */
static int make_image(uint32_t w, uint32_t h, VkImage* img, VkDeviceMemory* mem) {
    VkImageCreateInfo ic = { .sType = ST_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = { w, h, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    CK(vkCreateImage(g_dev, &ic, 0, img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(g_dev, *img, &mr);
    int mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mt < 0) mt = find_mem(mr.memoryTypeBits, 0);
    VkMemoryAllocateInfo ai = { .sType = ST_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = (uint32_t)mt };
    CK(vkAllocateMemory(g_dev, &ai, 0, mem));
    CK(vkBindImageMemory(g_dev, *img, *mem, 0));
    return 0;
}

/* Create a host-visible+coherent buffer. */
static int make_hostbuf(VkDeviceSize sz, VkFlags usage, VkBuffer* buf, VkDeviceMemory* mem) {
    VkBufferCreateInfo bc = { .sType = ST_BUFFER_CREATE_INFO, .size = sz,
        .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CK(vkCreateBuffer(g_dev, &bc, 0, buf));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(g_dev, *buf, &mr);
    int mt = find_mem(mr.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt < 0) { fprintf(stderr, "[vk_hostgpu] no host-visible mem\n"); return -1; }
    VkMemoryAllocateInfo ai = { .sType = ST_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = (uint32_t)mt };
    CK(vkAllocateMemory(g_dev, &ai, 0, mem));
    CK(vkBindBufferMemory(g_dev, *buf, *mem, 0));
    return 0;
}

static int begin_cmd(VkCommandBuffer* cb) {
    VkCommandBufferAllocateInfo ai = { .sType = ST_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = g_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    CK(vkAllocateCommandBuffers(g_dev, &ai, cb));
    VkCommandBufferBeginInfo bi = { .sType = ST_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    CK(vkBeginCommandBuffer(*cb, &bi));
    return 0;
}

static int submit_wait(VkCommandBuffer cb) {
    CK(vkEndCommandBuffer(cb));
    VkFenceCreateInfo fci = { .sType = ST_FENCE_CREATE_INFO };
    VkFence fence; CK(vkCreateFence(g_dev, &fci, 0, &fence));
    VkSubmitInfo si = { .sType = ST_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    CK(vkQueueSubmit(g_queue, 1, &si, fence));
    CK(vkWaitForFences(g_dev, 1, &fence, VK_TRUE, ~0ULL));
    vkDestroyFence(g_dev, fence, 0);
    return 0;
}

static void barrier(VkCommandBuffer cb, VkImage img, uint32_t oldL, uint32_t newL,
                    VkFlags srcA, VkFlags dstA, VkFlags srcS, VkFlags dstS) {
    VkImageMemoryBarrier b = { .sType = ST_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = srcA, .dstAccessMask = dstA, .oldLayout = oldL, .newLayout = newL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = img,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(cb, srcS, dstS, 0, 0, 0, 0, 0, 1, &b);
}

/* ============================ PPM read/write ============================= */
/* Read a binary P6 PPM into a freshly-malloc'd RGBA8888 buffer. */
static uint8_t* read_ppm(const char* path, uint32_t* w, uint32_t* h) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "[vk_hostgpu] cannot open %s\n", path); return 0; }
    char magic[3] = {0};
    if (fscanf(f, "%2s", magic) != 1 || strcmp(magic, "P6")) { fclose(f); return 0; }
    int W, H, MX;
    if (fscanf(f, "%d %d %d", &W, &H, &MX) != 3) { fclose(f); return 0; }
    fgetc(f); /* single whitespace after maxval */
    uint8_t* rgba = malloc((size_t)W * H * 4);
    for (long i = 0; i < (long)W * H; i++) {
        int r = fgetc(f), g = fgetc(f), b = fgetc(f);
        rgba[i*4+0] = (uint8_t)r; rgba[i*4+1] = (uint8_t)g;
        rgba[i*4+2] = (uint8_t)b; rgba[i*4+3] = 255;
    }
    fclose(f);
    *w = (uint32_t)W; *h = (uint32_t)H;
    return rgba;
}

static int write_ppm(const char* path, const uint8_t* rgba, uint32_t w, uint32_t h) {
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (uint32_t i = 0; i < w * h; i++) {
        fputc(rgba[i*4+0], f); fputc(rgba[i*4+1], f); fputc(rgba[i*4+2], f);
    }
    fclose(f);
    return 0;
}

/* Copy the whole image (currently TRANSFER_SRC) into a host buffer, write PPM. */
static int readback(VkImage img, uint32_t w, uint32_t h, const char* out) {
    VkDeviceSize sz = (VkDeviceSize)w * h * 4;
    VkBuffer buf; VkDeviceMemory bmem;
    if (make_hostbuf(sz, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &buf, &bmem)) return -1;
    VkCommandBuffer cb;
    if (begin_cmd(&cb)) return -1;
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageExtent = { w, h, 1 } };
    vkCmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &region);
    if (submit_wait(cb)) return -1;
    void* map;
    CK(vkMapMemory(g_dev, bmem, 0, sz, 0, &map));
    write_ppm(out, (uint8_t*)map, w, h);
    vkUnmapMemory(g_dev, bmem);
    vkDestroyBuffer(g_dev, buf, 0);
    vkFreeMemory(g_dev, bmem, 0);
    return 0;
}

/* ============================== modes =================================== */
static int mode_clear(uint32_t w, uint32_t h, uint32_t rgba, const char* out) {
    VkImage img; VkDeviceMemory imem;
    if (make_image(w, h, &img, &imem)) return -1;
    VkCommandBuffer cb;
    if (begin_cmd(&cb)) return -1;
    barrier(cb, img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkClearColorValue cc;
    cc.float32[0] = ((rgba>>24)&0xff) / 255.0f;
    cc.float32[1] = ((rgba>>16)&0xff) / 255.0f;
    cc.float32[2] = ((rgba>>8 )&0xff) / 255.0f;
    cc.float32[3] = ((rgba    )&0xff) / 255.0f;
    VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cc, 1, &range);
    barrier(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    if (submit_wait(cb)) return -1;
    int rc = readback(img, w, h, out);
    vkDestroyImage(g_dev, img, 0); vkFreeMemory(g_dev, imem, 0);
    return rc;
}

static int mode_upload(const char* in, const char* out) {
    uint32_t w, h;
    uint8_t* rgba = read_ppm(in, &w, &h);
    if (!rgba) return -1;
    VkDeviceSize sz = (VkDeviceSize)w * h * 4;

    VkBuffer stage; VkDeviceMemory smem;
    if (make_hostbuf(sz, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &stage, &smem)) return -1;
    void* map;
    CK(vkMapMemory(g_dev, smem, 0, sz, 0, &map));
    memcpy(map, rgba, sz);
    vkUnmapMemory(g_dev, smem);
    free(rgba);

    VkImage img; VkDeviceMemory imem;
    if (make_image(w, h, &img, &imem)) return -1;
    VkCommandBuffer cb;
    if (begin_cmd(&cb)) return -1;
    barrier(cb, img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageExtent = { w, h, 1 } };
    vkCmdCopyBufferToImage(cb, stage, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    barrier(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    if (submit_wait(cb)) return -1;
    int rc = readback(img, w, h, out);
    vkDestroyImage(g_dev, img, 0); vkFreeMemory(g_dev, imem, 0);
    vkDestroyBuffer(g_dev, stage, 0); vkFreeMemory(g_dev, smem, 0);
    return rc;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s info | clear W H 0xRRGGBBAA OUT.ppm | upload IN.ppm OUT.ppm\n", argv[0]);
        return 2;
    }
    if (vk_init()) { return 1; }
    int rc = 0;
    if (!strcmp(argv[1], "info")) {
        printf("VK_DEVICE %s\n", g_devname);
    } else if (!strcmp(argv[1], "clear") && argc == 6) {
        uint32_t w = (uint32_t)strtoul(argv[2], 0, 0);
        uint32_t h = (uint32_t)strtoul(argv[3], 0, 0);
        uint32_t c = (uint32_t)strtoul(argv[4], 0, 0);
        rc = mode_clear(w, h, c, argv[5]);
        if (!rc) printf("VK_DEVICE %s\nCLEAR_OK %s\n", g_devname, argv[5]);
    } else if (!strcmp(argv[1], "upload") && argc == 4) {
        rc = mode_upload(argv[2], argv[3]);
        if (!rc) printf("VK_DEVICE %s\nUPLOAD_OK %s\n", g_devname, argv[3]);
    } else {
        fprintf(stderr, "bad args\n"); rc = 2;
    }
    vk_shutdown();
    return rc ? 1 : 0;
}
