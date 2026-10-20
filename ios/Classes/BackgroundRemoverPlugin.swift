import Flutter
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import CoreML

public class BackgroundRemoverPlugin: NSObject, FlutterPlugin {
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "background_remover", binaryMessenger: registrar.messenger())
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
      result(FlutterError(code: "INVALID_ARGUMENT", message: "imageBytes argument missing or invalid", details: nil))
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
        #if targetEnvironment(simulator)
        if let fallbackData = self.generateSimulatorMockCutout(from: flutterData.data) {
          DispatchQueue.main.async {
            result(FlutterStandardTypedData(bytes: fallbackData))
          }
          return
        }
        #endif
        DispatchQueue.main.async {
          result(FlutterError(code: "PROCESSING_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func removeBackground(from data: Data) throws -> Data {
    guard let sourceImage = UIImage(data: data) else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to decode input image data"]
      )
    }

    let normalizedImage = sourceImage.fixOrientation()
    guard let cgImage = normalizedImage.cgImage else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to obtain CGImage from input"]
      )
    }

    let inputCIImage = CIImage(cgImage: cgImage)

    #if !targetEnvironment(simulator)
    // Attempt iOS 17+ foreground instance mask first on physical device
    if #available(iOS 17.0, *) {
      if let outputData = try? self.processWithForegroundInstanceMask(inputImage: inputCIImage) {
        return outputData
      }
    }
    #endif

    // Fallback to iOS 15+ person segmentation
    if #available(iOS 15.0, *) {
      return try self.processWithPersonSegmentation(inputImage: inputCIImage)
    } else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Background removal requires iOS 15.0 or later"]
      )
    }
  }

  @available(iOS 17.0, *)
  private func processWithForegroundInstanceMask(inputImage: CIImage) throws -> Data {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(ciImage: inputImage, options: [:])
    try handler.perform([request])

    guard let result = request.results?.first else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No foreground instance found"]
      )
    }

    let maskPixelBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
    let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)
    return try blend(mask: maskCIImage, with: inputImage)
  }

  @available(iOS 15.0, *)
  private func processWithPersonSegmentation(inputImage: CIImage) throws -> Data {
    let request = VNGeneratePersonSegmentationRequest()
    #if targetEnvironment(simulator)
    request.qualityLevel = .balanced
    if #available(iOS 17.0, *) {
      let devices = MLComputeDevice.allComputeDevices
      if let cpuDevice = devices.first(where: { "\($0)".contains("CPU") }) {
        request.setComputeDevice(cpuDevice, for: .main)
      }
    } else {
      request.usesCPUOnly = true
    }
    #else
    request.qualityLevel = .accurate
    #endif

    request.outputPixelFormat = kCVPixelFormatType_OneComponent8

    let handler = VNImageRequestHandler(ciImage: inputImage, options: [:])
    try handler.perform([request])

    guard let result = request.results?.first else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "No person found in image"]
      )
    }

    let maskCIImage = CIImage(cvPixelBuffer: result.pixelBuffer)
    let scaleX = inputImage.extent.width / maskCIImage.extent.width
    let scaleY = inputImage.extent.height / maskCIImage.extent.height
    let scaledMask = maskCIImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    return try blend(mask: scaledMask, with: inputImage)
  }

  private func blend(mask: CIImage, with inputImage: CIImage) throws -> Data {
    let filter = CIFilter.blendWithMask()
    filter.inputImage = inputImage
    filter.maskImage = mask
    filter.backgroundImage = CIImage(color: CIColor.clear).cropped(to: inputImage.extent)

    guard let outputCI = filter.outputImage else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "CoreImage blendWithMask filter failed"]
      )
    }

    guard let outputCG = ciContext.createCGImage(outputCI, from: inputImage.extent) else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Failed to render output CGImage"]
      )
    }

    let outputUI = UIImage(cgImage: outputCG)
    guard let pngData = outputUI.pngData() else {
      throw NSError(
        domain: "BackgroundRemover",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Failed to compress output as PNG"]
      )
    }

    return pngData
  }

  #if targetEnvironment(simulator)
  private func generateSimulatorMockCutout(from data: Data) -> Data? {
    guard let sourceImage = UIImage(data: data) else { return nil }
    let normalized = sourceImage.fixOrientation()
    let size = normalized.size
    UIGraphicsBeginImageContextWithOptions(size, false, normalized.scale)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }

    let rect = CGRect(
      x: size.width * 0.08,
      y: size.height * 0.05,
      width: size.width * 0.84,
      height: size.height * 0.90
    )
    context.addEllipse(in: rect)
    context.clip()
    normalized.draw(in: CGRect(origin: .zero, size: size))
    let cutout = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return cutout?.pngData()
  }
  #endif
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
