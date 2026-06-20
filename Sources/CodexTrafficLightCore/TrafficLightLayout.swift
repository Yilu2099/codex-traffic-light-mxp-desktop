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
        self.statusRect = statusRect
        self.quotaRows = quotaRows
        self.lensGlowRadius = lensGlowRadius
        self.lensBulbRadius = lensBulbRadius
        self.minimumHudGap = minimumHudGap
        self.bottomSafeInset = bottomSafeInset
        self.minimumPercentTextWidth = minimumPercentTextWidth
    }

    public static let `default`: TrafficLightLayout = {
        let width = 96.0
        let height = 292.0
        let bodyInsetX = 12.0
        let bodyInsetY = 9.0
        let contentX = 16.0
        let contentWidth = 64.0
        let labelWidth = 28.0
        let gap = 4.0
        let valueWidth = contentWidth - labelWidth - gap

        func quotaRow(label: String, baseY: Double) -> TrafficLightQuotaRowLayout {
            let textRect = TrafficLightRect(x: contentX, y: baseY + 4, width: contentWidth, height: 11)
            return TrafficLightQuotaRowLayout(
                label: label,
                textRect: textRect,
                labelRect: TrafficLightRect(x: contentX, y: textRect.y, width: labelWidth, height: textRect.height),
                valueRect: TrafficLightRect(
                    x: contentX + labelWidth + gap,
                    y: textRect.y,
                    width: valueWidth,
                    height: textRect.height
                ),
                progressRect: TrafficLightRect(x: contentX, y: baseY, width: contentWidth, height: 2.5)
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
            titleRect: TrafficLightRect(x: 0, y: height - 32, width: width, height: 20),
            lightCenters: [
                .red: TrafficLightPoint(x: width / 2, y: height - 68),
                .yellow: TrafficLightPoint(x: width / 2, y: height - 128),
                .green: TrafficLightPoint(x: width / 2, y: 108)
            ],
            statusRect: TrafficLightRect(x: 14, y: 51, width: width - 28, height: 16),
            quotaRows: [
                quotaRow(label: "5小时", baseY: 31),
                quotaRow(label: "1周", baseY: 15)
            ],
            lensGlowRadius: 31,
            lensBulbRadius: 21,
            minimumHudGap: 8,
            bottomSafeInset: 5,
            minimumPercentTextWidth: 24
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
