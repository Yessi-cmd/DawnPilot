import SwiftUI

enum WeatherScene: Equatable {
    case clear
    case rainy
    case unknown

    init(alarmKind: ManagedAlarmKind?) {
        switch alarmKind {
        case .clear:
            self = .clear
        case .rainy:
            self = .rainy
        case .fallback, nil:
            self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .clear: "sun.horizon.fill"
        case .rainy: "cloud.rain.fill"
        case .unknown: "cloud.fog.fill"
        }
    }

    fileprivate var skyColors: [Color] {
        switch self {
        case .clear:
            [
                Color(red: 0.03, green: 0.10, blue: 0.24),
                Color(red: 0.13, green: 0.38, blue: 0.60),
                Color(red: 0.86, green: 0.50, blue: 0.34)
            ]
        case .rainy:
            [
                Color(red: 0.025, green: 0.06, blue: 0.12),
                Color(red: 0.08, green: 0.19, blue: 0.27),
                Color(red: 0.15, green: 0.31, blue: 0.35)
            ]
        case .unknown:
            [
                Color(red: 0.04, green: 0.07, blue: 0.15),
                Color(red: 0.12, green: 0.20, blue: 0.31),
                Color(red: 0.30, green: 0.23, blue: 0.33)
            ]
        }
    }

    fileprivate var atmosphereColor: Color {
        switch self {
        case .clear: Color(red: 1.0, green: 0.58, blue: 0.34)
        case .rainy: Color(red: 0.25, green: 0.56, blue: 0.62)
        case .unknown: Color(red: 0.76, green: 0.42, blue: 0.44)
        }
    }

    fileprivate var atmosphereCenter: UnitPoint {
        switch self {
        case .clear: .bottomTrailing
        case .rainy: .bottom
        case .unknown: UnitPoint(x: 0.70, y: 0.72)
        }
    }
}

struct WeatherBackgroundView: View {
    let scene: WeatherScene

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var isAnimating: Bool {
        scenePhase == .active && !reduceMotion
    }

    private var minimumInterval: TimeInterval {
        isLowPowerModeEnabled ? 1.0 / 12.0 : 1.0 / 30.0
    }

    var body: some View {
        ZStack {
            WeatherSceneLayer(
                scene: scene,
                isAnimating: isAnimating,
                minimumInterval: minimumInterval
            )
            .id(scene)
            .transition(.opacity)

            LinearGradient(
                colors: [
                    .black.opacity(reduceTransparency ? 0.26 : 0.10),
                    .clear,
                    .black.opacity(reduceTransparency ? 0.56 : 0.30)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [.clear, .black.opacity(reduceTransparency ? 0.28 : 0.14)],
                center: .center,
                startRadius: 90,
                endRadius: 560
            )
        }
        .animation(.easeInOut(duration: 1.2), value: scene)
        .onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
        ) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityHidden(true)
    }
}

private struct WeatherSceneLayer: View {
    let scene: WeatherScene
    let isAnimating: Bool
    let minimumInterval: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: !isAnimating)) { timeline in
            WeatherSceneFrame(
                scene: scene,
                time: isAnimating ? timeline.date.timeIntervalSinceReferenceDate : 0
            )
        }
    }
}

private struct WeatherSceneFrame: View {
    let scene: WeatherScene
    let time: TimeInterval

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scene.skyColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [scene.atmosphereColor.opacity(0.26), .clear],
                center: scene.atmosphereCenter,
                startRadius: 0,
                endRadius: 480
            )

            Canvas { context, size in
                switch scene {
                case .clear:
                    drawClearScene(context: &context, size: size)
                case .rainy:
                    drawRainyScene(context: &context, size: size)
                case .unknown:
                    drawUnknownScene(context: &context, size: size)
                }
            }
        }
    }

    private func drawClearScene(context: inout GraphicsContext, size: CGSize) {
        let pulse = 0.92 + 0.08 * sin(time / 3.8)
        let sunCenter = CGPoint(x: size.width * 0.78, y: size.height * 0.31)
        let glowRadius = min(size.width, size.height) * 0.22 * pulse

        var glowContext = context
        glowContext.addFilter(.blur(radius: 28))
        glowContext.fill(
            Path(ellipseIn: CGRect(
                x: sunCenter.x - glowRadius,
                y: sunCenter.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )),
            with: .color(Color(red: 1.0, green: 0.66, blue: 0.34).opacity(0.50))
        )

        let slowDrift = wrapped(time / 44)
        let fastDrift = wrapped(time / 31)
        drawCloud(
            context: &context,
            center: CGPoint(x: size.width * (slowDrift * 1.4 - 0.2), y: size.height * 0.26),
            scale: 1.15,
            opacity: 0.20
        )
        drawCloud(
            context: &context,
            center: CGPoint(x: size.width * (1.15 - fastDrift * 1.35), y: size.height * 0.56),
            scale: 0.78,
            opacity: 0.14
        )

        var lightPath = Path()
        let pointCount = 24
        for index in 0..<pointCount {
            let seed = wrapped(Double(index) * 0.618_033_988_75)
            let x = size.width * (0.08 + 0.84 * seed)
            let ySeed = wrapped(Double(index) * 0.371 + time / 26)
            let y = size.height * (0.18 + 0.62 * ySeed)
            let radius = CGFloat(0.8 + Double(index % 3) * 0.45)
            lightPath.addEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }
        context.fill(lightPath, with: .color(.white.opacity(0.28)))
    }

    private func drawRainyScene(context: inout GraphicsContext, size: CGSize) {
        let slowDrift = wrapped(time / 35)
        let fastDrift = wrapped(time / 24)
        drawCloud(
            context: &context,
            center: CGPoint(x: size.width * (slowDrift * 1.5 - 0.25), y: size.height * 0.19),
            scale: 1.65,
            opacity: 0.38
        )
        drawCloud(
            context: &context,
            center: CGPoint(x: size.width * (1.3 - fastDrift * 1.55), y: size.height * 0.36),
            scale: 1.25,
            opacity: 0.28
        )

        drawRainLayer(
            context: &context,
            size: size,
            count: 58,
            speed: 0.42,
            length: 18,
            lineWidth: 0.8,
            opacity: 0.24
        )
        drawRainLayer(
            context: &context,
            size: size,
            count: 32,
            speed: 0.68,
            length: 29,
            lineWidth: 1.35,
            opacity: 0.42
        )

        var reflectionContext = context
        reflectionContext.addFilter(.blur(radius: 24))
        let reflection = CGRect(
            x: size.width * 0.08,
            y: size.height * 0.79,
            width: size.width * 0.84,
            height: size.height * 0.18
        )
        reflectionContext.fill(
            Path(ellipseIn: reflection),
            with: .color(Color(red: 0.31, green: 0.62, blue: 0.70).opacity(0.13))
        )
    }

    private func drawUnknownScene(context: inout GraphicsContext, size: CGSize) {
        let drift = wrapped(time / 48)
        let reverseDrift = wrapped(time / 39)

        var horizonContext = context
        horizonContext.addFilter(.blur(radius: 64))
        horizonContext.fill(
            Path(ellipseIn: CGRect(
                x: size.width * 0.18,
                y: size.height * 0.60,
                width: size.width * 1.05,
                height: size.height * 0.28
            )),
            with: .color(Color(red: 0.78, green: 0.43, blue: 0.43).opacity(0.12))
        )

        drawMistBand(
            context: &context,
            rect: CGRect(
                x: size.width * (drift * 0.6 - 0.3),
                y: size.height * 0.24,
                width: size.width * 1.15,
                height: size.height * 0.22
            ),
            opacity: 0.14
        )
        drawMistBand(
            context: &context,
            rect: CGRect(
                x: size.width * (-reverseDrift * 0.5 + 0.08),
                y: size.height * 0.54,
                width: size.width * 1.2,
                height: size.height * 0.24
            ),
            opacity: 0.10
        )
    }

    private func drawCloud(
        context: inout GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        opacity: Double
    ) {
        var cloudContext = context
        cloudContext.addFilter(.blur(radius: 18 * scale))
        cloudContext.opacity = opacity

        let parts = [
            CGRect(x: center.x - 94 * scale, y: center.y - 20 * scale, width: 188 * scale, height: 58 * scale),
            CGRect(x: center.x - 67 * scale, y: center.y - 48 * scale, width: 92 * scale, height: 78 * scale),
            CGRect(x: center.x + 4 * scale, y: center.y - 36 * scale, width: 76 * scale, height: 64 * scale)
        ]
        for part in parts {
            cloudContext.fill(Path(ellipseIn: part), with: .color(.white.opacity(0.82)))
        }
    }

    private func drawRainLayer(
        context: inout GraphicsContext,
        size: CGSize,
        count: Int,
        speed: Double,
        length: CGFloat,
        lineWidth: CGFloat,
        opacity: Double
    ) {
        var path = Path()
        let phase = wrapped(time * speed)

        for index in 0..<count {
            let xSeed = wrapped(Double(index) * 0.618_033_988_75)
            let ySeed = wrapped(Double(index) * 0.381_966_011_25 + phase)
            let x = size.width * (xSeed * 1.18 - 0.08)
            let y = size.height * (ySeed * 1.16 - 0.08)
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - length * 0.28, y: y + length))
        }

        context.stroke(
            path,
            with: .color(Color(red: 0.75, green: 0.91, blue: 1.0).opacity(opacity)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }

    private func drawMistBand(
        context: inout GraphicsContext,
        rect: CGRect,
        opacity: Double
    ) {
        var mistContext = context
        mistContext.addFilter(.blur(radius: 34))
        mistContext.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
    }

    private func wrapped(_ value: Double) -> CGFloat {
        CGFloat(value - floor(value))
    }
}

#Preview("晴天背景") {
    WeatherBackgroundView(scene: .clear)
        .ignoresSafeArea()
}

#Preview("雨天背景") {
    WeatherBackgroundView(scene: .rainy)
        .ignoresSafeArea()
}
