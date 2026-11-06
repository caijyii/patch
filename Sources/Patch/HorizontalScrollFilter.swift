// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import CoreGraphics

enum HorizontalScrollFilter {
    /// Mutates only horizontal scroll channels; vertical motion and gesture metadata stay intact.
    static func apply(to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis2, value: 0)
    }
}
