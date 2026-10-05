import Foundation

/// A smart card token as the PKCS#11 library reports it.
public struct TokenInfo: Equatable, Sendable {
    public var slot: UInt
    public var serial: String
    public var label: String
    public var model: String
    public var flags: UInt

    public init(slot: UInt, serial: String, label: String = "", model: String = "", flags: UInt = 0) {
        self.slot = slot; self.serial = serial; self.label = label; self.model = model; self.flags = flags
    }

    public var pinLocked: Bool { flags & PKCS11.CKF_USER_PIN_LOCKED != 0 }
    public var pinFinalTry: Bool { flags & PKCS11.CKF_USER_PIN_FINAL_TRY != 0 }
    public var pinCountLow: Bool { flags & PKCS11.CKF_USER_PIN_COUNT_LOW != 0 }
    public var pinToBeChanged: Bool { flags & PKCS11.CKF_USER_PIN_TO_BE_CHANGED != 0 }
}

public enum TokenError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The Rutoken driver (PKCS#11 library) is not installed.
    case noDriver
    case noToken
    case wrongPIN(finalTry: Bool)
    case pinLocked
    case pinLength
    case failed(String, UInt)

    public var description: String {
        switch self {
        case .noDriver: return "не установлен драйвер Рутокен"
        case .noToken: return "токен не вставлен"
        case .wrongPIN(let last): return last ? "неверный PIN, осталась одна попытка" : "неверный PIN"
        case .pinLocked: return "PIN заблокирован после неверных попыток, разблокируйте токен в «Панели управления Рутокен»"
        case .pinLength: return "PIN неподходящей длины"
        case .failed(let what, let code): return "\(what): ошибка токена 0x\(String(code, radix: 16))"
        }
    }
}

/// Work with one logged-in token. Data objects are private: reading them
/// needs the user PIN.
public protocol TokenSession {
    func readData(label: String) throws -> [UInt8]?
    /// Replaces any data objects with this label.
    func writeData(label: String, application: String, value: [UInt8]) throws
    func deleteData(label: String) throws
    func changePIN(old: String, new: String) throws
}

/// Talks to tokens. The real one loads the Rutoken PKCS#11 library; tests use
/// a fake. Calls block, so callers keep them off the main thread.
public protocol TokenDriver: Sendable {
    /// Tokens currently inserted. Throws noDriver when the library is missing.
    func tokens() throws -> [TokenInfo]
    func withSession<T>(slot: UInt, pin: String, _ body: (TokenSession) throws -> T) throws -> T
}

/// PKCS#11 through dlopen, so the app starts fine without the driver and
/// nothing has to be linked at build time.
public final class PKCS11: TokenDriver, @unchecked Sendable {
    static let CKF_RW_SESSION: UInt = 0x2
    static let CKF_SERIAL_SESSION: UInt = 0x4
    static let CKF_TOKEN_INITIALIZED: UInt = 0x400
    static let CKF_USER_PIN_COUNT_LOW: UInt = 0x10000
    static let CKF_USER_PIN_FINAL_TRY: UInt = 0x20000
    static let CKF_USER_PIN_LOCKED: UInt = 0x40000
    static let CKF_USER_PIN_TO_BE_CHANGED: UInt = 0x80000
    static let CKU_USER: UInt = 1
    static let CKO_DATA: UInt = 0
    static let CKA_CLASS: UInt = 0x0, CKA_TOKEN: UInt = 0x1, CKA_PRIVATE: UInt = 0x2, CKA_LABEL: UInt = 0x3
    static let CKA_APPLICATION: UInt = 0x10, CKA_VALUE: UInt = 0x11

    static let CKR_OK: UInt = 0
    static let CKR_PIN_INCORRECT: UInt = 0xA0
    static let CKR_PIN_INVALID: UInt = 0xA1
    static let CKR_PIN_LEN_RANGE: UInt = 0xA2
    static let CKR_PIN_LOCKED: UInt = 0xA4
    static let CKR_DEVICE_REMOVED: UInt = 0x32
    static let CKR_TOKEN_NOT_PRESENT: UInt = 0xE0
    static let CKR_TOKEN_NOT_RECOGNIZED: UInt = 0xE1
    static let CKR_SESSION_HANDLE_INVALID: UInt = 0xB3
    static let CKR_USER_ALREADY_LOGGED_IN: UInt = 0x100
    static let CKR_CRYPTOKI_ALREADY_INITIALIZED: UInt = 0x191

    /// Where the Rutoken installers put the library.
    public static let rutokenPaths = [
        "/Library/Frameworks/rtpkcs11ecp.framework/rtpkcs11ecp",
        "/usr/local/lib/librtpkcs11ecp.dylib",
        "/opt/homebrew/lib/librtpkcs11ecp.dylib",
        "/usr/lib/librtpkcs11ecp.so",
        "/usr/lib/x86_64-linux-gnu/librtpkcs11ecp.so",
    ]

    private typealias FnVoidPtr = @convention(c) (UnsafeMutableRawPointer?) -> UInt
    private typealias FnSlotList = @convention(c) (UInt8, UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<UInt>?) -> UInt
    private typealias FnTokenInfo = @convention(c) (UInt, UnsafeMutableRawPointer?) -> UInt
    private typealias FnOpen = @convention(c) (UInt, UInt, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                               UnsafeMutablePointer<UInt>?) -> UInt
    private typealias FnHandle = @convention(c) (UInt) -> UInt
    private typealias FnLogin = @convention(c) (UInt, UInt, UnsafePointer<UInt8>?, UInt) -> UInt
    private typealias FnFindInit = @convention(c) (UInt, UnsafeMutableRawPointer?, UInt) -> UInt
    private typealias FnFind = @convention(c) (UInt, UnsafeMutablePointer<UInt>?, UInt, UnsafeMutablePointer<UInt>?) -> UInt
    private typealias FnGetAttr = @convention(c) (UInt, UInt, UnsafeMutableRawPointer?, UInt) -> UInt
    private typealias FnCreate = @convention(c) (UInt, UnsafeMutableRawPointer?, UInt, UnsafeMutablePointer<UInt>?) -> UInt
    private typealias FnDestroy = @convention(c) (UInt, UInt) -> UInt
    private typealias FnSetPIN = @convention(c) (UInt, UnsafePointer<UInt8>?, UInt, UnsafePointer<UInt8>?, UInt) -> UInt

    private struct Functions {
        var getSlotList: FnSlotList
        var getTokenInfo: FnTokenInfo
        var openSession: FnOpen
        var closeSession: FnHandle
        var login: FnLogin
        var logout: FnHandle
        var findInit: FnFindInit
        var find: FnFind
        var findFinal: FnHandle
        var getAttr: FnGetAttr
        var create: FnCreate
        var destroy: FnDestroy
        var setPIN: FnSetPIN
    }

    private let paths: [String]
    private let lock = NSLock()
    private var fns: Functions?

    public init(paths: [String] = PKCS11.rutokenPaths) { self.paths = paths }

    public static var driverInstalled: Bool {
        rutokenPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Loads and initialises the library once; later calls reuse it.
    private func functions() throws -> Functions {
        try lock.withLock {
            if let fns { return fns }
            guard let handle = paths.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else { throw TokenError.noDriver }
            func sym<T>(_ name: String, _: T.Type) throws -> T {
                guard let p = dlsym(handle, name) else { throw TokenError.failed("в драйвере нет \(name)", 0) }
                return unsafeBitCast(p, to: T.self)
            }
            let initialize = try sym("C_Initialize", FnVoidPtr.self)
            let rv = initialize(nil)
            guard rv == Self.CKR_OK || rv == Self.CKR_CRYPTOKI_ALREADY_INITIALIZED else {
                throw TokenError.failed("запуск драйвера", rv)
            }
            let f = Functions(
                getSlotList: try sym("C_GetSlotList", FnSlotList.self),
                getTokenInfo: try sym("C_GetTokenInfo", FnTokenInfo.self),
                openSession: try sym("C_OpenSession", FnOpen.self),
                closeSession: try sym("C_CloseSession", FnHandle.self),
                login: try sym("C_Login", FnLogin.self),
                logout: try sym("C_Logout", FnHandle.self),
                findInit: try sym("C_FindObjectsInit", FnFindInit.self),
                find: try sym("C_FindObjects", FnFind.self),
                findFinal: try sym("C_FindObjectsFinal", FnHandle.self),
                getAttr: try sym("C_GetAttributeValue", FnGetAttr.self),
                create: try sym("C_CreateObject", FnCreate.self),
                destroy: try sym("C_DestroyObject", FnDestroy.self),
                setPIN: try sym("C_SetPIN", FnSetPIN.self))
            fns = f
            return f
        }
    }

    public func tokens() throws -> [TokenInfo] {
        let f = try functions()
        var count: UInt = 0
        var rv = f.getSlotList(1, nil, &count)
        guard rv == Self.CKR_OK else { throw TokenError.failed("список токенов", rv) }
        guard count > 0 else { return [] }
        var slots = [UInt](repeating: 0, count: Int(count))
        rv = f.getSlotList(1, &slots, &count)
        guard rv == Self.CKR_OK else { throw TokenError.failed("список токенов", rv) }
        // Uninitialised slots (empty readers, blank tokens) cannot hold the key.
        return slots.prefix(Int(count)).compactMap { try? info(f, slot: $0) }
            .filter { $0.flags & Self.CKF_TOKEN_INITIALIZED != 0 }
    }

    private func info(_ f: Functions, slot: UInt) throws -> TokenInfo {
        // CK_TOKEN_INFO: label[32], manufacturerID[32], model[16], serialNumber[16], flags (CK_ULONG), ...
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
        let rv = f.getTokenInfo(slot, buf)
        guard rv == Self.CKR_OK else { throw TokenError.failed("сведения о токене", rv) }
        func text(_ offset: Int, _ length: Int) -> String {
            let bytes = UnsafeRawBufferPointer(start: buf + offset, count: length)
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        }
        return TokenInfo(slot: slot, serial: text(80, 16), label: text(0, 32), model: text(64, 16),
                         flags: buf.load(fromByteOffset: 96, as: UInt.self))
    }

    public func withSession<T>(slot: UInt, pin: String, _ body: (TokenSession) throws -> T) throws -> T {
        let f = try functions()
        var h: UInt = 0
        var rv = f.openSession(slot, Self.CKF_SERIAL_SESSION | Self.CKF_RW_SESSION, nil, nil, &h)
        guard rv == Self.CKR_OK else { throw mapSessionError(rv, "открытие сессии") }
        defer { _ = f.closeSession(h) }
        let pinBytes = Array(pin.utf8)
        rv = f.login(h, Self.CKU_USER, pinBytes, UInt(pinBytes.count))
        switch rv {
        case Self.CKR_OK, Self.CKR_USER_ALREADY_LOGGED_IN: break
        case Self.CKR_PIN_INCORRECT, Self.CKR_PIN_INVALID:
            let flags = (try? info(f, slot: slot))?.flags ?? 0
            if flags & Self.CKF_USER_PIN_LOCKED != 0 { throw TokenError.pinLocked }
            throw TokenError.wrongPIN(finalTry: flags & Self.CKF_USER_PIN_FINAL_TRY != 0)
        case Self.CKR_PIN_LEN_RANGE: throw TokenError.wrongPIN(finalTry: false)
        case Self.CKR_PIN_LOCKED: throw TokenError.pinLocked
        default: throw mapSessionError(rv, "вход на токен")
        }
        defer { _ = f.logout(h) }
        return try body(Session(f: f, h: h))
    }

    private func mapSessionError(_ rv: UInt, _ what: String) -> TokenError {
        switch rv {
        case Self.CKR_TOKEN_NOT_PRESENT, Self.CKR_DEVICE_REMOVED, Self.CKR_TOKEN_NOT_RECOGNIZED,
             Self.CKR_SESSION_HANDLE_INVALID: return .noToken
        default: return .failed(what, rv)
        }
    }

    /// CK_ATTRIBUTE arrays built in raw memory: { CK_ULONG type; void *pValue; CK_ULONG ulValueLen }.
    struct Template {
        static let stride = 3 * MemoryLayout<UInt>.size
        let base: UnsafeMutableRawPointer
        let count: Int
        private var owned: [UnsafeMutableRawPointer] = []

        init(_ attrs: [(UInt, [UInt8])]) {
            count = attrs.count
            base = .allocate(byteCount: max(1, attrs.count) * Self.stride, alignment: 8)
            for (i, (type, value)) in attrs.enumerated() {
                let p = UnsafeMutableRawPointer.allocate(byteCount: max(1, value.count), alignment: 8)
                p.copyMemory(from: value, byteCount: value.count)
                owned.append(p)
                set(i, type: type, value: p, length: value.count)
            }
        }

        func set(_ i: Int, type: UInt, value: UnsafeMutableRawPointer?, length: Int) {
            let at = base + i * Self.stride
            at.storeBytes(of: type, as: UInt.self)
            at.storeBytes(of: UInt(bitPattern: value), toByteOffset: MemoryLayout<UInt>.size, as: UInt.self)
            at.storeBytes(of: UInt(length), toByteOffset: 2 * MemoryLayout<UInt>.size, as: UInt.self)
        }

        func length(_ i: Int) -> UInt { (base + i * Self.stride).load(fromByteOffset: 2 * MemoryLayout<UInt>.size, as: UInt.self) }

        func free() {
            owned.forEach { $0.deallocate() }
            base.deallocate()
        }

        static func ulong(_ v: UInt) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        static func bool(_ v: Bool) -> [UInt8] { [v ? 1 : 0] }
    }

    private struct Session: TokenSession {
        let f: Functions
        let h: UInt

        private func find(label: String) throws -> [UInt] {
            let t = Template([(CKA_CLASS, Template.ulong(CKO_DATA)), (CKA_LABEL, Array(label.utf8))])
            defer { t.free() }
            var rv = f.findInit(h, t.base, UInt(t.count))
            guard rv == CKR_OK else { throw TokenError.failed("поиск на токене", rv) }
            defer { _ = f.findFinal(h) }
            var found: [UInt] = []
            var batch = [UInt](repeating: 0, count: 16)
            while true {
                var n: UInt = 0
                rv = f.find(h, &batch, UInt(batch.count), &n)
                guard rv == CKR_OK else { throw TokenError.failed("поиск на токене", rv) }
                if n == 0 { break }
                found += batch.prefix(Int(n))
            }
            return found
        }

        func readData(label: String) throws -> [UInt8]? {
            guard let obj = try find(label: label).first else { return nil }
            let probe = UnsafeMutableRawPointer.allocate(byteCount: Template.stride, alignment: 8)
            defer { probe.deallocate() }
            let attr = Template(base: probe, count: 1)
            attr.set(0, type: CKA_VALUE, value: nil, length: 0)
            var rv = f.getAttr(h, obj, probe, 1)
            guard rv == CKR_OK else { throw TokenError.failed("чтение с токена", rv) }
            let length = Int(attr.length(0))
            let value = UnsafeMutableRawPointer.allocate(byteCount: max(1, length), alignment: 8)
            defer { value.deallocate() }
            attr.set(0, type: CKA_VALUE, value: value, length: length)
            rv = f.getAttr(h, obj, probe, 1)
            guard rv == CKR_OK else { throw TokenError.failed("чтение с токена", rv) }
            return Array(UnsafeRawBufferPointer(start: value, count: Int(attr.length(0))))
        }

        func writeData(label: String, application: String, value: [UInt8]) throws {
            try deleteData(label: label)
            let t = Template([(CKA_CLASS, Template.ulong(CKO_DATA)), (CKA_TOKEN, Template.bool(true)),
                              (CKA_PRIVATE, Template.bool(true)), (CKA_LABEL, Array(label.utf8)),
                              (CKA_APPLICATION, Array(application.utf8)), (CKA_VALUE, value)])
            defer { t.free() }
            var obj: UInt = 0
            let rv = f.create(h, t.base, UInt(t.count), &obj)
            guard rv == CKR_OK else { throw TokenError.failed("запись на токен", rv) }
        }

        func deleteData(label: String) throws {
            for obj in try find(label: label) {
                let rv = f.destroy(h, obj)
                guard rv == CKR_OK else { throw TokenError.failed("удаление с токена", rv) }
            }
        }

        func changePIN(old: String, new: String) throws {
            let o = Array(old.utf8), n = Array(new.utf8)
            let rv = f.setPIN(h, o, UInt(o.count), n, UInt(n.count))
            switch rv {
            case CKR_OK: return
            case CKR_PIN_INCORRECT: throw TokenError.wrongPIN(finalTry: false)
            case CKR_PIN_LEN_RANGE, CKR_PIN_INVALID: throw TokenError.pinLength
            case CKR_PIN_LOCKED: throw TokenError.pinLocked
            default: throw TokenError.failed("смена PIN", rv)
            }
        }
    }
}

extension PKCS11.Template {
    /// Wraps memory the caller owns; free() must not be called on it.
    init(base: UnsafeMutableRawPointer, count: Int) {
        self.base = base
        self.count = count
    }
}
