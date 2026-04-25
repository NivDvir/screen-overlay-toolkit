// SPDX-License-Identifier: MIT
//
// Public bounding-box type returned by the GroundingKit SDK.
//
// Coordinates are in the model's resize-space (max 1280 px on the longest side,
// snapped to multiples of 28 — the patch grid Qwen2.5-VL was trained on). To
// project back to screen-space, multiply by `screenWidth / resize.width`.

import Foundation

/// A rectangular region detected in an image, with a textual label assigned by the
/// vision-language model.
///
/// Coordinates are in the model's resize coordinate space, NOT raw screen pixels.
/// Use ``ground(image:prompt:)`` (returns coordinates ready to use) or scale
/// manually if you need screen pixels.
public struct BoundingBox: Sendable, Equatable, CustomStringConvertible {
    /// Left edge, in model coordinate space.
    public let x1: Int
    /// Top edge.
    public let y1: Int
    /// Right edge.
    public let x2: Int
    /// Bottom edge.
    public let y2: Int
    /// Label assigned by the model (e.g. `"question"`, `"editor"`, `"content"`).
    public let label: String

    public init(x1: Int, y1: Int, x2: Int, y2: Int, label: String) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.label = label
    }

    /// Width of the bounding box.
    public var width: Int { x2 - x1 }
    /// Height of the bounding box.
    public var height: Int { y2 - y1 }

    public var description: String {
        "BoundingBox(\(label): [\(x1), \(y1), \(x2), \(y2)])"
    }
}
