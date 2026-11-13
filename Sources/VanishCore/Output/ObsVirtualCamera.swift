import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

// MARK: - OBS Virtual Camera sink (CMIO)
func cmioProp<T>(_ obj: CMIOObjectID, _ sel: Int, as: T.Type, count: Int = 1) -> [T]? {
    var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == 0, size > 0 else { return nil }
    let n = Int(size) / MemoryLayout<T>.stride
    var out = [T](unsafeUninitializedCapacity: n) { _, c in c = n }
    var used: UInt32 = 0
    let st = out.withUnsafeMutableBytes { CMIOObjectGetPropertyData(obj, &addr, 0, nil, size, &used, $0.baseAddress!) }
    return st == 0 ? out : nil
}

func cmioStringProp(_ id: CMIOObjectID, _ sel: Int) -> String {
    var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let size = UInt32(MemoryLayout<CFString?>.size)
    var str: Unmanaged<CFString>?
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &str) == 0, let v = str else { return "" }
    return v.takeRetainedValue() as String
}

func deviceName(_ id: CMIOObjectID) -> String {
    var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
    var name: Unmanaged<CFString>?
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &name) == 0, let n = name else { return "" }
    size = 0
    return n.takeRetainedValue() as String
}

public final class ObsSink {
    public var enqueued = 0, dropped = 0, lastStatus: Int32 = 0, queueCapacity: Int32 = 0
    public init() {}
    var device: CMIODeviceID = 0
    var stream: CMIOStreamID = 0
    var queue: Unmanaged<CMSimpleQueue>?

    public func connect(deviceName wanted: String = "OBS Virtual Camera") -> Bool {
        guard let devs = cmioProp(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices, as: CMIODeviceID.self) else { return false }
        let obsUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"
        guard let dev = devs.first(where: { cmioStringProp($0, kCMIODevicePropertyDeviceUID) == obsUID }) ?? devs.first(where: { deviceName($0) == wanted }) else { return false }
        device = dev
        guard let streams = cmioProp(dev, kCMIODevicePropertyStreams, as: CMIOStreamID.self) else { return false }
        guard streams.count >= 2 else { return false }
        stream = streams[1]   // [0] = source, [1] = sink (same as pyvirtualcam)
        guard stream != 0 else { return false }
        let st = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue)
        guard st == 0, queue != nil else { print("CopyBufferQueue failed \(st)"); return false }
        let s2 = CMIODeviceStartStream(device, stream)
        if s2 != 0 { print("StartStream failed \(s2)"); return false }
        return true
    }

    public func pause() { CMIODeviceStopStream(device, stream) }
    public func resume() { CMIODeviceStartStream(device, stream) }
    /// Some process reads the camera. Excludes us only while our output is paused (~50 ms after pause()).
    public var othersReading: Bool { (cmioProp(device, kCMIODevicePropertyDeviceIsRunningSomewhere, as: UInt32.self)?.first ?? 0) != 0 }

    public func send(_ pb: CVPixelBuffer) {
        guard let q = queue?.takeUnretainedValue() else { return }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let f = fmt else { return }
        let now = CMTime(value: CMTimeValue(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: pb, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: f, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sample = sb else { return }
        queueCapacity = CMSimpleQueueGetCapacity(q)
        let st = CMSimpleQueueEnqueue(q, element: Unmanaged.passRetained(sample).toOpaque())
        lastStatus = st
        if st == 0 { enqueued += 1 } else { dropped += 1; Unmanaged.passUnretained(sample).release() }
    }
}

