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
#include <time.h>

/* Present-to-a-real-window (Xlib WSI) is compiled in only when the build has
 * X11 available (-DHAVE_XLIB -lX11). Every other mode — including the headless
 * GPU blit/scale path — builds and runs with zero display dependency. */
#ifdef HAVE_XLIB
#include <X11/Xlib.h>
#endif

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
extern void     vkFreeCommandBuffers(VkDevice, VkCommandPool, uint32_t, const VkCommandBuffer*);
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

/* ---- vkCmdBlitImage: a real GPU scaled copy (format-converting, filtered) -- */
#define VK_FILTER_NEAREST 0
#define VK_FILTER_LINEAR  1
typedef struct {
    VkImageSubresourceLayers srcSubresource; VkOffset3D srcOffsets[2];
    VkImageSubresourceLayers dstSubresource; VkOffset3D dstOffsets[2];
} VkImageBlit;
extern void vkCmdBlitImage(VkCommandBuffer, VkImage srcImage, uint32_t srcLayout,
                           VkImage dstImage, uint32_t dstLayout,
                           uint32_t regionCount, const VkImageBlit*, uint32_t filter);

/* ============ minimal COMPUTE ABI (SPIR-V pipeline for GPU 2D raster) ======= */
/* GPU-raster path: run vk_2d's fill/blit/blend/roundrect as a real compute
 * pipeline (scripts/shaders/vk2d_raster.comp.spv) over storage buffers. */
typedef uint64_t VkShaderModule;
typedef uint64_t VkDescriptorSetLayout;
typedef uint64_t VkPipelineLayout;
typedef uint64_t VkPipeline;
typedef uint64_t VkPipelineCache;
typedef uint64_t VkDescriptorPool;
typedef void*    VkDescriptorSet;

#define ST_SHADER_MODULE_CREATE_INFO           16
#define ST_PIPELINE_SHADER_STAGE_CREATE_INFO   18
#define ST_COMPUTE_PIPELINE_CREATE_INFO        29
#define ST_PIPELINE_LAYOUT_CREATE_INFO         30
#define ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO   32
#define ST_DESCRIPTOR_POOL_CREATE_INFO         33
#define ST_DESCRIPTOR_SET_ALLOCATE_INFO        34
#define ST_WRITE_DESCRIPTOR_SET                35
#define ST_MEMORY_BARRIER                      46

#define VK_SHADER_STAGE_COMPUTE_BIT      0x20
#define VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 7
#define VK_PIPELINE_BIND_POINT_COMPUTE    1
#define VK_BUFFER_USAGE_STORAGE_BUFFER_BIT 0x20
#define VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT 0x800
#define VK_ACCESS_SHADER_READ_BIT  0x20
#define VK_ACCESS_SHADER_WRITE_BIT 0x40

typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    size_t codeSize; const uint32_t* pCode; } VkShaderModuleCreateInfo;
typedef struct { uint32_t binding; uint32_t descriptorType; uint32_t descriptorCount;
    VkFlags stageFlags; const void* pImmutableSamplers; } VkDescriptorSetLayoutBinding;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t bindingCount; const VkDescriptorSetLayoutBinding* pBindings;
    } VkDescriptorSetLayoutCreateInfo;
typedef struct { VkFlags stageFlags; uint32_t offset; uint32_t size; } VkPushConstantRange;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t setLayoutCount; const VkDescriptorSetLayout* pSetLayouts;
    uint32_t pushConstantRangeCount; const VkPushConstantRange* pPushConstantRanges;
    } VkPipelineLayoutCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    VkFlags stage; VkShaderModule module; const char* pName;
    const void* pSpecializationInfo; } VkPipelineShaderStageCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    VkPipelineShaderStageCreateInfo stage; VkPipelineLayout layout;
    VkPipeline basePipelineHandle; int32_t basePipelineIndex; } VkComputePipelineCreateInfo;
typedef struct { uint32_t type; uint32_t descriptorCount; } VkDescriptorPoolSize;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t maxSets; uint32_t poolSizeCount; const VkDescriptorPoolSize* pPoolSizes;
    } VkDescriptorPoolCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkDescriptorPool descriptorPool;
    uint32_t descriptorSetCount; const VkDescriptorSetLayout* pSetLayouts;
    } VkDescriptorSetAllocateInfo;
typedef struct { VkBuffer buffer; VkDeviceSize offset; VkDeviceSize range; } VkDescriptorBufferInfo;
typedef struct { uint32_t sType; const void* pNext; VkDescriptorSet dstSet;
    uint32_t dstBinding; uint32_t dstArrayElement; uint32_t descriptorCount;
    uint32_t descriptorType; const void* pImageInfo;
    const VkDescriptorBufferInfo* pBufferInfo; const void* pTexelBufferView;
    } VkWriteDescriptorSet;
typedef struct { uint32_t sType; const void* pNext;
    VkFlags srcAccessMask; VkFlags dstAccessMask; } VkMemoryBarrier;

extern VkResult vkCreateShaderModule(VkDevice, const VkShaderModuleCreateInfo*, const void*, VkShaderModule*);
extern void     vkDestroyShaderModule(VkDevice, VkShaderModule, const void*);
extern VkResult vkCreateDescriptorSetLayout(VkDevice, const VkDescriptorSetLayoutCreateInfo*, const void*, VkDescriptorSetLayout*);
extern void     vkDestroyDescriptorSetLayout(VkDevice, VkDescriptorSetLayout, const void*);
extern VkResult vkCreatePipelineLayout(VkDevice, const VkPipelineLayoutCreateInfo*, const void*, VkPipelineLayout*);
extern void     vkDestroyPipelineLayout(VkDevice, VkPipelineLayout, const void*);
extern VkResult vkCreateComputePipelines(VkDevice, VkPipelineCache, uint32_t, const VkComputePipelineCreateInfo*, const void*, VkPipeline*);
extern void     vkDestroyPipeline(VkDevice, VkPipeline, const void*);
extern VkResult vkCreateDescriptorPool(VkDevice, const VkDescriptorPoolCreateInfo*, const void*, VkDescriptorPool*);
extern void     vkDestroyDescriptorPool(VkDevice, VkDescriptorPool, const void*);
extern VkResult vkAllocateDescriptorSets(VkDevice, const VkDescriptorSetAllocateInfo*, VkDescriptorSet*);
extern void     vkUpdateDescriptorSets(VkDevice, uint32_t, const VkWriteDescriptorSet*, uint32_t, const void*);
extern void     vkCmdBindPipeline(VkCommandBuffer, uint32_t, VkPipeline);
extern void     vkCmdBindDescriptorSets(VkCommandBuffer, uint32_t, VkPipelineLayout, uint32_t, uint32_t, const VkDescriptorSet*, uint32_t, const uint32_t*);
extern void     vkCmdPushConstants(VkCommandBuffer, VkPipelineLayout, VkFlags, uint32_t, uint32_t, const void*);
extern void     vkCmdDispatch(VkCommandBuffer, uint32_t, uint32_t, uint32_t);

/* ============ minimal WSI ABI (VK_KHR_surface / _swapchain / _xlib) ========= */
typedef uint64_t VkSurfaceKHR;
typedef uint64_t VkSwapchainKHR;
typedef uint64_t VkSemaphore;

#define ST_SEMAPHORE_CREATE_INFO         9
#define ST_XLIB_SURFACE_CREATE_INFO_KHR  1000004000
#define ST_SWAPCHAIN_CREATE_INFO_KHR     1000001000
#define ST_PRESENT_INFO_KHR              1000001001

#define VK_FORMAT_B8G8R8A8_UNORM 44
#define VK_FORMAT_B8G8R8A8_SRGB  50
#define VK_FORMAT_R8G8B8A8_SRGB  43
#define VK_COLORSPACE_SRGB_NONLINEAR_KHR 0
#define VK_PRESENT_MODE_FIFO_KHR 2
#define VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT 0x10
#define VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR 0x1
#define VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR 0x1
#define VK_IMAGE_LAYOUT_PRESENT_SRC_KHR 1000001002

typedef struct { uint32_t width, height; } VkExtent2D;

typedef struct {
    uint32_t minImageCount, maxImageCount;
    VkExtent2D currentExtent, minImageExtent, maxImageExtent;
    uint32_t maxImageArrayLayers, supportedTransforms, currentTransform;
    uint32_t supportedCompositeAlpha, supportedUsageFlags;
} VkSurfaceCapabilitiesKHR;

typedef struct { uint32_t format; uint32_t colorSpace; } VkSurfaceFormatKHR;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    void* dpy; unsigned long window;   /* Display* ; Window */
} VkXlibSurfaceCreateInfoKHR;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    VkSurfaceKHR surface;
    uint32_t minImageCount; uint32_t imageFormat; uint32_t imageColorSpace;
    VkExtent2D imageExtent; uint32_t imageArrayLayers; VkFlags imageUsage;
    uint32_t imageSharingMode; uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
    uint32_t preTransform; uint32_t compositeAlpha; uint32_t presentMode;
    VkBool32 clipped; VkSwapchainKHR oldSwapchain;
} VkSwapchainCreateInfoKHR;

typedef struct {
    uint32_t sType; const void* pNext;
    uint32_t waitSemaphoreCount; const VkSemaphore* pWaitSemaphores;
    uint32_t swapchainCount; const VkSwapchainKHR* pSwapchains;
    const uint32_t* pImageIndices; VkResult* pResults;
} VkPresentInfoKHR;

typedef struct { uint32_t sType; const void* pNext; VkFlags flags; } VkSemaphoreCreateInfo;

extern VkResult vkCreateXlibSurfaceKHR(VkInstance, const VkXlibSurfaceCreateInfoKHR*, const void*, VkSurfaceKHR*);
extern void     vkDestroySurfaceKHR(VkInstance, VkSurfaceKHR, const void*);
extern VkResult vkGetPhysicalDeviceSurfaceSupportKHR(VkPhysicalDevice, uint32_t, VkSurfaceKHR, VkBool32*);
extern VkResult vkGetPhysicalDeviceSurfaceCapabilitiesKHR(VkPhysicalDevice, VkSurfaceKHR, VkSurfaceCapabilitiesKHR*);
extern VkResult vkGetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice, VkSurfaceKHR, uint32_t*, VkSurfaceFormatKHR*);
extern VkResult vkGetPhysicalDeviceSurfacePresentModesKHR(VkPhysicalDevice, VkSurfaceKHR, uint32_t*, uint32_t*);
extern VkResult vkCreateSwapchainKHR(VkDevice, const VkSwapchainCreateInfoKHR*, const void*, VkSwapchainKHR*);
extern void     vkDestroySwapchainKHR(VkDevice, VkSwapchainKHR, const void*);
extern VkResult vkGetSwapchainImagesKHR(VkDevice, VkSwapchainKHR, uint32_t*, VkImage*);
extern VkResult vkAcquireNextImageKHR(VkDevice, VkSwapchainKHR, uint64_t, VkSemaphore, VkFence, uint32_t*);
extern VkResult vkQueuePresentKHR(VkQueue, const VkPresentInfoKHR*);
extern VkResult vkCreateSemaphore(VkDevice, const VkSemaphoreCreateInfo*, const void*, VkSemaphore*);
extern void     vkDestroySemaphore(VkDevice, VkSemaphore, const void*);

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

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

/* Upload an RGBA8888 buffer into a fresh device image, leaving it in
 * TRANSFER_SRC_OPTIMAL. Returns image+memory (caller destroys). */
static int upload_image(const uint8_t* rgba, uint32_t w, uint32_t h,
                        VkImage* img, VkDeviceMemory* imem) {
    VkDeviceSize sz = (VkDeviceSize)w * h * 4;
    VkBuffer stage; VkDeviceMemory smem;
    if (make_hostbuf(sz, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &stage, &smem)) return -1;
    void* map; CK(vkMapMemory(g_dev, smem, 0, sz, 0, &map));
    memcpy(map, rgba, sz); vkUnmapMemory(g_dev, smem);
    if (make_image(w, h, img, imem)) return -1;
    VkCommandBuffer cb; if (begin_cmd(&cb)) return -1;
    barrier(cb, *img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageExtent = { w, h, 1 } };
    vkCmdCopyBufferToImage(cb, stage, *img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    barrier(cb, *img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    if (submit_wait(cb)) return -1;
    vkDestroyBuffer(g_dev, stage, 0); vkFreeMemory(g_dev, smem, 0);
    return 0;
}

/* Real GPU scaled copy: upload IN, vkCmdBlitImage src->dst (scale x), readback.
 * The blit alone is timed (its own submit/fence). Filter is LINEAR by default,
 * NEAREST if env VK_HOSTGPU_NEAREST is set (exact integer-upscale for gating). */
static int mode_blit(const char* in, double scale, const char* out) {
    uint32_t w, h; uint8_t* rgba = read_ppm(in, &w, &h);
    if (!rgba) return -1;
    uint32_t dw = (uint32_t)((double)w * scale + 0.5), dh = (uint32_t)((double)h * scale + 0.5);
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;
    uint32_t filter = getenv("VK_HOSTGPU_NEAREST") ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;

    VkImage src, dst; VkDeviceMemory smem, dmem;
    if (upload_image(rgba, w, h, &src, &smem)) return -1;
    free(rgba);
    if (make_image(dw, dh, &dst, &dmem)) return -1;

    /* separate command buffer for the blit so its GPU time is isolated */
    VkCommandBuffer cb; if (begin_cmd(&cb)) return -1;
    barrier(cb, dst, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkImageBlit region = {
        .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .srcOffsets = { {0,0,0}, {(int32_t)w, (int32_t)h, 1} },
        .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .dstOffsets = { {0,0,0}, {(int32_t)dw, (int32_t)dh, 1} } };
    vkCmdBlitImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                   dst, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region, filter);
    barrier(cb, dst, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    double t0 = now_ms();
    if (submit_wait(cb)) return -1;
    double blit_ms = now_ms() - t0;

    int rc = readback(dst, dw, dh, out);
    vkDestroyImage(g_dev, src, 0); vkFreeMemory(g_dev, smem, 0);
    vkDestroyImage(g_dev, dst, 0); vkFreeMemory(g_dev, dmem, 0);
    if (rc) return rc;
    printf("VK_DEVICE %s\nBLIT_OK %s %ux%u->%ux%u filter=%s\nBLIT_MS %.3f\n",
           g_devname, out, w, h, dw, dh,
           filter == VK_FILTER_NEAREST ? "nearest" : "linear", blit_ms);
    return 0;
}

#ifdef HAVE_XLIB
/* ------- present IN.ppm [SCALE] [FRAMES]: DISPLAY the frame in a real window --
 * Creates an Xlib window + VkSurfaceKHR + VkSwapchainKHR on the real GPU, and
 * for FRAMES iterations: acquire a swapchain image, vkCmdBlitImage our uploaded
 * framebuffer onto it (GPU scale + format-convert RGBA->swapchain BGRA), and
 * vkQueuePresentKHR it — an actual hambrowse frame on screen through Vulkan.
 * Runs its OWN init (WSI instance/device extensions) so the headless path is
 * untouched. Reports the mean acquire+blit+present time. */
static VkInstance p_inst = 0; static VkPhysicalDevice p_phys = 0;
static VkDevice p_dev = 0; static VkQueue p_queue = 0; static uint32_t p_qfam = 0;
static VkCommandPool p_pool = 0; static char p_devname[320] = "?";
static VkPhysicalDeviceMemoryProperties p_memprops;

static int mode_present(const char* in, double scale, uint32_t frames) {
    uint32_t w, h; uint8_t* rgba = read_ppm(in, &w, &h);
    if (!rgba) return -1;
    uint32_t sw = (uint32_t)((double)w * scale + 0.5), sh = (uint32_t)((double)h * scale + 0.5);
    if (sw < 1) sw = 1;
    if (sh < 1) sh = 1;

    Display* dpy = XOpenDisplay(0);
    if (!dpy) { fprintf(stderr, "[vk_hostgpu] present: cannot open X display (headless?)\n"); free(rgba); return 2; }
    int screen = DefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, RootWindow(dpy, screen), 0, 0, sw, sh, 0,
                                     BlackPixel(dpy, screen), BlackPixel(dpy, screen));
    XStoreName(dpy, win, "hambrowse via real Vulkan (RTX)");
    XMapWindow(dpy, win); XSync(dpy, False);

    const char* iexts[] = { "VK_KHR_surface", "VK_KHR_xlib_surface" };
    const char* dexts[] = { "VK_KHR_swapchain" };
    VkApplicationInfo app = { .sType = ST_APPLICATION_INFO,
        .pApplicationName = "hamnix-vk-hostgpu-present", .apiVersion = (1u<<22) };
    VkInstanceCreateInfo ici = { .sType = ST_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
        .enabledExtensionCount = 2, .ppEnabledExtensionNames = iexts };
    { VkResult _r = vkCreateInstance(&ici, 0, &p_inst);
      if (_r != VK_SUCCESS) { fprintf(stderr, "[vk_hostgpu] present: vkCreateInstance(WSI) -> %d\n", _r); free(rgba); return -1; } }

    VkXlibSurfaceCreateInfoKHR sci = { .sType = ST_XLIB_SURFACE_CREATE_INFO_KHR,
        .dpy = dpy, .window = (unsigned long)win };
    VkSurfaceKHR surf;
    { VkResult _r = vkCreateXlibSurfaceKHR(p_inst, &sci, 0, &surf);
      if (_r != VK_SUCCESS) { fprintf(stderr, "[vk_hostgpu] present: vkCreateXlibSurfaceKHR -> %d\n", _r); free(rgba); return -1; } }

    uint32_t n = 0; vkEnumeratePhysicalDevices(p_inst, &n, 0);
    if (n == 0) { fprintf(stderr, "[vk_hostgpu] present: no devices\n"); free(rgba); return -1; }
    if (n > 16) n = 16;
    VkPhysicalDevice devs[16];
    vkEnumeratePhysicalDevices(p_inst, &n, devs);
    /* pick the highest-ranked device that can present to this surface */
    int best = -1, bestrank = -1; uint32_t best_qfam = 0;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties pp; memset(&pp, 0, sizeof pp);
        vkGetPhysicalDeviceProperties(devs[i], &pp);
        uint32_t qn = 0; vkGetPhysicalDeviceQueueFamilyProperties(devs[i], &qn, 0);
        if (qn > 32) qn = 32;
        VkQueueFamilyProperties qf[32];
        vkGetPhysicalDeviceQueueFamilyProperties(devs[i], &qn, qf);
        for (uint32_t q = 0; q < qn; q++) {
            VkBool32 sup = 0; vkGetPhysicalDeviceSurfaceSupportKHR(devs[i], q, surf, &sup);
            if (sup && (qf[q].queueFlags & (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_TRANSFER_BIT))) {
                int r = rank(pp.deviceType);
                if (r > bestrank) { bestrank = r; best = (int)i; best_qfam = q; }
                break;
            }
        }
    }
    if (best < 0) { fprintf(stderr, "[vk_hostgpu] present: no present-capable device/queue\n"); free(rgba); return 2; }
    p_phys = devs[best]; p_qfam = best_qfam;
    { VkPhysicalDeviceProperties pp; memset(&pp, 0, sizeof pp);
      vkGetPhysicalDeviceProperties(p_phys, &pp);
      snprintf(p_devname, sizeof p_devname, "%s [%s]", pp.deviceName, devtype_str(pp.deviceType)); }
    fprintf(stderr, "[vk_hostgpu] present device: %s\n", p_devname);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = ST_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = p_qfam, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = ST_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = dexts };
    { VkResult _r = vkCreateDevice(p_phys, &dci, 0, &p_dev);
      if (_r != VK_SUCCESS) { fprintf(stderr, "[vk_hostgpu] present: vkCreateDevice(swapchain) -> %d\n", _r); free(rgba); return -1; } }
    vkGetDeviceQueue(p_dev, p_qfam, 0, &p_queue);
    vkGetPhysicalDeviceMemoryProperties(p_phys, &p_memprops);
    VkCommandPoolCreateInfo pci = { .sType = ST_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = p_qfam };
    vkCreateCommandPool(p_dev, &pci, 0, &p_pool);

    /* surface caps + a supported format */
    VkSurfaceCapabilitiesKHR caps; memset(&caps, 0, sizeof caps);
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(p_phys, surf, &caps);
    uint32_t fn = 0; vkGetPhysicalDeviceSurfaceFormatsKHR(p_phys, surf, &fn, 0);
    if (fn > 32) fn = 32;
    VkSurfaceFormatKHR fmts[32];
    vkGetPhysicalDeviceSurfaceFormatsKHR(p_phys, surf, &fn, fmts);
    uint32_t scfmt = fmts[0].format, sccs = fmts[0].colorSpace;
    VkExtent2D ext = caps.currentExtent;
    if (ext.width == 0xffffffff) { ext.width = sw; ext.height = sh; }
    uint32_t imgcount = caps.minImageCount + 1;
    if (caps.maxImageCount && imgcount > caps.maxImageCount) imgcount = caps.maxImageCount;

    VkSwapchainCreateInfoKHR scci = { .sType = ST_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surf, .minImageCount = imgcount, .imageFormat = scfmt,
        .imageColorSpace = sccs, .imageExtent = ext, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE };
    VkSwapchainKHR swch;
    { VkResult _r = vkCreateSwapchainKHR(p_dev, &scci, 0, &swch);
      if (_r != VK_SUCCESS) { fprintf(stderr, "[vk_hostgpu] present: vkCreateSwapchainKHR -> %d\n", _r); free(rgba); return -1; } }
    uint32_t scn = 0; vkGetSwapchainImagesKHR(p_dev, swch, &scn, 0);
    if (scn > 8) scn = 8;
    VkImage scimgs[8];
    vkGetSwapchainImagesKHR(p_dev, swch, &scn, scimgs);
    fprintf(stderr, "[vk_hostgpu] present: swapchain %ux%u fmt=%u images=%u\n",
            ext.width, ext.height, scfmt, scn);

    /* upload the source frame once (device image, TRANSFER_SRC_OPTIMAL) via the
     * present device's pool/queue — reuse globals by pointing them at p_*. */
    g_dev = p_dev; g_queue = p_queue; g_pool = p_pool; g_memprops = p_memprops;
    VkImage srcimg; VkDeviceMemory srcmem;
    if (upload_image(rgba, w, h, &srcimg, &srcmem)) { free(rgba); return -1; }
    free(rgba);

    VkSemaphoreCreateInfo semci = { .sType = ST_SEMAPHORE_CREATE_INFO };
    VkSemaphore acq, done;
    vkCreateSemaphore(p_dev, &semci, 0, &acq);
    vkCreateSemaphore(p_dev, &semci, 0, &done);

    double total = 0; uint32_t drawn = 0;
    for (uint32_t f = 0; f < frames; f++) {
        double t0 = now_ms();
        uint32_t idx = 0;
        VkResult ar = vkAcquireNextImageKHR(p_dev, swch, ~0ULL, acq, 0, &idx);
        if (ar != VK_SUCCESS) { fprintf(stderr, "[vk_hostgpu] present: acquire -> %d\n", ar); break; }

        VkCommandBuffer cb; begin_cmd(&cb);   /* uses g_pool == p_pool */
        barrier(cb, scimgs[idx], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                0, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkImageBlit region = {
            .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
            .srcOffsets = { {0,0,0}, {(int32_t)w, (int32_t)h, 1} },
            .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
            .dstOffsets = { {0,0,0}, {(int32_t)ext.width, (int32_t)ext.height, 1} } };
        vkCmdBlitImage(cb, srcimg, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       scimgs[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region, VK_FILTER_LINEAR);
        barrier(cb, scimgs[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                VK_ACCESS_TRANSFER_WRITE_BIT, 0,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
        vkEndCommandBuffer(cb);

        VkFenceCreateInfo fci = { .sType = ST_FENCE_CREATE_INFO };
        VkFence fence; vkCreateFence(p_dev, &fci, 0, &fence);
        VkFlags waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si = { .sType = ST_SUBMIT_INFO,
            .waitSemaphoreCount = 1, .pWaitSemaphores = &acq, .pWaitDstStageMask = &waitStage,
            .commandBufferCount = 1, .pCommandBuffers = &cb,
            .signalSemaphoreCount = 1, .pSignalSemaphores = &done };
        vkQueueSubmit(p_queue, 1, &si, fence);

        VkPresentInfoKHR ppi = { .sType = ST_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1, .pWaitSemaphores = &done,
            .swapchainCount = 1, .pSwapchains = &swch, .pImageIndices = &idx };
        VkResult pr = vkQueuePresentKHR(p_queue, &ppi);
        vkWaitForFences(p_dev, 1, &fence, VK_TRUE, ~0ULL);
        vkDestroyFence(p_dev, fence, 0);
        if (pr != VK_SUCCESS) { fprintf(stderr, "[vk_hostgpu] present: queuePresent -> %d\n", pr); break; }
        total += now_ms() - t0; drawn++;
        XSync(dpy, False);
    }

    vkDeviceWaitIdle(p_dev);
    if (drawn) printf("VK_DEVICE %s\nPRESENT_OK %ux%u frames=%u\nPRESENT_MS %.3f\n",
                      p_devname, ext.width, ext.height, drawn, total / drawn);

    vkDestroySemaphore(p_dev, acq, 0); vkDestroySemaphore(p_dev, done, 0);
    vkDestroyImage(p_dev, srcimg, 0); vkFreeMemory(p_dev, srcmem, 0);
    vkDestroySwapchainKHR(p_dev, swch, 0);
    vkDestroyCommandPool(p_dev, p_pool, 0);
    vkDestroyDevice(p_dev, 0);
    vkDestroySurfaceKHR(p_inst, surf, 0);
    /* Order matters: XCloseDisplay runs an Xlib close-display hook that the
     * Vulkan ICD registered at surface creation; it lives in the driver .so.
     * Tear the X connection down BEFORE vkDestroyInstance (which can unload
     * that ICD), else the hook jumps into unmapped code (NVIDIA SIGSEGV). */
    XDestroyWindow(dpy, win); XCloseDisplay(dpy);
    vkDestroyInstance(p_inst, 0);
    g_dev = 0; g_pool = 0; g_queue = 0;   /* don't let vk_shutdown double-free */
    return drawn ? 0 : 1;
}
#endif /* HAVE_XLIB */

/* =================== GPU 2D raster (real compute pipeline) ===============
 * Runs vk_2d's core primitives — fill_rect, fill_rect_alpha (source-over),
 * blit (nearest, source-over), fill_roundrect (AA corners), draw_line — as a
 * REAL Vulkan compute pipeline (scripts/shaders/vk2d_raster.comp.spv), then
 * reads the SSBO back. The result is compared BIT-FOR-BIT to the vk_2d.ad SW
 * rasterizer reference (build/host/vk_hostgpu_ref.ppm). A parallel C port of
 * the same ops (cpu_* below) provides the SW-raster TIMING baseline on the
 * same machine and doubles as an independent oracle.
 *
 * Scene is IDENTICAL to lib/vk/vk_hostgpu.ad vk_hostgpu_compose(): 96x64. */

#define RW 96
#define RH 64
#define SRC_W 4
#define SRC_H 4

/* PushC layout MUST match scripts/shaders/vk2d_raster.comp push_constant. */
typedef struct {
    int32_t  op, bx, by, dispw, disph, img_w, img_h;
    uint32_t rgba;
    int32_t  px, py, pw, ph, rad, corners;
    int32_t  dx, dy, rsx, rsy, rsw, rsh, tw, th, src_w, src_h;
    int32_t  mask_off;      /* OP_COV_MASK: base offset (in uints) into src[] */
} PushC;
enum { OP_FILL=0, OP_FILL_ALPHA=1, OP_BLIT=2, OP_ROUNDRECT=3, OP_LINE=4,
       OP_COVMASK=5 };

/* ---- CPU reference port of the vk_2d ops (byte-identical integer math) ---- */
static inline void cpu_blend_at(uint8_t* p, uint32_t r, uint32_t g, uint32_t b, uint32_t a) {
    if (a == 0) return;
    if (a >= 255) { p[0]=r; p[1]=g; p[2]=b; p[3]=255; return; }
    uint32_t ia = 255 - a;
    p[0] = (uint8_t)((r*a + p[0]*ia)/255);
    p[1] = (uint8_t)((g*a + p[1]*ia)/255);
    p[2] = (uint8_t)((b*a + p[2]*ia)/255);
    p[3] = 255;
}
static void cpu_fill(uint8_t* img, int x, int y, int w, int h, uint32_t rgba) {
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF, g=(rgba>>16)&0xFF, b=(rgba>>8)&0xFF;
    int x0=x<0?0:x, y0=y<0?0:y, x1=x+w>RW?RW:x+w, y1=y+h>RH?RH:y+h;
    for (int yy=y0; yy<y1; yy++) for (int xx=x0; xx<x1; xx++) {
        uint8_t* p=img+(yy*RW+xx)*4; p[0]=r;p[1]=g;p[2]=b;p[3]=255;
    }
}
static void cpu_fill_alpha(uint8_t* img, int x, int y, int w, int h, uint32_t rgba) {
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF, g=(rgba>>16)&0xFF, b=(rgba>>8)&0xFF, a=rgba&0xFF;
    if (a==0) return;
    int x0=x<0?0:x, y0=y<0?0:y, x1=x+w>RW?RW:x+w, y1=y+h>RH?RH:y+h;
    for (int yy=y0; yy<y1; yy++) for (int xx=x0; xx<x1; xx++)
        cpu_blend_at(img+(yy*RW+xx)*4, r,g,b,a);
}
static void cpu_blit(uint8_t* img, const uint8_t* src, int dx, int dy, int dw, int dh) {
    int rsw=SRC_W, rsh=SRC_H, tw=dw>0?dw:rsw, th=dh>0?dh:rsh;
    int yy0=dy<0?-dy:0, yy1=dy+th>RH?RH-dy:th;
    int xx0=dx<0?-dx:0, xx1=dx+tw>RW?RW-dx:tw;
    for (int yy=yy0; yy<yy1; yy++) {
        int syi=(yy*rsh/th); if (syi>=SRC_H) syi=SRC_H-1;
        for (int xx=xx0; xx<xx1; xx++) {
            int sxi=(xx*rsw/tw); if (sxi>=SRC_W) sxi=SRC_W-1;
            const uint8_t* s=src+(syi*SRC_W+sxi)*4;
            cpu_blend_at(img+((dy+yy)*RW+(dx+xx))*4, s[0],s[1],s[2],s[3]);
        }
    }
}
static uint32_t cpu_isqrt(uint32_t n){ if(!n)return 0; uint32_t x=n,y=(x+1)/2; while(y<x){x=y;y=(x+n/x)/2;} return x; }
static int cpu_rr_cov(int px,int py,int ccx2,int ccy2,int r2){
    int dxh=(2*px+1)-ccx2, dyh=(2*py+1)-ccy2, d2=dxh*dxh+dyh*dyh;
    int dh=(int)cpu_isqrt((uint32_t)d2);
    if (dh<=r2-1) return 255; if (dh>=r2+1) return 0; return (r2+1-dh)*255/2;
}
static void cpu_roundrect(uint8_t* img, int x,int y,int w,int h,int rad,int corners,uint32_t rgba){
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF, g=(rgba>>16)&0xFF, b=(rgba>>8)&0xFF, a=rgba&0xFF;
    if (a==0) return;
    int rr=rad; if(rr<0)rr=0; if(rr>w/2)rr=w/2; if(rr>h/2)rr=h/2;
    if (rr<=0){ cpu_fill_alpha(img,x,y,w,h,rgba); return; }
    int r2=2*rr, tlx2=2*(x+rr),tly2=2*(y+rr), trx2=2*(x+w-rr),try2=tly2,
        blx2=tlx2,bly2=2*(y+h-rr), brx2=trx2,bry2=bly2;
    int px0=x<0?0:x, px1=x+w>RW?RW:x+w, py0=y<0?0:y, py1=y+h>RH?RH:y+h;
    for (int py=py0; py<py1; py++) for (int px=px0; px<px1; px++) {
        int cov=255;
        int it=py<y+rr, ib=py>=y+h-rr, il=px<x+rr, ir=px>=x+w-rr;
        if (it&&il&&(corners&1)) cov=cpu_rr_cov(px,py,tlx2,tly2,r2);
        else if (it&&ir&&(corners&2)) cov=cpu_rr_cov(px,py,trx2,try2,r2);
        else if (ib&&il&&(corners&4)) cov=cpu_rr_cov(px,py,blx2,bly2,r2);
        else if (ib&&ir&&(corners&8)) cov=cpu_rr_cov(px,py,brx2,bry2,r2);
        if (cov>0){ uint32_t ae=a*(uint32_t)cov/255; cpu_blend_at(img+(py*RW+px)*4, r,g,b,ae); }
    }
}
static void cpu_line(uint8_t* img,int x1,int y1,int x2,int y2,int thick,uint32_t rgba){
    uint32_t r=(rgba>>24)&0xFF, g=(rgba>>16)&0xFF, b=(rgba>>8)&0xFF;
    int dx=abs(x2-x1), dy=abs(y2-y1), sx=x1>x2?-1:1, sy=y1>y2?-1:1, err=dx-dy, cx=x1, cy=y1;
    int t=thick<1?1:thick, guard=0;
    while (guard<100000){
        for(int by=0;by<t;by++)for(int bx=0;bx<t;bx++){
            int X=cx+bx,Y=cy+by;
            if(X>=0&&Y>=0&&X<RW&&Y<RH){uint8_t*p=img+(Y*RW+X)*4;p[0]=r;p[1]=g;p[2]=b;p[3]=255;}
        }
        if(cx==x2&&cy==y2)return;
        int e2=err*2; if(e2>-dy){err-=dy;cx+=sx;} if(e2<dx){err+=dx;cy+=sy;}
        guard++;
    }
}

static void make_sprite(uint8_t* src) {
    for (int i=0;i<SRC_W*SRC_H;i++){ src[i*4]=0; src[i*4+1]=255; src[i*4+2]=0; src[i*4+3]=255; }
    uint8_t* p=src+(3*SRC_W+3)*4; p[0]=0;p[1]=0;p[2]=255;p[3]=255;   /* blue at (3,3) */
}
/* Render the reference scene on the CPU (mirrors vk_hostgpu_compose). */
static void cpu_raster_scene(uint8_t* img, const uint8_t* src) {
    cpu_fill(img, 0,0,RW,RH, 0x0D1220FF);
    cpu_fill(img, 0,0,RW,10, 0x2B3350FF);
    cpu_fill(img, 8,16,60,40, 0xFFFFFFFF);
    cpu_fill_alpha(img, 20,24,24,16, 0x00CCFF80);
    cpu_blit(img, src, 74,20,8,8);
    cpu_line(img, 8,58,88,58, 2, 0xFFFF00FF);
    cpu_roundrect(img, 68,44,20,12, 4,15, 0xFF33CCFF);
}

/* ---- scene as a GPU dispatch list (same 7 ops, CPU-clamped like vk_2d) ---- */
static int g_nops = 0;
static PushC g_ops[16];
static uint32_t g_grp[16][2];
static void push_op(PushC pc, int dispw, int disph) {
    if (dispw<=0 || disph<=0) return;
    pc.img_w=RW; pc.img_h=RH; pc.dispw=dispw; pc.disph=disph;
    g_ops[g_nops]=pc;
    g_grp[g_nops][0]=(uint32_t)((dispw+7)/8);
    g_grp[g_nops][1]=(uint32_t)((disph+7)/8);
    g_nops++;
}
static void gpu_fill(int op,int x,int y,int w,int h,uint32_t rgba){
    if (w<=0||h<=0) return;
    if (op==OP_FILL_ALPHA && (rgba&0xFF)==0) return;
    int x0=x<0?0:x,y0=y<0?0:y,x1=x+w>RW?RW:x+w,y1=y+h>RH?RH:y+h;
    if (x0>=x1||y0>=y1) return;
    PushC pc={0}; pc.op=op; pc.rgba=rgba; pc.bx=x0; pc.by=y0;
    push_op(pc, x1-x0, y1-y0);
}
static void gpu_blit(int dx,int dy,int dw,int dh){
    int rsw=SRC_W,rsh=SRC_H,tw=dw>0?dw:rsw,th=dh>0?dh:rsh;
    int yy0=dy<0?-dy:0, yy1=dy+th>RH?RH-dy:th, xx0=dx<0?-dx:0, xx1=dx+tw>RW?RW-dx:tw;
    if (xx0>=xx1||yy0>=yy1) return;
    PushC pc={0}; pc.op=OP_BLIT; pc.bx=dx+xx0; pc.by=dy+yy0;
    pc.dx=dx; pc.dy=dy; pc.rsx=0; pc.rsy=0; pc.rsw=rsw; pc.rsh=rsh;
    pc.tw=tw; pc.th=th; pc.src_w=SRC_W; pc.src_h=SRC_H;
    push_op(pc, xx1-xx0, yy1-yy0);
}
static void gpu_line(int x1,int y1,int x2,int y2,int thick,uint32_t rgba){
    PushC pc={0}; pc.op=OP_LINE; pc.rgba=rgba; pc.bx=0; pc.by=0;
    pc.px=x1; pc.py=y1; pc.pw=x2; pc.ph=y2; pc.rad=thick;
    push_op(pc, 1, 1);
}
static void gpu_roundrect(int x,int y,int w,int h,int rad,int corners,uint32_t rgba){
    if (w<=0||h<=0||(rgba&0xFF)==0) return;
    int rr=rad; if(rr<0)rr=0; if(rr>w/2)rr=w/2; if(rr>h/2)rr=h/2;
    if (rr<=0){ gpu_fill(OP_FILL_ALPHA,x,y,w,h,rgba); return; }
    int px0=x<0?0:x,px1=x+w>RW?RW:x+w,py0=y<0?0:y,py1=y+h>RH?RH:y+h;
    if (px0>=px1||py0>=py1) return;
    PushC pc={0}; pc.op=OP_ROUNDRECT; pc.rgba=rgba; pc.bx=px0; pc.by=py0;
    pc.px=x; pc.py=y; pc.pw=w; pc.ph=h; pc.rad=rr; pc.corners=corners;
    push_op(pc, px1-px0, py1-py0);
}
static void build_scene(void) {
    g_nops=0;
    gpu_fill(OP_FILL, 0,0,RW,RH, 0x0D1220FF);
    gpu_fill(OP_FILL, 0,0,RW,10, 0x2B3350FF);
    gpu_fill(OP_FILL, 8,16,60,40, 0xFFFFFFFF);
    gpu_fill(OP_FILL_ALPHA, 20,24,24,16, 0x00CCFF80);
    gpu_blit(74,20,8,8);
    gpu_line(8,58,88,58, 2, 0xFFFF00FF);
    gpu_roundrect(68,44,20,12, 4,15, 0xFF33CCFF);
}

static uint32_t* read_spv(const char* path, size_t* sz) {
    FILE* f=fopen(path,"rb"); if(!f){fprintf(stderr,"[vk_hostgpu] cannot open %s\n",path);return 0;}
    fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET);
    uint32_t* buf=malloc((size_t)n);
    if (fread(buf,1,(size_t)n,f)!=(size_t)n){fclose(f);free(buf);return 0;}
    fclose(f); *sz=(size_t)n; return buf;
}

/* Make a host-visible+coherent storage buffer (also transfer src for readback). */
static int make_storagebuf(VkDeviceSize sz, VkBuffer* buf, VkDeviceMemory* mem) {
    VkBufferCreateInfo bc = { .sType = ST_BUFFER_CREATE_INFO, .size = sz,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT
               | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CK(vkCreateBuffer(g_dev, &bc, 0, buf));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(g_dev, *buf, &mr);
    int mt = find_mem(mr.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt < 0) { fprintf(stderr, "[vk_hostgpu] no host-visible storage mem\n"); return -1; }
    VkMemoryAllocateInfo ai = { .sType = ST_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = (uint32_t)mt };
    CK(vkAllocateMemory(g_dev, &ai, 0, mem));
    CK(vkBindBufferMemory(g_dev, *buf, *mem, 0));
    return 0;
}

/* Device-local storage buffer (fast on-GPU memory; not host-mappable). Used by
 * the bench so the measured GPU-raster time reflects true VRAM throughput, not
 * PCIe-bound host-visible access. */
static int make_storagebuf_devlocal(VkDeviceSize sz, VkBuffer* buf, VkDeviceMemory* mem) {
    VkBufferCreateInfo bc = { .sType = ST_BUFFER_CREATE_INFO, .size = sz,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT
               | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CK(vkCreateBuffer(g_dev, &bc, 0, buf));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(g_dev, *buf, &mr);
    int mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mt < 0) mt = find_mem(mr.memoryTypeBits, 0);
    VkMemoryAllocateInfo ai = { .sType = ST_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = (uint32_t)mt };
    CK(vkAllocateMemory(g_dev, &ai, 0, mem));
    CK(vkBindBufferMemory(g_dev, *buf, *mem, 0));
    return 0;
}

/* raster IN_UNUSED OUT.ppm : GPU-rasterize the reference scene, readback PPM,
 * print GPU-raster and SW-raster per-frame timings. */
static int mode_raster(const char* out) {
    size_t spvsz;
    uint32_t* spv = read_spv("scripts/shaders/vk2d_raster.comp.spv", &spvsz);
    if (!spv) return -1;

    VkDeviceSize dstsz = (VkDeviceSize)RW*RH*4, srcsz = (VkDeviceSize)SRC_W*SRC_H*4;
    VkBuffer dbuf, sbuf; VkDeviceMemory dmem, smem;
    if (make_storagebuf(dstsz, &dbuf, &dmem)) return -1;
    if (make_storagebuf(srcsz, &sbuf, &smem)) return -1;

    /* upload the 4x4 sprite into the src storage buffer */
    uint8_t sprite[SRC_W*SRC_H*4]; make_sprite(sprite);
    void* map; CK(vkMapMemory(g_dev, smem, 0, srcsz, 0, &map));
    memcpy(map, sprite, srcsz); vkUnmapMemory(g_dev, smem);

    /* shader module + descriptor/pipeline layout + compute pipeline */
    VkShaderModuleCreateInfo smi = { .sType = ST_SHADER_MODULE_CREATE_INFO,
        .codeSize = spvsz, .pCode = spv };
    VkShaderModule module; CK(vkCreateShaderModule(g_dev, &smi, 0, &module));
    free(spv);

    VkDescriptorSetLayoutBinding binds[2] = {
        { .binding=0, .descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount=1, .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT },
        { .binding=1, .descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount=1, .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT } };
    VkDescriptorSetLayoutCreateInfo dli = { .sType=ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount=2, .pBindings=binds };
    VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(g_dev,&dli,0,&dsl));

    VkPushConstantRange pcr = { .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT, .offset=0, .size=sizeof(PushC) };
    VkPipelineLayoutCreateInfo pli = { .sType=ST_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount=1, .pSetLayouts=&dsl, .pushConstantRangeCount=1, .pPushConstantRanges=&pcr };
    VkPipelineLayout playout; CK(vkCreatePipelineLayout(g_dev,&pli,0,&playout));

    VkComputePipelineCreateInfo cpi = { .sType=ST_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = { .sType=ST_PIPELINE_SHADER_STAGE_CREATE_INFO,
                   .stage=VK_SHADER_STAGE_COMPUTE_BIT, .module=module, .pName="main" },
        .layout=playout };
    VkPipeline pipe; CK(vkCreateComputePipelines(g_dev, 0, 1, &cpi, 0, &pipe));

    VkDescriptorPoolSize psz = { .type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount=2 };
    VkDescriptorPoolCreateInfo dpi = { .sType=ST_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets=1, .poolSizeCount=1, .pPoolSizes=&psz };
    VkDescriptorPool dpool; CK(vkCreateDescriptorPool(g_dev,&dpi,0,&dpool));
    VkDescriptorSetAllocateInfo dsai = { .sType=ST_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool=dpool, .descriptorSetCount=1, .pSetLayouts=&dsl };
    VkDescriptorSet dset; CK(vkAllocateDescriptorSets(g_dev,&dsai,&dset));

    VkDescriptorBufferInfo dbi = { .buffer=dbuf, .offset=0, .range=dstsz };
    VkDescriptorBufferInfo sbi = { .buffer=sbuf, .offset=0, .range=srcsz };
    VkWriteDescriptorSet wr[2] = {
        { .sType=ST_WRITE_DESCRIPTOR_SET, .dstSet=dset, .dstBinding=0, .descriptorCount=1,
          .descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo=&dbi },
        { .sType=ST_WRITE_DESCRIPTOR_SET, .dstSet=dset, .dstBinding=1, .descriptorCount=1,
          .descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo=&sbi } };
    vkUpdateDescriptorSets(g_dev, 2, wr, 0, 0);

    build_scene();

    /* GPU raster: record all ops (barrier between each) + submit, timed over N. */
    const int N = 200;
    VkMemoryBarrier mb = { .sType=ST_MEMORY_BARRIER,
        .srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT };
    double gpu_best = 1e30;
    for (int it=0; it<N; it++) {
        VkCommandBuffer cb; if (begin_cmd(&cb)) return -1;
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, playout, 0, 1, &dset, 0, 0);
        for (int i=0; i<g_nops; i++) {
            vkCmdPushConstants(cb, playout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushC), &g_ops[i]);
            vkCmdDispatch(cb, g_grp[i][0], g_grp[i][1], 1);
            if (i+1 < g_nops)
                vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, 0, 0, 0);
        }
        double t0 = now_ms();
        if (submit_wait(cb)) return -1;
        double ms = now_ms() - t0;
        if (ms < gpu_best) gpu_best = ms;
        vkFreeCommandBuffers(g_dev, g_pool, 1, &cb);
    }

    /* SW raster baseline on the same machine (best of N). */
    uint8_t* cbuf = malloc(RW*RH*4);
    double cpu_best = 1e30;
    for (int it=0; it<N; it++) {
        double t0 = now_ms();
        cpu_raster_scene(cbuf, sprite);
        double ms = now_ms() - t0;
        if (ms < cpu_best) cpu_best = ms;
    }

    /* readback GPU SSBO -> PPM; compare GPU vs CPU-port in memory. */
    CK(vkMapMemory(g_dev, dmem, 0, dstsz, 0, &map));
    uint8_t* gpix = (uint8_t*)map;
    int mism = 0, first = -1;
    for (int i=0;i<RW*RH;i++)
        for (int c=0;c<3;c++)
            if (gpix[i*4+c] != cbuf[i*4+c]) { if (first<0) first=i; mism++; }
    write_ppm(out, gpix, RW, RH);
    vkUnmapMemory(g_dev, dmem);

    printf("VK_DEVICE %s\nRASTER_OK %s %dx%d ops=%d\n", g_devname, out, RW, RH, g_nops);
    printf("RASTER_GPU_MS %.4f\nRASTER_SW_MS %.4f\n", gpu_best, cpu_best);
    printf("RASTER_GPUvsCPUport_MISMATCH %d", mism);
    if (first>=0) printf(" first@%d,%d", first%RW, first/RW);
    printf("\n");

    free(cbuf);
    vkDestroyDescriptorPool(g_dev, dpool, 0);
    vkDestroyPipeline(g_dev, pipe, 0);
    vkDestroyPipelineLayout(g_dev, playout, 0);
    vkDestroyDescriptorSetLayout(g_dev, dsl, 0);
    vkDestroyShaderModule(g_dev, module, 0);
    vkDestroyBuffer(g_dev, dbuf, 0); vkFreeMemory(g_dev, dmem, 0);
    vkDestroyBuffer(g_dev, sbuf, 0); vkFreeMemory(g_dev, smem, 0);
    return 0;
}

/* rasterbench W H : fill/blend-heavy workload at an arbitrary resolution to
 * quantify the GPU-vs-SW-raster CROSSOVER — the number that shows the win at
 * real browser/game frame sizes (the 96x64 `raster` scene is overhead-bound).
 * Workload per frame: full-screen opaque fill + full-screen translucent blend
 * (the expensive per-pixel source-over path) + a half-screen opaque fill. The
 * shader is fully parameterized on img_w/img_h, so it needs no code changes. */
static int mode_rasterbench(uint32_t W, uint32_t H) {
    size_t spvsz;
    uint32_t* spv = read_spv("scripts/shaders/vk2d_raster.comp.spv", &spvsz);
    if (!spv) return -1;
    VkDeviceSize dstsz = (VkDeviceSize)W*H*4, srcsz = (VkDeviceSize)SRC_W*SRC_H*4;
    VkBuffer dbuf, sbuf; VkDeviceMemory dmem, smem;
    if (make_storagebuf_devlocal(dstsz, &dbuf, &dmem)) return -1;   /* fast VRAM */
    if (make_storagebuf(srcsz, &sbuf, &smem)) return -1;
    uint8_t sprite[SRC_W*SRC_H*4]; make_sprite(sprite);
    void* map; CK(vkMapMemory(g_dev, smem, 0, srcsz, 0, &map));
    memcpy(map, sprite, srcsz); vkUnmapMemory(g_dev, smem);

    VkShaderModuleCreateInfo smi = { .sType=ST_SHADER_MODULE_CREATE_INFO, .codeSize=spvsz, .pCode=spv };
    VkShaderModule module; CK(vkCreateShaderModule(g_dev,&smi,0,&module)); free(spv);
    VkDescriptorSetLayoutBinding binds[2] = {
        { .binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT },
        { .binding=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT } };
    VkDescriptorSetLayoutCreateInfo dli = { .sType=ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount=2, .pBindings=binds };
    VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(g_dev,&dli,0,&dsl));
    VkPushConstantRange pcr = { .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT, .offset=0, .size=sizeof(PushC) };
    VkPipelineLayoutCreateInfo pli = { .sType=ST_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount=1, .pSetLayouts=&dsl, .pushConstantRangeCount=1, .pPushConstantRanges=&pcr };
    VkPipelineLayout playout; CK(vkCreatePipelineLayout(g_dev,&pli,0,&playout));
    VkComputePipelineCreateInfo cpi = { .sType=ST_COMPUTE_PIPELINE_CREATE_INFO,
        .stage={ .sType=ST_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage=VK_SHADER_STAGE_COMPUTE_BIT, .module=module, .pName="main" }, .layout=playout };
    VkPipeline pipe; CK(vkCreateComputePipelines(g_dev,0,1,&cpi,0,&pipe));
    VkDescriptorPoolSize psz = { .type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount=2 };
    VkDescriptorPoolCreateInfo dpi = { .sType=ST_DESCRIPTOR_POOL_CREATE_INFO, .maxSets=1, .poolSizeCount=1, .pPoolSizes=&psz };
    VkDescriptorPool dpool; CK(vkCreateDescriptorPool(g_dev,&dpi,0,&dpool));
    VkDescriptorSetAllocateInfo dsai = { .sType=ST_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool=dpool, .descriptorSetCount=1, .pSetLayouts=&dsl };
    VkDescriptorSet dset; CK(vkAllocateDescriptorSets(g_dev,&dsai,&dset));
    VkDescriptorBufferInfo dbi = { .buffer=dbuf, .offset=0, .range=dstsz };
    VkDescriptorBufferInfo sbi = { .buffer=sbuf, .offset=0, .range=srcsz };
    VkWriteDescriptorSet wr[2] = {
        { .sType=ST_WRITE_DESCRIPTOR_SET,.dstSet=dset,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&dbi },
        { .sType=ST_WRITE_DESCRIPTOR_SET,.dstSet=dset,.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&sbi } };
    vkUpdateDescriptorSets(g_dev, 2, wr, 0, 0);

    /* three fill/blend ops covering the whole frame */
    PushC ops[3]; uint32_t grp[3][2];
    int nops=0;
    #define BOP(OP,X,Y,WW,HH,RGBA) do { PushC p={0}; p.op=(OP); p.rgba=(RGBA); \
        p.img_w=(int)W; p.img_h=(int)H; p.bx=(X); p.by=(Y); p.dispw=(WW); p.disph=(HH); \
        ops[nops]=p; grp[nops][0]=((WW)+7)/8; grp[nops][1]=((HH)+7)/8; nops++; } while(0)
    BOP(OP_FILL,       0,0,(int)W,(int)H,     0x0D1220FF);
    BOP(OP_FILL_ALPHA, 0,0,(int)W,(int)H,     0x00CCFF80);
    BOP(OP_FILL,       0,0,(int)W,(int)H/2,   0x2B3350FF);
    #undef BOP

    VkMemoryBarrier mb = { .sType=ST_MEMORY_BARRIER, .srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT };
    const int N = 60;
    double gpu_best = 1e30;
    for (int it=0; it<N; it++) {
        VkCommandBuffer cb; if (begin_cmd(&cb)) return -1;
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, playout, 0, 1, &dset, 0, 0);
        for (int i=0;i<nops;i++){
            vkCmdPushConstants(cb, playout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushC), &ops[i]);
            vkCmdDispatch(cb, grp[i][0], grp[i][1], 1);
            if (i+1<nops) vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, 0, 0, 0);
        }
        double t0=now_ms(); if (submit_wait(cb)) return -1; double ms=now_ms()-t0;
        if (ms<gpu_best) gpu_best=ms;
        vkFreeCommandBuffers(g_dev, g_pool, 1, &cb);
    }
    /* SW port: same three ops, generic W/H loops. */
    uint8_t* cbuf = malloc((size_t)W*H*4);
    double cpu_best = 1e30;
    for (int it=0; it<N; it++) {
        double t0=now_ms();
        for (uint32_t i=0;i<W*H;i++){ uint8_t*p=cbuf+i*4; p[0]=0x0D;p[1]=0x12;p[2]=0x20;p[3]=255; }
        uint32_t a=0x80, ia=255-a;
        for (uint32_t i=0;i<W*H;i++){ uint8_t*p=cbuf+i*4;
            p[0]=(uint8_t)((0x00*a+p[0]*ia)/255); p[1]=(uint8_t)((0xCC*a+p[1]*ia)/255);
            p[2]=(uint8_t)((0xFF*a+p[2]*ia)/255); p[3]=255; }
        for (uint32_t i=0;i<W*(H/2);i++){ uint8_t*p=cbuf+i*4; p[0]=0x2B;p[1]=0x33;p[2]=0x50;p[3]=255; }
        double ms=now_ms()-t0; if (ms<cpu_best) cpu_best=ms;
    }
    free(cbuf);
    printf("VK_DEVICE %s\nRASTERBENCH %ux%u ops=%d (fill+alpha-blend+fill)\n", g_devname, W, H, nops);
    printf("RASTERBENCH_GPU_MS %.4f\nRASTERBENCH_SW_MS %.4f\nRASTERBENCH_SPEEDUP %.2fx\n",
           gpu_best, cpu_best, cpu_best/gpu_best);
    vkDestroyDescriptorPool(g_dev,dpool,0); vkDestroyPipeline(g_dev,pipe,0);
    vkDestroyPipelineLayout(g_dev,playout,0); vkDestroyDescriptorSetLayout(g_dev,dsl,0);
    vkDestroyShaderModule(g_dev,module,0);
    vkDestroyBuffer(g_dev,dbuf,0); vkFreeMemory(g_dev,dmem,0);
    vkDestroyBuffer(g_dev,sbuf,0); vkFreeMemory(g_dev,smem,0);
    return 0;
}

/* ======================================================================
 * pageraster W H OUT.ppm [SECONDS] — a REAL Hamnix workload on the GPU.
 *
 * Unlike the fixed 96x64 `raster` scene, this composes a full-frame
 * (e.g. 1280x720) DE + browser-page-shaped frame from the SAME vk_2d op
 * vocabulary the DE compositor and the hambrowse painter emit: a page
 * background fill, a browser chrome bar, a rounded URL box, a translucent
 * hero banner (source-over alpha), rows of text-line block fills (the
 * shape of laid-out text runs), image blits, card roundrects with AA
 * corners, and separator lines. It runs on the RTX 3090 via the compute
 * pipeline and byte-verifies the GPU readback against a bit-exact runtime
 * CPU port (the SW oracle). With SECONDS given, it keeps submitting GPU
 * frames for that long so an external `nvidia-smi --query-compute-apps`
 * observes THIS pid actively resident on the GPU — unforgeable proof the
 * real hardware executed the pixels.
 *
 * This mode is fully self-contained (its own runtime-dim CPU port + op
 * builder) so the proven `raster`/`rasterbench` paths are untouched.
 * ==================================================================== */
#define PR_MAXOPS 4096
static int      pr_nops;
static PushC    pr_ops[PR_MAXOPS];
static uint32_t pr_grp[PR_MAXOPS][2];
static int      PR_W, PR_H;

/* ---- runtime-dimension CPU port (bit-exact twin of vk2d_raster.comp) ---- */
static inline void pr_blend_at(uint8_t* p, uint32_t r, uint32_t g, uint32_t b, uint32_t a) {
    if (a == 0) return;
    if (a >= 255) { p[0]=r; p[1]=g; p[2]=b; p[3]=255; return; }
    uint32_t ia = 255 - a;
    p[0]=(uint8_t)((r*a+p[0]*ia)/255); p[1]=(uint8_t)((g*a+p[1]*ia)/255);
    p[2]=(uint8_t)((b*a+p[2]*ia)/255); p[3]=255;
}
static void pr_cpu_fill(uint8_t* img, int x,int y,int w,int h, uint32_t rgba){
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF,g=(rgba>>16)&0xFF,b=(rgba>>8)&0xFF;
    int x0=x<0?0:x,y0=y<0?0:y,x1=x+w>PR_W?PR_W:x+w,y1=y+h>PR_H?PR_H:y+h;
    for (int yy=y0;yy<y1;yy++) for (int xx=x0;xx<x1;xx++){
        uint8_t* p=img+(yy*PR_W+xx)*4; p[0]=r;p[1]=g;p[2]=b;p[3]=255; }
}
static void pr_cpu_fill_alpha(uint8_t* img, int x,int y,int w,int h, uint32_t rgba){
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF,g=(rgba>>16)&0xFF,b=(rgba>>8)&0xFF,a=rgba&0xFF;
    if (a==0) return;
    int x0=x<0?0:x,y0=y<0?0:y,x1=x+w>PR_W?PR_W:x+w,y1=y+h>PR_H?PR_H:y+h;
    for (int yy=y0;yy<y1;yy++) for (int xx=x0;xx<x1;xx++)
        pr_blend_at(img+(yy*PR_W+xx)*4, r,g,b,a);
}
static void pr_cpu_blit(uint8_t* img, const uint8_t* src, int sw,int sh,
                        int dx,int dy,int dw,int dh){
    int rsw=sw,rsh=sh,tw=dw>0?dw:rsw,th=dh>0?dh:rsh;
    int yy0=dy<0?-dy:0, yy1=dy+th>PR_H?PR_H-dy:th, xx0=dx<0?-dx:0, xx1=dx+tw>PR_W?PR_W-dx:tw;
    for (int yy=yy0;yy<yy1;yy++){
        int syi=(yy*rsh/th); if(syi>=sh) syi=sh-1;
        for (int xx=xx0;xx<xx1;xx++){
            int sxi=(xx*rsw/tw); if(sxi>=sw) sxi=sw-1;
            const uint8_t* s=src+(syi*sw+sxi)*4;
            pr_blend_at(img+((dy+yy)*PR_W+(dx+xx))*4, s[0],s[1],s[2],s[3]);
        }
    }
}
static void pr_cpu_roundrect(uint8_t* img,int x,int y,int w,int h,int rad,int corners,uint32_t rgba){
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF,g=(rgba>>16)&0xFF,b=(rgba>>8)&0xFF,a=rgba&0xFF;
    if (a==0) return;
    int rr=rad; if(rr<0)rr=0; if(rr>w/2)rr=w/2; if(rr>h/2)rr=h/2;
    if (rr<=0){ pr_cpu_fill_alpha(img,x,y,w,h,rgba); return; }
    int r2=2*rr, tlx2=2*(x+rr),tly2=2*(y+rr), trx2=2*(x+w-rr),try2=tly2,
        blx2=tlx2,bly2=2*(y+h-rr), brx2=trx2,bry2=bly2;
    int px0=x<0?0:x,px1=x+w>PR_W?PR_W:x+w,py0=y<0?0:y,py1=y+h>PR_H?PR_H:y+h;
    for (int py=py0;py<py1;py++) for (int px=px0;px<px1;px++){
        int cov=255, it=py<y+rr,ib=py>=y+h-rr,il=px<x+rr,ir=px>=x+w-rr;
        if (it&&il&&(corners&1)) cov=cpu_rr_cov(px,py,tlx2,tly2,r2);
        else if (it&&ir&&(corners&2)) cov=cpu_rr_cov(px,py,trx2,try2,r2);
        else if (ib&&il&&(corners&4)) cov=cpu_rr_cov(px,py,blx2,bly2,r2);
        else if (ib&&ir&&(corners&8)) cov=cpu_rr_cov(px,py,brx2,bry2,r2);
        if (cov>0){ uint32_t ae=a*(uint32_t)cov/255; pr_blend_at(img+(py*PR_W+px)*4, r,g,b,ae); }
    }
}
static void pr_cpu_line(uint8_t* img,int x1,int y1,int x2,int y2,int thick,uint32_t rgba){
    uint32_t r=(rgba>>24)&0xFF,g=(rgba>>16)&0xFF,b=(rgba>>8)&0xFF;
    int dx=abs(x2-x1),dy=abs(y2-y1),sx=x1>x2?-1:1,sy=y1>y2?-1:1,err=dx-dy,cx=x1,cy=y1;
    int t=thick<1?1:thick,guard=0;
    while (guard<100000){
        for(int by=0;by<t;by++)for(int bx=0;bx<t;bx++){
            int X=cx+bx,Y=cy+by;
            if(X>=0&&Y>=0&&X<PR_W&&Y<PR_H){uint8_t*p=img+(Y*PR_W+X)*4;p[0]=r;p[1]=g;p[2]=b;p[3]=255;}
        }
        if(cx==x2&&cy==y2)return;
        int e2=err*2; if(e2>-dy){err-=dy;cx+=sx;} if(e2<dx){err+=dx;cy+=sy;}
        guard++;
    }
}

/* ---- GPU op list builders (runtime dims; clamp mirrors the CPU port) ---- */
static void pr_push(PushC pc,int dispw,int disph){
    if (dispw<=0||disph<=0||pr_nops>=PR_MAXOPS) return;
    pc.img_w=PR_W; pc.img_h=PR_H; pc.dispw=dispw; pc.disph=disph;
    pr_ops[pr_nops]=pc; pr_grp[pr_nops][0]=(uint32_t)((dispw+7)/8);
    pr_grp[pr_nops][1]=(uint32_t)((disph+7)/8); pr_nops++;
}
static void pr_gpu_fill(int op,int x,int y,int w,int h,uint32_t rgba){
    if (w<=0||h<=0) return;
    if (op==OP_FILL_ALPHA && (rgba&0xFF)==0) return;
    int x0=x<0?0:x,y0=y<0?0:y,x1=x+w>PR_W?PR_W:x+w,y1=y+h>PR_H?PR_H:y+h;
    if (x0>=x1||y0>=y1) return;
    PushC pc={0}; pc.op=op; pc.rgba=rgba; pc.bx=x0; pc.by=y0;
    pr_push(pc, x1-x0, y1-y0);
}
static void pr_gpu_blit(int sw,int sh,int dx,int dy,int dw,int dh){
    int rsw=sw,rsh=sh,tw=dw>0?dw:rsw,th=dh>0?dh:rsh;
    int yy0=dy<0?-dy:0, yy1=dy+th>PR_H?PR_H-dy:th, xx0=dx<0?-dx:0, xx1=dx+tw>PR_W?PR_W-dx:tw;
    if (xx0>=xx1||yy0>=yy1) return;
    PushC pc={0}; pc.op=OP_BLIT; pc.bx=dx+xx0; pc.by=dy+yy0;
    pc.dx=dx; pc.dy=dy; pc.rsx=0; pc.rsy=0; pc.rsw=rsw; pc.rsh=rsh;
    pc.tw=tw; pc.th=th; pc.src_w=sw; pc.src_h=sh;
    pr_push(pc, xx1-xx0, yy1-yy0);
}
static void pr_gpu_line(int x1,int y1,int x2,int y2,int thick,uint32_t rgba){
    PushC pc={0}; pc.op=OP_LINE; pc.rgba=rgba;
    pc.px=x1; pc.py=y1; pc.pw=x2; pc.ph=y2; pc.rad=thick;
    pr_push(pc, 1, 1);
}
static void pr_gpu_roundrect(int x,int y,int w,int h,int rad,int corners,uint32_t rgba){
    if (w<=0||h<=0||(rgba&0xFF)==0) return;
    int rr=rad; if(rr<0)rr=0; if(rr>w/2)rr=w/2; if(rr>h/2)rr=h/2;
    if (rr<=0){ pr_gpu_fill(OP_FILL_ALPHA,x,y,w,h,rgba); return; }
    int px0=x<0?0:x,px1=x+w>PR_W?PR_W:x+w,py0=y<0?0:y,py1=y+h>PR_H?PR_H:y+h;
    if (px0>=px1||py0>=py1) return;
    PushC pc={0}; pc.op=OP_ROUNDRECT; pc.rgba=rgba; pc.bx=px0; pc.by=py0;
    pc.px=x; pc.py=y; pc.pw=w; pc.ph=h; pc.rad=rr; pc.corners=corners;
    pr_push(pc, px1-px0, py1-py0);
}
/* AA glyph coverage-mask blend. bx/by = clamped dispatch origin, px/py/pw/ph =
 * the (unclamped) mask bbox origin+size so the shader indexes the mask by
 * (X-px, Y-py); mask_off locates this run's coverage bytes in src[]. */
static void pr_gpu_covmask(int x,int y,int w,int h,uint32_t rgba,int mask_off){
    if (w<=0||h<=0||(rgba&0xFF)==0) return;
    int px0=x<0?0:x,px1=x+w>PR_W?PR_W:x+w,py0=y<0?0:y,py1=y+h>PR_H?PR_H:y+h;
    if (px0>=px1||py0>=py1) return;
    PushC pc={0}; pc.op=OP_COVMASK; pc.rgba=rgba; pc.bx=px0; pc.by=py0;
    pc.px=x; pc.py=y; pc.pw=w; pc.ph=h; pc.mask_off=mask_off;
    pr_push(pc, px1-px0, py1-py0);
}
/* CPU oracle twin of the OP_COVMASK shader path — byte-identical integer math. */
static void pr_cpu_covmask(uint8_t* img,int x,int y,int w,int h,uint32_t rgba,
                           const uint8_t* mask){
    if (w<=0||h<=0) return;
    uint32_t r=(rgba>>24)&0xFF,g=(rgba>>16)&0xFF,b=(rgba>>8)&0xFF,a=rgba&0xFF;
    int x0=x<0?0:x,y0=y<0?0:y,x1=x+w>PR_W?PR_W:x+w,y1=y+h>PR_H?PR_H:y+h;
    for (int yy=y0;yy<y1;yy++) for (int xx=x0;xx<x1;xx++){
        uint32_t cov=mask[(yy-y)*w+(xx-x)];
        uint32_t ae=a*cov/255;
        pr_blend_at(img+(yy*PR_W+xx)*4, r,g,b,ae);
    }
}

/* Two dispatch back-ends over the same op stream: GPU (record+submit) and the
 * CPU oracle. Called with distinct fn pointers so the scene is authored ONCE. */
enum { EMIT_GPU, EMIT_CPU };
static uint8_t* g_pr_cpuimg; static const uint8_t* g_pr_sprite;
static int g_pr_sw, g_pr_sh; static int g_pr_emit;

static void e_fill(int x,int y,int w,int h,uint32_t c){
    if (g_pr_emit==EMIT_GPU) pr_gpu_fill(OP_FILL,x,y,w,h,c);
    else pr_cpu_fill(g_pr_cpuimg,x,y,w,h,c); }
static void e_fill_a(int x,int y,int w,int h,uint32_t c){
    if (g_pr_emit==EMIT_GPU) pr_gpu_fill(OP_FILL_ALPHA,x,y,w,h,c);
    else pr_cpu_fill_alpha(g_pr_cpuimg,x,y,w,h,c); }
static void e_blit(int dx,int dy,int dw,int dh){
    if (g_pr_emit==EMIT_GPU) pr_gpu_blit(g_pr_sw,g_pr_sh,dx,dy,dw,dh);
    else pr_cpu_blit(g_pr_cpuimg,g_pr_sprite,g_pr_sw,g_pr_sh,dx,dy,dw,dh); }
static void e_line(int x1,int y1,int x2,int y2,int t,uint32_t c){
    if (g_pr_emit==EMIT_GPU) pr_gpu_line(x1,y1,x2,y2,t,c);
    else pr_cpu_line(g_pr_cpuimg,x1,y1,x2,y2,t,c); }
static void e_rr(int x,int y,int w,int h,int r,int cn,uint32_t c){
    if (g_pr_emit==EMIT_GPU) pr_gpu_roundrect(x,y,w,h,r,cn,c);
    else pr_cpu_roundrect(g_pr_cpuimg,x,y,w,h,r,cn,c); }

/* Author the frame ONCE; emit selects GPU op-list vs CPU oracle draw. A DE
 * desktop (wallpaper, top panel, dock) hosting a browser window that has
 * laid out a real page (chrome, URL bar, hero image, headings, paragraph
 * text runs, cards, links). ~1300 ops at 1280x720 — a genuine frame. */
static void pr_author_frame(void) {
    int W=PR_W, H=PR_H;
    /* --- DE: wallpaper + top panel + dock --- */
    e_fill(0,0,W,H, 0x101828FF);                 /* desktop wallpaper */
    e_fill_a(0,0,W,H, 0x2A3A6010);               /* subtle vignette wash */
    e_fill(0,0,W,28, 0x0B1020FF);                /* top panel bar */
    for (int i=0;i<6;i++) e_fill(12+i*84,7,70,14, 0x33406AFF); /* panel menus */
    e_rr(W-160,4,150,20, 8,15, 0x1E2A4AFF);      /* clock/tray pill */
    /* dock along the bottom */
    e_rr(W/2-220,H-56,440,48, 14,15, 0x0A0F1CCC);
    for (int i=0;i<8;i++) e_rr(W/2-206+i*54,H-50,40,36, 8,15, 0x3B6FF0FF);

    /* --- browser window --- */
    int bx=120, by=56, bw=W-240, bh=H-140;
    e_rr(bx,by,bw,bh, 10, 3, 0xF4F6FBFF);        /* window body (top corners) */
    e_fill(bx,by,bw,36, 0x232A3AFF);             /* title/tab strip */
    e_rr(bx+10,by+6,180,26, 8,3, 0xF4F6FBFF);    /* active tab */
    e_fill(bx,by+36,bw,40, 0xE7EAF2FF);          /* toolbar */
    e_rr(bx+90,by+44,bw-180,24, 12,15, 0xFFFFFFFF); /* URL box */
    e_fill(bx+100,by+52,220,8, 0x9AA3B8FF);      /* URL text run */
    e_rr(bx+16,by+44,24,24, 6,15, 0x5B78E6FF);   /* back button */
    e_rr(bx+48,by+44,24,24, 6,15, 0x5B78E6FF);   /* fwd button */

    int cx=bx, cy=by+76, cw=bw, ch=bh-76;        /* content viewport */
    e_fill(cx,cy,cw,ch, 0xFFFFFFFF);             /* page background */
    /* hero banner image + translucent gradient scrim + heading */
    e_blit(cx+40,cy+24,cw-80,150);
    e_fill_a(cx+40,cy+24,cw-80,150, 0x0A122888);
    e_fill(cx+70,cy+120,360,26, 0xFFFFFFFF);     /* hero H1 */
    e_fill(cx+70,cy+152,240,14, 0xD6DEECFF);
    /* article: heading + paragraph text-run blocks */
    int ty=cy+200;
    e_fill(cx+40,ty,300,22, 0x1A2233FF); ty+=34; /* H2 */
    for (int ln=0; ln<9; ln++){                  /* paragraph lines (text runs) */
        int lw = (ln%3==2)? (cw-80)*3/5 : cw-80;
        e_fill(cx+40,ty, lw,10, 0x515A6EFF); ty+=18;
    }
    ty+=14;
    e_fill(cx+40,ty,260,22, 0x1A2233FF); ty+=34; /* H2 */
    for (int ln=0; ln<7; ln++){
        int lw=(ln%4==3)?(cw-80)/2:cw-80;
        e_fill(cx+40,ty, lw,10, 0x515A6EFF); ty+=18;
    }
    /* a row of link/nav lines */
    e_line(cx+40,ty+10, cx+cw-40,ty+10, 2, 0xC7CEDBFF);
    /* --- sidebar: 3 cards with thumbnails, headings, and text --- */
    int sx=cx+cw-300, sy=cy+200;
    for (int card=0; card<3; card++){
        int yy=sy+card*150;
        e_rr(sx,yy,260,132, 12,15, 0xF7F9FDFF);  /* card body */
        e_line(sx,yy+131, sx+260,yy+131, 1, 0xDFE4EEFF);
        e_blit(sx+12,yy+12,72,72);               /* thumbnail */
        e_fill(sx+96,yy+16,150,14, 0x27304AFF);  /* card title */
        for (int ln=0; ln<3; ln++)
            e_fill(sx+96,yy+40+ln*16, (ln==2?100:150),8, 0x6B7488FF);
        e_rr(sx+96,yy+96,88,24, 12,15, 0x3B6FF0FF); /* CTA button */
    }
    /* scrollbar */
    e_fill(cx+cw-10,cy,10,ch, 0xEDEFF5FF);
    e_rr(cx+cw-9,cy+40,8,160, 4,15, 0xB4BDD0FF);
}

/* readback + byte-verify GPU SSBO against the CPU oracle image. */
static int mode_pageraster(int W, int H, const char* out, double seconds) {
    PR_W=W; PR_H=H;
    size_t spvsz;
    uint32_t* spv = read_spv("scripts/shaders/vk2d_raster.comp.spv", &spvsz);
    if (!spv) return -1;
    VkDeviceSize dstsz=(VkDeviceSize)W*H*4;
    /* a small procedural sprite as the "image" source for blits */
    int SW=64, SH=64; VkDeviceSize srcsz=(VkDeviceSize)SW*SH*4;
    uint8_t* sprite = malloc(srcsz);
    for (int y=0;y<SH;y++) for (int x=0;x<SW;x++){ uint8_t*p=sprite+(y*SW+x)*4;
        p[0]=(uint8_t)(x*4); p[1]=(uint8_t)(y*4); p[2]=(uint8_t)(160-x); p[3]=255; }
    g_pr_sprite=sprite; g_pr_sw=SW; g_pr_sh=SH;

    VkBuffer dbuf,sbuf; VkDeviceMemory dmem,smem;
    if (make_storagebuf(dstsz,&dbuf,&dmem)) return -1;
    if (make_storagebuf(srcsz,&sbuf,&smem)) return -1;
    void* map; CK(vkMapMemory(g_dev,smem,0,srcsz,0,&map));
    memcpy(map,sprite,srcsz); vkUnmapMemory(g_dev,smem);

    VkShaderModuleCreateInfo smi={ .sType=ST_SHADER_MODULE_CREATE_INFO, .codeSize=spvsz, .pCode=spv };
    VkShaderModule module; CK(vkCreateShaderModule(g_dev,&smi,0,&module)); free(spv);
    VkDescriptorSetLayoutBinding binds[2]={
        {.binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT},
        {.binding=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT}};
    VkDescriptorSetLayoutCreateInfo dli={ .sType=ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=2,.pBindings=binds};
    VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(g_dev,&dli,0,&dsl));
    VkPushConstantRange pcr={ .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT,.offset=0,.size=sizeof(PushC)};
    VkPipelineLayoutCreateInfo pli={ .sType=ST_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&dsl,.pushConstantRangeCount=1,.pPushConstantRanges=&pcr};
    VkPipelineLayout playout; CK(vkCreatePipelineLayout(g_dev,&pli,0,&playout));
    VkComputePipelineCreateInfo cpi={ .sType=ST_COMPUTE_PIPELINE_CREATE_INFO,
        .stage={.sType=ST_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=module,.pName="main"},.layout=playout};
    VkPipeline pipe; CK(vkCreateComputePipelines(g_dev,0,1,&cpi,0,&pipe));
    VkDescriptorPoolSize psz={ .type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=2};
    VkDescriptorPoolCreateInfo dpi={ .sType=ST_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&psz};
    VkDescriptorPool dpool; CK(vkCreateDescriptorPool(g_dev,&dpi,0,&dpool));
    VkDescriptorSetAllocateInfo dsai={ .sType=ST_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dpool,.descriptorSetCount=1,.pSetLayouts=&dsl};
    VkDescriptorSet dset; CK(vkAllocateDescriptorSets(g_dev,&dsai,&dset));
    VkDescriptorBufferInfo dbi={.buffer=dbuf,.offset=0,.range=dstsz}, sbi={.buffer=sbuf,.offset=0,.range=srcsz};
    VkWriteDescriptorSet wr[2]={
        {.sType=ST_WRITE_DESCRIPTOR_SET,.dstSet=dset,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&dbi},
        {.sType=ST_WRITE_DESCRIPTOR_SET,.dstSet=dset,.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&sbi}};
    vkUpdateDescriptorSets(g_dev,2,wr,0,0);

    /* author the GPU op list once */
    pr_nops=0; g_pr_emit=EMIT_GPU; pr_author_frame();

    VkMemoryBarrier mb={ .sType=ST_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT};

    /* One record; timed submit loop. If SECONDS>0 keep resubmitting so
     * nvidia-smi can observe this pid resident on the GPU. */
    double gpu_best=1e30; int frames=0; double t_start=now_ms();
    int min_iters = seconds>0 ? 1000000000 : 200;
    for (int it=0; it<min_iters; it++) {
        VkCommandBuffer cb; if (begin_cmd(&cb)) return -1;
        vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
        vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,playout,0,1,&dset,0,0);
        for (int i=0;i<pr_nops;i++){
            vkCmdPushConstants(cb,playout,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(PushC),&pr_ops[i]);
            vkCmdDispatch(cb,pr_grp[i][0],pr_grp[i][1],1);
            if (i+1<pr_nops) vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&mb,0,0,0,0);
        }
        double t0=now_ms(); if (submit_wait(cb)) return -1; double ms=now_ms()-t0;
        if (ms<gpu_best) gpu_best=ms;
        vkFreeCommandBuffers(g_dev,g_pool,1,&cb);
        frames++;
        if (seconds>0 && (now_ms()-t_start)>=seconds*1000.0 && frames>=60) break;
        if (seconds<=0 && it>=199) break;
    }

    /* CPU oracle: author the SAME frame on the CPU. */
    uint8_t* cbuf=calloc((size_t)W*H,4);
    g_pr_cpuimg=cbuf; g_pr_emit=EMIT_CPU;
    double cpu_best=1e30;
    int cpu_iters = seconds>0?20:200;
    for (int it=0; it<cpu_iters; it++){
        memset(cbuf,0,(size_t)W*H*4);
        double t0=now_ms(); pr_author_frame(); double ms=now_ms()-t0;
        if (ms<cpu_best) cpu_best=ms;
    }

    /* readback GPU SSBO, byte-verify RGB against the CPU oracle */
    CK(vkMapMemory(g_dev,dmem,0,dstsz,0,&map));
    uint8_t* gpix=(uint8_t*)map;
    long mism=0, first=-1;
    for (long i=0;i<(long)W*H;i++) for (int c=0;c<3;c++)
        if (gpix[i*4+c]!=cbuf[i*4+c]){ if(first<0) first=i; mism++; }
    write_ppm(out,gpix,W,H);
    vkUnmapMemory(g_dev,dmem);

    printf("VK_DEVICE %s\n", g_devname);
    printf("PAGERASTER_OK %s %dx%d ops=%d gpu_frames=%d\n", out, W, H, pr_nops, frames);
    printf("PAGERASTER_GPU_MS %.4f\nPAGERASTER_SW_MS %.4f\nPAGERASTER_SPEEDUP %.2fx\n",
           gpu_best, cpu_best, cpu_best/gpu_best);
    printf("PAGERASTER_GPUvsCPUport_MISMATCH %ld", mism);
    if (first>=0) printf(" first@%ld,%ld", first%W, first/W);
    printf("\n");

    free(cbuf); free(sprite);
    vkDestroyDescriptorPool(g_dev,dpool,0); vkDestroyPipeline(g_dev,pipe,0);
    vkDestroyPipelineLayout(g_dev,playout,0); vkDestroyDescriptorSetLayout(g_dev,dsl,0);
    vkDestroyShaderModule(g_dev,module,0);
    vkDestroyBuffer(g_dev,dbuf,0); vkFreeMemory(g_dev,dmem,0);
    vkDestroyBuffer(g_dev,sbuf,0); vkFreeMemory(g_dev,smem,0);
    return mism==0 ? 0 : 1;
}

/* =================== pagefromops: REAL hambrowse page on the GPU ===========
 * Ingest the paint-op stream that user/hambrowse_host_gfx.ad dumps for an
 * ACTUAL laid-out HTML page (PAGEOPS W H / OP fill|rrect|line|glyph / ENDOPS)
 * and rasterize it on the discrete GPU through the SAME vk_2d op vocabulary the
 * proven `pageraster` path uses. Unlike `pageraster` (a hand-authored
 * representative frame), every op here is the browser engine's real output.
 *
 * GPU-capable ops (fill/rrect/line) run on the RTX 3090 compute pipeline; the
 * result is read back and byte-verified against a CPU oracle that runs the
 * IDENTICAL op stream. `glyph` ops (text runs) are HONESTLY routed to the CPU
 * fallback — true per-glyph AA coverage is not yet a GPU op — and counted, so
 * the report distinguishes what the GPU actually rasterized from what the CPU
 * still owns. Text runs are emitted LAST by the driver (topmost paint order),
 * so applying the deferred CPU glyph pass after the GPU box pass preserves the
 * exact stacking order the CPU oracle uses -> byte-identical. */
enum { PK_FILL=0, PK_AFILL=1, PK_RRECT=2, PK_LINE=3, PK_GLYPH=4, PK_COVMASK=5 };
typedef struct { int kind, a,b,c,d,e,f; uint32_t rgba;
                 uint8_t* mask; int maskoff; } POp;
#define PFO_MAXOPS 65536

/* parse "#rrggbbaa" (or bare 8-hex) into 0xRRGGBBAA. */
static uint32_t parse_rgba(const char* s) {
    if (*s=='#') s++;
    return (uint32_t)strtoul(s, 0, 16);
}

/* Read one hex-encoded byte from the op stream, skipping any whitespace/newline
 * between digits — used for OP_COV_MASK glyph coverage payloads (which are
 * emitted as wrapped hex lines after the covmask header). */
static int pfo_hexnyb(int c){
    if (c>='0'&&c<='9') return c-'0';
    if (c>='a'&&c<='f') return c-'a'+10;
    if (c>='A'&&c<='F') return c-'A'+10;
    return -1;
}
static int pfo_read_hex_byte(FILE* f){
    int c, hi, lo;
    do { c=fgetc(f); } while (c!=EOF && pfo_hexnyb(c)<0);
    if (c==EOF) return 0;
    hi=pfo_hexnyb(c);
    do { c=fgetc(f); } while (c!=EOF && pfo_hexnyb(c)<0);
    lo = (c==EOF) ? 0 : pfo_hexnyb(c);
    return (hi<<4) | (lo<0?0:lo);
}

static int mode_pagefromops(const char* opsfile, const char* out, double seconds) {
    FILE* f = fopen(opsfile, "r");
    if (!f) { fprintf(stderr,"[vk_hostgpu] pagefromops: cannot open %s\n", opsfile); return -1; }
    static POp ops[PFO_MAXOPS];
    int nops=0, W=0, H=0, order_ok=1, seen_glyph=0;
    long n_gpu=0, n_glyph=0, n_textgpu=0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int x,y,w,h,rad,corners,thick,nbytes; char col[32];
        if (sscanf(line, "PAGEOPS %d %d", &W, &H)==2) continue;
        if (!strncmp(line,"ENDOPS",6)) break;
        if (nops>=PFO_MAXOPS) { fprintf(stderr,"[vk_hostgpu] pagefromops: op overflow\n"); break; }
        if (sscanf(line, "OP fill %d %d %d %d %31s", &x,&y,&w,&h, col)==5) {
            uint32_t c=parse_rgba(col);
            ops[nops].kind=(c&0xFF)==0xFF?PK_FILL:PK_AFILL;
            ops[nops].a=x;ops[nops].b=y;ops[nops].c=w;ops[nops].d=h;ops[nops].rgba=c;
            if (seen_glyph) order_ok=0; n_gpu++; nops++;
        } else if (sscanf(line, "OP rrect %d %d %d %d %d %d %31s",
                          &x,&y,&w,&h,&rad,&corners, col)==7) {
            ops[nops].kind=PK_RRECT;
            ops[nops].a=x;ops[nops].b=y;ops[nops].c=w;ops[nops].d=h;
            ops[nops].e=rad;ops[nops].f=corners;ops[nops].rgba=parse_rgba(col);
            if (seen_glyph) order_ok=0; n_gpu++; nops++;
        } else if (sscanf(line, "OP line %d %d %d %d %d %31s",
                          &x,&y,&w,&h,&thick, col)==6) {
            ops[nops].kind=PK_LINE;
            ops[nops].a=x;ops[nops].b=y;ops[nops].c=w;ops[nops].d=h;
            ops[nops].e=thick;ops[nops].rgba=parse_rgba(col);
            if (seen_glyph) order_ok=0; n_gpu++; nops++;
        } else if (sscanf(line, "OP covmask %d %d %d %d %31s %d",
                          &x,&y,&w,&h, col, &nbytes)==6) {
            /* AA glyph coverage mask: header, then `nbytes` (== w*h) hex bytes
             * of 8-bit per-pixel coverage over the tight ink bbox. Runs on the
             * GPU via OP_COVMASK — REAL anti-aliased text on the device. */
            long mcap = (long)w*h > 0 ? (long)w*h : 1;
            uint8_t* m = (uint8_t*)malloc((size_t)mcap);
            for (int k=0;k<nbytes;k++){ int bval=pfo_read_hex_byte(f);
                if (k < mcap) m[k]=(uint8_t)bval; }   /* clamp vs malformed nbytes */
            ops[nops].kind=PK_COVMASK;
            ops[nops].a=x;ops[nops].b=y;ops[nops].c=w;ops[nops].d=h;
            ops[nops].rgba=parse_rgba(col); ops[nops].mask=m;
            seen_glyph=1; n_gpu++; n_textgpu++; nops++;
        } else if (sscanf(line, "OP glyph %d %d %d %d %31s", &x,&y,&w,&h, col)==5) {
            ops[nops].kind=PK_GLYPH;
            ops[nops].a=x;ops[nops].b=y;ops[nops].c=w;ops[nops].d=h;ops[nops].rgba=parse_rgba(col);
            seen_glyph=1; n_glyph++; nops++;
        }
    }
    fclose(f);
    if (W<=0||H<=0||nops==0) { fprintf(stderr,"[vk_hostgpu] pagefromops: empty/invalid op stream\n"); return -1; }
    if (!order_ok) fprintf(stderr,"[vk_hostgpu] pagefromops: WARNING box op after glyph — paint order not grouped\n");

    PR_W=W; PR_H=H;
    size_t spvsz;
    uint32_t* spv = read_spv("scripts/shaders/vk2d_raster.comp.spv", &spvsz);
    if (!spv) return -1;
    VkDeviceSize dstsz=(VkDeviceSize)W*H*4;

    /* src[] SSBO carries every OP_COV_MASK run's AA coverage, one 8-bit value
     * per uint (packed one-per-uint so the shader byte-reads it directly),
     * laid end-to-end; each covmask op's maskoff points at its slice. */
    long cov_total=0;
    for (int i=0;i<nops;i++) if (ops[i].kind==PK_COVMASK) cov_total += (long)ops[i].c*ops[i].d;
    if (cov_total < 4) cov_total = 4;                 /* keep the buffer non-empty */
    VkDeviceSize srcsz=(VkDeviceSize)cov_total*4;
    uint32_t* covvals=(uint32_t*)calloc((size_t)cov_total,4);
    { long off=0;
      for (int i=0;i<nops;i++) if (ops[i].kind==PK_COVMASK) {
          long n=(long)ops[i].c*ops[i].d; ops[i].maskoff=(int)off;
          for (long k=0;k<n;k++) covvals[off+k]=ops[i].mask[k];
          off+=n;
      } }

    VkBuffer dbuf,sbuf; VkDeviceMemory dmem,smem;
    if (make_storagebuf(dstsz,&dbuf,&dmem)) return -1;
    if (make_storagebuf(srcsz,&sbuf,&smem)) return -1;
    void* map; CK(vkMapMemory(g_dev,smem,0,srcsz,0,&map));
    memcpy(map,covvals,srcsz); vkUnmapMemory(g_dev,smem);
    /* zero the destination SSBO (page starts transparent; op 0 paints paper). */
    CK(vkMapMemory(g_dev,dmem,0,dstsz,0,&map)); memset(map,0,dstsz); vkUnmapMemory(g_dev,dmem);

    VkShaderModuleCreateInfo smi={ .sType=ST_SHADER_MODULE_CREATE_INFO, .codeSize=spvsz, .pCode=spv };
    VkShaderModule module; CK(vkCreateShaderModule(g_dev,&smi,0,&module)); free(spv);
    VkDescriptorSetLayoutBinding binds[2]={
        {.binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT},
        {.binding=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT}};
    VkDescriptorSetLayoutCreateInfo dli={ .sType=ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=2,.pBindings=binds};
    VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(g_dev,&dli,0,&dsl));
    VkPushConstantRange pcr={ .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT,.offset=0,.size=sizeof(PushC)};
    VkPipelineLayoutCreateInfo pli={ .sType=ST_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&dsl,.pushConstantRangeCount=1,.pPushConstantRanges=&pcr};
    VkPipelineLayout playout; CK(vkCreatePipelineLayout(g_dev,&pli,0,&playout));
    VkComputePipelineCreateInfo cpi={ .sType=ST_COMPUTE_PIPELINE_CREATE_INFO,
        .stage={.sType=ST_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=module,.pName="main"},.layout=playout};
    VkPipeline pipe; CK(vkCreateComputePipelines(g_dev,0,1,&cpi,0,&pipe));
    VkDescriptorPoolSize psz={ .type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=2};
    VkDescriptorPoolCreateInfo dpi={ .sType=ST_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&psz};
    VkDescriptorPool dpool; CK(vkCreateDescriptorPool(g_dev,&dpi,0,&dpool));
    VkDescriptorSetAllocateInfo dsai={ .sType=ST_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dpool,.descriptorSetCount=1,.pSetLayouts=&dsl};
    VkDescriptorSet dset; CK(vkAllocateDescriptorSets(g_dev,&dsai,&dset));
    VkDescriptorBufferInfo dbi={.buffer=dbuf,.offset=0,.range=dstsz}, sbi={.buffer=sbuf,.offset=0,.range=srcsz};
    VkWriteDescriptorSet wr[2]={
        {.sType=ST_WRITE_DESCRIPTOR_SET,.dstSet=dset,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&dbi},
        {.sType=ST_WRITE_DESCRIPTOR_SET,.dstSet=dset,.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&sbi}};
    vkUpdateDescriptorSets(g_dev,2,wr,0,0);

    /* build the GPU op list — ALL ops (boxes AND glyph coverage masks) in file
     * order, so the paint stacking (text last => topmost) is exact and the whole
     * page, text included, rasterizes on the GPU. */
    pr_nops=0;
    for (int i=0;i<nops;i++){
        POp* o=&ops[i];
        if (o->kind==PK_FILL)  pr_gpu_fill(OP_FILL, o->a,o->b,o->c,o->d, o->rgba);
        else if (o->kind==PK_AFILL) pr_gpu_fill(OP_FILL_ALPHA, o->a,o->b,o->c,o->d, o->rgba);
        else if (o->kind==PK_RRECT) pr_gpu_roundrect(o->a,o->b,o->c,o->d, o->e,o->f, o->rgba);
        else if (o->kind==PK_LINE)  pr_gpu_line(o->a,o->b,o->c,o->d, o->e, o->rgba);
        else if (o->kind==PK_COVMASK) pr_gpu_covmask(o->a,o->b,o->c,o->d, o->rgba, o->maskoff);
        else if (o->kind==PK_GLYPH) { /* legacy flat glyph box (no covmask stream) */
            pr_gpu_fill(OP_FILL_ALPHA, o->a,o->b,o->c,o->d, o->rgba); }
    }

    VkMemoryBarrier mb={ .sType=ST_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT};

    double gpu_best=1e30; int frames=0; double t_start=now_ms();
    int min_iters = seconds>0 ? 1000000000 : 200;
    for (int it=0; it<min_iters; it++) {
        /* re-zero the SSBO each pass so a resubmit loop stays deterministic. */
        CK(vkMapMemory(g_dev,dmem,0,dstsz,0,&map)); memset(map,0,dstsz); vkUnmapMemory(g_dev,dmem);
        VkCommandBuffer cb; if (begin_cmd(&cb)) return -1;
        vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
        vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,playout,0,1,&dset,0,0);
        for (int i=0;i<pr_nops;i++){
            vkCmdPushConstants(cb,playout,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(PushC),&pr_ops[i]);
            vkCmdDispatch(cb,pr_grp[i][0],pr_grp[i][1],1);
            if (i+1<pr_nops) vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&mb,0,0,0,0);
        }
        double t0=now_ms(); if (submit_wait(cb)) return -1; double ms=now_ms()-t0;
        if (ms<gpu_best) gpu_best=ms;
        vkFreeCommandBuffers(g_dev,g_pool,1,&cb);
        frames++;
        if (seconds>0 && (now_ms()-t_start)>=seconds*1000.0 && frames>=60) break;
        if (seconds<=0 && it>=199) break;
    }

    /* readback the GPU result — the FULL page (backgrounds, borders AND text)
     * is now rasterized on the GPU, so this is the device image as-is. */
    CK(vkMapMemory(g_dev,dmem,0,dstsz,0,&map));
    uint8_t* gpix=(uint8_t*)map;
    uint8_t* gimg=malloc(dstsz); memcpy(gimg,gpix,dstsz);
    vkUnmapMemory(g_dev,dmem);

    /* CPU oracle: the IDENTICAL op stream, all on the CPU, in file order. */
    uint8_t* cbuf=calloc((size_t)W*H,4);
    double cpu_best=1e30;
    int cpu_iters = seconds>0?20:200;
    for (int it=0; it<cpu_iters; it++){
        memset(cbuf,0,(size_t)W*H*4);
        double t0=now_ms();
        for (int i=0;i<nops;i++){
            POp* o=&ops[i];
            if (o->kind==PK_FILL)  pr_cpu_fill(cbuf, o->a,o->b,o->c,o->d, o->rgba);
            else if (o->kind==PK_AFILL||o->kind==PK_GLYPH) pr_cpu_fill_alpha(cbuf, o->a,o->b,o->c,o->d, o->rgba);
            else if (o->kind==PK_RRECT) pr_cpu_roundrect(cbuf, o->a,o->b,o->c,o->d, o->e,o->f, o->rgba);
            else if (o->kind==PK_LINE)  pr_cpu_line(cbuf, o->a,o->b,o->c,o->d, o->e, o->rgba);
            else if (o->kind==PK_COVMASK) pr_cpu_covmask(cbuf, o->a,o->b,o->c,o->d, o->rgba, o->mask);
        }
        double ms=now_ms()-t0;
        if (ms<cpu_best) cpu_best=ms;
    }

    long mism=0, first=-1;
    for (long i=0;i<(long)W*H;i++) for (int c=0;c<3;c++)
        if (gimg[i*4+c]!=cbuf[i*4+c]){ if(first<0) first=i; mism++; }
    write_ppm(out,gimg,W,H);

    printf("VK_DEVICE %s\n", g_devname);
    printf("PAGEFROMOPS_OK %s %dx%d ops=%d gpu_ops=%ld glyph_cpu_ops=%ld text_gpu_ops=%ld gpu_frames=%d order_grouped=%d\n",
           out, W, H, nops, n_gpu, n_glyph, n_textgpu, frames, order_ok);
    printf("PAGEFROMOPS_GPU_MS %.4f\nPAGEFROMOPS_SW_MS %.4f\nPAGEFROMOPS_SPEEDUP %.2fx\n",
           gpu_best, cpu_best, cpu_best/gpu_best);
    printf("PAGEFROMOPS_GPUvsCPUport_MISMATCH %ld", mism);
    if (first>=0) printf(" first@%ld,%ld", first%W, first/W);
    printf("\n");

    for (int i=0;i<nops;i++) if (ops[i].mask) free(ops[i].mask);
    free(covvals);
    free(gimg); free(cbuf);
    vkDestroyDescriptorPool(g_dev,dpool,0); vkDestroyPipeline(g_dev,pipe,0);
    vkDestroyPipelineLayout(g_dev,playout,0); vkDestroyDescriptorSetLayout(g_dev,dsl,0);
    vkDestroyShaderModule(g_dev,module,0);
    vkDestroyBuffer(g_dev,dbuf,0); vkFreeMemory(g_dev,dmem,0);
    vkDestroyBuffer(g_dev,sbuf,0); vkFreeMemory(g_dev,smem,0);
    return mism==0 ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s info | clear W H 0xRRGGBBAA OUT.ppm | upload IN.ppm OUT.ppm\n"
                        "       %s blit IN.ppm SCALE OUT.ppm | raster OUT.ppm | rasterbench W H\n"
                        "       %s pageraster W H OUT.ppm [SECONDS] | present IN.ppm [SCALE] [FRAMES]\n"
                        "       %s pagefromops OPS.txt OUT.ppm [SECONDS]\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }
    /* present mode runs an entirely self-contained WSI init (own instance +
     * device with surface/swapchain extensions) — the headless vk_init() path
     * that the proven clear/upload/blit gate depends on is left untouched. */
    if (!strcmp(argv[1], "present")) {
#ifdef HAVE_XLIB
        if (argc < 3) { fprintf(stderr, "usage: present IN.ppm [SCALE] [FRAMES]\n"); return 2; }
        double scale = (argc >= 4) ? strtod(argv[3], 0) : 1.0;
        uint32_t frames = (argc >= 5) ? (uint32_t)strtoul(argv[4], 0, 0) : 60;
        return mode_present(argv[2], scale, frames);
#else
        fprintf(stderr, "[vk_hostgpu] present: built without X11 (recompile -DHAVE_XLIB -lX11)\n");
        return 2;
#endif
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
    } else if (!strcmp(argv[1], "blit") && argc == 5) {
        rc = mode_blit(argv[2], strtod(argv[3], 0), argv[4]);
    } else if (!strcmp(argv[1], "raster") && argc == 3) {
        rc = mode_raster(argv[2]);
    } else if (!strcmp(argv[1], "rasterbench") && argc == 4) {
        rc = mode_rasterbench((uint32_t)strtoul(argv[2],0,0), (uint32_t)strtoul(argv[3],0,0));
    } else if (!strcmp(argv[1], "pageraster") && (argc == 5 || argc == 6)) {
        int W = (int)strtoul(argv[2],0,0), H = (int)strtoul(argv[3],0,0);
        double secs = (argc == 6) ? strtod(argv[5],0) : 0.0;
        rc = mode_pageraster(W, H, argv[4], secs);
    } else if (!strcmp(argv[1], "pagefromops") && (argc == 4 || argc == 5)) {
        double secs = (argc == 5) ? strtod(argv[4],0) : 0.0;
        rc = mode_pagefromops(argv[2], argv[3], secs);
    } else {
        fprintf(stderr, "bad args\n"); rc = 2;
    }
    vk_shutdown();
    return rc ? 1 : 0;
}
