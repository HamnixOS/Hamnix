/* scripts/vk_headless_probe.c — GPU track #182 HW-NVIDIA probe (Venus path).
 *
 * Enumerates Vulkan physical devices via the loader (no dev headers needed —
 * dlopen libvulkan.so.1, minimal ABI declared inline). Proves NVIDIA Vulkan
 * comes up HEADLESS with no GBM/X — the host GPU a future virtio-gpu
 * `venus=on` path would forward guest Vulkan to. On this host it prints:
 *   VK-PROBE-RESULT device[0]=NVIDIA GeForce RTX 3090 api=1.3.277 type=2 ...
 *   VK-PROBE-RESULT device[1]=llvmpipe ...
 * Build: cc scripts/vk_headless_probe.c -o /tmp/vk_headless_probe -ldl
 * (See docs/inguest_gpu_hw_nvidia_2026-07-18.md, "Venus (Vulkan) path".)
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
typedef int VkResult; typedef void* VkInstance; typedef void* VkPhysicalDevice;
typedef struct { uint32_t sType; const void* pNext; const char* pApplicationName;
  uint32_t applicationVersion; const char* pEngineName; uint32_t engineVersion; uint32_t apiVersion;} VkApplicationInfo;
typedef struct { uint32_t sType; const void* pNext; uint32_t flags; const VkApplicationInfo* pApplicationInfo;
  uint32_t enabledLayerCount; const char*const* ppEnabledLayerNames; uint32_t enabledExtensionCount;
  const char*const* ppEnabledExtensionNames;} VkInstanceCreateInfo;
typedef struct { uint32_t apiVersion; uint32_t driverVersion; uint32_t vendorID; uint32_t deviceID;
  uint32_t deviceType; char deviceName[256]; uint8_t pad[2048];} VkPhysicalDeviceProperties;
int main(void){
  void* lib=dlopen("libvulkan.so.1",RTLD_NOW); if(!lib){printf("VK: no libvulkan\n");return 2;}
  VkResult(*vkCreateInstance)(const VkInstanceCreateInfo*,const void*,VkInstance*)=dlsym(lib,"vkCreateInstance");
  VkResult(*vkEnumeratePhysicalDevices)(VkInstance,uint32_t*,VkPhysicalDevice*)=dlsym(lib,"vkEnumeratePhysicalDevices");
  void(*vkGetPhysicalDeviceProperties)(VkPhysicalDevice,VkPhysicalDeviceProperties*)=dlsym(lib,"vkGetPhysicalDeviceProperties");
  VkApplicationInfo app; memset(&app,0,sizeof app); app.sType=0; app.apiVersion=(1<<22)|(1<<12);
  VkInstanceCreateInfo ci; memset(&ci,0,sizeof ci); ci.sType=1; ci.pApplicationInfo=&app;
  VkInstance inst; if(vkCreateInstance(&ci,0,&inst)!=0){printf("VK: create instance FAIL\n");return 3;}
  uint32_t n=0; vkEnumeratePhysicalDevices(inst,&n,0);
  if(!n){printf("VK: 0 physical devices\n");return 4;}
  VkPhysicalDevice d[8]; if(n>8)n=8; vkEnumeratePhysicalDevices(inst,&n,d);
  for(uint32_t i=0;i<n;i++){VkPhysicalDeviceProperties p; memset(&p,0,sizeof p); vkGetPhysicalDeviceProperties(d[i],&p);
    printf("VK-PROBE-RESULT device[%u]=%s api=%u.%u.%u type=%u vendor=0x%x\n",i,p.deviceName,
      (p.apiVersion>>22)&0x7f,(p.apiVersion>>12)&0x3ff,p.apiVersion&0xfff,p.deviceType,p.vendorID);}
  return 0;}
