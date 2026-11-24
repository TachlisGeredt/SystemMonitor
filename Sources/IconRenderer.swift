import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Pre-processed, Retina-ready (@2x) icon layers for zero-allocation 2 Hz blitting.
private struct PreparedIcon {
    let widthPx: Int
    let heightPx: Int
    let fillMinXPx: Int
    let fillWidthPx: Int
    let foregroundLight: CGImage
    let foregroundDark: CGImage
    let gradientFilled: CGImage
}

private enum MonochromeMode {
    /// Line-art PNGs (RAM, Thermal): dark ink becomes monochrome foreground; white interiors stay transparent.
    case darkInkOnWhite
    /// Multi-tone PNGs (CPU): corner flood-fill removes outer white; all remaining opaque shapes (border, pins, text) become monochrome foreground.
    case allOpaqueForeground
}

private struct RenderKey: Equatable {
    let cpuFillPx: Int
    let ramFillPx: Int
    let isThrottling: Bool
    let showCPU: Bool
    let showRAM: Bool
    let isDarkMode: Bool
}

/// Ultra-lightweight menu bar icon compositor.
/// Pre-bakes monochrome foregrounds and masked green→yellow→red gradients once at startup,
/// then performs at most 2 CoreGraphics blits per visible icon only when quantized fill pixels change.
final class IconRenderer {
    private static let scale: CGFloat = 2.0
    private static let canvasHeightPx: Int = 36   // 18 pt @2x
    private static let iconGapPx: Int = 10        // 5 pt @2x

    private let cpuIcon: PreparedIcon?
    private let thermalIcon: PreparedIcon?
    private let ramIcon: PreparedIcon?

    private var scratchContext: CGContext?
    private var scratchWidthPx: Int = 0
    private var lastKey: RenderKey?

    init(resourcesDirectoryURL: URL) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        self.cpuIcon = IconRenderer.prepareIcon(
            url: resourcesDirectoryURL.appendingPathComponent("cpu.png"),
            targetWidthPx: 36,
            targetHeightPx: 36,
            canvasHeightPx: Self.canvasHeightPx,
            mode: .allOpaqueForeground,
            colorSpace: colorSpace
        )
        self.thermalIcon = IconRenderer.prepareIcon(
            url: resourcesDirectoryURL.appendingPathComponent("thermal.png"),
            targetWidthPx: 36,
            targetHeightPx: 36,
            canvasHeightPx: Self.canvasHeightPx,
            mode: .darkInkOnWhite,
            colorSpace: colorSpace
        )
        self.ramIcon = IconRenderer.prepareIcon(
            url: resourcesDirectoryURL.appendingPathComponent("ram.png"),
            targetWidthPx: 56,
            targetHeightPx: 28,
            canvasHeightPx: Self.canvasHeightPx,
            mode: .darkInkOnWhite,
            colorSpace: colorSpace
        )
    }

    func invalidateCache() {
        lastKey = nil
    }

    /// Returns a newly rendered `NSImage` if visual state changed, or `nil` if the previous image is still exact.
    func renderIfNeeded(
        cpuUsage: Double,
        ramUsage: Double,
        isThrottling: Bool,
        showCPU: Bool,
        showRAM: Bool,
        isDarkMode: Bool
    ) -> NSImage? {
        guard showCPU || showRAM else {
            lastKey = nil
            return nil
        }

        let activeCPU = isThrottling ? (thermalIcon ?? cpuIcon) : cpuIcon
        let clampedCPU = min(1.0, max(0.0, cpuUsage))
        let clampedRAM = min(1.0, max(0.0, ramUsage))

        let cpuFillPx = (showCPU && activeCPU != nil)
            ? Int((clampedCPU * Double(activeCPU!.fillWidthPx)).rounded())
            : -1
        let ramFillPx = (showRAM && ramIcon != nil)
            ? Int((clampedRAM * Double(ramIcon!.fillWidthPx)).rounded())
            : -1

        let key = RenderKey(
            cpuFillPx: cpuFillPx,
            ramFillPx: ramFillPx,
            isThrottling: isThrottling,
            showCPU: showCPU,
            showRAM: showRAM,
            isDarkMode: isDarkMode
        )

        if key == lastKey {
            return nil
        }
        lastKey = key

        var totalWidthPx = 0
        if showCPU, let c = activeCPU {
            totalWidthPx += c.widthPx
        }
        if showRAM, let r = ramIcon {
            if totalWidthPx > 0 { totalWidthPx += Self.iconGapPx }
            totalWidthPx += r.widthPx
        }
        guard totalWidthPx > 0 else { return nil }

        guard let ctx = ensureScratchContext(widthPx: totalWidthPx, heightPx: Self.canvasHeightPx) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: totalWidthPx, height: Self.canvasHeightPx))

        var cursorX = 0
        if showCPU, let c = activeCPU {
            draw(icon: c, atX: cursorX, fillPx: cpuFillPx, isDarkMode: isDarkMode, into: ctx)
            cursorX += c.widthPx + Self.iconGapPx
        }
        if showRAM, let r = ramIcon {
            draw(icon: r, atX: cursorX, fillPx: ramFillPx, isDarkMode: isDarkMode, into: ctx)
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let pointSize = NSSize(
            width: CGFloat(totalWidthPx) / Self.scale,
            height: CGFloat(Self.canvasHeightPx) / Self.scale
        )
        let image = NSImage(cgImage: cgImage, size: pointSize)
        image.isTemplate = false
        return image
    }

    private func draw(icon: PreparedIcon, atX x: Int, fillPx: Int, isDarkMode: Bool, into ctx: CGContext) {
        let rect = CGRect(x: x, y: 0, width: icon.widthPx, height: icon.heightPx)

        if fillPx > 0 {
            ctx.saveGState()
            let clipRect = CGRect(
                x: x + icon.fillMinXPx,
                y: 0,
                width: min(fillPx, icon.fillWidthPx),
                height: icon.heightPx
            )
            ctx.clip(to: clipRect)
            ctx.draw(icon.gradientFilled, in: rect)
            ctx.restoreGState()
        }

        let fg = isDarkMode ? icon.foregroundDark : icon.foregroundLight
        ctx.draw(fg, in: rect)
    }

    private func ensureScratchContext(widthPx: Int, heightPx: Int) -> CGContext? {
        if let existing = scratchContext, scratchWidthPx == widthPx {
            return existing
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: widthPx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        scratchContext = ctx
        scratchWidthPx = widthPx
        return ctx
    }

    // MARK: - One-Time Asset Preprocessing

    private static func prepareIcon(
        url: URL,
        targetWidthPx: Int,
        targetHeightPx: Int,
        canvasHeightPx: Int,
        mode: MonochromeMode,
        colorSpace: CGColorSpace
    ) -> PreparedIcon? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        // Read raw RGBA8 pixels (premultipliedLast).
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let readCtx = CGContext(
            data: &raw,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        readCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 1. Flood-fill exterior opaque white pixels starting from image edges.
        var isExterior = [Bool](repeating: false, count: w * h)
        var queue = [Int]()
        queue.reserveCapacity(w * 2 + h * 2)

        func isNearWhiteOpaque(_ idx: Int) -> Bool {
            let o = idx * 4
            return raw[o + 3] >= 240 && raw[o] >= 235 && raw[o + 1] >= 235 && raw[o + 2] >= 235
        }

        for x in 0..<w {
            let top = x
            let bot = (h - 1) * w + x
            if isNearWhiteOpaque(top) && !isExterior[top] { isExterior[top] = true; queue.append(top) }
            if isNearWhiteOpaque(bot) && !isExterior[bot] { isExterior[bot] = true; queue.append(bot) }
        }
        for y in 0..<h {
            let left = y * w
            let right = y * w + (w - 1)
            if isNearWhiteOpaque(left) && !isExterior[left] { isExterior[left] = true; queue.append(left) }
            if isNearWhiteOpaque(right) && !isExterior[right] { isExterior[right] = true; queue.append(right) }
        }

        var head = 0
        while head < queue.count {
            let idx = queue[head]
            head += 1
            let x = idx % w
            let y = idx / w

            if x > 0 {
                let n = idx - 1
                if !isExterior[n] && isNearWhiteOpaque(n) { isExterior[n] = true; queue.append(n) }
            }
            if x + 1 < w {
                let n = idx + 1
                if !isExterior[n] && isNearWhiteOpaque(n) { isExterior[n] = true; queue.append(n) }
            }
            if y > 0 {
                let n = idx - w
                if !isExterior[n] && isNearWhiteOpaque(n) { isExterior[n] = true; queue.append(n) }
            }
            if y + 1 < h {
                let n = idx + w
                if !isExterior[n] && isNearWhiteOpaque(n) { isExterior[n] = true; queue.append(n) }
            }
        }

        // 2. Build full-resolution foreground alpha buffer & interior fill mask buffer,
        //    and find the tight content bounding box.
        var fgBuffer = [UInt8](repeating: 0, count: w * h * 4)
        var maskBuffer = [UInt8](repeating: 0, count: w * h * 4)

        var minX = w
        var maxX = 0
        var minY = h
        var maxY = 0

        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                let o = idx * 4
                let r = Int(raw[o])
                let g = Int(raw[o + 1])
                let b = Int(raw[o + 2])
                let a = Int(raw[o + 3])

                // Interior fillable region: literally the transparent pixels of the original PNG.
                let fillA = 255 - a
                if fillA > 0 {
                    maskBuffer[o] = UInt8(fillA)
                    maskBuffer[o + 1] = UInt8(fillA)
                    maskBuffer[o + 2] = UInt8(fillA)
                    maskBuffer[o + 3] = UInt8(fillA)
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }

                if !isExterior[idx] && a > 0 {
                    // Un-premultiply RGB to measure true luminance.
                    let ur = min(255, (r * 255) / a)
                    let ug = min(255, (g * 255) / a)
                    let ub = min(255, (b * 255) / a)
                    let luma = (299 * ur + 587 * ug + 114 * ub) / 1000

                    let fgA: Int
                    switch mode {
                    case .darkInkOnWhite:
                        // Dark ink lines become solid foreground; white hollows become transparent.
                        let inkStrength = max(0, min(255, ((245 - luma) * 255) / 200))
                        fgA = (a * inkStrength) / 255
                    case .allOpaqueForeground:
                        // Softly feather any near-white fringe pixels right against the exterior.
                        let isNearWhite = (ur >= 242 && ug >= 242 && ub >= 242)
                        fgA = isNearWhite ? 0 : a
                    }

                    if fgA > 0 {
                        // Store as white premultiplied (we'll tint to pure black or pure white below).
                        fgBuffer[o] = UInt8(fgA)
                        fgBuffer[o + 1] = UInt8(fgA)
                        fgBuffer[o + 2] = UInt8(fgA)
                        fgBuffer[o + 3] = UInt8(fgA)
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        guard let fullFgImage = makeCGImage(from: &fgBuffer, width: w, height: h, colorSpace: colorSpace),
              let fullMaskImage = makeCGImage(from: &maskBuffer, width: w, height: h, colorSpace: colorSpace) else {
            return nil
        }

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let croppedFg = fullFgImage.cropping(to: cropRect),
              let croppedMask = fullMaskImage.cropping(to: cropRect) else {
            return nil
        }

        // Vertically center the icon inside canvasHeightPx.
        let yOffset = (canvasHeightPx - targetHeightPx) / 2
        let drawRect = CGRect(x: 0, y: yOffset, width: targetWidthPx, height: targetHeightPx)

        // 3. Downscale foreground once into Light (pure black) and Dark (pure white) CGImages.
        guard let fgDark = renderTinted(
                croppedFg,
                tint: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                width: targetWidthPx,
                height: canvasHeightPx,
                drawRect: drawRect,
                colorSpace: colorSpace
              ),
              let fgLight = renderTinted(
                croppedFg,
                tint: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                width: targetWidthPx,
                height: canvasHeightPx,
                drawRect: drawRect,
                colorSpace: colorSpace
              ) else {
            return nil
        }

        // 4. Downscale the interior fill mask and measure exact horizontal bounds [fillMinXPx, fillMaxXPx].
        var scaledMaskBytes = [UInt8](repeating: 0, count: targetWidthPx * canvasHeightPx * 4)
        guard let maskCtx = CGContext(
            data: &scaledMaskBytes,
            width: targetWidthPx,
            height: canvasHeightPx,
            bitsPerComponent: 8,
            bytesPerRow: targetWidthPx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        maskCtx.interpolationQuality = .high
        maskCtx.draw(croppedMask, in: drawRect)
        guard let scaledMaskImage = maskCtx.makeImage() else { return nil }

        var fillMinX = targetWidthPx
        var fillMaxX = 0
        for y in 0..<canvasHeightPx {
            for x in 0..<targetWidthPx {
                let a = scaledMaskBytes[(y * targetWidthPx + x) * 4 + 3]
                if a > 12 {
                    if x < fillMinX { fillMinX = x }
                    if x > fillMaxX { fillMaxX = x }
                }
            }
        }
        if fillMaxX < fillMinX {
            fillMinX = 0
            fillMaxX = targetWidthPx - 1
        }
        let fillWidthPx = max(1, fillMaxX - fillMinX + 1)

        // 5. Pre-render the full green → yellow → red horizontal gradient masked by scaledMaskImage.
        guard let gradCtx = CGContext(
            data: nil,
            width: targetWidthPx,
            height: canvasHeightPx,
            bitsPerComponent: 8,
            bytesPerRow: targetWidthPx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let colors = [
            CGColor(red: 0.18, green: 0.82, blue: 0.25, alpha: 1.0), // Green
            CGColor(red: 1.00, green: 0.85, blue: 0.00, alpha: 1.0), // Yellow
            CGColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)  // Red
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.5, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            return nil
        }

        gradCtx.drawLinearGradient(
            gradient,
            start: CGPoint(x: CGFloat(fillMinX), y: 0),
            end: CGPoint(x: CGFloat(fillMaxX + 1), y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        gradCtx.setBlendMode(.destinationIn)
        gradCtx.draw(scaledMaskImage, in: CGRect(x: 0, y: 0, width: targetWidthPx, height: canvasHeightPx))

        guard let gradientFilled = gradCtx.makeImage() else { return nil }

        return PreparedIcon(
            widthPx: targetWidthPx,
            heightPx: canvasHeightPx,
            fillMinXPx: fillMinX,
            fillWidthPx: fillWidthPx,
            foregroundLight: fgLight,
            foregroundDark: fgDark,
            gradientFilled: gradientFilled
        )
    }

    private static func makeCGImage(
        from bytes: inout [UInt8],
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return bytes.withUnsafeMutableBytes { rawBuf -> CGImage? in
            guard let ctx = CGContext(
                data: rawBuf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }
            return ctx.makeImage()
        }
    }

    private static func renderTinted(
        _ source: CGImage,
        tint: CGColor,
        width: Int,
        height: Int,
        drawRect: CGRect,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: drawRect)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(tint)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
