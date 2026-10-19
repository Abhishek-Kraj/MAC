import Foundation

/// A manual expanded size survives tab changes, content updates and the pill.
/// A surface minimum may temporarily enlarge it without erasing the choice.
struct PanelSizePreference {
    private(set) var manualSize: NSSize?

    mutating func record(_ size: NSSize) { manualSize = size }
    mutating func reset() { manualSize = nil }

    func expandedSize(automatic: NSSize, minimum: NSSize) -> NSSize {
        let desired = manualSize ?? automatic
        return NSSize(width: max(desired.width, minimum.width),
                      height: max(desired.height, minimum.height))
    }
}
