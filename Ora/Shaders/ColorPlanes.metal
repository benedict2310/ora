//
// ColorPlanes.metal
// Ora
//
// Chromatic aberration effect - separates RGB channels for a glitch-style effect.
// Adapted from Inferno (https://github.com/twostraws/Inferno) - MIT License
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// A shader that separates the RGB values for a pixel and offsets them to create
/// a glitch-style effect (chromatic aberration).
///
/// This works by reading different pixels than the original for both the red
/// and blue color components, offsetting them by the `offset` value
/// and a fixed multiplier.
///
/// - Parameter position: The user-space coordinate of the current pixel.
/// - Parameter layer: The SwiftUI layer we're reading from.
/// - Parameter offset: How much to offset colors by (x, y).
/// - Returns: The new pixel color.
[[ stitchable ]] half4 colorPlanes(float2 position, SwiftUI::Layer layer, float2 offset) {
    // Red value read from double the offset
    float2 red = position - (offset * 2.0);

    // Blue value read from the offset
    float2 blue = position - offset;

    // Read the green value from the actual position
    half4 color = layer.sample(position);

    // Use the red value from the offset location
    color.r = layer.sample(red).r;

    // Use the blue value from the offset location
    color.b = layer.sample(blue).b;

    // Return result, factoring in original alpha for smooth edges
    return color * color.a;
}
