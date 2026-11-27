import AppKit
import CoreFoundation
import Darwin
import Foundation

/// Dynamically resolves macOS SkyLight overlay-space functions (`dlopen`/`dlsym`) so
/// `LockScreenNotchPanel` can sit in an absolute-level-400 Space visible over the macOS Lock Screen.
/// Never hard-linked; gracefully falls back to a no-op if symbols are unavailable.
@MainActor
public final class SkyLightOverlaySpace {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias HideSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let fnMainConnectionID: MainConnectionIDFn?
    private let fnSpaceCreate: SpaceCreateFn?
    private let fnSpaceSetAbsoluteLevel: SpaceSetAbsoluteLevelFn?
    private let fnShowSpaces: ShowSpacesFn?
    private let fnHideSpaces: HideSpacesFn?
    private let fnSpaceDestroy: SpaceDestroyFn?
    private let fnSpaceAddWindows: SpaceAddWindowsFn?

    private var connectionID: Int32 = 0
    private var spaceID: UInt64 = 0

    public var isAvailable: Bool {
        fnMainConnectionID != nil
            && fnSpaceCreate != nil
            && fnSpaceSetAbsoluteLevel != nil
            && fnShowSpaces != nil
            && fnSpaceAddWindows != nil
    }

    public init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let h = dlopen(path, RTLD_LAZY)
        self.handle = h

        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let h, let sym = dlsym(h, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        self.fnMainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFn.self)
        self.fnSpaceCreate = resolve("SLSSpaceCreate", as: SpaceCreateFn.self)
        self.fnSpaceSetAbsoluteLevel = resolve("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevelFn.self)
        self.fnShowSpaces = resolve("SLSShowSpaces", as: ShowSpacesFn.self)
        self.fnHideSpaces = resolve("SLSHideSpaces", as: HideSpacesFn.self)
        self.fnSpaceDestroy = resolve("SLSSpaceDestroy", as: SpaceDestroyFn.self)
        self.fnSpaceAddWindows = resolve("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindowsFn.self)
    }

    /// Elevates `window` into a dedicated level-400 WindowServer overlay Space visible above Lock Screen.
    @discardableResult
    public func attach(window: NSWindow) -> Bool {
        guard isAvailable, window.windowNumber > 0 else { return false }
        guard let fnMainConnectionID,
              let fnSpaceCreate,
              let fnSpaceSetAbsoluteLevel,
              let fnShowSpaces,
              let fnSpaceAddWindows else {
            return false
        }

        if connectionID == 0 {
            connectionID = fnMainConnectionID()
        }
        guard connectionID != 0 else { return false }

        if spaceID == 0 {
            let created = fnSpaceCreate(connectionID, 1, 0)
            guard created != 0 else { return false }
            spaceID = created
            _ = fnSpaceSetAbsoluteLevel(connectionID, spaceID, 400)
            let spaceArray = [NSNumber(value: spaceID)] as CFArray
            _ = fnShowSpaces(connectionID, spaceArray)
        }

        let windowArray = [NSNumber(value: window.windowNumber)] as CFArray
        let status = fnSpaceAddWindows(connectionID, spaceID, windowArray, 7)
        return status == 0
    }

    public func teardown() {
        guard connectionID != 0, spaceID != 0 else { return }
        let spaceArray = [NSNumber(value: spaceID)] as CFArray
        _ = fnHideSpaces?(connectionID, spaceArray)
        _ = fnSpaceDestroy?(connectionID, spaceID)
        spaceID = 0
    }
}
