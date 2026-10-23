import Foundation

/// When to take a keyframe during a guided sweep, and what to tell the user otherwise. Pure; unit-tested.
struct KeyframePolicy {
    /// Take the next keyframe once the view overlaps the existing keyframes by at most this much. A bit above the
    /// ~65% target because the high-res capture lands a few hundred ms later. Dense on purpose: each photo also
    /// overlaps the one two along, so a photo that doesn't match can be left out (`PoseRegistrar`).
    var triggerOverlap = 0.70
    /// Below this the user has moved too far past the last keyframe.
    var minOverlap = 0.30
    var maxSpeed = 0.25               // m/s
    var maxAngularSpeed = 25.0        // deg/s
    var maxViewAngle = 40.0           // deg away from facing the board squarely
    /// Sharpness must be at least this fraction of the best seen recently.
    var minRelativeSharpness = 0.55
    var maxKeyframes = 14
    /// The first photo is taken by the user (so they choose where the sweep starts); auto-capture after that.
    var manualFirst = true

    struct State {
        var trackingNormal: Bool
        var hasPlane: Bool
        var footprintValid: Bool
        var viewAngle: Double
        var keyframeCount: Int
        /// Max over keyframes of (fraction of the current view already covered). Nil before the first keyframe.
        var overlap: Double?
        var speed: Double
        var angularSpeed: Double
        var sharpness: Double
        var recentBestSharpness: Double
        var capturing: Bool
    }

    enum Guidance: String, Equatable {
        case trackingLimited = "Move slowly — tracking is limited"
        case findBoard = "Point at the whiteboard"
        case tapToStart = "Line up one end of the board, then tap the shutter"
        case tooOblique = "Face the board more squarely"
        case holdStill = "Hold still…"
        case full = "That's enough photos — tap Done"
        case tooFast = "Slow down"
        case blurry = "Hold steady"
        case keepMoving = "Move slowly along the board"
        case moveBack = "Too far — move back a little"
    }

    enum Decision: Equatable { case capture, wait(Guidance) }

    func decide(_ s: State) -> Decision {
        if !s.trackingNormal { return .wait(.trackingLimited) }
        if !s.hasPlane || !s.footprintValid { return .wait(.findBoard) }
        if s.capturing { return .wait(.holdStill) }
        if s.viewAngle > maxViewAngle { return .wait(.tooOblique) }
        if s.keyframeCount >= maxKeyframes { return .wait(.full) }
        if manualFirst, s.keyframeCount == 0 { return .wait(.tapToStart) }
        if let o = s.overlap, o < minOverlap { return .wait(.moveBack) }
        if s.speed > maxSpeed || s.angularSpeed > maxAngularSpeed { return .wait(.tooFast) }
        if let o = s.overlap, o > triggerOverlap { return .wait(.keepMoving) }
        if s.sharpness < minRelativeSharpness * s.recentBestSharpness { return .wait(.blurry) }
        return .capture
    }
}
