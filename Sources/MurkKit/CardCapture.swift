#if os(iOS) && canImport(ARKit)
import ARKit
import AVFoundation
import CoreImage
import RealityKit

enum CardCaptureError: Error {
    case cameraUnavailable
    case cannotLockCamera
}

/// Samples the two halves of a fixed, centered reference card.
@MainActor
final class CardCapture {
    private let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace])
    private var device: AVCaptureDevice?
    private var previousExposureMode: AVCaptureDevice.ExposureMode?
    private var previousWhiteBalanceMode: AVCaptureDevice.WhiteBalanceMode?
    private var previousFocusMode: AVCaptureDevice.FocusMode?
    private var lockedSettings: Settings?

    private struct Settings {
        let duration: Double
        let iso: Double
        let gains: [Double]
        let lensPosition: Double

        init(_ device: AVCaptureDevice) {
            duration = CMTimeGetSeconds(device.exposureDuration)
            iso = Double(device.iso)
            let wb = device.deviceWhiteBalanceGains
            gains = [Double(wb.redGain), Double(wb.greenGain), Double(wb.blueGain)]
            lensPosition = Double(device.lensPosition)
        }

        var values: [Double] { [duration, iso] + gains }
        var isValid: Bool {
            values.allSatisfy { $0.isFinite && $0 > 0 }
                && lensPosition.isFinite && (0...1).contains(lensPosition)
        }
    }

    /// Keeps the host's original modes until this instance releases the camera.
    func lockCamera() throws {
        if device != nil {
            guard modesAreLocked else { throw CardCaptureError.cannotLockCamera }
            return
        }
        guard let camera = ARConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            throw CardCaptureError.cameraUnavailable
        }
        do {
            try camera.lockForConfiguration()
        } catch {
            throw CardCaptureError.cannotLockCamera
        }
        defer { camera.unlockForConfiguration() }

        let changeExposure = camera.exposureMode != .locked && camera.exposureMode != .custom
        let changeWhiteBalance = camera.whiteBalanceMode != .locked
        let changeFocus = camera.focusMode != .locked
        guard (!changeExposure || camera.isExposureModeSupported(.locked)),
              (!changeWhiteBalance || camera.isWhiteBalanceModeSupported(.locked)),
              (!changeFocus || camera.isFocusModeSupported(.locked)) else {
            throw CardCaptureError.cannotLockCamera
        }
        if changeExposure {
            previousExposureMode = camera.exposureMode
            camera.exposureMode = .locked
        }
        if changeWhiteBalance {
            previousWhiteBalanceMode = camera.whiteBalanceMode
            camera.whiteBalanceMode = .locked
        }
        if changeFocus {
            previousFocusMode = camera.focusMode
            camera.focusMode = .locked
        }
        device = camera
    }

    func restoreCamera() {
        guard let camera = device else { return }
        // Retain the saved modes if the device is temporarily unavailable, allowing a retry.
        guard (try? camera.lockForConfiguration()) != nil else { return }
        defer { camera.unlockForConfiguration() }
        if let mode = previousExposureMode, camera.exposureMode == .locked {
            camera.exposureMode = mode
        }
        if let mode = previousWhiteBalanceMode, camera.whiteBalanceMode == .locked {
            camera.whiteBalanceMode = mode
        }
        if let mode = previousFocusMode, camera.focusMode == .locked {
            camera.focusMode = mode
        }
        previousExposureMode = nil
        previousWhiteBalanceMode = nil
        previousFocusMode = nil
        lockedSettings = nil
        device = nil
    }

    private var modesAreLocked: Bool {
        guard let camera = device else { return false }
        return (camera.exposureMode == .locked || camera.exposureMode == .custom)
            && camera.whiteBalanceMode == .locked && camera.focusMode == .locked
    }

    var cameraIsStable: Bool {
        guard let camera = device else { return false }
        return modesAreLocked && !camera.isAdjustingExposure
            && !camera.isAdjustingWhiteBalance && !camera.isAdjustingFocus
    }

    func saveLockedSettings() {
        guard let camera = device, cameraIsStable else {
            lockedSettings = nil
            return
        }
        let settings = Settings(camera)
        lockedSettings = settings.isValid ? settings : nil
    }

    var settingsAreUnchanged: Bool {
        guard let camera = device, let saved = lockedSettings, cameraIsStable else { return false }
        let current = Settings(camera)
        return current.isValid && abs(saved.lensPosition - current.lensPosition) <= 0.01
            && zip(saved.values, current.values).allSatisfy {
            abs($0 - $1) <= $0 * 0.01
        }
    }

    func sample(frame: ARFrame, in view: ARView) -> ContrastSample? {
        guard let orientation = view.window?.windowScene?.interfaceOrientation,
              orientation != .unknown,
              view.bounds.width > 0, view.bounds.height > 0,
              let depth = frame.sceneDepth else { return nil }

        let imageTransform = frame.displayTransform(
            for: orientation, viewportSize: view.bounds.size
        ).inverted()
        let darkRect = CGRect(x: 0.34, y: 0.44, width: 0.12, height: 0.12)
            .applying(imageTransform)
        let lightRect = CGRect(x: 0.54, y: 0.44, width: 0.12, height: 0.12)
            .applying(imageTransform)
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard unitRect.contains(darkRect), unitRect.contains(lightRect),
              let darkDepth = medianDepth(in: darkRect, data: depth),
              let lightDepth = medianDepth(in: lightRect, data: depth) else { return nil }
        let distance = (darkDepth + lightDepth) / 2
        guard abs(darkDepth - lightDepth) <= max(0.05, distance * 0.05) else { return nil }

        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let dark = luminance(in: darkRect, image: image),
              let light = luminance(in: lightRect, image: image) else { return nil }
        return ContrastSample(darkLuminance: dark, lightLuminance: light, axialDepth: distance)
    }

    private func luminance(in normalizedRect: CGRect, image: CIImage) -> Double? {
        // ARKit image coordinates have a top-left origin; Core Image uses bottom-left.
        let extent = image.extent
        let rect = CGRect(
            x: extent.minX + normalizedRect.minX * extent.width,
            y: extent.minY + (1 - normalizedRect.maxY) * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        )
        let average = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect)
        ])
        var rgba = [Float](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(
                average, toBitmap: bytes.baseAddress!, rowBytes: 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf, colorSpace: linearSpace
            )
        }
        let value = 0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])
        return value.isFinite ? value : nil
    }

    private func medianDepth(in rect: CGRect, data: ARDepthData) -> Double? {
        let depth = data.depthMap
        guard let confidence = data.confidenceMap,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height,
              CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return nil }

        var values: [Double] = []
        for row in 0..<3 {
            for column in 0..<3 {
                let x = min(width - 1, Int((rect.minX + rect.width * (CGFloat(column) + 0.5) / 3) * CGFloat(width)))
                let y = min(height - 1, Int((rect.minY + rect.height * (CGFloat(row) + 0.5) / 3) * CGFloat(height)))
                let level = confidenceBase.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence))
                    .assumingMemoryBound(to: UInt8.self)[x]
                let value = depthBase.advanced(by: y * CVPixelBufferGetBytesPerRow(depth))
                    .assumingMemoryBound(to: Float.self)[x]
                if level == UInt8(ARConfidenceLevel.high.rawValue), value.isFinite, value > 0 {
                    values.append(Double(value))
                }
            }
        }
        guard values.count >= 7 else { return nil }
        values.sort()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }
}
#endif
