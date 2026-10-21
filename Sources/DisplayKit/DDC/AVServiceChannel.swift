import CoreGraphics
import DisplayMonkCore
import Foundation
import IOKit

/// Apple Silicon DDC: every external framebuffer has a `DCPAVServiceProxy` beneath it, and an
/// IOAVService created from that proxy can perform I2C transfers to the display.
final class AVServiceChannel: DDCChannel {
    private let service: UnsafeMutableRawPointer
    private let readI2C: PrivateAPI.IOAVServiceI2C
    private let writeI2C: PrivateAPI.IOAVServiceI2C
    private let lock = NSLock()
    var timing = DDCTiming()

    /// Takes ownership of a +1 retained IOAVService.
    private init(service: UnsafeMutableRawPointer, readI2C: @escaping PrivateAPI.IOAVServiceI2C, writeI2C: @escaping PrivateAPI.IOAVServiceI2C) {
        self.service = service
        self.readI2C = readI2C
        self.writeI2C = writeI2C
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(service).release()
    }

    func write(_ code: VCPCode, value: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var message = DDCRequest.setVCP(code, value).avServiceMessage
        var delivered = false
        for _ in 0 ..< timing.writeRepeats {
            usleep(timing.delayBeforeWrite)
            delivered = send(&message) == 0 || delivered
        }
        return delivered
    }

    func read(_ code: VCPCode) -> Result<VCPReply, DDCError> {
        lock.lock()
        defer { lock.unlock() }
        var message = DDCRequest.getVCP(code).avServiceMessage
        var lastError = DDCError.noReply
        for attempt in 0 ... timing.retries {
            if attempt > 0 { usleep(timing.delayBetweenRetries) }
            usleep(timing.delayBeforeWrite)
            let sent = send(&message)
            guard sent == 0 else {
                lastError = .transportFailed(sent)
                continue
            }
            usleep(timing.delayBeforeRead)
            var reply = [UInt8](repeating: 0, count: DDC.vcpReplyLength)
            let received = reply.withUnsafeMutableBytes { buffer in
                readI2C(service, UInt32(DDC.chipAddress), 0, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard received == 0 else {
                lastError = .transportFailed(received)
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

    private func send(_ message: inout [UInt8]) -> IOReturn {
        message.withUnsafeMutableBytes { buffer in
            writeI2C(service, UInt32(DDC.chipAddress), UInt32(DDC.hostAddress), buffer.baseAddress!, UInt32(buffer.count))
        }
    }
}

// MARK: - Discovery

extension AVServiceChannel {
    /// What the framebuffer above a proxy says about the display it drives.
    private struct Candidate {
        let channel: AVServiceChannel
        let identity: EDIDIdentity?
        let registryPath: String?
        let productName: String?
        let serialNumber: Int?
    }

    static func discover(for displays: [Display]) -> [CGDirectDisplayID: DDCChannel] {
        let candidates = externalServices()
        guard !displays.isEmpty, !candidates.isEmpty else { return [:] }

        var pairs: [(score: Int, display: Int, candidate: Int)] = []
        for (displayIndex, display) in displays.enumerated() {
            let location = PrivateAPI.displayInfo(display.id)?["IODisplayLocation"] as? String
            for (candidateIndex, candidate) in candidates.enumerated() {
                pairs.append((score(display, candidate, location: location), displayIndex, candidateIndex))
            }
        }

        // With exactly one external display and one service there is nothing to disambiguate.
        let minimumScore = displays.count == 1 && candidates.count == 1 ? 0 : 2
        var result: [CGDirectDisplayID: DDCChannel] = [:]
        var usedCandidates = Set<Int>()
        for pair in pairs.sorted(by: { $0.score > $1.score }) where pair.score >= minimumScore {
            let display = displays[pair.display]
            guard result[display.id] == nil, !usedCandidates.contains(pair.candidate) else { continue }
            result[display.id] = candidates[pair.candidate].channel
            usedCandidates.insert(pair.candidate)
        }
        return result
    }

    private static func score(_ display: Display, _ candidate: Candidate, location: String?) -> Int {
        var score = 0
        // The framebuffer's registry path is what CoreDisplay reports as the display location,
        // which is the only thing that tells two identical monitors apart.
        if let location, location == candidate.registryPath { score += 10 }
        if let identity = candidate.identity {
            if UInt32(identity.vendorID) == display.vendorID { score += 1 }
            if UInt32(identity.productID) == display.modelID { score += 1 }
            let widthCM = Int((CGDisplayScreenSize(display.id).width / 10).rounded())
            if identity.widthCM > 0, abs(widthCM - Int(identity.widthCM)) <= 1 { score += 1 }
        }
        if let serial = candidate.serialNumber, serial != 0, UInt32(truncatingIfNeeded: serial) == display.serialNumber { score += 1 }
        if let name = candidate.productName, name.caseInsensitiveCompare(display.name) == .orderedSame { score += 1 }
        return score
    }

    private static func externalServices() -> [Candidate] {
        guard let create = PrivateAPI.ioAVServiceCreateWithService,
              let readI2C = PrivateAPI.ioAVServiceReadI2C,
              let writeI2C = PrivateAPI.ioAVServiceWriteI2C
        else { return [] }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        // A recursive walk visits each framebuffer before the proxy beneath it.
        var framebuffer: (identity: EDIDIdentity?, path: String?, name: String?, serial: Int?)?
        var candidates: [Candidate] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let name = registryName(entry) else { continue }
            if name.hasPrefix("AppleCLCD2") || name.hasPrefix("IOMobileFramebufferShim") {
                let product = (registryProperty(entry, "DisplayAttributes", as: [String: Any].self))?["ProductAttributes"] as? [String: Any]
                framebuffer = (
                    identity: registryProperty(entry, "EDID UUID", as: String.self).flatMap(EDIDIdentity.init(edidUUID:)),
                    path: registryPath(entry),
                    name: product?["ProductName"] as? String,
                    serial: product?["SerialNumber"] as? Int
                )
            } else if name == "DCPAVServiceProxy",
                      registryProperty(entry, "Location", as: String.self) == "External",
                      let info = framebuffer,
                      let service = create(nil, entry)
            {
                let channel = AVServiceChannel(service: service, readI2C: readI2C, writeI2C: writeI2C)
                candidates.append(Candidate(channel: channel, identity: info.identity, registryPath: info.path, productName: info.name, serialNumber: info.serial))
            }
        }
        return candidates
    }
}
