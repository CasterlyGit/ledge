import Foundation
import AppKit

/// AI-powered image analysis using Claude Vision API.
/// Tags images with content type, confidence, and extracted info.
final class ImageAnalyzer {
    static let shared = ImageAnalyzer()

    struct ImageTag: Codable {
        let url: URL
        let tags: [String]  // ["error", "code", "chart", etc.]
        let description: String  // brief AI summary
        let timestamp: Date
    }

    private var tagCache: [String: ImageTag] = [:]
    private let cacheKey = "LedgeImageTags"

    init() {
        loadCache()
    }

    /// Analyze an image (or return cached tag if available).
    /// Runs off-main; completion on main.
    func analyzeImage(_ item: ShelfItem, completion: @escaping (ImageTag?) -> Void) {
        let key = item.url.lastPathComponent
        if let cached = tagCache[key] { completion(cached); return }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = NSImage(contentsOf: item.url),
                  let tiff = img.tiffRepresentation else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Convert to base64 for API
            let base64 = tiff.base64EncodedString()
            self.callClaudeVision(imageBase64: base64, for: item) { tag in
                if let tag { self.cache(tag) }
                DispatchQueue.main.async { completion(tag) }
            }
        }
    }

    private func callClaudeVision(imageBase64: String, for item: ShelfItem,
                                  completion: @escaping (ImageTag?) -> Void) {
        // NOTE: This is a placeholder for Claude API integration.
        // In production, use the Anthropic SDK to send the image to Claude Vision.
        // For now, we'll use a simple heuristic based on filename.
        let filename = item.url.lastPathComponent.lowercased()
        var tags: [String] = []
        var desc = "Screenshot"

        if filename.contains("error") || filename.contains("fail") {
            tags = ["error", "debug"]; desc = "Error screen"
        } else if filename.contains("chart") || filename.contains("graph") {
            tags = ["chart", "data"]; desc = "Chart or graph"
        } else if filename.contains("code") || filename.contains("xcode") {
            tags = ["code", "editor"]; desc = "Code editor"
        } else if filename.contains("message") || filename.contains("chat") {
            tags = ["message", "communication"]; desc = "Message or chat"
        } else {
            tags = ["screenshot"]; desc = "General screenshot"
        }

        let tag = ImageTag(url: item.url, tags: tags, description: desc, timestamp: Date())
        completion(tag)
    }

    private func cache(_ tag: ImageTag) {
        let key = tag.url.lastPathComponent
        tagCache[key] = tag
        persistCache()
    }

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: ImageTag].self, from: data) {
            tagCache = decoded
        }
    }

    private func persistCache() {
        if let encoded = try? JSONEncoder().encode(tagCache) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }

    /// Get cached tag if available (synchronous).
    func cachedTag(for item: ShelfItem) -> ImageTag? {
        tagCache[item.url.lastPathComponent]
    }

    /// Search by tag (e.g., find all images tagged "error").
    func itemsWithTag(_ tag: String) -> [ShelfItem] {
        ShelfStore.shared.items.filter { item in
            tagCache[item.url.lastPathComponent]?.tags.contains(tag) == true
        }
    }
}
