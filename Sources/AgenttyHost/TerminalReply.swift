import Foundation

/// Tells what a terminal emulator sends by itself apart from what a person
/// types: answers to the program's questions, focus changes, and the pointer
/// passing over the window.
///
/// Programs ask the terminal questions: where the cursor is, what kind of
/// terminal it is, what its colors are. Every emulator attached to a session
/// answers, and the answer travels the same way keystrokes do. Two things
/// follow when several clients watch one session:
///
/// - An answer must not count as "the user typed here". It would hand the
///   session's size to a client that is only showing it.
/// - The program should get one answer, from the client it is being used on.
///   An emulator with a different grid would report a different cursor
///   position.
public enum TerminalReply {
    /// True when `data` is nothing but emulator answers.
    public static func isReply(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count {
            guard let next = replyEnd(in: bytes, from: index) else { return false }
            index = next
        }
        return true
    }

    private static let escape: UInt8 = 0x1b

    /// Index just past one answer starting at `start`, or nil if what starts
    /// there is not an answer.
    private static func replyEnd(in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes[start] == escape, start + 1 < bytes.count else { return nil }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            return controlSequenceEnd(in: bytes, from: start + 2)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"):
            // Color and feature reports come as OSC, DCS or APC strings.
            return stringEnd(in: bytes, from: start + 2, allowBell: bytes[start + 1] == UInt8(ascii: "]"))
        default:
            return nil
        }
    }

    private static func controlSequenceEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        var parameters: [UInt8] = []
        var intermediates: [UInt8] = []
        while index < bytes.count, (0x30...0x3f).contains(bytes[index]) {
            parameters.append(bytes[index])
            index += 1
        }
        while index < bytes.count, (0x20...0x2f).contains(bytes[index]) {
            intermediates.append(bytes[index])
            index += 1
        }
        guard index < bytes.count, (0x40...0x7e).contains(bytes[index]) else { return nil }
        let final = bytes[index]
        let marker = parameters.first.flatMap { [UInt8(ascii: "?"), UInt8(ascii: ">"), UInt8(ascii: "=")].contains($0) ? $0 : nil }

        let isReply: Bool
        switch final {
        case UInt8(ascii: "R"):
            // Cursor position. Needs "row;column", which F3 alone does not send.
            isReply = parameters.contains(UInt8(ascii: ";")) || marker != nil
        case UInt8(ascii: "c"):
            // Device attributes always carry a marker.
            isReply = marker != nil
        case UInt8(ascii: "n"):
            // Status report ("0n").
            isReply = !parameters.isEmpty
        case UInt8(ascii: "y"):
            // Mode report ("?2026;2$y").
            isReply = intermediates == [UInt8(ascii: "$")]
        case UInt8(ascii: "u"):
            // Keyboard protocol flags ("?1u"). Without "?" it is a key press.
            isReply = marker == UInt8(ascii: "?")
        case UInt8(ascii: "t"):
            // Window and cell size reports.
            isReply = !parameters.isEmpty
        case UInt8(ascii: "I"), UInt8(ascii: "O"):
            // Focus gained or lost: the window, not the user's hands.
            isReply = parameters.isEmpty && intermediates.isEmpty
        case UInt8(ascii: "M"), UInt8(ascii: "m"):
            // Mouse reports ("<35;10;5M"). The pointer merely passing over a
            // window is not use of it; a click or a scroll is. Bit 32 marks
            // movement, and the low bits say 3 when no button is held.
            guard marker == nil, parameters.first == UInt8(ascii: "<"),
                  let code = Int(String(decoding: parameters.dropFirst().prefix { $0 != UInt8(ascii: ";") }, as: UTF8.self))
            else { isReply = false; break }
            isReply = code & 32 != 0 && code & 3 == 3 && code & 64 == 0
        default:
            isReply = false
        }
        return isReply ? index + 1 : nil
    }

    private static func stringEnd(in bytes: [UInt8], from start: Int, allowBell: Bool) -> Int? {
        var index = start
        while index < bytes.count {
            if allowBell, bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == escape, index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") { return index + 2 }
            index += 1
        }
        return nil
    }
}
