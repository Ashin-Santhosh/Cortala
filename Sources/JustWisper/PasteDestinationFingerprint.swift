import Foundation

/// A recreated accessibility object must still describe the same unchanged editor.
struct PasteDestinationFingerprint: Equatable {
    var role: String
    var identifier: String?
    var placeholder: String?
    var contentDigest: String
    var selection: NSRange
    var frame: CGRect

    func permitsReplacement(_ current: Self, sameWindow: Bool, sameParent: Bool) -> Bool {
        sameWindow && sameParent && self == current
    }
}
