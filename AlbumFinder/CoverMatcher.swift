import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Compares album artwork from Apple Music with what was shown in the video, using Vision's
/// image fingerprints (feature prints): similar-looking images have a small distance.
nonisolated enum CoverMatcher {
    /// Fingerprints closer than this count as the same cover.
    static let threshold = 0.6

    /// Fingerprints of the places a cover might be in a frame: square-ish shapes, and the objects
    /// that stand out most (a cover pasted over the video usually does).
    static func coverPrints(in frame: CGImage) async throws -> [FeaturePrintObservation] {
        var rectangles = DetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.6
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.1
        rectangles.maximumObservations = 8
        let salient = try await GenerateObjectnessBasedSaliencyImageRequest().perform(on: frame).salientObjects

        let size = CGSize(width: frame.width, height: frame.height)
        var images: [CGImage] = []
        for region in try await rectangles.perform(on: frame) + salient {
            let box = region.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            // Covers are square, so also try the largest square in the middle of the region.
            let side = min(box.width, box.height)
            let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            for rect in [box, square] where rect.width >= 40 {
                if let crop = frame.cropping(to: rect) { images.append(crop) }
            }
        }
        // The detectors miss some smaller covers. Overlays are almost always centered horizontally,
        // so also try centered squares of a few sizes at a few heights.
        for scale in [0.4, 0.55, 0.7] {
            let side = size.width * scale
            for centerY in [0.35, 0.5, 0.65] {
                let rect = CGRect(x: (size.width - side) / 2, y: size.height * centerY - side / 2, width: side, height: side)
                if let crop = frame.cropping(to: rect) { images.append(crop) }
            }
        }
        var prints: [FeaturePrintObservation] = []
        for image in images {
            prints.append(try await GenerateImageFeaturePrintRequest().perform(on: image))
        }
        return prints
    }

    static func artworkPrint(_ url: URL) async throws -> FeaturePrintObservation? {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return try await GenerateImageFeaturePrintRequest().perform(on: image)
    }

    /// How close the artwork comes to anything shown in the video.
    static func distance(_ artwork: FeaturePrintObservation, to shown: [FeaturePrintObservation]) -> Double {
        shown.compactMap { try? artwork.distance(to: $0) }.min() ?? .infinity
    }

    static func wasShown(_ album: CatalogAlbum, in shown: [FeaturePrintObservation]) async throws -> Bool {
        guard let url = album.largeArtworkURL, let artwork = try await artworkPrint(url) else { return false }
        return distance(artwork, to: shown) < threshold
    }

    /// The candidate whose cover came closest to something shown, if under the threshold.
    static func pick(from candidates: [CatalogAlbum], shown: [FeaturePrintObservation]) async throws -> CatalogAlbum? {
        // One cover after another took 17 s for an artist with many releases, so fetch them all at once.
        let distances = await withTaskGroup(of: (index: Int, distance: Double)?.self) { group in
            for (index, album) in candidates.prefix(30).enumerated() {
                group.addTask {
                    guard let url = album.largeArtworkURL, let artwork = try? await artworkPrint(url) else { return nil }
                    return (index, distance(artwork, to: shown))
                }
            }
            var distances: [(index: Int, distance: Double)] = []
            for await result in group {
                if let result { distances.append(result) }
            }
            return distances
        }
        guard let best = distances.filter({ $0.distance < threshold }).min(by: { $0.distance < $1.distance }) else { return nil }
        return candidates[best.index]
    }
}
