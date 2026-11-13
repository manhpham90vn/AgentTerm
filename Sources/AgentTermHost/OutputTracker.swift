import Foundation

/// Follows a session's output byte by byte for the few things the screen
/// kept by `ScreenMirror` does not say.
///
/// The first is where the output stands. A program's output arrives in
/// pieces cut anywhere, also in the middle of an escape sequence or of a
/// character. A client that is given the screen at such a moment, and the
/// live output from then on, would get the end of something whose beginning
/// it never saw, and draw it as text. `pending` is that beginning.
///
/// The others are settings the emulator keeps to itself: how the mouse is
/// reported, whether lines wrap, whether the cursor shows, its shape, and
/// the colors the next text is written in.
struct OutputTracker {
    private enum State: Equatable {
        case ground
        case escape
        case csi
        /// An operating system command, or one of the other strings (device
        /// control, application command, privacy message, start of string).
        case string(endsWithBell: Bool)
        case stringEscape(endsWithBell: Bool)
        case character(left: Int)
    }

    private var state = State.ground
    /// The parameters of the control sequence being read, without its final byte.
    private var parameters: [UInt8] = []
    private var parametersOverflowed = false

    /// The bytes of what has begun and not ended: an escape sequence or a
    /// character of several bytes. Empty between two of them.
    private(set) var pending = Data()
    /// The private modes the program set or reset, by number.
    private(set) var modes: [Int: Bool] = [:]
    /// The parameters of each "select graphic rendition" since the last one
    /// that reset them: together, the colors and style of the next text.
    private(set) var pen: [String] = []
    /// The parameter of the last "set cursor style", if any.
    private(set) var cursorStyle: String?

    /// More than any sequence a terminal acts on. One that goes on longer, an
    /// image for one, is not kept: a client attaching in the middle of it
    /// misses that image.
    private static let pendingLimit = 1024 * 1024
    /// True from where what has begun grew past the limit until it ends.
    /// Its later pieces are not kept either: they would be its middle.
    private var pendingDropped = false
    /// Stands in for a string that was too long to keep. It opens a string
    /// of no meaning, so a client's emulator reads the rest of the real one
    /// as a string, up to its end, and draws none of it.
    private static let droppedString = Data([0x1B, 0x5D])
    private static let parameterLimit = 256
    private static let penLimit = 64

    mutating func consume(_ data: Data) {
        // Where in `data` the unfinished sequence began, or nil while it is
        // one that began in an earlier piece.
        var start: Int? = nil

        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<bytes.count {
                let byte = bytes[index]
                let was = state
                step(byte)
                if state == .ground {
                    start = nil
                } else if was == .ground || begins(byte, after: was) {
                    start = index
                }
            }
        }

        if state == .ground {
            pending.removeAll(keepingCapacity: true)
            pendingDropped = false
        } else if let start {
            pending = Data(data.suffix(from: data.startIndex + start))
            pendingDropped = false
        } else if !pendingDropped {
            // Nothing began in this piece, so all of it belongs to what an
            // earlier piece began.
            pending.append(data)
        }
        if pending.count > Self.pendingLimit {
            pendingDropped = true
            if case .string = state { pending = Self.droppedString } else { pending.removeAll() }
        }
    }

    /// True when `byte` ended what `was` was reading by starting something new.
    private func begins(_ byte: UInt8, after was: State) -> Bool {
        switch was {
        case .escape, .csi:
            return byte == 0x1B
        case .character:
            // A character cut short by the start of another one.
            return state != .ground && !(0x80...0xBF).contains(byte)
        case .string, .stringEscape:
            // The escape that ends a string, or cuts it short by starting
            // something else: either way what came before it is over.
            return byte == 0x1B
        case .ground:
            return false
        }
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .character(let left):
            if (0x80...0xBF).contains(byte) {
                state = left > 1 ? .character(left: left - 1) : .ground
            } else {
                // Not a valid character: whatever this byte is, it starts anew.
                state = .ground
                ground(byte)
            }
        case .escape:
            switch byte {
            case 0x5B:  // [
                state = .csi
                parameters.removeAll(keepingCapacity: true)
                parametersOverflowed = false
            case 0x5D:  // ]
                state = .string(endsWithBell: true)
            case 0x50, 0x58, 0x5E, 0x5F:  // P X ^ _
                state = .string(endsWithBell: false)
            case 0x1B:
                state = .escape
            case 0x20...0x2F:
                // An intermediate byte: the sequence goes on.
                break
            case 0x63:  // c, a full reset
                reset()
                state = .ground
            default:
                state = .ground
            }
        case .csi:
            switch byte {
            case 0x40...0x7E:
                if !parametersOverflowed { finishControlSequence(final: byte) }
                state = .ground
            case 0x1B:
                state = .escape
            case 0x18, 0x1A:
                state = .ground
            default:
                if parameters.count < Self.parameterLimit { parameters.append(byte) } else { parametersOverflowed = true }
            }
        case .string(let endsWithBell):
            switch byte {
            case 0x07 where endsWithBell: state = .ground
            case 0x18, 0x1A: state = .ground
            case 0x1B: state = .stringEscape(endsWithBell: endsWithBell)
            default: break
            }
        case .stringEscape:
            switch byte {
            case 0x5C: state = .ground  // \, the end of the string
            case 0x1B: break
            default:
                // Not the end of the string but the start of something
                // else: the string is over all the same, as an emulator has it.
                state = .escape
                step(byte)
            }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        switch byte {
        case 0x1B: state = .escape
        case 0xC2...0xDF: state = .character(left: 1)
        case 0xE0...0xEF: state = .character(left: 2)
        case 0xF0...0xF4: state = .character(left: 3)
        default: break
        }
    }

    private mutating func reset() {
        modes.removeAll()
        pen.removeAll()
        cursorStyle = nil
    }

    private mutating func finishControlSequence(final: UInt8) {
        let text = String(decoding: parameters, as: UTF8.self)
        switch final {
        case 0x68, 0x6C:  // h, l
            guard text.hasPrefix("?") else { return }
            for part in text.dropFirst().split(separator: ";") {
                if let mode = Int(part) { modes[mode] = final == 0x68 }
            }
        case 0x6D:  // m
            // Only digits and separators: with a prefix it is another command.
            guard text.allSatisfy({ $0.isNumber || $0 == ";" || $0 == ":" }) else { return }
            if text.isEmpty || text == "0" {
                pen.removeAll()
            } else if text.hasPrefix("0;") {
                pen = [text]
            } else {
                pen.append(text)
                if pen.count > Self.penLimit { pen.removeFirst() }
            }
        case 0x71:  // q
            if text.hasSuffix(" "), !text.hasPrefix("?"), !text.hasPrefix(">") {
                cursorStyle = String(text.dropLast())
            }
        case 0x70:  // p
            // A soft reset: the cursor shows again, lines wrap, text is plain.
            if text == "!" {
                modes[25] = nil
                modes[7] = nil
                pen.removeAll()
                cursorStyle = nil
            }
        default:
            break
        }
    }
}
