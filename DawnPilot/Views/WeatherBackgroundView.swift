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

/// Particle density for the animated scene. Low Power Mode keeps the same
/// composition and rhythm with fewer elements and no soft-focus passes.
private enum SceneDetail {
    case full
    case reduced

    var density: Double {
        switch self {
        case .full: 1.0
        case .reduced: 0.5
        }
    }

    var drawsSoftFocus: Bool {
        switch self {
        case .full: true
        case .reduced: false
        }
    }
}

struct WeatherBackgroundView: View {
    let scene: WeatherScene

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var animationStart: Date

    /// `animationStart` anchors the scene clock. Production callers use the
    /// default; previews and offscreen renders can pass an earlier anchor to
    /// compose a specific moment of the animation.
    init(scene: WeatherScene, animationStart: Date = Date()) {
        self.scene = scene
        _animationStart = State(initialValue: animationStart)
    }

    private var isAnimating: Bool {
        scenePhase == .active && !reduceMotion
    }

    private var minimumInterval: TimeInterval {
        isLowPowerModeEnabled ? 1.0 / 12.0 : 1.0 / 30.0
    }

    private var detail: SceneDetail {
        isLowPowerModeEnabled ? .reduced : .full
    }

    var body: some View {
        ZStack {
            WeatherSceneLayer(
                scene: scene,
                detail: detail,
                isAnimating: isAnimating,
                holdsStaticFrame: reduceMotion,
                minimumInterval: minimumInterval,
                animationStart: animationStart
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
    let detail: SceneDetail
    let isAnimating: Bool
    let holdsStaticFrame: Bool
    let minimumInterval: TimeInterval
    let animationStart: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: !isAnimating)) { timeline in
            // A paused timeline holds its last date, so the scene never jumps when
            // the app returns to the foreground. Reduce Motion pins one composed frame.
            WeatherSceneFrame(
                scene: scene,
                detail: detail,
                time: holdsStaticFrame
                    ? WeatherSceneFrame.staticFrameTime
                    : timeline.date.timeIntervalSince(animationStart)
            )
        }
    }
}

/// A cloud that crosses the full width and only recycles while it is entirely
/// off screen, so the loop point is never visible.
private struct DriftingCloud {
    let yFraction: CGFloat
    let scale: CGFloat
    let opacity: Double
    let period: TimeInterval
    let phase: Double
    let bobAmplitude: CGFloat
    let bobPeriod: TimeInterval
    let travelsLeft: Bool
}

/// One depth of rainfall. Each drop inside a layer gets its own speed, length
/// and phase, so drops recycle independently instead of as a single curtain.
private struct RainLayer {
    let count: Int
    let fallSpeed: Double
    let length: CGFloat
    let lineWidth: CGFloat
    let opacity: Double
    let driftStrength: CGFloat
    let blurRadius: CGFloat
    let salt: Int
}

private struct MistBand {
    let yFraction: CGFloat
    let heightFraction: CGFloat
    let opacity: Double
    let swayAmplitude: CGFloat
    let swayPeriod: TimeInterval
    let swayPhase: Double
    let bobAmplitude: CGFloat
    let bobPeriod: TimeInterval
}

private struct WeatherSceneFrame: View {
    /// Composition used when Reduce Motion is on: past every particle's fade-in.
    static let staticFrameTime: TimeInterval = 9.0

    let scene: WeatherScene
    let detail: SceneDetail
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

    // MARK: - Clear

    private static let clearClouds: [DriftingCloud] = [
        DriftingCloud(
            yFraction: 0.21,
            scale: 1.22,
            opacity: 0.18,
            period: 176,
            phase: 0.12,
            bobAmplitude: 0.010,
            bobPeriod: 23,
            travelsLeft: false
        ),
        DriftingCloud(
            yFraction: 0.42,
            scale: 0.82,
            opacity: 0.12,
            period: 127,
            phase: 0.63,
            bobAmplitude: 0.008,
            bobPeriod: 17,
            travelsLeft: false
        ),
        DriftingCloud(
            yFraction: 0.58,
            scale: 1.05,
            opacity: 0.09,
            period: 214,
            phase: 0.37,
            bobAmplitude: 0.012,
            bobPeriod: 29,
            travelsLeft: true
        )
    ]

    private func drawClearScene(context: inout GraphicsContext, size: CGSize) {
        let unit = min(size.width, size.height)
        // Two out-of-phase rhythms: the combined period is long enough that the
        // light never reads as a repeating pulse.
        let breath = 0.5 + 0.5 * (0.62 * sin(time / 6.4) + 0.38 * sin(time / 10.3 + 0.8))
        let sunCenter = CGPoint(
            x: size.width * (0.77 + 0.010 * CGFloat(sin(time / 53))),
            y: size.height * (0.30 - 0.014 * CGFloat(sin(time / 41)))
        )

        var bloomContext = context
        bloomContext.addFilter(.blur(radius: detail.drawsSoftFocus ? 34 : 20))
        bloomContext.fill(
            disc(at: sunCenter, radius: unit * (0.195 + 0.030 * CGFloat(breath))),
            with: .color(Self.sunlight.opacity(0.34 + 0.14 * breath))
        )

        drawSunRays(context: &context, center: sunCenter, radius: unit * 1.05)

        context.fill(
            disc(at: sunCenter, radius: unit * 0.105),
            with: .radialGradient(
                Gradient(colors: [
                    .white.opacity(0.52 + 0.10 * breath),
                    Self.sunlight.opacity(0.20),
                    Self.sunlight.opacity(0)
                ]),
                center: sunCenter,
                startRadius: 0,
                endRadius: unit * 0.105
            )
        )

        drawClouds(
            context: &context,
            size: size,
            clouds: Self.clearClouds,
            tint: .white,
            undersideTint: Color(red: 0.35, green: 0.30, blue: 0.44),
            blurRadius: 13,
            windOffset: 0
        )

        // Warm band just above the horizon, breathing on its own rhythm.
        var horizonContext = context
        horizonContext.addFilter(.blur(radius: detail.drawsSoftFocus ? 46 : 26))
        horizonContext.fill(
            Path(ellipseIn: CGRect(
                x: -size.width * 0.15,
                y: size.height * (0.86 - 0.012 * CGFloat(breath)),
                width: size.width * 1.30,
                height: size.height * (0.16 + 0.03 * CGFloat(breath))
            )),
            with: .color(Self.sunlight.opacity(0.16 + 0.07 * breath))
        )

        drawRisingMotes(context: &context, size: size)
    }

    private func drawSunRays(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        var rayContext = context
        rayContext.addFilter(.blur(radius: detail.drawsSoftFocus ? 14 : 8))

        let rayCount = 7
        // A very slow rotation plus per-ray shimmer on distinct periods.
        let baseAngle = time / 104
        for index in 0..<rayCount {
            let angle = baseAngle + Double(index) * (.pi * 2 / Double(rayCount))
            let shimmer = 0.5 + 0.5 * sin(time / (5.1 + Double(index) * 0.7) + Double(index) * 1.7)
            let spread = 0.028 + 0.020 * shimmer
            var path = Path()
            path.move(to: center)
            path.addLine(to: point(from: center, angle: angle - spread, distance: radius))
            path.addLine(to: point(from: center, angle: angle + spread, distance: radius))
            path.closeSubpath()
            rayContext.fill(path, with: .color(Self.sunlight.opacity(0.045 + 0.080 * shimmer)))
        }
    }

    private func drawRisingMotes(context: inout GraphicsContext, size: CGSize) {
        let count = max(8, Int(28 * detail.density))
        for index in 0..<count {
            let lane = hash01(index, 401)
            let speed = 0.020 + 0.034 * hash01(index, 402)
            let phase = hash01(index, 403)
            let life = fract(time * speed + phase)
            // sin envelope: every mote fades in and out, so recycling is invisible.
            let envelope = sin(.pi * life)
            let sway = sin(time / (3.1 + 2.4 * hash01(index, 404)) + Double(index))
            let x = size.width * (0.05 + 0.90 * CGFloat(lane) + 0.022 * CGFloat(sway))
            let y = size.height * (0.94 - CGFloat(life) * 0.74)
            let radius = 0.6 + 1.2 * CGFloat(hash01(index, 405))
            context.fill(
                disc(at: CGPoint(x: x, y: y), radius: radius),
                with: .color(.white.opacity(0.24 * envelope))
            )
        }
    }

    // MARK: - Rainy

    private static let rainClouds: [DriftingCloud] = [
        DriftingCloud(
            yFraction: 0.16,
            scale: 1.70,
            opacity: 0.34,
            period: 118,
            phase: 0.08,
            bobAmplitude: 0.010,
            bobPeriod: 19,
            travelsLeft: false
        ),
        DriftingCloud(
            yFraction: 0.31,
            scale: 1.24,
            opacity: 0.24,
            period: 91,
            phase: 0.55,
            bobAmplitude: 0.013,
            bobPeriod: 13,
            travelsLeft: false
        ),
        DriftingCloud(
            yFraction: 0.44,
            scale: 0.94,
            opacity: 0.16,
            period: 147,
            phase: 0.31,
            bobAmplitude: 0.009,
            bobPeriod: 27,
            travelsLeft: false
        )
    ]

    private static let rainLayers: [RainLayer] = [
        RainLayer(
            count: 66,
            fallSpeed: 0.34,
            length: 15,
            lineWidth: 0.7,
            opacity: 0.20,
            driftStrength: 0.45,
            blurRadius: 0,
            salt: 101
        ),
        RainLayer(
            count: 44,
            fallSpeed: 0.56,
            length: 26,
            lineWidth: 1.2,
            opacity: 0.36,
            driftStrength: 0.85,
            blurRadius: 0,
            salt: 211
        ),
        RainLayer(
            count: 12,
            fallSpeed: 0.92,
            length: 44,
            lineWidth: 2.1,
            opacity: 0.30,
            driftStrength: 1.30,
            blurRadius: 3.2,
            salt: 331
        )
    ]

    private func drawRainyScene(context: inout GraphicsContext, size: CGSize) {
        let wind = windField(time)

        drawClouds(
            context: &context,
            size: size,
            clouds: Self.rainClouds,
            tint: Color(red: 0.86, green: 0.90, blue: 0.94),
            undersideTint: Color(red: 0.10, green: 0.18, blue: 0.24),
            blurRadius: 14,
            windOffset: CGFloat(wind) * 0.012
        )

        for layer in Self.rainLayers {
            drawRainLayer(context: &context, size: size, layer: layer, wind: wind)
        }

        drawSplashes(context: &context, size: size)

        // Wet ground sheen, brightening slightly with the gusts.
        var sheenContext = context
        sheenContext.addFilter(.blur(radius: detail.drawsSoftFocus ? 26 : 14))
        let sheen = CGRect(
            x: size.width * 0.06,
            y: size.height * 0.80,
            width: size.width * 0.88,
            height: size.height * 0.18
        )
        sheenContext.fill(
            Path(ellipseIn: sheen),
            with: .color(Self.sheenColor.opacity(0.10 + 0.05 * (0.5 + 0.5 * wind)))
        )
    }

    private func drawRainLayer(
        context: inout GraphicsContext,
        size: CGSize,
        layer: RainLayer,
        wind: Double
    ) {
        let count = max(6, Int(Double(layer.count) * detail.density))
        var target = context
        if layer.blurRadius > 0, detail.drawsSoftFocus {
            target.addFilter(.blur(radius: layer.blurRadius))
        }

        // Three alpha buckets give per-drop variation with three stroke calls.
        var paths = [Path(), Path(), Path()]
        let drift = CGFloat(wind) * size.width * 0.055 * layer.driftStrength

        for index in 0..<count {
            let lane = hash01(index, layer.salt)
            let speedJitter = 0.76 + 0.48 * hash01(index, layer.salt &+ 1)
            let phase = hash01(index, layer.salt &+ 2)
            let lengthJitter = 0.70 + 0.60 * hash01(index, layer.salt &+ 3)
            let bucket = min(2, Int(hash01(index, layer.salt &+ 4) * 3))

            // Spawn above the top edge and retire below the bottom edge, so the
            // per-drop wrap always happens off screen.
            let fall = fract(time * layer.fallSpeed * speedJitter + phase)
            let y = size.height * (CGFloat(fall) * 1.28 - 0.14)
            let x = size.width * (CGFloat(lane) * 1.26 - 0.13) + drift
            let length = layer.length * lengthJitter
            let slant = CGFloat(wind) * length * 0.52 * layer.driftStrength - length * 0.10

            paths[bucket].move(to: CGPoint(x: x, y: y))
            paths[bucket].addLine(to: CGPoint(x: x + slant, y: y + length))
        }

        let bucketAlphas = [0.58, 0.82, 1.0]
        for (bucket, path) in paths.enumerated() {
            target.stroke(
                path,
                with: .color(Self.rainColor.opacity(layer.opacity * bucketAlphas[bucket])),
                style: StrokeStyle(lineWidth: layer.lineWidth, lineCap: .round)
            )
        }
    }

    private func drawSplashes(context: inout GraphicsContext, size: CGSize) {
        let count = max(4, Int(11 * detail.density))
        for index in 0..<count {
            let cycle = 1.5 + 1.9 * hash01(index, 501)
            let life = fract(time / cycle + hash01(index, 502))
            let x = size.width * (0.05 + 0.90 * CGFloat(hash01(index, 503)))
            let y = size.height * (0.86 + 0.10 * CGFloat(hash01(index, 504)))
            let reach = 8 + 9 * CGFloat(hash01(index, 505))
            let radius = 1.4 + CGFloat(life) * reach
            let fade = pow(1 - life, 2.2)
            let rect = CGRect(
                x: x - radius,
                y: y - radius * 0.30,
                width: radius * 2,
                height: radius * 0.60
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Self.sheenColor.opacity(0.32 * fade)),
                lineWidth: 0.9
            )
        }
    }

    // MARK: - Unknown

    private static let mistBands: [MistBand] = [
        MistBand(
            yFraction: 0.24,
            heightFraction: 0.19,
            opacity: 0.20,
            swayAmplitude: 0.16,
            swayPeriod: 47,
            swayPhase: 0.0,
            bobAmplitude: 0.012,
            bobPeriod: 31
        ),
        MistBand(
            yFraction: 0.52,
            heightFraction: 0.22,
            opacity: 0.15,
            swayAmplitude: 0.13,
            swayPeriod: 61,
            swayPhase: 1.9,
            bobAmplitude: 0.016,
            bobPeriod: 23
        ),
        MistBand(
            yFraction: 0.70,
            heightFraction: 0.18,
            opacity: 0.11,
            swayAmplitude: 0.19,
            swayPeriod: 79,
            swayPhase: 3.4,
            bobAmplitude: 0.010,
            bobPeriod: 37
        )
    ]

    private func drawUnknownScene(context: inout GraphicsContext, size: CGSize) {
        let breath = 0.5 + 0.5 * (0.6 * sin(time / 12.7) + 0.4 * sin(time / 19.3 + 1.1))

        var horizonContext = context
        horizonContext.addFilter(.blur(radius: detail.drawsSoftFocus ? 64 : 32))
        horizonContext.fill(
            Path(ellipseIn: CGRect(
                x: size.width * (0.16 - 0.03 * CGFloat(breath)),
                y: size.height * 0.60,
                width: size.width * 1.05,
                height: size.height * (0.26 + 0.04 * CGFloat(breath))
            )),
            with: .color(Self.hazeColor.opacity(0.09 + 0.05 * breath))
        )

        // Wide, heavily blurred bands sway back and forth instead of wrapping,
        // so there is no seam to notice.
        var mistContext = context
        mistContext.addFilter(.blur(radius: detail.drawsSoftFocus ? 26 : 15))
        for band in Self.mistBands {
            let sway = CGFloat(sin(time / band.swayPeriod + band.swayPhase))
            let bob = CGFloat(sin(time / band.bobPeriod + band.swayPhase * 0.5))
            let rect = CGRect(
                x: size.width * (-0.12 + band.swayAmplitude * sway),
                y: size.height * (band.yFraction + band.bobAmplitude * bob),
                width: size.width * 1.24,
                height: size.height * band.heightFraction
            )
            mistContext.fill(
                Path(ellipseIn: rect),
                with: .color(.white.opacity(band.opacity * (0.82 + 0.18 * breath)))
            )
        }

        drawFloatingDust(context: &context, size: size)
    }

    /// Slow, barely-there dust so the "weather unknown" sky still feels alive.
    private func drawFloatingDust(context: inout GraphicsContext, size: CGSize) {
        let count = max(6, Int(20 * detail.density))
        for index in 0..<count {
            let cycle = 34 + 46 * hash01(index, 601)
            let life = fract(time / cycle + hash01(index, 602))
            let envelope = sin(.pi * life)
            let x = size.width * (0.04 + 0.92 * CGFloat(hash01(index, 603))
                + 0.05 * CGFloat(sin(time / (7.3 + 4 * hash01(index, 604)) + Double(index))))
            let y = size.height * (0.10 + 0.82 * CGFloat(hash01(index, 605))
                - 0.06 * CGFloat(life))
            let radius = 0.7 + 1.1 * CGFloat(hash01(index, 606))
            context.fill(
                disc(at: CGPoint(x: x, y: y), radius: radius),
                with: .color(.white.opacity(0.17 * envelope))
            )
        }
    }

    // MARK: - Shared drawing

    private func drawClouds(
        context: inout GraphicsContext,
        size: CGSize,
        clouds: [DriftingCloud],
        tint: Color,
        undersideTint: Color?,
        blurRadius: CGFloat,
        windOffset: CGFloat
    ) {
        var cloudContext = context
        cloudContext.addFilter(.blur(radius: detail.drawsSoftFocus ? blurRadius : blurRadius * 0.55))

        for (index, cloud) in clouds.enumerated() {
            let span = Self.cloudHalfWidth * cloud.scale
            let travel = size.width + span * 2
            let progress = CGFloat(fract(time / cloud.period + cloud.phase))
            let advance = cloud.travelsLeft ? (1 - progress) : progress
            let center = CGPoint(
                x: -span + advance * travel + windOffset * size.width,
                y: size.height * (cloud.yFraction
                    + cloud.bobAmplitude * CGFloat(sin(time / cloud.bobPeriod + cloud.phase * 6)))
            )
            let seed = 900 &+ index &* 17
            if let undersideTint {
                appendCloud(
                    to: &cloudContext,
                    center: CGPoint(x: center.x, y: center.y + 13 * cloud.scale),
                    scale: cloud.scale * 0.94,
                    seed: seed,
                    color: undersideTint.opacity(cloud.opacity * 0.8)
                )
            }
            appendCloud(
                to: &cloudContext,
                center: center,
                scale: cloud.scale,
                seed: seed,
                color: tint.opacity(cloud.opacity)
            )
        }
    }

    /// Puffs of varying size along a flat base, jittered per cloud so no two
    /// clouds share a silhouette.
    private static let cloudPuffs: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
        (-52, 2, 156, 52),
        (32, 4, 132, 46),
        (-64, -22, 84, 66),
        (-16, -34, 96, 74),
        (34, -24, 76, 60),
        (76, -10, 56, 44),
        (-96, -6, 60, 44)
    ]

    private func appendCloud(
        to context: inout GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        seed: Int,
        color: Color
    ) {
        var path = Path()
        for (index, puff) in Self.cloudPuffs.enumerated() {
            let widthJitter = 0.84 + 0.32 * CGFloat(hash01(index, seed))
            let heightJitter = 0.82 + 0.36 * CGFloat(hash01(index, seed &+ 1))
            let width = puff.width * scale * widthJitter
            let height = puff.height * scale * heightJitter
            path.addEllipse(in: CGRect(
                x: center.x + puff.x * scale - width / 2,
                y: center.y + puff.y * scale - height / 2,
                width: width,
                height: height
            ))
        }
        context.fill(path, with: .color(color))
    }

    private func disc(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    private func point(from origin: CGPoint, angle: Double, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + distance * CGFloat(cos(angle)),
            y: origin.y + distance * CGFloat(sin(angle))
        )
    }

    /// Gusts built from three incommensurate periods, so the wind never settles
    /// into an obvious cycle. Result is roughly -1...1.
    private func windField(_ seconds: TimeInterval) -> Double {
        0.55 * sin(seconds / 11.3)
            + 0.30 * sin(seconds / 5.7 + 1.3)
            + 0.15 * sin(seconds / 23.9 + 0.4)
    }

    private func fract(_ value: Double) -> Double {
        value - floor(value)
    }

    /// Deterministic per-element noise in 0..<1. Stateless so every frame agrees.
    private func hash01(_ index: Int, _ salt: Int) -> Double {
        var value = UInt64(bitPattern: Int64(index &* 0x9E37_79B9 &+ salt &* 0x85EB_CA6B))
        value ^= value >> 33
        value = value &* 0xFF51_AFD7_ED55_8CCD
        value ^= value >> 29
        value = value &* 0xC4CE_B9FE_1A85_EC53
        value ^= value >> 32
        return Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Widest horizontal extent of a unit-scale cloud, including blur headroom.
    private static let cloudHalfWidth: CGFloat = 124

    private static let sunlight = Color(red: 1.0, green: 0.66, blue: 0.34)
    private static let rainColor = Color(red: 0.75, green: 0.91, blue: 1.0)
    private static let sheenColor = Color(red: 0.46, green: 0.76, blue: 0.85)
    private static let hazeColor = Color(red: 0.78, green: 0.43, blue: 0.43)
}

#Preview("晴天背景") {
    WeatherBackgroundView(scene: .clear)
        .ignoresSafeArea()
}

#Preview("雨天背景") {
    WeatherBackgroundView(scene: .rainy)
        .ignoresSafeArea()
}

#Preview("未知天气背景") {
    WeatherBackgroundView(scene: .unknown)
        .ignoresSafeArea()
}

#Preview("雨天背景 · 动画中段") {
    WeatherBackgroundView(scene: .rainy, animationStart: Date().addingTimeInterval(-45))
        .ignoresSafeArea()
}
