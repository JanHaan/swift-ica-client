import CMachBootstrap
import Darwin
import Dispatch
import Foundation

/// What arrived on a receive port.
public enum MachReceived {
    /// One of our messages: the payload and, if it carried one, a port right now owned by the handler
    /// (deallocate it when done).
    case message(Data, port: mach_port_t)
    /// A send right we asked about (`MachReceiver.notifyDeadName`) lost its receiver: the peer is gone.
    case deadName(mach_port_t)
}

/// Raw Mach messages for the helper channel (docs/99 §4): a payload of up to `maxPayload` bytes inline
/// plus at most one port descriptor (the IOSurface port, or the helper's reply port at check-in).
///
/// Layout: header (24) [, body (4), port descriptor (12) when complex], payload length (4), payload
/// padded to 4 bytes.
public enum MachChannel {
    public static let messageId: mach_msg_id_t = 0x1CA0
    public static let maxPayload = 32 * 1024
    static let headerSize = MemoryLayout<mach_msg_header_t>.size              // 24
    static let descriptorSize = MemoryLayout<mach_msg_port_descriptor_t>.size  // 12
    static let maxMessage = headerSize + 4 + descriptorSize + 4 + maxPayload
    static let receiveBufferSize = maxMessage + MemoryLayout<mach_msg_max_trailer_t>.size

    public static func checkIn(_ name: String) -> mach_port_t? {
        var port: mach_port_t = 0
        guard cmb_check_in(name, &port) == KERN_SUCCESS else { return nil }
        setQueueLimit(port)
        return port
    }

    public static func lookUp(_ name: String) -> mach_port_t? {
        var port: mach_port_t = 0
        return cmb_look_up(name, &port) == KERN_SUCCESS ? port : nil
    }

    public static func allocateReceivePort() -> mach_port_t? {
        var port: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS else { return nil }
        setQueueLimit(port)
        return port
    }

    /// The default queue holds 5 messages; frames and input bursts need more slack.
    static func setQueueLimit(_ port: mach_port_t) {
        var limits = mach_port_limits_t(mpl_qlimit: mach_port_msgcount_t(MACH_PORT_QLIMIT_LARGE))
        let count = mach_msg_type_number_t(MemoryLayout<mach_port_limits_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &limits) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                mach_port_set_attributes(mach_task_self_, port, MACH_PORT_LIMITS_INFO, $0, count)
            }
        }
    }

    public static func deallocate(_ port: mach_port_t) {
        if port != MACH_PORT_NULL { mach_port_deallocate(mach_task_self_, port) }
    }

    /// The bytes of one message (pure; exposed for tests).
    static func encode(payload: Data, dest: mach_port_t, port: mach_port_t, disposition: mach_msg_type_name_t) -> [UInt8]? {
        guard payload.count <= maxPayload else { return nil }
        let complex = port != MACH_PORT_NULL
        let inlineOffset = headerSize + (complex ? 4 + descriptorSize : 0)
        let size = inlineOffset + 4 + ((payload.count + 3) & ~3)
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { raw in
            var bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
            if complex { bits |= MACH_MSGH_BITS_COMPLEX }
            let header = mach_msg_header_t(msgh_bits: bits, msgh_size: mach_msg_size_t(size), msgh_remote_port: dest,
                                           msgh_local_port: mach_port_t(MACH_PORT_NULL), msgh_voucher_port: mach_port_t(MACH_PORT_NULL),
                                           msgh_id: messageId)
            raw.storeBytes(of: header, toByteOffset: 0, as: mach_msg_header_t.self)
            if complex {
                raw.storeBytes(of: mach_msg_size_t(1), toByteOffset: headerSize, as: mach_msg_size_t.self)
                var descriptor = mach_msg_port_descriptor_t()
                descriptor.name = port
                descriptor.disposition = disposition
                descriptor.type = mach_msg_descriptor_type_t(MACH_MSG_PORT_DESCRIPTOR)
                raw.storeBytes(of: descriptor, toByteOffset: headerSize + 4, as: mach_msg_port_descriptor_t.self)
            }
            raw.storeBytes(of: UInt32(payload.count), toByteOffset: inlineOffset, as: UInt32.self)
            payload.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: raw[(inlineOffset + 4)...]), count: payload.count)
        }
        return bytes
    }

    /// Payload and port of one received message, nil if it is not one of ours (pure; exposed for tests).
    static func decode(_ raw: UnsafeRawBufferPointer) -> (payload: Data, port: mach_port_t)? {
        guard raw.count >= headerSize else { return nil }
        let header = raw.loadUnaligned(fromByteOffset: 0, as: mach_msg_header_t.self)
        let size = min(Int(header.msgh_size), raw.count)
        guard header.msgh_id == messageId else { return nil }
        var offset = headerSize
        var port = mach_port_t(MACH_PORT_NULL)
        if header.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0 {
            guard size >= offset + 4 else { return nil }
            let count = Int(raw.loadUnaligned(fromByteOffset: offset, as: mach_msg_size_t.self))
            offset += 4
            guard count <= 1, size >= offset + count * descriptorSize else { return nil }
            if count == 1 {
                port = raw.loadUnaligned(fromByteOffset: offset, as: mach_msg_port_descriptor_t.self).name
                offset += descriptorSize
            }
        }
        guard size >= offset + 4 else { return nil }
        let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        guard length <= maxPayload, size >= offset + 4 + length else { return nil }
        return (Data(raw[(offset + 4)..<(offset + 4 + length)]), port)
    }

    /// Sends `payload` (and optionally `port` with `disposition`, COPY_SEND or MAKE_SEND: the sender
    /// keeps its own right either way). `timeoutMs` 0 = fail at once when the peer's queue is full.
    @discardableResult
    public static func send(_ payload: Data, to dest: mach_port_t, port: mach_port_t = mach_port_t(MACH_PORT_NULL),
                            disposition: mach_msg_type_name_t = mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
                            timeoutMs: UInt32 = 200) -> kern_return_t {
        guard var bytes = encode(payload: payload, dest: dest, port: port, disposition: disposition) else { return KERN_INVALID_ARGUMENT }
        let size = mach_msg_size_t(bytes.count)
        return bytes.withUnsafeMutableBytes { raw in
            mach_msg(raw.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                     size, 0, mach_port_t(MACH_PORT_NULL), timeoutMs, mach_port_t(MACH_PORT_NULL))
        }
    }

    @discardableResult
    public static func send<T: Encodable>(_ message: T, to dest: mach_port_t, port: mach_port_t = mach_port_t(MACH_PORT_NULL),
                                          disposition: mach_msg_type_name_t = mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
                                          timeoutMs: UInt32 = 200) -> kern_return_t {
        guard let data = try? WireCoding.encode(message) else { return KERN_INVALID_ARGUMENT }
        return send(data, to: dest, port: port, disposition: disposition, timeoutMs: timeoutMs)
    }
}

/// Receives on one port with a dispatch source; the handler runs on `queue`. Owns the receive right.
public final class MachReceiver {
    public let port: mach_port_t
    private var source: DispatchSourceMachReceive?
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: MachChannel.receiveBufferSize, alignment: 8)

    public init(port: mach_port_t) { self.port = port }

    deinit { buffer.deallocate() }

    public func start(queue: DispatchQueue, handler: @escaping (MachReceived) -> Void) {
        let source = DispatchSource.makeMachReceiveSource(port: port, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(handler) }
        let port = port
        source.setCancelHandler { mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1) }
        self.source = source
        source.resume()
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }

    /// Asks the kernel for a dead-name notification on this port when `send`'s receiver goes away.
    @discardableResult
    public func notifyDeadName(of send: mach_port_t) -> kern_return_t {
        var previous = mach_port_t(MACH_PORT_NULL)
        let kr = mach_port_request_notification(mach_task_self_, send, MACH_NOTIFY_DEAD_NAME, 0, port,
                                                mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE), &previous)
        MachChannel.deallocate(previous)
        return kr
    }

    private func drain(_ handler: (MachReceived) -> Void) {
        while true {
            let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
            let kr = mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, mach_msg_size_t(MachChannel.receiveBufferSize),
                              port, 0, mach_port_t(MACH_PORT_NULL))
            if kr == MACH_RCV_TIMED_OUT { return }
            if kr == MACH_RCV_TOO_LARGE { continue }       // dropped by the kernel (no MACH_RCV_LARGE)
            guard kr == KERN_SUCCESS else { return }
            let raw = UnsafeRawBufferPointer(start: buffer, count: Int(header.pointee.msgh_size))
            if header.pointee.msgh_id == MACH_NOTIFY_DEAD_NAME {
                // mach_dead_name_notification_t: header, NDR record (8), the dead name.
                let name = raw.count >= MachChannel.headerSize + 12
                    ? raw.loadUnaligned(fromByteOffset: MachChannel.headerSize + 8, as: mach_port_name_t.self) : 0
                handler(.deadName(name))
            } else if let (payload, port) = MachChannel.decode(raw) {
                handler(.message(payload, port: port))
            } else {
                mach_msg_destroy(header)                     // not ours: release any rights it carried
            }
        }
    }
}
