#if os(iOS) && canImport(ARKit)
import ARKit
import AVFoundation
import CoreImage

enum RoomCaptureError: Error {
    case cameraUnavailable, cannotLockCamera
}

/// Follows a bounded set of planar texture patches through an already hazy scene.
@MainActor
final class RoomCapture {
    private struct Patch {
        let id: Int
        let corners: [SIMD3<Float>] // Top-left, top-right, bottom-right, bottom-left.
        let center: SIMD3<Float>
        let direction: SIMD3<Float>
        let signature: [Double]
        let lensPosition: Float
        var lastSeen: TimeInterval
    }

    private struct Settings {
        let values: [Double]
        init(_ camera: AVCaptureDevice) {
            let gains = camera.deviceWhiteBalanceGains
            values = [CMTimeGetSeconds(camera.exposureDuration), Double(camera.iso),
                      Double(gains.redGain), Double(gains.greenGain), Double(gains.blueGain)]
        }
        var isValid: Bool { values.allSatisfy { $0.isFinite && $0 > 0 } }
        func matches(_ other: Settings) -> Bool {
            isValid && other.isValid && zip(values, other.values).allSatisfy {
                abs($0 - $1) <= $0 * 0.01
            }
        }
    }

    private struct DepthView {
        let pixels: UnsafeMutableRawPointer
        let confidence: UnsafeMutableRawPointer
        let width: Int
        let height: Int
        let rowBytes: Int
        let confidenceRowBytes: Int
        let imageSize: CGSize

        func value(at point: CGPoint) -> Float? {
            guard point.x.isFinite, point.y.isFinite, imageSize.width > 0, imageSize.height > 0,
                  point.x >= 0, point.y >= 0, point.x < imageSize.width, point.y < imageSize.height else {
                return nil
            }
            let x = Int(point.x / imageSize.width * CGFloat(width))
            let y = Int(point.y / imageSize.height * CGFloat(height))
            guard x > 0, y > 0, x < width - 1, y < height - 1 else { return nil }
            var values: [Float] = []
            for row in (y - 1)...(y + 1) {
                for column in (x - 1)...(x + 1) {
                    let level = confidence.advanced(by: row * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)[column]
                    let value = pixels.advanced(by: row * rowBytes)
                        .assumingMemoryBound(to: Float.self)[column]
                    if level == UInt8(ARConfidenceLevel.high.rawValue),
                       value.isFinite, (0.3...5).contains(value) {
                        values.append(value)
                    }
                }
            }
            guard values.count >= 7 else { return nil }
            values.sort()
            let middle = values.count / 2
            return values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        }
    }

    private let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace])
    private var device: AVCaptureDevice?
    private var previousExposureMode: AVCaptureDevice.ExposureMode?
    private var previousWhiteBalanceMode: AVCaptureDevice.WhiteBalanceMode?
    private var settings: Settings?
    private var settlingUntil: TimeInterval = 0
    private var patches: [Patch] = []
    private var nextID = 0

    /// Locks photometric controls without changing the host's focus mode.
    func start() throws {
        if device != nil {
            guard modesAreLocked else { throw RoomCaptureError.cannotLockCamera }
            return
        }
        guard let camera = ARConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            throw RoomCaptureError.cameraUnavailable
        }
        do { try camera.lockForConfiguration() }
        catch { throw RoomCaptureError.cannotLockCamera }
        defer { camera.unlockForConfiguration() }
        let changeExposure = camera.exposureMode != .locked && camera.exposureMode != .custom
        let changeWhiteBalance = camera.whiteBalanceMode != .locked
        guard (!changeExposure || camera.isExposureModeSupported(.locked)),
              (!changeWhiteBalance || camera.isWhiteBalanceModeSupported(.locked)) else {
            throw RoomCaptureError.cannotLockCamera
        }
        if changeExposure {
            previousExposureMode = camera.exposureMode
            camera.exposureMode = .locked
        }
        if changeWhiteBalance {
            previousWhiteBalanceMode = camera.whiteBalanceMode
            camera.whiteBalanceMode = .locked
        }
        device = camera
        reset()
    }

    func stop() {
        patches.removeAll()
        settings = nil
        guard let camera = device else { return }
        // Keep ownership if the hardware is temporarily unavailable so stop can retry.
        guard (try? camera.lockForConfiguration()) != nil else { return }
        defer { camera.unlockForConfiguration() }
        if let mode = previousExposureMode, camera.exposureMode == .locked {
            camera.exposureMode = mode
        }
        if let mode = previousWhiteBalanceMode, camera.whiteBalanceMode == .locked {
            camera.whiteBalanceMode = mode
        }
        previousExposureMode = nil
        previousWhiteBalanceMode = nil
        device = nil
    }

    func reset() {
        patches.removeAll()
        settings = nil
        settlingUntil = ProcessInfo.processInfo.systemUptime + 0.15
    }

    private var modesAreLocked: Bool {
        guard let camera = device else { return false }
        return (camera.exposureMode == .locked || camera.exposureMode == .custom)
            && camera.whiteBalanceMode == .locked
    }

    /// nil invalidates photometric history; [] means temporarily no usable patch.
    func observations(frame: ARFrame) -> [HazeObservation]? {
        guard let camera = device, modesAreLocked,
              frame.timestamp >= settlingUntil,
              !camera.isAdjustingExposure, !camera.isAdjustingWhiteBalance else { return nil }
        let currentSettings = Settings(camera)
        guard currentSettings.isValid else { return nil }
        if let settings {
            guard settings.matches(currentSettings) else { return nil }
        } else {
            settings = currentSettings
        }
        // Keep matching surfaces; the estimator expires old measurements separately.
        patches.removeAll { frame.timestamp - $0.lastSeen > 1.5 }
        guard !camera.isAdjustingFocus else { return [] }
        guard camera.lensPosition.isFinite,
              let data = frame.sceneDepth, let confidence = data.confidenceMap else { return nil }
        // A materially different focus setting starts a new patch history, not a haze reading.
        patches.removeAll { abs(camera.lensPosition - $0.lensPosition) > 0.03 }
        let map = data.depthMap
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard width > 2, height > 2,
              CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(map),
              let levels = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let depth = DepthView(pixels: pixels, confidence: levels, width: width, height: height,
                              rowBytes: CVPixelBufferGetBytesPerRow(map),
                              confidenceRowBytes: CVPixelBufferGetBytesPerRow(confidence),
                              imageSize: frame.camera.imageResolution)
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let cameraOrigin = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                       frame.camera.transform.columns.3.y,
                                       frame.camera.transform.columns.3.z)
        let inverse = frame.camera.transform.inverse
        var observations: [HazeObservation] = []
        for index in patches.indices {
            let patch = patches[index]
            let delta = cameraOrigin - patch.center
            let distance = simd_length(delta)
            guard distance > 0,
                  abs(camera.lensPosition - patch.lensPosition) <= 0.03,
                  simd_dot(delta / distance, patch.direction) >= cos(.pi / 9),
                  let points = visiblePoints(patch: patch, frame: frame, inverse: inverse, depth: depth),
                  let profile = profile(image: image, points: points),
                  correlation(patch.signature, profile.signature) >= 0.94 else { continue }
            patches[index].lastSeen = frame.timestamp
            observations.append(HazeObservation(patchID: patch.id, contrast: profile.contrast,
                                                distance: Double(distance), timestamp: frame.timestamp))
        }

        // New patches only supply observations already in haze; none is labelled clear air.
        for y in [0.28, 0.5, 0.72] {
            for x in [0.25, 0.5, 0.75] where patches.count < 8 {
                guard let result = seed(x: x, y: y, frame: frame, depth: depth,
                                        image: image, cameraOrigin: cameraOrigin,
                                        lensPosition: camera.lensPosition) else { continue }
                patches.append(result.patch)
                observations.append(result.observation)
                nextID += 1
            }
        }
        return observations
    }

    private func seed(x: Double, y: Double, frame: ARFrame, depth: DepthView, image: CIImage,
                      cameraOrigin: SIMD3<Float>, lensPosition: Float) -> (patch: Patch, observation: HazeObservation)? {
        let size = frame.camera.imageResolution
        let halfSide = min(size.width, size.height) * 0.06
        let center = CGPoint(x: size.width * x, y: size.height * y)
        let points = [CGPoint(x: center.x - halfSide, y: center.y - halfSide),
                      CGPoint(x: center.x + halfSide, y: center.y - halfSide),
                      CGPoint(x: center.x + halfSide, y: center.y + halfSide),
                      CGPoint(x: center.x - halfSide, y: center.y + halfSide)]
        var corners: [SIMD3<Float>] = []
        for point in points {
            guard let z = depth.value(at: point) else { return nil }
            corners.append(worldPoint(point, depth: z, camera: frame.camera))
        }
        let worldCenter = corners.reduce(SIMD3<Float>(repeating: 0), +) / 4
        let radius = corners.map { simd_distance($0, worldCenter) }.max() ?? 0
        guard patches.allSatisfy({ existing in
            let otherRadius = existing.corners.map { simd_distance($0, existing.center) }.max() ?? 0
            return simd_distance(existing.center, worldCenter) >= max(0.25, radius + otherRadius)
        }),
              let centerDepth = depth.value(at: center) else { return nil }
        let normal = simd_normalize(simd_cross(corners[1] - corners[0], corners[3] - corners[0]))
        let direction = simd_normalize(cameraOrigin - worldCenter)
        guard normal.x.isFinite, abs(simd_dot(normal, direction)) >= 0.8,
              abs(simd_dot(corners[2] - corners[0], normal)) <= 0.025,
              simd_distance(worldPoint(center, depth: centerDepth, camera: frame.camera), worldCenter) <= 0.04,
              let profile = profile(image: image, points: points) else { return nil }
        let patch = Patch(id: nextID, corners: corners, center: worldCenter, direction: direction,
                          signature: profile.signature, lensPosition: lensPosition,
                          lastSeen: frame.timestamp)
        return (patch, HazeObservation(patchID: nextID, contrast: profile.contrast,
                                      distance: Double(simd_distance(cameraOrigin, worldCenter)),
                                      timestamp: frame.timestamp))
    }

    private func worldPoint(_ point: CGPoint, depth: Float, camera: ARCamera) -> SIMD3<Float> {
        let k = camera.intrinsics
        let local = SIMD4<Float>((Float(point.x) - k[2].x) * depth / k[0].x,
                                 -(Float(point.y) - k[2].y) * depth / k[1].y, -depth, 1)
        let world = camera.transform * local
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    private func visiblePoints(patch: Patch, frame: ARFrame, inverse: simd_float4x4,
                               depth: DepthView) -> [CGPoint]? {
        let k = frame.camera.intrinsics
        var points: [CGPoint] = []
        for world in patch.corners + [patch.center] {
            let local = inverse * SIMD4<Float>(world, 1)
            let z = -local.z
            guard z.isFinite, z > 0 else { return nil }
            let point = CGPoint(x: CGFloat(k[0].x * local.x / z + k[2].x),
                                y: CGFloat(k[1].y * -local.y / z + k[2].y))
            guard let observed = depth.value(at: point), abs(observed - z) <= max(0.04, z * 0.025) else {
                return nil
            }
            points.append(point)
        }
        return Array(points.prefix(4))
    }

    private func profile(image: CIImage, points: [CGPoint]) -> (contrast: Double, signature: [Double])? {
        let extent = image.extent
        let safeBounds = CGRect(x: 8, y: 8, width: extent.width - 16, height: extent.height - 16)
        guard points.count == 4, points.allSatisfy({ safeBounds.contains($0) }) else { return nil }
        for i in 0..<4 {
            let a = points[i], b = points[(i + 1) % 4]
            guard hypot(a.x - b.x, a.y - b.y) >= 36 else { return nil }
        }
        func ciPoint(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.minX + p.x, y: extent.maxY - p.y)
        }
        let rectified = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": ciPoint(points[0]), "inputTopRight": ciPoint(points[1]),
            "inputBottomRight": ciPoint(points[2]), "inputBottomLeft": ciPoint(points[3])
        ])
        let rect = rectified.extent
        guard rect.width.isFinite, rect.height.isFinite, rect.width >= 36, rect.height >= 36 else { return nil }
        let scaled = rectified.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 6 / rect.height, kCIInputAspectRatioKey: rect.height / rect.width
            ])
        var rgba = [Float](repeating: 0, count: 6 * 6 * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: 6 * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: 6, height: 6), format: .RGBAf, colorSpace: linearSpace)
        }
        let values = stride(from: 0, to: rgba.count, by: 4).map {
            0.2126 * Double(rgba[$0]) + 0.7152 * Double(rgba[$0 + 1]) + 0.0722 * Double(rgba[$0 + 2])
        }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              values.filter({ $0 >= 0.98 }).count <= 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        let contrast = sqrt(centered.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        guard contrast >= 0.015 else { return nil }
        return (contrast, centered.map { $0 / contrast })
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / Double(a.count)
    }
}
#endif
