import Foundation

/// Reading and measuring D-Bus type signatures.
///
/// A signature is a flat string — `a{sv}`, `(iiay)`, `a(iiay)` — in which
/// containers nest without delimiters between siblings, so splitting one into
/// its top-level types means matching brackets rather than scanning for a
/// separator. Everything the marshaller does depends on getting that right, and
/// on the alignment each type demands, so both live here as plain functions
/// that can be tested directly.
public enum DBusSignature {
    /// The byte alignment a value of `signature` must start on.
    ///
    /// These are fixed by the specification, not by the host: a struct is always
    /// 8-aligned even though it may hold nothing wider than a byte, and a
    /// variant is 1-aligned even though its payload may be 8. Deriving them from
    /// the contents instead would produce a message the bus rejects.
    public static func alignment(of signature: String) -> Int {
        guard let first = signature.first else { return 1 }
        switch first {
        case "y", "g", "v": return 1
        case "n", "q": return 2
        case "b", "i", "u", "s", "o", "a": return 4
        case "x", "t", "d": return 8
        case "(", "{": return 8
        default: return 1
        }
    }

    /// Splits a signature into its top-level complete types.
    ///
    /// `"a{sv}s"` is two types, not six characters: `a{sv}` and `s`. Returns nil
    /// for anything unbalanced, so a malformed signature fails here rather than
    /// halfway through writing a message the bus will disconnect us for.
    public static func split(_ signature: String) -> [String]? {
        var types = [String]()
        let characters = Array(signature)
        var index = 0
        while index < characters.count {
            guard let length = completeTypeLength(characters, from: index) else { return nil }
            types.append(String(characters[index..<(index + length)]))
            index += length
        }
        return types
    }

    /// The element type of an array signature — `a{sv}` yields `{sv}`.
    public static func elementType(of signature: String) -> String? {
        guard signature.first == "a", signature.count > 1 else { return nil }
        return String(signature.dropFirst())
    }

    /// Length in characters of the one complete type starting at `start`.
    private static func completeTypeLength(_ characters: [Character], from start: Int) -> Int? {
        guard start < characters.count else { return nil }
        switch characters[start] {
        case "y", "b", "n", "q", "i", "u", "x", "t", "d", "s", "o", "g", "v":
            return 1
        case "a":
            // An array's type is `a` followed by exactly one complete type, so a
            // trailing `a` is unbalanced rather than an empty array.
            guard let inner = completeTypeLength(characters, from: start + 1) else { return nil }
            return 1 + inner
        case "(":
            return closingLength(characters, from: start, open: "(", close: ")")
        case "{":
            return closingLength(characters, from: start, open: "{", close: "}")
        default:
            return nil
        }
    }

    /// Length of a bracketed group, counting nested pairs of the same bracket.
    private static func closingLength(_ characters: [Character], from start: Int,
                                      open: Character, close: Character) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == open { depth += 1 }
            if characters[index] == close {
                depth -= 1
                if depth == 0 { return index - start + 1 }
            }
            index += 1
        }
        // Ran off the end with brackets still open.
        return nil
    }
}
