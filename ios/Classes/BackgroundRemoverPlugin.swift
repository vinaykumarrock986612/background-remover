import Flutter
import CoreImage
import CoreImage.CIFilterBuiltins
import MLKitSegmentationCommon
import MLKitSegmentationSelfie
import MLKitVision
import UIKit

public class BackgroundRemoverPlugin: NSObject, FlutterPlugin {
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  // The Android implementation uses ML Kit's selfie segmentation model. Use
  // that same model on iOS instead of Vision's person-segmentation request:
  // the latter is not supported by some Simulator runtimes (E5RT).
  private let segmenter: Segmenter = {
    let options = SelfieSegmenterOptions()
    options.segmenterMode = .singleImage
    // A full-size mask has the same dimensions as the input image, so it can
    // be applied directly without introducing a mismatched crop or scale.
    options.shouldEnableRawSizeMask = false
    return Segmenter.segmenter(options: options)
  }()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "background_remover",
      binaryMessenger: registrar.messenger()
    )
    let instance = BackgroundRemoverPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "removeBackground" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard let args = call.arguments as? [String: Any],
          let flutterData = args["imageBytes"] as? FlutterStandardTypedData else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENT",
          message: "imageBytes argument missing or invalid",
          details: nil
        )
      )
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      do {
        let pngData = try self.removeBackground(from: flutterData.data)
        DispatchQueue.main.async {
          result(FlutterStandardTypedData(bytes: pngData))
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "PROCESSING_ERROR",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func removeBackground(from data: Data) throws -> Data {
    guard let sourceImage = UIImage(data: data) else {
      throw BackgroundRemoverError.failedToDecodeInput
    }

    let normalizedImage = sourceImage.fixOrientation()
    guard let cgImage = normalizedImage.cgImage else {
      throw BackgroundRemoverError.failedToCreateCGImage
    }

    let visionImage = VisionImage(image: normalizedImage)
    visionImage.orientation = normalizedImage.imageOrientation
    let mask = try segmenter.results(in: visionImage)

    let inputImage = CIImage(cgImage: cgImage)
    let maskImage = CIImage(cvPixelBuffer: mask.buffer)
    return try blend(mask: maskImage, with: inputImage)
  }

  private func blend(mask: CIImage, with inputImage: CIImage) throws -> Data {
    let filter = CIFilter.blendWithMask()
    filter.inputImage = inputImage
    filter.maskImage = mask
    filter.backgroundImage = CIImage(color: .clear).cropped(to: inputImage.extent)

    guard let outputImage = filter.outputImage,
          let outputCGImage = ciContext.createCGImage(outputImage, from: inputImage.extent) else {
      throw BackgroundRemoverError.failedToRenderOutput
    }

    guard let pngData = UIImage(cgImage: outputCGImage).pngData() else {
      throw BackgroundRemoverError.failedToEncodeOutput
    }
    return pngData
  }
}

private enum BackgroundRemoverError: LocalizedError {
  case failedToDecodeInput
  case failedToCreateCGImage
  case failedToRenderOutput
  case failedToEncodeOutput

  var errorDescription: String? {
    switch self {
    case .failedToDecodeInput:
      return "Failed to decode input image data"
    case .failedToCreateCGImage:
      return "Failed to obtain CGImage from input"
    case .failedToRenderOutput:
      return "Failed to render output image"
    case .failedToEncodeOutput:
      return "Failed to encode output as PNG"
    }
  }
}

private extension UIImage {
  func fixOrientation() -> UIImage {
    if imageOrientation == .up { return self }
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    draw(in: CGRect(origin: .zero, size: size))
    let normalized = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return normalized ?? self
  }
}
