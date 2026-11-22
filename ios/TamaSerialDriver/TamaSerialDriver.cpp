#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSCollections.h>
#include <USBDriverKit/USBDriverKit.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>

#include "TamaSerialDriver.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "TamaSerial: " fmt, ##__VA_ARGS__)

static const uint32_t kChunk = 4096;

struct TamaSerialDriver_IVars {
    IOUSBHostDevice * device;
    IOUSBHostInterface * intf;
    IOUSBHostPipe * pipeIn;
    IOUSBHostPipe * pipeOut;
    IOBufferMemoryDescriptor * bufIn;
    IOBufferMemoryDescriptor * bufOut;
    IOBufferMemoryDescriptor * bufCtl;
    uint16_t vid, pid;
    uint8_t ifaceNumber;
    bool open;
};

bool TamaSerialDriver::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(TamaSerialDriver_IVars, 1);
    return ivars != nullptr;
}

void TamaSerialDriver::free()
{
    IOSafeDeleteNULL(ivars, TamaSerialDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(TamaSerialDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ivars->device = OSDynamicCast(IOUSBHostDevice, provider);
    if (!ivars->device) return kIOReturnNoDevice;
    ivars->device->retain();
    const IOUSBDeviceDescriptor * dd = ivars->device->CopyDeviceDescriptor();
    if (dd) {
        ivars->vid = USBToHost16(dd->idVendor);
        ivars->pid = USBToHost16(dd->idProduct);
        IOUSBHostFreeDescriptor(dd);
    }
    LOG("found %04x:%04x", ivars->vid, ivars->pid);
    // the app finds us by this property (IOServiceGetMatchingServices)
    RegisterService();
    return kIOReturnSuccess;
}

kern_return_t IMPL(TamaSerialDriver, Stop)
{
    ClosePort();
    OSSafeReleaseNULL(ivars->device);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(TamaSerialDriver, NewUserClient)
{
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) return ret;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

/// Opens the device, takes its first configuration and the first interface that has a bulk IN
/// and a bulk OUT endpoint (CDC-ACM: the data interface).
kern_return_t TamaSerialDriver::OpenPort(uint32_t * vidPid, uint32_t * interfaceNumber)
{
    if (ivars->open) {
        *vidPid = ((uint32_t)ivars->vid << 16) | ivars->pid;
        *interfaceNumber = ivars->ifaceNumber;
        return kIOReturnSuccess;
    }
    IOUSBHostDevice * dev = ivars->device;
    if (!dev) return kIOReturnNoDevice;
    kern_return_t ret = dev->Open(this, 0, NULL);
    if (ret != kIOReturnSuccess) { LOG("device open 0x%x", ret); return ret; }

    const IOUSBConfigurationDescriptor * cfg = dev->CopyConfigurationDescriptor(0);
    if (!cfg) { dev->Close(this, 0); return kIOReturnNotFound; }
    ret = dev->SetConfiguration(cfg->bConfigurationValue, true);
    IOUSBHostFreeDescriptor(cfg);
    if (ret != kIOReturnSuccess) LOG("set configuration 0x%x", ret);

    uintptr_t iter = 0;
    ret = dev->CreateInterfaceIterator(&iter);
    if (ret != kIOReturnSuccess) { dev->Close(this, 0); return ret; }
    IOUSBHostInterface * intf = nullptr;
    while (dev->CopyInterface(iter, &intf) == kIOReturnSuccess && intf) {
        const IOUSBConfigurationDescriptor * c = intf->CopyConfigurationDescriptor();
        const IOUSBInterfaceDescriptor * id = intf->GetInterfaceDescriptor(c);
        uint8_t epIn = 0, epOut = 0;
        if (c && id) {
            const IOUSBEndpointDescriptor * ep = nullptr;
            while ((ep = IOUSBGetNextEndpointDescriptor(c, id, (const IOUSBDescriptorHeader *)ep)) != nullptr) {
                if (IOUSBGetEndpointType(ep) != kIOUSBEndpointTypeBulk) continue;
                if (IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn) { if (!epIn) epIn = ep->bEndpointAddress; }
                else if (!epOut) epOut = ep->bEndpointAddress;
            }
        }
        uint8_t num = id ? id->bInterfaceNumber : 0;
        if (c) IOUSBHostFreeDescriptor(c);
        if (epIn && epOut && intf->Open(this, 0, NULL) == kIOReturnSuccess) {
            if (intf->CopyPipe(epIn, &ivars->pipeIn) == kIOReturnSuccess &&
                intf->CopyPipe(epOut, &ivars->pipeOut) == kIOReturnSuccess) {
                ivars->intf = intf;
                ivars->ifaceNumber = num;
                break;
            }
            OSSafeReleaseNULL(ivars->pipeIn);
            OSSafeReleaseNULL(ivars->pipeOut);
            intf->Close(this, 0);
        }
        OSSafeReleaseNULL(intf);
    }
    dev->DestroyInterfaceIterator(iter);
    if (!ivars->intf) { dev->Close(this, 0); return kIOReturnNotFound; }

    IOBufferMemoryDescriptor::Create(kIOMemoryDirectionIn, kChunk, 0, &ivars->bufIn);
    IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOut, kChunk, 0, &ivars->bufOut);
    IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, 4096, 0, &ivars->bufCtl);
    if (!ivars->bufIn || !ivars->bufOut || !ivars->bufCtl) { ClosePort(); return kIOReturnNoMemory; }
    ivars->open = true;
    *vidPid = ((uint32_t)ivars->vid << 16) | ivars->pid;
    *interfaceNumber = ivars->ifaceNumber;
    LOG("open, interface %u", ivars->ifaceNumber);
    return kIOReturnSuccess;
}

kern_return_t TamaSerialDriver::ClosePort()
{
    if (ivars->pipeIn) ivars->pipeIn->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, NULL);
    if (ivars->pipeOut) ivars->pipeOut->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, NULL);
    OSSafeReleaseNULL(ivars->pipeIn);
    OSSafeReleaseNULL(ivars->pipeOut);
    OSSafeReleaseNULL(ivars->bufIn);
    OSSafeReleaseNULL(ivars->bufOut);
    OSSafeReleaseNULL(ivars->bufCtl);
    if (ivars->intf) { ivars->intf->Close(this, 0); OSSafeReleaseNULL(ivars->intf); }
    if (ivars->open && ivars->device) ivars->device->Close(this, 0);
    ivars->open = false;
    return kIOReturnSuccess;
}

kern_return_t TamaSerialDriver::Control(uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
                                       uint8_t * data, uint16_t length, uint16_t * done)
{
    if (!ivars->open) return kIOReturnNotOpen;
    if (length > 4096) return kIOReturnBadArgument;
    IOAddressSegment seg = {};
    ivars->bufCtl->GetAddressRange(&seg);
    bool in = (bmRequestType & 0x80) != 0;
    if (!in && length) memcpy((void *)seg.address, data, length);
    uint16_t n = 0;
    kern_return_t ret = ivars->device->DeviceRequest(this, bmRequestType, bRequest, wValue, wIndex, length,
                                                     length ? ivars->bufCtl : nullptr, &n, 2000);
    if (in && n) memcpy(data, (const void *)seg.address, n);
    *done = n;
    return ret;
}

kern_return_t TamaSerialDriver::BulkWrite(const uint8_t * data, uint32_t length, uint32_t * done)
{
    if (!ivars->open) return kIOReturnNotOpen;
    if (length > kChunk) return kIOReturnBadArgument;
    IOAddressSegment seg = {};
    ivars->bufOut->GetAddressRange(&seg);
    memcpy((void *)seg.address, data, length);
    ivars->bufOut->SetLength(length);
    uint32_t n = 0;
    kern_return_t ret = ivars->pipeOut->IO(ivars->bufOut, length, &n, 5000);
    *done = n;
    return ret;
}

kern_return_t TamaSerialDriver::BulkRead(uint8_t * data, uint32_t capacity, uint32_t timeoutMs, uint32_t * done)
{
    if (!ivars->open) return kIOReturnNotOpen;
    if (capacity > kChunk) capacity = kChunk;
    IOAddressSegment seg = {};
    ivars->bufIn->GetAddressRange(&seg);
    ivars->bufIn->SetLength(capacity);
    uint32_t n = 0;
    kern_return_t ret = ivars->pipeIn->IO(ivars->bufIn, capacity, &n, timeoutMs);
    if (n) memcpy(data, (const void *)seg.address, n);
    *done = n;
    if (ret == kIOReturnTimeout) ret = kIOReturnSuccess; // nothing came in
    return ret;
}
