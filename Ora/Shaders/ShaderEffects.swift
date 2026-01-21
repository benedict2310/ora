//
//  ShaderEffects.swift
//  Ora
//
//  SwiftUI view modifiers for Metal shader effects.
//  Shaders adapted from Inferno (https://github.com/twostraws/Inferno) - MIT License
//

import SwiftUI

// MARK: - Shimmer Effect (Pure SwiftUI)

/// A view modifier that applies an animated shimmering effect.
/// Based on markiv/SwiftUI-Shimmer approach - masks content with animated gradient.
struct ShimmerEffect: ViewModifier {
    let isActive: Bool
    let duration: TimeInterval
    let bandSize: CGFloat

    @State private var isInitialState = true
    @Environment(\.layoutDirection) private var layoutDirection

    /// The shimmer gradient - translucent at edges, opaque in center
    /// Edge opacity controls base readability, center-to-edge ratio controls intensity
    private var gradient: Gradient {
        Gradient(colors: [
            .black.opacity(0.7),
            .black,
            .black.opacity(0.7)
        ])
    }

    /// Calculate start/end points for gradient animation
    private var min: CGFloat { 0 - bandSize }
    private var max: CGFloat { 1 + bandSize }

    private var startPoint: UnitPoint {
        if layoutDirection == .rightToLeft {
            isInitialState ? UnitPoint(x: max, y: min) : UnitPoint(x: 0, y: 1)
        } else {
            isInitialState ? UnitPoint(x: min, y: min) : UnitPoint(x: 1, y: 1)
        }
    }

    private var endPoint: UnitPoint {
        if layoutDirection == .rightToLeft {
            isInitialState ? UnitPoint(x: 1, y: 0) : UnitPoint(x: min, y: max)
        } else {
            isInitialState ? UnitPoint(x: 0, y: 0) : UnitPoint(x: max, y: max)
        }
    }

    func body(content: Content) -> some View {
        if isActive {
            content
                .mask(
                    LinearGradient(
                        gradient: gradient,
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
                .animation(
                    .linear(duration: duration).delay(0.25).repeatForever(autoreverses: false),
                    value: isInitialState
                )
                .onAppear {
                    // Delay animation start to prevent animating view appearance
                    DispatchQueue.main.asyncAfter(deadline: .now()) {
                        isInitialState = false
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Applies a shimmering spotlight effect to the view.
    ///
    /// - Parameters:
    ///   - active: Whether the effect is active. Defaults to `true`.
    ///   - duration: Duration of one shimmer cycle in seconds. Defaults to `1.5`.
    ///   - bandSize: Size of the shimmer band (0-1). Defaults to `0.3`.
    func shimmer(
        active: Bool = true,
        duration: TimeInterval = 1.5,
        bandSize: CGFloat = 0.3
    ) -> some View {
        modifier(ShimmerEffect(
            isActive: active,
            duration: duration,
            bandSize: bandSize
        ))
    }
}

// MARK: - Chromatic Aberration Effect

/// A view modifier that applies a chromatic aberration (color planes) effect.
struct ChromaticAberrationEffect: ViewModifier {
    let isActive: Bool
    let intensity: Float
    let animated: Bool

    @State private var startTime = Date.now

    func body(content: Content) -> some View {
        if isActive {
            if animated {
                TimelineView(.animation) { timeline in
                    let elapsedTime = Float(startTime.distance(to: timeline.date))
                    // Subtle oscillating offset based on time
                    let oscillation = sin(elapsedTime * 2.0) * 0.5 + 0.5
                    let currentIntensity = intensity * (0.5 + oscillation * 0.5)

                    content
                        .drawingGroup()
                        .visualEffect { view, proxy in
                            view.layerEffect(
                                ShaderLibrary.colorPlanes(
                                    .float2(currentIntensity, currentIntensity * 0.7)
                                ),
                                maxSampleOffset: CGSize(width: 20, height: 20)
                            )
                        }
                }
            } else {
                content
                    .drawingGroup()
                    .visualEffect { view, _ in
                        view.layerEffect(
                            ShaderLibrary.colorPlanes(
                                .float2(intensity, intensity * 0.7)
                            ),
                            maxSampleOffset: CGSize(width: 20, height: 20)
                        )
                    }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Applies a chromatic aberration effect to the view.
    ///
    /// - Parameters:
    ///   - active: Whether the effect is active. Defaults to `true`.
    ///   - intensity: How much to offset the color channels. Defaults to `3.0`.
    ///   - animated: Whether to animate the effect. Defaults to `true`.
    func chromaticAberration(
        active: Bool = true,
        intensity: Float = 3.0,
        animated: Bool = true
    ) -> some View {
        modifier(ChromaticAberrationEffect(
            isActive: active,
            intensity: intensity,
            animated: animated
        ))
    }
}
