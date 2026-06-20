import Foundation

public enum TrafficLightSlot: String, Equatable, CaseIterable, Sendable {
    case red
    case yellow
    case green
}

public struct TrafficLightPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TrafficLightRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func intersects(_ other: TrafficLightRect) -> Bool {
        minX < other.maxX
            && maxX > other.minX
            && minY < other.maxY
            && maxY > other.minY
    }
}

public struct TrafficLightQuotaRowLayout: Equatable, Sendable {
    public var label: String
    public var textRect: TrafficLightRect
    public var labelRect: TrafficLightRect
    public var valueRect: TrafficLightRect
    public var progressRect: TrafficLightRect

    public init(
        label: String,
        textRect: TrafficLightRect,
        labelRect: TrafficLightRect,
        valueRect: TrafficLightRect,
        progressRect: TrafficLightRect
    ) {
        self.label = label
        self.textRect = textRect
        self.labelRect = labelRect
        self.valueRect = valueRect
        self.progressRect = progressRect
    }
}

public struct TrafficLightLayout: Equatable, Sendable {
    public var windowSize: TrafficLightPoint
    public var bodyRect: TrafficLightRect
    public var titleRect: TrafficLightRect
    public var lightCenters: [TrafficLightSlot: TrafficLightPoint]
    public var hudRect: TrafficLightRect
    public var statusRect: TrafficLightRect
    public var quotaRows: [TrafficLightQuotaRowLayout]
    public var lensGlowRadius: Double
    public var lensBulbRadius: Double
    public var minimumHudGap: Double
    public var bottomSafeInset: Double
    public var minimumPercentTextWidth: Double

    public init(
        windowSize: TrafficLightPoint,
        bodyRect: TrafficLightRect,
        titleRect: TrafficLightRect,
        lightCenters: [TrafficLightSlot: TrafficLightPoint],
        hudRect: TrafficLightRect,
        statusRect: TrafficLightRect,
        quotaRows: [TrafficLightQuotaRowLayout],
        lensGlowRadius: Double,
        lensBulbRadius: Double,
        minimumHudGap: Double,
        bottomSafeInset: Double,
        minimumPercentTextWidth: Double
    ) {
        self.windowSize = windowSize
        self.bodyRect = bodyRect
        self.titleRect = titleRect
        self.lightCenters = lightCenters
        self.hudRect = hudRect
        self.statusRect = statusRect
        self.quotaRows = quotaRows
        self.lensGlowRadius = lensGlowRadius
        self.lensBulbRadius = lensBulbRadius
        self.minimumHudGap = minimumHudGap
        self.bottomSafeInset = bottomSafeInset
        self.minimumPercentTextWidth = minimumPercentTextWidth
    }

    public static let `default`: TrafficLightLayout = {
        let width = 360.0
        let height = 165.0
        let bodyInsetX = 8.0
        let bodyInsetY = 8.0

        func quotaRow(label: String, x: Double, baseY: Double, width: Double, labelWidth: Double, gap: Double) -> TrafficLightQuotaRowLayout {
            let valueWidth = width - labelWidth - gap
            let textRect = TrafficLightRect(x: x, y: baseY + 12, width: width, height: 26)
            return TrafficLightQuotaRowLayout(
                label: label,
                textRect: textRect,
                labelRect: TrafficLightRect(x: x, y: textRect.y, width: labelWidth, height: textRect.height),
                valueRect: TrafficLightRect(
                    x: x + labelWidth + gap,
                    y: textRect.y,
                    width: valueWidth,
                    height: textRect.height
                ),
                progressRect: TrafficLightRect(x: x, y: baseY, width: width, height: 6)
            )
        }

        return TrafficLightLayout(
            windowSize: TrafficLightPoint(x: width, y: height),
            bodyRect: TrafficLightRect(
                x: bodyInsetX,
                y: bodyInsetY,
                width: width - bodyInsetX * 2,
                height: height - bodyInsetY * 2
            ),
            titleRect: TrafficLightRect(x: 244, y: 112, width: 86, height: 18),
            lightCenters: [
                .red: TrafficLightPoint(x: 78, y: 103),
                .yellow: TrafficLightPoint(x: 138, y: 103),
                .green: TrafficLightPoint(x: 198, y: 103)
            ],
            hudRect: TrafficLightRect(x: 22, y: 17, width: 316, height: 132),
            statusRect: TrafficLightRect(x: 244, y: 86, width: 86, height: 32),
            quotaRows: [
                quotaRow(label: "5小时", x: 54, baseY: 33, width: 136, labelWidth: 64, gap: 12),
                quotaRow(label: "1周", x: 224, baseY: 33, width: 104, labelWidth: 46, gap: 12)
            ],
            lensGlowRadius: 28,
            lensBulbRadius: 24,
            minimumHudGap: 10,
            bottomSafeInset: 8,
            minimumPercentTextWidth: 42
        )
    }()

    public func center(for slot: TrafficLightSlot) -> TrafficLightPoint {
        lightCenters[slot]!
    }

    public func glowRect(for slot: TrafficLightSlot) -> TrafficLightRect {
        let center = center(for: slot)
        return TrafficLightRect(
            x: center.x - lensGlowRadius,
            y: center.y - lensGlowRadius,
            width: lensGlowRadius * 2,
            height: lensGlowRadius * 2
        )
    }

    public func bulbRect(for slot: TrafficLightSlot) -> TrafficLightRect {
        let center = center(for: slot)
        return TrafficLightRect(
            x: center.x - lensBulbRadius,
            y: center.y - lensBulbRadius,
            width: lensBulbRadius * 2,
            height: lensBulbRadius * 2
        )
    }
}
