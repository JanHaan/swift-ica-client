import Foundation

/// Thinwire capability blobs and client-to-server messages (docs/40-thinwire.md §2.3, §4, §7).
public enum ThinwireCapabilities {
    /// The recommended client capability blob of §7 (with the u16 first-entry offset after the count,
    /// §9.5): v1's default set minus JPEG, selective H.264,
    /// multi-monitor, YUV 4:4:4 and (for profile 2) text tracking.
    /// - Parameters:
    ///   - profile: 2 (full-screen H.264) or 3 (H.264 plus lossless text overlays).
    ///   - dpiScale: 100 × the display scale factor, at least 100.
    public static func recommendedBlob(profile: UInt32 = 2, dpiScale: UInt16 = 100) -> Data {
        var entries: [(UInt16, [UInt8])] = [
            (0x20, [0x02, 0x00, 0x01, 0x00, UInt8(max(dpiScale, 100) & 0xff), UInt8(max(dpiScale, 100) >> 8)]),
            (0x04, []), (0x03, []), (0x08, []), (0x0E, []), (0x19, []),
            (0x10, [0x0F, 0x00]),
            (0x15, []), (0x22, []),
            (0x0D, [0x04, 0x00, 0x00, 0x00]),
            (0x16, []),
            (0x18, [0x01, 0x00, 0x01, 0x00]),
            (0x1C, []),
            (0x17, [UInt8(profile & 0xff), UInt8((profile >> 8) & 0xff), UInt8((profile >> 16) & 0xff), UInt8(profile >> 24)]),
            (0x1A, [0x00]),
        ]
        if profile >= 3 { entries.append((0x1B, [0x00, 0x00])) }
        var w = ByteWriter()
        w.u8(0)
        w.u8(UInt8(entries.count))
        w.u16(4)   // offset of the first entry, as in the server blob (docs/30 live findings, §9.5)
        for (id, data) in entries {
            w.u16(UInt16(4 + data.count))
            w.u16(id)
            w.raw(data)
        }
        return w.data
    }

    /// Parses the server capability blob carried by INIT (§2.4). Returns entries in order.
    public static func parseServerBlob(_ blob: [UInt8]) -> [(id: UInt16, data: [UInt8])] {
        guard blob.count >= 4 else { return [] }
        var out: [(UInt16, [UInt8])] = []
        var off = Int(blob[2]) | Int(blob[3]) << 8
        while off + 2 < blob.count {
            guard off + 4 <= blob.count else { break }
            let len = Int(blob[off]) | Int(blob[off + 1]) << 8
            let id = UInt16(blob[off + 2]) | UInt16(blob[off + 3]) << 8
            guard len >= 4, off + len <= blob.count else { break }
            out.append((id, Array(blob[(off + 4)..<(off + len)])))
            off += len
        }
        return out
    }

    // MARK: WD packets

    /// A Thinwire C2H packet: WD type 0x3A, body = u16 length, u8 sub-command, data.
    public static func c2h(_ sub: UInt8, _ data: [UInt8]) -> ChannelOutput {
        var w = ByteWriter()
        w.u16(UInt16(1 + data.count))
        w.u8(sub)
        w.raw(data)
        return .wdPacket(type: 0x3A, body: w.data)
    }

    /// INIT acknowledgement (sub 0x15).
    public static func initAck(sessionId: UInt32) -> ChannelOutput {
        var w = ByteWriter(); w.u32(sessionId)
        return c2h(0x15, Array(w.data))
    }

    /// Stopwatch reply (sub 0x14).
    public static func stopwatchReply(id: UInt16, elapsedMs: UInt32) -> ChannelOutput {
        var w = ByteWriter(); w.u16(id); w.u32(elapsedMs)
        return c2h(0x14, Array(w.data))
    }

    /// Client FPS limit (sub 0x1F).
    public static func fpsLimit(_ fps: UInt16) -> ChannelOutput {
        var w = ByteWriter(); w.u16(fps)
        return c2h(0x1F, Array(w.data))
    }

    /// Enhanced mode change (sub 0x1E): resize or capability change when the server echoed 0x19.
    public static func enhancedModeChange(bitsPerPixel: UInt8 = 24, width: UInt16, height: UInt16, capabilityBlob: Data) -> ChannelOutput {
        var w = ByteWriter()
        w.u8(0); w.u8(bitsPerPixel); w.u16(width); w.u16(height)
        w.u16(UInt16(capabilityBlob.count)); w.raw(capabilityBlob)
        return c2h(0x1E, Array(w.data))
    }

    /// The part of `rect` a WD REDRAW can address: 12-bit edges with exclusive right/bottom, so at most
    /// up to `ScalingLimits.redrawMaxCoordinate` (4095; the last pixel column/row is 4094). 4096 does not
    /// fit the encoding (docs/40 §4.2, docs/80 §5 item 3).
    public static func redrawable(_ rect: TWRect) -> TWRect {
        let m = ScalingLimits.redrawMaxCoordinate
        let l = max(0, min(rect.x, m)), t = max(0, min(rect.y, m))
        let r = max(l, min(rect.maxX, m)), b = max(t, min(rect.maxY, m))
        return TWRect(l, t, r - l, b - t)
    }

    /// WD REDRAW (type 0x06): `06 00` + four 12-bit values left, top, right, bottom (exclusive), clipped
    /// to the addressable range (`redrawable`).
    public static func redraw(_ rect: TWRect) -> ChannelOutput {
        let c = redrawable(rect)
        let l = c.x, t = c.y, r = c.maxX, b = c.maxY
        let body: [UInt8] = [
            0x06, 0x00,
            UInt8(l & 0xff), UInt8((l >> 8) & 0xf) | UInt8((t & 0xf) << 4), UInt8((t >> 4) & 0xff),
            UInt8(r & 0xff), UInt8((r >> 8) & 0xf) | UInt8((b & 0xf) << 4), UInt8((b >> 4) & 0xff),
        ]
        return .wdPacket(type: 0x06, body: Data(body))
    }
}
