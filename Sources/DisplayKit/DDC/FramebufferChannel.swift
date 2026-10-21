import CoreGraphics
import DisplayMonkCore
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

/// Intel Mac DDC: raw I2C requests sent through the IOFramebuffer driving the display.
final class FramebufferChannel: DDCChannel {
    private let framebuffer: io_service_t
    private let replyTransactionType: IOOptionBits
    private let lock = NSLock()
    var timing = DDCTiming()

    init?(display: Display) {
        guard let framebuffer = Self.framebuffer(for: display) else { return nil }
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS, busCount > 0,
              let replyType = Self.supportedReplyTransactionType()
        else {
            IOObjectRelease(framebuffer)
            return nil
        }
        self.framebuffer = framebuffer
        replyTransactionType = replyType
    }

    deinit {
        IOObjectRelease(framebuffer)
    }

    func write(_ code: VCPCode, value: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var message = DDCRequest.setVCP(code, value).i2cMessage
        var delivered = false
        for _ in 0 ..< timing.writeRepeats {
            usleep(timing.delayBeforeWrite)
            let status = message.withUnsafeMutableBytes { buffer -> IOReturn in
                var request = IOI2CRequest()
                request.sendAddress = UInt32(DDC.displayWriteAddress)
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
                request.sendBytes = UInt32(buffer.count)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                return perform(&request)
            }
            delivered = status == 0 || delivered
        }
        return delivered
    }

    func read(_ code: VCPCode) -> Result<VCPReply, DDCError> {
        lock.lock()
        defer { lock.unlock() }
        var message = DDCRequest.getVCP(code).i2cMessage
        var lastError = DDCError.noReply
        for attempt in 0 ... timing.retries {
            if attempt > 0 { usleep(timing.delayBetweenRetries) }
            usleep(timing.delayBeforeWrite)
            var reply = [UInt8](repeating: 0, count: DDC.vcpReplyLength)
            let status = message.withUnsafeMutableBytes { send in
                reply.withUnsafeMutableBytes { receive -> IOReturn in
                    var request = IOI2CRequest()
                    request.sendAddress = UInt32(DDC.displayWriteAddress)
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: send.baseAddress)
                    request.sendBytes = UInt32(send.count)
                    request.minReplyDelay = 10
                    request.replyAddress = UInt32(DDC.displayWriteAddress) + 1
                    request.replySubAddress = DDC.hostAddress
                    request.replyTransactionType = replyTransactionType
                    request.replyBuffer = vm_address_t(bitPattern: receive.baseAddress)
                    request.replyBytes = UInt32(receive.count)
                    return perform(&request)
                }
            }
            guard status == 0 else {
                lastError = .transportFailed(status)
                continue
            }
            do {
                return .success(try VCPReply(parsing: reply, expecting: code))
            } catch let error as DDCReplyError {
                if case .unsupportedCode = error { return .failure(.invalidReply(error)) }
                lastError = .invalidReply(error)
            } catch {
                lastError = .noReply
            }
        }
        return .failure(lastError)
    }

    /// Tries each I2C bus of the framebuffer until one accepts the request.
    private func perform(_ request: inout IOI2CRequest) -> IOReturn {
        var busCount: IOItemCount = 0
        var status = IOFBGetI2CInterfaceCount(framebuffer, &busCount)
        guard status == KERN_SUCCESS else { return status }
        for bus in 0 ..< busCount {
            var interface: io_service_t = 0
            status = IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface)
            guard status == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }
            var connect: IOI2CConnectRef?
            status = IOI2CInterfaceOpen(interface, 0, &connect)
            guard status == KERN_SUCCESS, let connect else { continue }
            defer { IOI2CInterfaceClose(connect, 0) }
            status = IOI2CSendRequest(connect, 0, &request)
            if status == KERN_SUCCESS, request.result == KERN_SUCCESS {
                return KERN_SUCCESS
            }
            if status == KERN_SUCCESS { status = request.result }
        }
        return status
    }

    private static func framebuffer(for display: Display) -> io_service_t? {
        if let lookup = PrivateAPI.cgsServiceForDisplayNumber {
            var service: io_service_t = 0
            lookup(display.id, &service)
            // Ownership of the returned port is undocumented; take our own reference.
            if service != 0, IOObjectRetain(service) == KERN_SUCCESS {
                return service
            }
        }
        return matchingFramebuffer(for: display)
    }

    /// Fallback: the IOFramebuffer whose attached display reports the same vendor, product and serial.
    private static func matchingFramebuffer(for display: Display) -> io_service_t? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any]
            func value(_ key: String) -> UInt32 {
                (info?[key] as? NSNumber)?.uint32Value ?? 0
            }
            if value("DisplayVendorID") == display.vendorID,
               value("DisplayProductID") == display.modelID,
               value("DisplaySerialNumber") == display.serialNumber
            {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    private static func supportedReplyTransactionType() -> IOOptionBits? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let types = (registryProperty(service, kIOI2CTransactionTypesKey, as: NSNumber.self))?.uint64Value else { continue }
            if types & (1 << UInt64(kIOI2CDDCciReplyTransactionType)) != 0 {
                return IOOptionBits(kIOI2CDDCciReplyTransactionType)
            }
            if types & (1 << UInt64(kIOI2CSimpleTransactionType)) != 0 {
                return IOOptionBits(kIOI2CSimpleTransactionType)
            }
        }
        return nil
    }
}
