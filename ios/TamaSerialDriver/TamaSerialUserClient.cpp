#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>
#include <DriverKit/IOUserClient.h>

#include "TamaSerialUserClient.h"
#include "TamaSerialDriver.h"

// Selectors, as the app calls them (ios/Runner/UsbDriverBridge.swift)
enum {
    kOpen = 0,      // -> scalar[0] = vid << 16 | pid, scalar[1] = interface number
    kClose = 1,
    kControl = 2,   // scalars: bmRequestType, bRequest, wValue, wIndex, length; struct in: OUT data; struct out: IN data
    kWrite = 3,     // struct in: data (<= 4096); -> scalar[0] = bytes written
    kRead = 4,      // scalars: capacity, timeout ms; struct out: data
};

struct TamaSerialUserClient_IVars {
    TamaSerialDriver * driver;
};

bool TamaSerialUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(TamaSerialUserClient_IVars, 1);
    return ivars != nullptr;
}

void TamaSerialUserClient::free()
{
    IOSafeDeleteNULL(ivars, TamaSerialUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(TamaSerialUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ivars->driver = OSDynamicCast(TamaSerialDriver, provider);
    if (!ivars->driver) return kIOReturnNoDevice;
    ivars->driver->retain();
    return kIOReturnSuccess;
}

kern_return_t IMPL(TamaSerialUserClient, Stop)
{
    if (ivars->driver) {
        ivars->driver->ClosePort();
        OSSafeReleaseNULL(ivars->driver);
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t TamaSerialUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments * a,
                                                  const IOUserClientMethodDispatch *, OSObject *, void *)
{
    TamaSerialDriver * d = ivars->driver;
    if (!d) return kIOReturnNotAttached;
    switch (selector) {
    case kOpen: {
        if (a->scalarOutputCount < 2) return kIOReturnBadArgument;
        uint32_t vp = 0, iface = 0;
        kern_return_t r = d->OpenPort(&vp, &iface);
        a->scalarOutput[0] = vp;
        a->scalarOutput[1] = iface;
        return r;
    }
    case kClose:
        return d->ClosePort();
    case kControl: {
        if (a->scalarInputCount < 5) return kIOReturnBadArgument;
        uint8_t type = (uint8_t)a->scalarInput[0], req = (uint8_t)a->scalarInput[1];
        uint16_t value = (uint16_t)a->scalarInput[2], index = (uint16_t)a->scalarInput[3], len = (uint16_t)a->scalarInput[4];
        if (len > 4096) return kIOReturnBadArgument;
        uint8_t buf[4096];
        if (!(type & 0x80) && len) {
            if (!a->structureInput || a->structureInput->getLength() < len) return kIOReturnBadArgument;
            memcpy(buf, a->structureInput->getBytesNoCopy(), len);
        }
        uint16_t done = 0;
        kern_return_t r = d->Control(type, req, value, index, buf, len, &done);
        if ((type & 0x80) && r == kIOReturnSuccess) a->structureOutput = OSData::withBytes(buf, done);
        return r;
    }
    case kWrite: {
        if (!a->structureInput || a->scalarOutputCount < 1) return kIOReturnBadArgument;
        uint32_t done = 0;
        kern_return_t r = d->BulkWrite((const uint8_t *)a->structureInput->getBytesNoCopy(),
                                       (uint32_t)a->structureInput->getLength(), &done);
        a->scalarOutput[0] = done;
        return r;
    }
    case kRead: {
        if (a->scalarInputCount < 2) return kIOReturnBadArgument;
        uint32_t cap = (uint32_t)a->scalarInput[0], to = (uint32_t)a->scalarInput[1];
        if (cap > 4096) cap = 4096;
        uint8_t buf[4096];
        uint32_t done = 0;
        kern_return_t r = d->BulkRead(buf, cap, to, &done);
        if (r == kIOReturnSuccess) a->structureOutput = OSData::withBytes(buf, done);
        return r;
    }
    }
    return kIOReturnBadArgument;
}
