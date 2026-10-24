import Accelerate
import CoreGraphics
import Foundation

/// Finds where a TV image came from in an original photo.
///
/// Every copy on the TV is a scaled, axis-aligned 16:9 crop of an original, so recognition is template matching: slide the TV thumbnail, at each plausible crop size, over a
/// small grayscale copy of the original and score each position with normalized cross-correlation (NCC). NCC ignores
/// brightness and contrast differences, so JPEG recompression and resizing barely move it. Coarse search at 64 px,
/// then refine at 256 px around the best hit. On Matt's photo: a real match scored 0.99 (crop recovered to within
/// 0.1%), unrelated images ≤ 0.6.
public enum SubImageMatcher {
    public struct Result: Sendable, Equatable {
        public let choice: LibraryPhoto.Choice
        /// NCC, 1.0 = identical.
        public let score: Double
    }

    /// Scores at or above this count as "the same photo".
    public static let threshold = 0.9
    /// Narrowest crop searched, as a share of the original's width.
    public static let minimumCropWidth = 0.25

    /// The crop of `original` that produced `tvImage`, or nil if it isn't from this photo.
    /// `original` must have its EXIF orientation applied.
    public static func match(original: CGImage, tvImage: CGImage) -> Result? {
        if let crop = matchCrop(original: original, tvImage: tvImage), crop.score >= threshold { return crop }
        return nil
    }

    // MARK: Crop

    static func matchCrop(original: CGImage, tvImage: CGImage) -> Result? {
        let aspect = Double(original.width) / Double(original.height)
        // Coarse: 64 px wide original, every crop width from 25% to 100% in 3% steps, every position.
        let coarseW = 64
        guard var coarse = Gray(original, width: coarseW, height: max(Int((Double(coarseW) / aspect).rounded()), 1)) else { return nil }
        coarse.blur()
        var scales = Array(stride(from: minimumCropWidth, through: 1.0, by: 0.03))
        if scales.last != 1.0 { scales.append(1.0) }
        guard let hit = search(coarse, tvImage, scales: scales, region: nil) else { return nil }

        // Fine: 256 px wide, scales within ±3% of the hit, positions within ±8 px of it.
        let k = 4
        let fineW = coarseW * k
        guard var fine = Gray(original, width: fineW, height: max(Int((Double(fineW) / aspect).rounded()), 1)) else { return nil }
        fine.blur()
        let fineScales = stride(from: hit.scale - 0.03, through: hit.scale + 0.03, by: 0.01).filter { $0 > 0.05 && $0 <= 1.0001 }
        let region = (x: (hit.x * k - 8)...(hit.x * k + 8), y: (hit.y * k - 8)...(hit.y * k + 8))
        let best = search(fine, tvImage, scales: fineScales, region: region) ?? hit.rescaled(by: k)
        let rect = NormalizedRect(x: Double(best.x) / Double(fine.width), y: Double(best.y) / Double(fine.height),
                                  width: Double(best.w) / Double(fine.width), height: Double(best.h) / Double(fine.height))
        return Result(choice: .crop(rect.clamped()), score: best.score)
    }

    struct Hit {
        var score: Double
        var scale: Double
        var x: Int, y: Int, w: Int, h: Int

        func rescaled(by k: Int) -> Hit { Hit(score: score, scale: scale, x: x * k, y: y * k, w: w * k, h: h * k) }
    }

    /// Best NCC over `scales` (template width as a share of the image width) and positions.
    static func search(_ image: Gray, _ tv: CGImage, scales: [Double],
                       region: (x: ClosedRange<Int>, y: ClosedRange<Int>)?) -> Hit? {
        let integral = Integral(image)
        var best: Hit?
        for scale in scales {
            let tw = Int((Double(image.width) * scale).rounded())
            // The copy's own shape: 16:9 for TV copies, but saved copies can be anything (e.g. 4:3).
            let th = Int((Double(tw) * Double(tv.height) / Double(tv.width)).rounded())
            guard tw >= 8, th >= 4, tw <= image.width, th <= image.height,
                  var template = Gray(tv, width: tw, height: th) else { continue }
            template.blur()
            guard template.normalize() else { continue }
            let xs = clamp(region?.x ?? 0...(image.width - tw), 0, image.width - tw)
            let ys = clamp(region?.y ?? 0...(image.height - th), 0, image.height - th)
            guard let xs, let ys else { continue }
            let n = Double(tw * th)
            for y in ys {
                for x in xs {
                    let (sum, sumSq) = integral.sums(x: x, y: y, w: tw, h: th)
                    let variance = sumSq / n - (sum / n) * (sum / n)
                    guard variance > 1e-6 else { continue }
                    // Template is zero-mean, unit-variance: NCC = Σ(P·T) / (n·σP).
                    var dot: Float = 0
                    image.pixels.withUnsafeBufferPointer { p in
                        template.pixels.withUnsafeBufferPointer { t in
                            for row in 0..<th {
                                var d: Float = 0
                                vDSP_dotpr(p.baseAddress! + (y + row) * image.width + x, 1,
                                           t.baseAddress! + row * tw, 1, &d, vDSP_Length(tw))
                                dot += d
                            }
                        }
                    }
                    let score = Double(dot) / (n * variance.squareRoot())
                    if score > (best?.score ?? -2) { best = Hit(score: score, scale: scale, x: x, y: y, w: tw, h: th) }
                }
            }
        }
        return best
    }

    private static func clamp(_ r: ClosedRange<Int>, _ lo: Int, _ hi: Int) -> ClosedRange<Int>? {
        let a = max(r.lowerBound, lo), b = min(r.upperBound, hi)
        return a <= b ? a...b : nil
    }
}

/// An 8-bit grayscale rendering of an image at a given size, as floats.
struct Gray {
    let width: Int
    let height: Int
    var pixels: [Float]

    init?(_ image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.width = width
        self.height = height
        pixels = [Float](repeating: 0, count: bytes.count)
        vDSP_vfltu8(bytes, 1, &pixels, 1, vDSP_Length(bytes.count))
    }

    /// A light blur (≈ Gaussian, σ 1 px). Fine texture such as waves loses most of its correlation from a
    /// fraction-of-a-pixel misalignment after resizing; blurring both sides first makes NCC tolerant of that
    /// (Matt's beach photo: 0.91 → 0.99 for the true match).
    mutating func blur() {
        guard width >= 5, height >= 5 else { return }
        let k: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var tmp = pixels
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for i in -2...2 { acc += k[i + 2] * pixels[y * width + min(max(x + i, 0), width - 1)] }
                tmp[y * width + x] = acc
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for i in -2...2 { acc += k[i + 2] * tmp[min(max(y + i, 0), height - 1) * width + x] }
                pixels[y * width + x] = acc
            }
        }
    }

    /// Zero mean, unit variance. False for a flat image (nothing to match).
    mutating func normalize() -> Bool {
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(pixels, 1, &pixels, 1, &mean, &std, vDSP_Length(pixels.count))
        return std > 1e-3
    }
}

/// Summed-area tables for O(1) patch sums and sums of squares.
struct Integral {
    let w: Int
    var s: [Double]
    var s2: [Double]

    init(_ g: Gray) {
        w = g.width + 1
        s = [Double](repeating: 0, count: w * (g.height + 1))
        s2 = s
        for y in 0..<g.height {
            var row = 0.0, row2 = 0.0
            for x in 0..<g.width {
                let v = Double(g.pixels[y * g.width + x])
                row += v
                row2 += v * v
                s[(y + 1) * w + x + 1] = s[y * w + x + 1] + row
                s2[(y + 1) * w + x + 1] = s2[y * w + x + 1] + row2
            }
        }
    }

    func sums(x: Int, y: Int, w pw: Int, h ph: Int) -> (Double, Double) {
        let a = y * w + x, b = y * w + x + pw, c = (y + ph) * w + x, d = (y + ph) * w + x + pw
        return (s[d] - s[b] - s[c] + s[a], s2[d] - s2[b] - s2[c] + s2[a])
    }
}

extension NormalizedRect {
    /// Kept inside the unit square (search rounding can overshoot by a pixel).
    func clamped() -> NormalizedRect {
        let w = min(width, 1), h = min(height, 1)
        return NormalizedRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }
}
