import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Decodes frames out of an **exported `.mp4`** and measures them.
///
/// The M13 tests assert over the real encoded file, not over the composition that
/// produced it (§5 S2): a purely structural check — right track count, right codec,
/// right duration — passes happily on an all-black export, which is exactly the
/// failure mode of the render path the plan rejected (§4A). So the video tests
/// decode actual pixels.
///
/// Frames are fetched with **zero** time tolerance in both directions, so the frame
/// inspected is the frame at the requested time and not a convenient neighbour.
enum VideoFrameProbe {
    enum ProbeError: Error, CustomStringConvertible {
        case noFrame(seconds: Double)
        case noContext

        var description: String {
            switch self {
            case .noFrame(let seconds): "no decodable frame at \(seconds)s"
            case .noContext: "could not build the measuring bitmap context"
            }
        }
    }

    static func image(from url: URL, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ProbeError.noFrame(seconds: time.seconds))
                }
            }
        }
    }

    /// Mean relative luminance (0…1) of `image`, or of `rect` within it.
    ///
    /// `rect` is in the image's own top-left-origin pixel space — the same space
    /// `VideoFrameLayout` reports — so a layout rectangle can be passed straight in.
    static func meanBrightness(of image: CGImage, in rect: CGRect? = nil, grid: Int = 32) throws -> Double {
        let target = rect.flatMap { image.cropping(to: $0) } ?? image
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        return try pixels.withUnsafeMutableBytes { raw -> Double in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: grid,
                height: grid,
                bitsPerComponent: 8,
                bytesPerRow: grid * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw ProbeError.noContext }
            context.draw(target, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            let bytes = raw.bindMemory(to: UInt8.self)
            var total = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                total += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
            }
            return total / (255.0 * Double(grid * grid))
        }
    }

    /// The share of pixels in `rect` that are lit brightly enough to count as a
    /// *revealed* waveform bar — the reveal-coverage measure S2 asserts grows
    /// monotonically across the clip.
    static func brightCoverage(
        of image: CGImage,
        in rect: CGRect,
        threshold: Double = 0.30,
        grid: Int = 64
    ) throws -> Double {
        let target = image.cropping(to: rect) ?? image
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        return try pixels.withUnsafeMutableBytes { raw -> Double in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: grid,
                height: grid,
                bitsPerComponent: 8,
                bytesPerRow: grid * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw ProbeError.noContext }
            context.draw(target, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            let bytes = raw.bindMemory(to: UInt8.self)
            var lit = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let luma = (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
                if luma >= threshold { lit += 1 }
            }
            return Double(lit) / Double(grid * grid)
        }
    }
}
