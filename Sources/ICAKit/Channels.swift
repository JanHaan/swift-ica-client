import Foundation

/// Contract between the Winstation Driver and the per-channel engines (Thinwire, TWI).
/// Owned by the orchestrator; change only by agreement (see DECISIONS.md D5).

/// What a channel engine may send towards the server.
public enum ChannelOutput {
    /// Data written on the engine's own virtual channel (WD packets 0x2F/0x30/0x31).
    case channel(Data)
    /// A WD-level packet the engine needs, e.g. Thinwire's 0x3A replies or 0x06 redraw.
    /// `body` is everything after the packet type byte, already length-encoded as the type requires.
    case wdPacket(type: UInt8, body: Data)
}

/// A virtual-channel engine. The WD calls `receive` with each reassembled channel payload,
/// in order, on one serial queue.
public protocol VirtualChannelEngine: AnyObject {
    /// Channel name as announced in the module list, e.g. "CTXTW  " or "CTXTWI\0".
    var channelName: String { get }
    /// Set by the WD before the first `receive`.
    var output: ((ChannelOutput) -> Void)? { get set }
    func receive(_ data: Data)
}
