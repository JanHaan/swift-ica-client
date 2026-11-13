import Darwin
import Foundation
import Testing
@testable import AppHostKit

@Suite struct MachChannelTests {
    @Test func encodeDecodeWithoutPort() throws {
        let payload = Data("hello".utf8)
        let bytes = try #require(MachChannel.encode(payload: payload, dest: 0x1234, port: 0, disposition: 19))
        #expect(bytes.count == 24 + 4 + 8)                     // header, length, 5 bytes padded to 8
        let decoded = try #require(bytes.withUnsafeBytes { MachChannel.decode($0) })
        #expect(decoded.payload == payload && decoded.port == 0)
    }

    @Test func encodeDecodeWithPort() throws {
        let payload = Data(repeating: 7, count: 13)
        let bytes = try #require(MachChannel.encode(payload: payload, dest: 0x1234, port: 0x5678, disposition: 19))
        #expect(bytes.count == 24 + 4 + 12 + 4 + 16)
        let header = bytes.withUnsafeBytes { $0.loadUnaligned(as: mach_msg_header_t.self) }
        #expect(header.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0)
        #expect(header.msgh_id == MachChannel.messageId)
        let decoded = try #require(bytes.withUnsafeBytes { MachChannel.decode($0) })
        #expect(decoded.payload == payload && decoded.port == 0x5678)
    }

    @Test func rejectsForeignAndTruncatedMessages() throws {
        var bytes = try #require(MachChannel.encode(payload: Data("x".utf8), dest: 1, port: 0, disposition: 19))
        #expect(bytes.dropLast(4).withUnsafeBytes { MachChannel.decode($0) } == nil)
        bytes[20] ^= 0xFF                                       // msgh_id
        #expect(bytes.withUnsafeBytes { MachChannel.decode($0) } == nil)
        #expect(MachChannel.encode(payload: Data(count: MachChannel.maxPayload + 1), dest: 1, port: 0, disposition: 19) == nil)
    }

    /// A real kernel round trip inside the test process: a payload plus a port right.
    @Test func sendsPayloadAndPortThroughTheKernel() throws {
        let receivePort = try #require(MachChannel.allocateReceivePort())
        #expect(mach_port_insert_right(mach_task_self_, receivePort, receivePort, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        let carried = try #require(MachChannel.allocateReceivePort())
        let receiver = MachReceiver(port: receivePort)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var got: (Data, mach_port_t)?
        receiver.start(queue: DispatchQueue(label: "test")) { received in
            if case .message(let data, let port) = received { got = (data, port); done.signal() }
        }
        let message = HostMessage.frame(seed: 1, dirty: [WireRect(x: 1, y: 2, width: 3, height: 4)], sentNs: 5)
        #expect(MachChannel.send(message, to: receivePort, port: carried, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        #expect(done.wait(timeout: .now() + 2) == .success)
        let (data, port) = try #require(got)
        #expect(try WireCoding.decode(HostMessage.self, from: data) == message)
        #expect(port == carried)                               // one name per port within a task
        receiver.cancel()
        MachChannel.deallocate(port)
        mach_port_mod_refs(mach_task_self_, carried, MACH_PORT_RIGHT_RECEIVE, -1)
        MachChannel.deallocate(receivePort)
    }

    @Test func bootstrapCheckInAndLookUp() throws {
        let name = "local.alttab.ICAViewer.test.\(getpid()).\(UUID().uuidString.prefix(8))"
        let receive = try #require(MachChannel.checkIn(name))
        let send = try #require(MachChannel.lookUp(name))
        #expect(send == receive)
        MachChannel.deallocate(send)
        mach_port_mod_refs(mach_task_self_, receive, MACH_PORT_RIGHT_RECEIVE, -1)
    }
}
