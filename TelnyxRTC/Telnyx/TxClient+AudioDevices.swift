//
//  TxClient+AudioDevices.swift
//  TelnyxRTC
//
//  macOS-only: per-process selection of the audio devices WebRTC captures from and plays to.
//  iOS routes audio through AVAudioSession instead, so this file is compiled out there.
//

#if !os(iOS)
import CoreAudio
import Foundation
import WebRTC

/// An audio device as WebRTC's macOS audio device module sees it, joined with its CoreAudio identity.
public struct TxAudioDevice: Identifiable, Equatable, Sendable, CustomStringConvertible {
    /// Unique within one device list (input or output). Not stable across launches; see `uid`.
    public var id: String { admId }
    /// CoreAudio `kAudioDevicePropertyDeviceUID`. Stable across launches and reboots: persist this.
    /// Empty when WebRTC's id could not be resolved to a CoreAudio device.
    public let uid: String
    public let name: String
    /// WebRTC's own id: `"default"` for the system-default pseudo-entry at index 0, otherwise the
    /// decimal CoreAudio `AudioDeviceID`, which is only valid for the current HAL session.
    public let admId: String
    public let isDefault: Bool

    public var description: String { "\(name) [adm=\(admId) uid=\(uid.isEmpty ? "?" : uid)]" }
}

public enum TxAudioDeviceResult: Equatable, Sendable {
    /// The module now reports the requested device.
    case applied
    /// The peer connection factory was not built with an audio device module (iOS-style init).
    case noAudioDeviceModule
    /// No CoreAudio device with that UID has streams in the requested direction.
    case notFound
    /// CoreAudio has the device with streams in that direction, but WebRTC's list does not.
    /// Not observed with webrtc-sdk M150, whose list is an extra `"default (…)"` entry at index 0
    /// followed by every device; kept as a guard against a module that replaces index 0 instead.
    case shadowedByDefault
    /// The module refused or ignored the change. Expected while a call has recording/playout
    /// initialised; device changes only take effect between calls.
    case rejected
}

public enum TxAudioDirection: Sendable {
    case input
    case output
}

extension TxClient {

    /// `true` when the shared factory exposes an audio device module (macOS long initializer).
    public static var hasAudioDeviceModule: Bool { audioDeviceSelector.hasAudioDeviceModule }

    /// Capture devices WebRTC can use, in the module's own order (index 0 is the default entry).
    public static func audioInputDevices() -> [TxAudioDevice] { audioDeviceSelector.inputDevices() }

    /// Playout devices WebRTC can use, in the module's own order (index 0 is the default entry).
    public static func audioOutputDevices() -> [TxAudioDevice] { audioDeviceSelector.outputDevices() }

    /// The capture device the module currently reports, or nil if none is selected.
    public static var currentAudioInputDevice: TxAudioDevice? { audioDeviceSelector.currentInputDevice }

    /// The playout device the module currently reports, or nil if none is selected.
    public static var currentAudioOutputDevice: TxAudioDevice? { audioDeviceSelector.currentOutputDevice }

    /// Selects the capture device by CoreAudio UID; `nil` selects the system default entry.
    /// Call it between calls (before `Call.answer` / `newCall`), never during one.
    @discardableResult
    public static func setAudioInputDevice(uid: String?) -> TxAudioDeviceResult {
        audioDeviceSelector.setDevice(.input, uid: uid)
    }

    /// Selects the playout device by CoreAudio UID; `nil` selects the system default entry.
    /// Call it between calls (before `Call.answer` / `newCall`), never during one.
    @discardableResult
    public static func setAudioOutputDevice(uid: String?) -> TxAudioDeviceResult {
        audioDeviceSelector.setDevice(.output, uid: uid)
    }

    /// The selector behind the static API above, for code written against `TxAudioDeviceSelector`
    /// so it can serve this factory and a second WebRTC stack's alike. Created on first use, which
    /// also warms up the shared factory's audio device module.
    public static let audioDeviceSelector = TxAudioDeviceSelector(factory: Peer.factory, logPrefix: "TxClient")
}

/// Lists and selects the capture/playout devices of one `RTCPeerConnectionFactory`'s audio device
/// module. `TxClient`'s static API uses one for the SDK's shared factory; an app that runs a second
/// WebRTC stack in the same process (its own factory, so its own devices) can use another.
///
/// Creating it warms the module up: it keeps one idle, never-negotiated peer connection for its
/// lifetime (see `idleConnection`). Thread-safe in the same sense as the WebRTC calls it wraps.
public final class TxAudioDeviceSelector: @unchecked Sendable {

    public let factory: RTCPeerConnectionFactory
    private let logPrefix: String
    private let idleConnection: RTCPeerConnection?

    private static let defaultAdmId = "default"

    /// - Parameter factory: built with the long initializer and an audio device module type;
    ///   the plain initializer has no module and every call then reports `.noAudioDeviceModule`.
    public init(factory: RTCPeerConnectionFactory, logPrefix: String) {
        self.factory = factory
        self.logPrefix = logPrefix
        // webrtc-sdk M150 initialises the native module lazily and tears it down again when the
        // last peer connection is released: `RecordingDevices()` / `PlayoutDevices()` report
        // nothing unless at least one `RTCPeerConnection` exists (verified: an audio source alone
        // is not enough, closing the connection is fine, releasing it empties the lists again).
        // Keep one idle connection for the selector's lifetime so the lists exist between calls.
        // It never negotiates, so it opens no sockets and starts no audio.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        idleConnection = factory.peerConnection(with: RTCConfiguration(), constraints: constraints, delegate: nil)
        let adm = Self.module(of: factory)
        let counts = "inputs=\(adm?.inputDevices.count ?? -1) outputs=\(adm?.outputDevices.count ?? -1)"
        if idleConnection == nil {
            Logger.log.e(message: "\(logPrefix):: audio device module warm-up: idle peer connection could not be created (\(counts))")
        } else {
            Logger.log.i(message: "\(logPrefix):: audio device module warm-up done (\(counts))")
        }
    }

    public var hasAudioDeviceModule: Bool { audioDeviceModule != nil }

    /// Capture devices, in the module's own order (index 0 is the default entry).
    public func inputDevices() -> [TxAudioDevice] {
        guard let adm = audioDeviceModule else { return [] }
        return Self.joined(adm.inputDevices, direction: .input)
    }

    /// Playout devices, in the module's own order (index 0 is the default entry).
    public func outputDevices() -> [TxAudioDevice] {
        guard let adm = audioDeviceModule else { return [] }
        return Self.joined(adm.outputDevices, direction: .output)
    }

    public var currentInputDevice: TxAudioDevice? { currentDevice(.input) }
    public var currentOutputDevice: TxAudioDevice? { currentDevice(.output) }

    /// Selects a device by CoreAudio UID; `nil` selects the system default entry. The CoreAudio
    /// module rejects changes while recording/playout is initialised, so call it between calls.
    @discardableResult
    public func setDevice(_ direction: TxAudioDirection, uid: String?) -> TxAudioDeviceResult {
        let label = direction == .input ? "input" : "output"
        guard let adm = audioDeviceModule else {
            Logger.log.e(message: "\(logPrefix):: cannot set \(label) device: the peer connection factory has no audio device module")
            return .noAudioDeviceModule
        }
        let ioDevices = direction == .input ? adm.inputDevices : adm.outputDevices
        let known = Self.joined(ioDevices, direction: direction)
        guard !ioDevices.isEmpty else {
            Logger.log.e(message: "\(logPrefix):: cannot set \(label) device: WebRTC reports no \(label) devices")
            return .notFound
        }

        let target: RTCIODevice
        if let uid {
            // Prefer the explicit entry over the "default (…)" one when both carry the same UID.
            if let index = known.firstIndex(where: { $0.uid == uid && !$0.isDefault })
                ?? known.firstIndex(where: { $0.uid == uid }) {
                target = ioDevices[index]
            } else if let id = HAL.deviceID(forUID: uid), HAL.hasStreams(id, direction: direction) {
                Logger.log.e(message: "\(logPrefix):: \(label) device \(uid) exists in CoreAudio but not in WebRTC's list: shadowed by the index-0 default entry. Known: \(known)")
                return .shadowedByDefault
            } else {
                Logger.log.e(message: "\(logPrefix):: \(label) device \(uid) not found. Known: \(known)")
                return .notFound
            }
        } else if let index = ioDevices.firstIndex(where: { $0.deviceId == Self.defaultAdmId }) {
            target = ioDevices[index]
        } else {
            target = ioDevices[0]
        }

        // Do not trust the Bool: the Objective-C wrapper returns YES when the native call returns a
        // non-zero status, and the native call returns 0 on success. The getter is the truth.
        let reported = direction == .input ? adm.trySetInputDevice(target) : adm.trySetOutputDevice(target)
        let now = Self.currentIODevice(adm, direction: direction)
        let applied = now?.deviceId == target.deviceId
        Logger.log.i(message: "\(logPrefix):: set \(label) device → \(target.name) [\(target.deviceId)]: trySet returned \(reported), module now reports \(now?.name ?? "nil") [\(now?.deviceId ?? "-")] → \(applied ? "applied" : "rejected")")
        return applied ? .applied : .rejected
    }

    // MARK: - Implementation

    private var audioDeviceModule: RTCAudioDeviceModule? { Self.module(of: factory) }

    /// The header marks the property nonnull, but it is nil when the factory was created with the
    /// plain initializer. Reading it through KVC yields a real optional instead of a trap.
    private static func module(of factory: RTCPeerConnectionFactory) -> RTCAudioDeviceModule? {
        factory.value(forKey: "audioDeviceModule") as? RTCAudioDeviceModule
    }

    private func currentDevice(_ direction: TxAudioDirection) -> TxAudioDevice? {
        guard let adm = audioDeviceModule, let device = Self.currentIODevice(adm, direction: direction) else { return nil }
        return Self.joined([device], direction: direction).first
    }

    /// Same nullability story as `audioDeviceModule`: the getter returns nil when no device is
    /// selected or the device list is empty.
    private static func currentIODevice(_ adm: RTCAudioDeviceModule, direction: TxAudioDirection) -> RTCIODevice? {
        adm.value(forKey: direction == .input ? "inputDevice" : "outputDevice") as? RTCIODevice
    }

    private static func joined(_ devices: [RTCIODevice], direction: TxAudioDirection) -> [TxAudioDevice] {
        devices.map { device in
            let isDefault = device.isDefault || device.deviceId == defaultAdmId
            let coreAudioID: AudioDeviceID? = isDefault
                ? HAL.defaultDeviceID(direction: direction)
                : AudioDeviceID(device.deviceId)
            let uid = coreAudioID.flatMap { HAL.string($0, kAudioDevicePropertyDeviceUID) } ?? ""
            return TxAudioDevice(uid: uid, name: device.name, admId: device.deviceId, isDefault: isDefault)
        }
    }
}

// MARK: - CoreAudio HAL helpers

private enum HAL {

    static func defaultDeviceID(direction: TxAudioDirection) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// `kAudioHardwarePropertyTranslateUIDToDevice`: the UID is passed as the qualifier.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func hasStreams(_ deviceID: AudioDeviceID, direction: TxAudioDirection) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func string(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The HAL hands back a +1 CFString reference, hence Unmanaged + takeRetainedValue.
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
