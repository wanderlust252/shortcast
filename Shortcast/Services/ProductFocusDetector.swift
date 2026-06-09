import CoreGraphics
import CoreML
import Foundation
import Vision

/// Core ML object detector used by vertical reframing to follow products instead
/// of faces. The model is optional at runtime: without a bundled
/// `ProductDetector` model, detection simply returns nil and the reframer can
/// fall back to speaker tracking or blurred letterbox.
actor ProductFocusDetector {

    struct Detection: Sendable {
        let midX: CGFloat
        let confidence: Float
        let label: String
        let area: CGFloat
    }

    static let shared = ProductFocusDetector()
    nonisolated static var isModelBundled: Bool { modelURL() != nil }

    private let minimumConfidence: Float = 0.45
    private var visionModel: VNCoreMLModel?
    private var didTryLoading = false

    func detectProduct(in cgImage: CGImage) -> Detection? {
        let observations = detectProducts(in: cgImage)
        return observations.max { a, b in
            let aScore = Self.score(a)
            let bScore = Self.score(b)
            if aScore == bScore {
                return abs(a.midX - 0.5) > abs(b.midX - 0.5)
            }
            return aScore < bScore
        }
    }

    func detectProducts(in cgImage: CGImage) -> [Detection] {
        guard let model = loadModelIfNeeded() else { return [] }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        return request.results?.compactMap { observation -> Detection? in
            guard let object = observation as? VNRecognizedObjectObservation,
                  let label = object.labels.first else { return nil }
            let normalizedLabel = Self.normalize(label.identifier)
            guard label.confidence >= minimumConfidence,
                  Self.supportedProductLabels.contains(normalizedLabel) else { return nil }

            let box = object.boundingBox
            let area = box.width * box.height
            return Detection(
                midX: box.midX,
                confidence: label.confidence,
                label: normalizedLabel,
                area: area)
        } ?? []
    }

    private func loadModelIfNeeded() -> VNCoreMLModel? {
        if let visionModel { return visionModel }
        guard !didTryLoading else { return nil }
        didTryLoading = true

        guard let url = Self.modelURL(),
              let mlModel = try? MLModel(contentsOf: url),
              let model = try? VNCoreMLModel(for: mlModel)
        else { return nil }

        visionModel = model
        return model
    }

    nonisolated private static func modelURL() -> URL? {
        let bundle = Bundle.main
        if let compiled = bundle.url(forResource: "ProductDetector", withExtension: "mlmodelc") {
            return compiled
        }
        if let package = bundle.url(forResource: "ProductDetector", withExtension: "mlpackage") {
            return package
        }
        return bundle.url(forResource: "ProductDetector", withExtension: "mlmodel")
    }

    private static let supportedProductLabels: Set<String> = [
        // Open Images V7 labels that commonly map to products in creator,
        // review, commerce, and desk/setup videos.
        "adhesive tape", "alarm clock", "apple", "auto part", "axe",
        "backpack", "bagel", "ball", "bicycle", "bicycle helmet",
        "binoculars", "blender", "book", "boot", "bottle", "bowl", "box",
        "briefcase", "camera", "candle", "candy", "can opener",
        "cassette deck", "cello", "chainsaw", "chisel", "clock", "clothing",
        "coat", "cocktail shaker", "computer keyboard", "computer mouse",
        "cosmetics", "cupboard", "desk", "digital clock", "dishwasher",
        "dress", "drill (tool)", "drink", "earrings", "fashion accessory",
        "flowerpot", "food processor", "footwear", "frying pan", "glasses",
        "goggles", "guitar", "hair dryer", "handbag", "headphones", "helmet",
        "home appliance", "ipod", "jacket", "jeans", "kitchen appliance",
        "kitchen knife", "laptop", "light switch", "lipstick", "luggage and bags",
        "microphone", "microwave oven", "mobile phone", "mug", "musical instrument",
        "necklace", "office supplies", "oven", "pen", "pencil case", "perfume",
        "personal care", "printer", "remote control", "ring binder",
        "ruler", "sandal", "saucer", "scissors", "screwdriver", "shirt",
        "skirt", "soap dispenser", "sunglasses",
        "suitcase", "tablet computer", "telephone", "television", "tie",
        "toaster", "toothbrush", "tool", "tripod", "vase",
        "watch", "wine glass", "wrench"
    ]

    private static func normalize(_ label: String) -> String {
        label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(_ detection: Detection) -> Float {
        let areaBoost = min(Float(detection.area), 0.35)
        let centerPenalty = Float(abs(detection.midX - 0.5)) * 0.15
        return detection.confidence + areaBoost - centerPenalty
    }
}
