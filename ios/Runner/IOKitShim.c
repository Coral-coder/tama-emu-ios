#include "IOKitShim.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <string.h>

typedef mach_port_t io_object_t;
typedef CFMutableDictionaryRef (*NameMatching)(const char *);
typedef CFMutableDictionaryRef (*IdMatching)(uint64_t);
typedef kern_return_t (*GetServices)(mach_port_t, CFDictionaryRef, io_object_t *);
typedef io_object_t (*GetService)(mach_port_t, CFDictionaryRef);
typedef io_object_t (*IterNext)(io_object_t);
typedef kern_return_t (*Release)(io_object_t);
typedef kern_return_t (*EntryId)(io_object_t, uint64_t *);
typedef CFTypeRef (*SearchProp)(io_object_t, const char *, CFStringRef, CFAllocatorRef, uint32_t);
typedef kern_return_t (*Open)(io_object_t, mach_port_t, uint32_t, mach_port_t *);
typedef kern_return_t (*Close)(mach_port_t);
typedef kern_return_t (*CallMethod)(mach_port_t, uint32_t, const uint64_t *, uint32_t, const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);

static struct {
  int tried, ok;
  NameMatching name_matching;
  IdMatching id_matching;
  GetServices get_services;
  GetService get_service;
  IterNext next;
  Release release;
  EntryId entry_id;
  SearchProp search;
  Open open;
  Close close;
  CallMethod call;
} k;

static int load(void) {
  if (k.tried) return k.ok;
  k.tried = 1;
  void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!h) return 0;
  k.name_matching = (NameMatching)dlsym(h, "IOServiceNameMatching");
  k.id_matching = (IdMatching)dlsym(h, "IORegistryEntryIDMatching");
  k.get_services = (GetServices)dlsym(h, "IOServiceGetMatchingServices");
  k.get_service = (GetService)dlsym(h, "IOServiceGetMatchingService");
  k.next = (IterNext)dlsym(h, "IOIteratorNext");
  k.release = (Release)dlsym(h, "IOObjectRelease");
  k.entry_id = (EntryId)dlsym(h, "IORegistryEntryGetRegistryEntryID");
  k.search = (SearchProp)dlsym(h, "IORegistryEntrySearchCFProperty");
  k.open = (Open)dlsym(h, "IOServiceOpen");
  k.close = (Close)dlsym(h, "IOServiceClose");
  k.call = (CallMethod)dlsym(h, "IOConnectCallMethod");
  k.ok = k.name_matching && k.id_matching && k.get_services && k.get_service && k.next && k.release && k.entry_id &&
         k.search && k.open && k.close && k.call;
  return k.ok;
}

int tk_available(void) { return load(); }

static int32_t number(io_object_t s, const char *key) {
  CFStringRef ks = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = k.search(s, "IOService", ks, kCFAllocatorDefault, 1 | 2);  // recursively, through the parents
  CFRelease(ks);
  int32_t n = 0;
  if (v) {
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &n);
    CFRelease(v);
  }
  return n;
}

static void text(io_object_t s, const char *key, char *out, size_t len) {
  CFStringRef ks = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = k.search(s, "IOService", ks, kCFAllocatorDefault, 1 | 2);
  CFRelease(ks);
  if (v) {
    if (CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, out, (CFIndex)len, kCFStringEncodingUTF8);
    CFRelease(v);
  }
}

int tk_list(uint64_t *ids, int32_t *vids, int32_t *pids, char *names, int max) {
  if (!load()) return 0;
  io_object_t it = 0;
  if (k.get_services(MACH_PORT_NULL, k.name_matching("TamaSerialDriver"), &it) != KERN_SUCCESS) return 0;
  int n = 0;
  io_object_t s;
  while ((s = k.next(it)) != 0) {
    if (n < max) {
      ids[n] = 0;
      k.entry_id(s, &ids[n]);
      vids[n] = number(s, "idVendor");
      pids[n] = number(s, "idProduct");
      char *nm = names + n * 64;
      strcpy(nm, "USB serial");
      text(s, "USB Product Name", nm, 64);
      n++;
    }
    k.release(s);
  }
  k.release(it);
  return n;
}

int tk_open(uint64_t id, uint32_t *conn) {
  if (!load()) return -1;
  io_object_t s = k.get_service(MACH_PORT_NULL, k.id_matching(id));
  if (!s) return -2;
  mach_port_t c = 0;
  kern_return_t kr = k.open(s, mach_task_self(), 0, &c);
  k.release(s);
  *conn = c;
  return kr;
}

int tk_call(uint32_t conn, uint32_t selector, const uint64_t *in, uint32_t in_n, const void *in_s, size_t in_s_n,
            uint64_t *out, uint32_t *out_n, void *out_s, size_t *out_s_n) {
  if (!load()) return -1;
  return k.call(conn, selector, in, in_n, in_s, in_s_n, out, out_n, out_s, out_s_n);
}

void tk_close(uint32_t conn) {
  if (load() && conn) k.close(conn);
}
