import Foundation
import UIKit
import SwiftSignalKit
import Display
import Postbox
import TelegramCore
import MediaResources
import ImageBlur
import FastBlur
import TinyThumbnail
import PhotoResources
import LocalMediaResources
import TelegramPresentationData
import TelegramUIPreferences
import AppBundle
import Svg
import GradientBackground
import GZip

public func wallpaperDatas(account: Account, accountManager: AccountManager, fileReference: FileMediaReference? = nil, representations: [ImageRepresentationWithReference], alwaysShowThumbnailFirst: Bool = false, thumbnail: Bool = false, onlyFullSize: Bool = false, autoFetchFullSize: Bool = false, synchronousLoad: Bool = false) -> Signal<(Data?, Data?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(representations.map({ $0.representation })), let largestRepresentation = largestImageRepresentation(representations.map({ $0.representation })), let smallestIndex = representations.firstIndex(where: { $0.representation == smallestRepresentation }), let largestIndex = representations.firstIndex(where: { $0.representation == largestRepresentation }) {
        
        let maybeFullSize: Signal<MediaResourceData, NoError>
        if thumbnail, let file = fileReference?.media {
            maybeFullSize = combineLatest(accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false, attemptSynchronously: synchronousLoad),  account.postbox.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false, attemptSynchronously: synchronousLoad))
            |> mapToSignal { maybeSharedData, maybeData -> Signal<MediaResourceData, NoError> in
                if maybeSharedData.complete {
                    return .single(maybeSharedData)
                } else if maybeData.complete {
                    return .single(maybeData)
                } else {
                    return combineLatest(accountManager.mediaBox.resourceData(file.resource), account.postbox.mediaBox.resourceData(file.resource))
                    |> mapToSignal { maybeSharedData, maybeData -> Signal<MediaResourceData, NoError> in
                        if maybeSharedData.complete {
                            return accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: true)
                        }
                        else if maybeData.complete {
                            return account.postbox.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: true)
                        } else {
                            return .single(maybeData)
                        }
                    }
                }
            }
        } else {
            if thumbnail {
                maybeFullSize = combineLatest(accountManager.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false), account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false))
                |> mapToSignal { maybeSharedData, maybeData -> Signal<MediaResourceData, NoError> in
                    if maybeSharedData.complete {
                        return .single(maybeSharedData)
                    } else if maybeData.complete {
                        return .single(maybeData)
                    } else {
                        return account.postbox.mediaBox.resourceData(largestRepresentation.resource)
                    }
                }
            } else {
                maybeFullSize = combineLatest(accountManager.mediaBox.resourceData(largestRepresentation.resource), account.postbox.mediaBox.resourceData(largestRepresentation.resource))
                |> map { sharedData, data -> MediaResourceData in
                    if sharedData.complete && data.complete {
                        if sharedData.size > data.size {
                            return sharedData
                        } else {
                            return data
                        }
                    } else if sharedData.complete {
                        return sharedData
                    } else {
                        return data
                    }
                }
            }
        }
        let decodedThumbnailData = fileReference?.media.immediateThumbnailData.flatMap(decodeTinyThumbnail)
        
        let signal = maybeFullSize
        |> take(1)
        |> mapToSignal { maybeData -> Signal<(Data?, Data?, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                if alwaysShowThumbnailFirst, let decodedThumbnailData = decodedThumbnailData {
                    return .single((decodedThumbnailData, nil, false))
                    |> then(.complete() |> delay(0.05, queue: Queue.concurrentDefaultQueue()))
                    |> then(.single((nil, loadedData, true)))
                } else {
                    return .single((nil, loadedData, true))
                }
            } else {
                let fetchedThumbnail: Signal<FetchResourceSourceType, FetchResourceError>
                fetchedThumbnail = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: representations[smallestIndex].reference)
                
                let fetchedFullSize = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: representations[largestIndex].reference)
                
                let thumbnailData: Signal<Data?, NoError>

                thumbnailData = Signal<Data?, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)

                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                var fullSizeData: Signal<(Data?, Bool), NoError>
                if autoFetchFullSize {
                    fullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                        let fetchedFullSizeDisposable = fetchedFullSize.start()
                        
                        let fullSizeDisposable = account.postbox.mediaBox.resourceData(largestRepresentation.resource).start(next: { next in
                            subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                        
                        return ActionDisposable {
                            fetchedFullSizeDisposable.dispose()
                            fullSizeDisposable.dispose()
                        }
                    }
                } else {
                    fullSizeData = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
                    |> map { next -> (Data?, Bool) in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                    }
                }
                
                if thumbnail, let file = fileReference?.media {
                    let betterThumbnailData = account.postbox.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: true)
                    |> map { next -> (Data?, Bool) in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                    } |> filter { (data, _) -> Bool in
                        return data != nil
                    }
                    
                    return thumbnailData |> mapToSignal { thumbnailData in
                        return fullSizeData |> mapToSignal { (fullSizeData, complete) in
                            if complete {
                                return .single((thumbnailData, fullSizeData, complete))
                                |> then(
                                    betterThumbnailData |> map { (betterFullSizeData, complete) in
                                        return (thumbnailData, betterFullSizeData ?? fullSizeData, complete)
                                    })
                            } else {
                                return .single((thumbnailData, fullSizeData, complete))
                            }
                        }
                    }
                } else {
                    if onlyFullSize {
                        return fullSizeData |> map { (fullSizeData, complete) in
                            return (nil, fullSizeData, complete)
                        }
                    } else {
                        return thumbnailData |> mapToSignal { thumbnailData in
                            return fullSizeData |> map { (fullSizeData, complete) in
                                return (thumbnailData, fullSizeData, complete)
                            }
                        }
                    }
                }
            }
        } |> filter({ $0.0 != nil || $0.1 != nil })
        return signal
    } else {
        return .never()
    }
}

public func wallpaperImage(account: Account, accountManager: AccountManager, fileReference: FileMediaReference? = nil, representations: [ImageRepresentationWithReference], alwaysShowThumbnailFirst: Bool = false, thumbnail: Bool = false, onlyFullSize: Bool = false, autoFetchFullSize: Bool = false, blurred: Bool = false, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = wallpaperDatas(account: account, accountManager: accountManager, fileReference: fileReference, representations: representations, alwaysShowThumbnailFirst: alwaysShowThumbnailFirst, thumbnail: thumbnail, onlyFullSize: onlyFullSize, autoFetchFullSize: autoFetchFullSize, synchronousLoad: synchronousLoad)
    
    return signal
    |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            var imageOrientation: UIImage.Orientation = .up
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        imageOrientation = imageOrientationFromSource(imageSource)
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        imageOrientation = imageOrientationFromSource(imageSource)
                        fullSizeImage = image
                    }
                }
            }

            if blurred, let fullSizeImageValue = fullSizeImage {
                let thumbnailSize = CGSize(width: fullSizeImageValue.width, height: fullSizeImageValue.height)

                let initialThumbnailContextFittingSize = fittedSize.fitted(CGSize(width: 90.0, height: 90.0))

                let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.draw(fullSizeImageValue, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)

                var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                    thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                }

                if false, thumbnailContextFittingSize.width > thumbnailContextSize.width {
                    let additionalContextSize = thumbnailContextFittingSize
                    let additionalBlurContext = DrawingContext(size: additionalContextSize, scale: 1.0)
                    additionalBlurContext.withFlippedContext { c in
                        c.interpolationQuality = .default
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: additionalContextSize))
                        }
                    }
                    imageFastBlur(Int32(additionalContextSize.width), Int32(additionalContextSize.height), Int32(additionalBlurContext.bytesPerRow), additionalBlurContext.bytes)
                    fullSizeImage = additionalBlurContext.generateImage()?.cgImage
                } else {
                    fullSizeImage = thumbnailContext.generateImage()?.cgImage
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                
                let initialThumbnailContextFittingSize = fittedSize.fitted(CGSize(width: 90.0, height: 90.0))
                
                let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                    thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                }
                
                if false, thumbnailContextFittingSize.width > thumbnailContextSize.width {
                    let additionalContextSize = thumbnailContextFittingSize
                    let additionalBlurContext = DrawingContext(size: additionalContextSize, scale: 1.0)
                    additionalBlurContext.withFlippedContext { c in
                        c.interpolationQuality = .default
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: additionalContextSize))
                        }
                    }
                    imageFastBlur(Int32(additionalContextSize.width), Int32(additionalContextSize.height), Int32(additionalBlurContext.bytesPerRow), additionalBlurContext.bytes)
                    blurredThumbnailImage = additionalBlurContext.generateImage()
                } else {
                    blurredThumbnailImage = thumbnailContext.generateImage()
                }
            }
            
            if let blurredThumbnailImage = blurredThumbnailImage, fullSizeImage == nil {
                let context = DrawingContext(size: blurredThumbnailImage.size, scale: blurredThumbnailImage.scale, clear: true)
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)
                    if let cgImage = blurredThumbnailImage.cgImage {
                        c.interpolationQuality = .none
                        drawImage(context: c, image: cgImage, orientation: imageOrientation, in: CGRect(origin: CGPoint(), size: blurredThumbnailImage.size))
                        c.setBlendMode(.normal)
                    }
                }
                return context
            }
            
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .medium
                    drawImage(context: c, image: cgImage, orientation: imageOrientation, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    drawImage(context: c, image: fullSizeImage, orientation: imageOrientation, in: fittedRect)
                }
            }
            addCorners(context, arguments: arguments)
            return context
        }
    }
}

public enum PatternWallpaperDrawMode {
    case thumbnail
    case screen
}

public struct PatternWallpaperArguments: TransformImageCustomArguments {
    let colors: [UIColor]
    let rotation: Int32?
    let preview: Bool
    let customPatternColor: UIColor?
    let bakePatternAlpha: CGFloat
    
    public init(colors: [UIColor], rotation: Int32?, customPatternColor: UIColor? = nil, preview: Bool = false, bakePatternAlpha: CGFloat = 1.0) {
        self.colors = colors
        self.rotation = rotation
        self.customPatternColor = customPatternColor
        self.preview = preview
        self.bakePatternAlpha = bakePatternAlpha
    }
    
    public func serialized() -> NSArray {
        let array = NSMutableArray()
        array.addObjects(from: self.colors)
        array.add(NSNumber(value: self.rotation ?? 0))
        if let customPatternColor = customPatternColor {
            array.add(NSNumber(value: customPatternColor.argb))
        }
        array.add(NSNumber(value: self.preview))
        array.add(NSNumber(value: Double(self.bakePatternAlpha)))
        return array
    }
}

private func patternWallpaperDatas(account: Account, accountManager: AccountManager, representations: [ImageRepresentationWithReference], mode: PatternWallpaperDrawMode, autoFetchFullSize: Bool = false) -> Signal<(Data?, Bool), NoError> {
    var targetRepresentation: ImageRepresentationWithReference?
    switch mode {
    case .thumbnail:
        if let representation = smallestImageRepresentation(representations.map({ $0.representation })) {
            targetRepresentation = representations[representations.firstIndex(where: { $0.representation == representation })!]
        }
    case .screen:
        if let representation = largestImageRepresentation(representations.map({ $0.representation })) {
            targetRepresentation = representations[representations.firstIndex(where: { $0.representation == representation })!]
        }
    }

    if let targetRepresentation = targetRepresentation {
        let maybeFullSize = combineLatest(
            accountManager.mediaBox.resourceData(targetRepresentation.representation.resource),
            account.postbox.mediaBox.resourceData(targetRepresentation.representation.resource)
        )
        
        let signal = maybeFullSize
        |> take(1)
        |> mapToSignal { maybeSharedData, maybeData -> Signal<(Data?, Bool), NoError> in
            if maybeSharedData.complete {
                if let loadedData = try? Data(contentsOf: URL(fileURLWithPath: maybeSharedData.path), options: [.mappedRead]) {
                    return .single((loadedData, true))
                } else {
                    return .single(( nil, true))
                }
            } else if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((loadedData, true))
            } else {
                let fetchedFullSize = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: targetRepresentation.reference)

                let accountFullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                    let fetchedFullSizeDisposable = fetchedFullSize.start()
                    let fullSizeDisposable = account.postbox.mediaBox.resourceData(targetRepresentation.representation.resource).start(next: { next in
                        subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                        
                        if next.complete, let data = try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedRead) {
                            accountManager.mediaBox.storeResourceData(targetRepresentation.representation.resource.id, data: data)
                        }
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedFullSizeDisposable.dispose()
                        fullSizeDisposable.dispose()
                    }
                }

                let sharedFullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                    let fullSizeDisposable = accountManager.mediaBox.resourceData(targetRepresentation.representation.resource).start(next: { next in
                        subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)

                    return ActionDisposable {
                        fullSizeDisposable.dispose()
                    }
                }

                let fullSizeData = combineLatest(accountFullSizeData, sharedFullSizeData)
                |> map { accountFullSizeData, sharedFullSizeData -> (Data?, Bool) in
                    if accountFullSizeData.0 != nil {
                        return accountFullSizeData
                    } else {
                        return sharedFullSizeData
                    }
                }
                |> distinctUntilChanged(isEqual: { lhs, rhs in
                    if lhs.0 == nil && rhs.0 == nil {
                        return true
                    } else {
                        return false
                    }
                })
                |> take(until: { value in
                    if value.0 != nil {
                        return SignalTakeAction(passthrough: true, complete: true)
                    } else {
                        return SignalTakeAction(passthrough: true, complete: false)
                    }
                })

                return fullSizeData
            }
        }
    
        return signal
    } else {
        return .never()
    }
}

public func patternWallpaperImage(account: Account, accountManager: AccountManager, representations: [ImageRepresentationWithReference], mode: PatternWallpaperDrawMode, autoFetchFullSize: Bool = false) -> Signal<((TransformImageArguments) -> DrawingContext?)?, NoError> {
    return patternWallpaperDatas(account: account, accountManager: accountManager, representations: representations, mode: mode, autoFetchFullSize: autoFetchFullSize)
    |> mapToSignal { fullSizeData, fullSizeComplete in
        return patternWallpaperImageInternal(fullSizeData: fullSizeData, fullSizeComplete: fullSizeComplete, mode: mode)
    }
}

private func patternWallpaperImageInternal(fullSizeData: Data?, fullSizeComplete: Bool, mode: PatternWallpaperDrawMode) -> Signal<((TransformImageArguments) -> DrawingContext?)?, NoError> {
    var prominent = false
    if case .thumbnail = mode {
        prominent = true
    }
    
    let scale: CGFloat = 0.0
    
    return .single((fullSizeData, fullSizeComplete))
    |> map { fullSizeData, fullSizeComplete in
        return { arguments in
            var scale = scale
            if scale.isZero {
                scale = arguments.scale ?? UIScreenScale
            }
            
            let drawingRect = arguments.drawingRect
         
            if let customArguments = arguments.custom as? PatternWallpaperArguments, let combinedColor = customArguments.colors.first {
                if customArguments.preview {
                    scale = max(1.0, UIScreenScale - 1.0)
                }
                
                let combinedColors = customArguments.colors
                let colors = combinedColors.reversed().map { $0.withAlphaComponent(1.0) }
                let color = combinedColor.withAlphaComponent(1.0)
                let intensity = combinedColor.alpha
                
                let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: !arguments.corners.isEmpty)
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)

                    if colors.count == 1 {
                        if customArguments.colors[0].alpha.isZero {
                            c.clear(arguments.drawingRect)
                        } else {
                            c.setFillColor(color.cgColor)
                            c.fill(arguments.drawingRect)
                        }
                    } else if colors.count >= 3 {
                        let image = GradientBackgroundNode.generatePreview(size: CGSize(width: 60.0, height: 60.0), colors: colors)
                        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                        c.draw(image.cgImage!, in: drawingRect)
                        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                    } else {
                        let gradientColors = colors.map { $0.cgColor } as CFArray
                        let delta: CGFloat = 1.0 / (CGFloat(colors.count) - 1.0)
                        
                        var locations: [CGFloat] = []
                        for i in 0 ..< colors.count {
                            locations.append(delta * CGFloat(i))
                        }
                        let colorSpace = CGColorSpaceCreateDeviceRGB()
                        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
                        
                        c.saveGState()
                        c.translateBy(x: arguments.drawingSize.width / 2.0, y: arguments.drawingSize.height / 2.0)
                        c.rotate(by: CGFloat(customArguments.rotation ?? 0) * CGFloat.pi / -180.0)
                        c.translateBy(x: -arguments.drawingSize.width / 2.0, y: -arguments.drawingSize.height / 2.0)
                        
                        c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: arguments.drawingSize.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                        c.restoreGState()
                    }

                    let overlayImage = generateImage(arguments.drawingRect.size, rotatedContext: { size, c in
                        c.clear(CGRect(origin: CGPoint(), size: size))
                        var image: UIImage?
                        if let fullSizeData = fullSizeData, let unpackedData = TGGUnzipData(fullSizeData, 2 * 1024 * 1024) {
                            image = drawSvgImage(unpackedData, CGSize(width: size.width * context.scale, height: size.height * context.scale), .black, .white)
                        } else if let fullSizeData = fullSizeData {
                            image = UIImage(data: fullSizeData)
                        }

                        if let customPatternColor = customArguments.customPatternColor, customPatternColor.alpha < 1.0 {
                            c.setBlendMode(.copy)
                            c.setFillColor(UIColor.black.cgColor)
                            c.fill(CGRect(origin: CGPoint(), size: size))
                        } else {
                            c.setBlendMode(.normal)
                        }

                        if let image = image {
                            var fittedSize = image.size
                            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                                fittedSize.width = arguments.boundingSize.width
                            }
                            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                                fittedSize.height = arguments.boundingSize.height
                            }
                            fittedSize = fittedSize.aspectFilled(arguments.drawingRect.size)

                            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)

                            c.interpolationQuality = customArguments.preview ? .low : .medium
                            c.clip(to: fittedRect, mask: image.cgImage!)

                            if let customPatternColor = customArguments.customPatternColor {
                                c.setFillColor(customPatternColor.cgColor)
                                c.fill(CGRect(origin: CGPoint(), size: arguments.drawingRect.size))
                            } else if colors.count >= 3 && customArguments.customPatternColor == nil {
                                c.setFillColor(UIColor(white: 0.0, alpha: 0.5).cgColor)
                                c.fill(CGRect(origin: CGPoint(), size: arguments.drawingRect.size))
                            } else if colors.count == 1 {
                                c.setFillColor(customArguments.customPatternColor?.cgColor ?? patternColor(for: color, intensity: intensity, prominent: prominent).cgColor)
                                c.fill(CGRect(origin: CGPoint(), size: arguments.drawingRect.size))
                            } else {
                                let gradientColors = colors.map { patternColor(for: $0, intensity: intensity, prominent: prominent).cgColor } as CFArray
                                let delta: CGFloat = 1.0 / (CGFloat(colors.count) - 1.0)

                                var locations: [CGFloat] = []
                                for i in 0 ..< colors.count {
                                    locations.append(delta * CGFloat(i))
                                }
                                let colorSpace = CGColorSpaceCreateDeviceRGB()
                                let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!

                                c.translateBy(x: arguments.drawingSize.width / 2.0, y: arguments.drawingSize.height / 2.0)
                                c.rotate(by: CGFloat(customArguments.rotation ?? 0) * CGFloat.pi / -180.0)
                                c.translateBy(x: -arguments.drawingSize.width / 2.0, y: -arguments.drawingSize.height / 2.0)

                                c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: arguments.drawingSize.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                            }
                        }
                    })
                    if let customPatternColor = customArguments.customPatternColor, customPatternColor.alpha < 1.0 {
                        c.setBlendMode(.normal)
                    } else if customArguments.colors.count == 1 && customArguments.colors[0].alpha.isZero {
                        c.setBlendMode(.normal)
                    } else {
                        c.setBlendMode(.softLight)
                    }
                    if let overlayImage = overlayImage {
                        if customArguments.bakePatternAlpha != 1.0 {
                            c.setAlpha(customArguments.bakePatternAlpha)
                        }
                        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                        c.draw(overlayImage.cgImage!, in: drawingRect)
                        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                        c.setAlpha(1.0)
                    }
                }
                addCorners(context, arguments: arguments)
                return context
            } else {
                return nil
            }
        }
    }
}

public func patternColor(for color: UIColor, intensity: CGFloat, prominent: Bool = false) -> UIColor {
    var hue:  CGFloat = 0.0
    var saturation: CGFloat = 0.0
    var brightness: CGFloat = 0.0
    if color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil) {
        if saturation > 0.0 {
            saturation = min(1.0, saturation + 0.05 + 0.1 * (1.0 - saturation))
        }
        if brightness > 0.45 {
            brightness = max(0.0, brightness * 0.65)
        } else {
            brightness = max(0.0, min(1.0, 1.0 - brightness * 0.65))
        }
        let alpha = (prominent ? 0.6 : 0.55) * intensity
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
    return .black
}

public func solidColorImage(_ color: UIColor) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return .single({ arguments in
        let context = DrawingContext(size: arguments.drawingSize, clear: true)
        
        context.withFlippedContext { c in
            c.setFillColor(color.withAlphaComponent(1.0).cgColor)
            c.fill(arguments.drawingRect)
        }
        
        addCorners(context, arguments: arguments)
        
        return context
    })
}

public func drawWallpaperGradientImage(_ colors: [UIColor], rotation: Int32? = nil, context: CGContext, size: CGSize) {
    guard !colors.isEmpty else {
        return
    }
    guard colors.count > 1 else {
        context.setFillColor(colors[0].cgColor)
        context.fill(CGRect(origin: CGPoint(), size: size))
        return
    }

    let drawingRect = CGRect(origin: CGPoint(), size: size)

    let c = context

    if colors.count >= 3 {
        let image = GradientBackgroundNode.generatePreview(size: CGSize(width: 60.0, height: 60.0), colors: colors)
        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
        c.scaleBy(x: 1.0, y: -1.0)
        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
        c.draw(image.cgImage!, in: drawingRect)
        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
        c.scaleBy(x: 1.0, y: -1.0)
        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
    } else {
        let gradientColors = colors.map { $0.withAlphaComponent(1.0).cgColor } as CFArray
        let delta: CGFloat = 1.0 / (CGFloat(colors.count) - 1.0)

        var locations: [CGFloat] = []
        for i in 0 ..< colors.count {
            locations.append(delta * CGFloat(i))
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!

        if let rotation = rotation {
            c.saveGState()
            c.translateBy(x: drawingRect.width / 2.0, y: drawingRect.height / 2.0)
            c.rotate(by: CGFloat(rotation) * CGFloat.pi / 180.0)
            c.translateBy(x: -drawingRect.width / 2.0, y: -drawingRect.height / 2.0)
        }

        c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: drawingRect.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        if rotation != nil {
            c.restoreGState()
        }
    }
}

public func gradientImage(_ colors: [UIColor], rotation: Int32? = nil) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    guard !colors.isEmpty else {
        return .complete()
    }
    guard colors.count > 1 else {
        if let color = colors.first {
            return solidColorImage(color)
        } else {
            return .complete()
        }
    }
    return .single({ arguments in
        let context = DrawingContext(size: arguments.drawingSize, clear: !arguments.corners.isEmpty)

        let drawingRect = arguments.drawingRect
        
        context.withContext { c in
            if colors.count >= 3 {
                let image = GradientBackgroundNode.generatePreview(size: CGSize(width: 60.0, height: 60.0), colors: colors)
                c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                c.scaleBy(x: 1.0, y: -1.0)
                c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                c.draw(image.cgImage!, in: drawingRect)
                c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                c.scaleBy(x: 1.0, y: -1.0)
                c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
            } else {
                let gradientColors = colors.map { $0.withAlphaComponent(1.0).cgColor } as CFArray
                let delta: CGFloat = 1.0 / (CGFloat(colors.count) - 1.0)

                var locations: [CGFloat] = []
                for i in 0 ..< colors.count {
                    locations.append(delta * CGFloat(i))
                }
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!

                if let rotation = rotation {
                    c.translateBy(x: arguments.drawingSize.width / 2.0, y: arguments.drawingSize.height / 2.0)
                    c.rotate(by: CGFloat(rotation) * CGFloat.pi / 180.0)
                    c.translateBy(x: -arguments.drawingSize.width / 2.0, y: -arguments.drawingSize.height / 2.0)
                }

                c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: arguments.drawingSize.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        
        addCorners(context, arguments: arguments)
        
        return context
    })
}

private func builtinWallpaperData() -> Signal<UIImage, NoError> {
    return Signal { subscriber in
        if let filePath = getAppBundle().path(forResource: "ChatWallpaperBuiltin0", ofType: "jpg"), let image = UIImage(contentsOfFile: filePath) {
            subscriber.putNext(image)
        }
        subscriber.putCompletion()
        
        return EmptyDisposable
        } |> runOn(Queue.concurrentDefaultQueue())
}

public func settingsBuiltinWallpaperImage(account: Account, thumbnail: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return builtinWallpaperData() |> map { fullSizeImage in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = fullSizeImage.size.aspectFilled(drawingRect.size)
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if thumbnail {
                    c.translateBy(x: fittedRect.midX, y: fittedRect.midY)
                    c.scaleBy(x: 3.4, y: 3.4)
                    c.translateBy(x: -fittedRect.midX, y: -fittedRect.midY)
                }
                if let fullSizeImage = fullSizeImage.cgImage {
                    c.interpolationQuality = .medium
                    drawImage(context: c, image: fullSizeImage, orientation: .up, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

public func photoWallpaper(postbox: Postbox, photoLibraryResource: PhotoLibraryMediaResource) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let thumbnail = fetchPhotoLibraryImage(localIdentifier: photoLibraryResource.localIdentifier, thumbnail: true)
    let fullSize = fetchPhotoLibraryImage(localIdentifier: photoLibraryResource.localIdentifier, thumbnail: false)
    
    return (thumbnail |> then(fullSize))
    |> map { result in
        var sourceImage = result?.0
        let isThumbnail = result?.1 ?? false
        
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: 1.0, clear: true)
            
            let dimensions = sourceImage?.size
            
            if let thumbnailImage = sourceImage?.cgImage, isThumbnail {
                var fittedSize = arguments.imageSize
                if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                    fittedSize.width = arguments.boundingSize.width
                }
                if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                    fittedSize.height = arguments.boundingSize.height
                }
                
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                
                let initialThumbnailContextFittingSize = fittedSize.fitted(CGSize(width: 100.0, height: 100.0))
                
                let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                imageFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                    thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                }
                
                if thumbnailContextFittingSize.width > thumbnailContextSize.width {
                    let additionalContextSize = thumbnailContextFittingSize
                    let additionalBlurContext = DrawingContext(size: additionalContextSize, scale: 1.0)
                    additionalBlurContext.withFlippedContext { c in
                        c.interpolationQuality = .default
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: additionalContextSize))
                        }
                    }
                    imageFastBlur(Int32(additionalContextSize.width), Int32(additionalContextSize.height), Int32(additionalBlurContext.bytesPerRow), additionalBlurContext.bytes)
                    sourceImage = additionalBlurContext.generateImage()
                } else {
                    sourceImage = thumbnailContext.generateImage()
                }
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if let sourceImage = sourceImage, let cgImage = sourceImage.cgImage, let dimensions = dimensions {
                    let imageSize = dimensions.aspectFilled(arguments.drawingRect.size)
                    let fittedRect = CGRect(origin: CGPoint(x: floor((arguments.drawingRect.size.width - imageSize.width) / 2.0), y: floor((arguments.drawingRect.size.height - imageSize.height) / 2.0)), size: imageSize)
                    c.draw(cgImage, in: fittedRect)
                }
            }
            
            return context
        }
    }
}

public func telegramThemeData(account: Account, accountManager: AccountManager, reference: MediaResourceReference, synchronousLoad: Bool = false) -> Signal<Data?, NoError> {
    let maybeFetched = accountManager.mediaBox.resourceData(reference.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad)
    return maybeFetched
    |> take(1)
    |> mapToSignal { maybeData in
        if maybeData.complete {
            let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
            return .single(loadedData)
        } else {
            let data = account.postbox.mediaBox.resourceData(reference.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            return Signal { subscriber in
                let fetch = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: reference).start()
                let disposable = (data
                |> map { data -> Data? in
                    return data.complete ? try? Data(contentsOf: URL(fileURLWithPath: data.path)) : nil
                }).start(next: { next in
                    if let data = next {
                        accountManager.mediaBox.storeResourceData(reference.resource.id, data: data)
                    }
                    subscriber.putNext(next)
                }, error: { _ in
                }, completed: {
                    subscriber.putCompletion()
                })
                return ActionDisposable {
                    fetch.dispose()
                    disposable.dispose()
                }
            }
        }
    }
}

private func generateBackArrowImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 13.0, height: 22.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(color.cgColor)
        
        context.translateBy(x: 0.0, y: -UIScreenPixel)
        
        let _ = try? drawSvgPath(context, path: "M3.60751322,11.5 L11.5468531,3.56066017 C12.1326395,2.97487373 12.1326395,2.02512627 11.5468531,1.43933983 C10.9610666,0.853553391 10.0113191,0.853553391 9.42553271,1.43933983 L0.449102936,10.4157696 C-0.149700979,11.0145735 -0.149700979,11.9854265 0.449102936,12.5842304 L9.42553271,21.5606602 C10.0113191,22.1464466 10.9610666,22.1464466 11.5468531,21.5606602 C12.1326395,20.9748737 12.1326395,20.0251263 11.5468531,19.4393398 L3.60751322,11.5 Z ")
    })
}

public func drawThemeImage(context c: CGContext, theme: PresentationTheme, wallpaperImage: UIImage? = nil, size: CGSize) {
    let drawingRect = CGRect(origin: CGPoint(), size: size)
    
    switch theme.chat.defaultWallpaper {
        case .builtin:
            if let filePath = getAppBundle().path(forResource: "ChatWallpaperBuiltin0", ofType: "jpg"), let image = UIImage(contentsOfFile: filePath), let cgImage = image.cgImage {
                let size = image.size.aspectFilled(drawingRect.size)
                c.draw(cgImage, in: CGRect(origin: CGPoint(x: (drawingRect.size.width - size.width) / 2.0, y: (drawingRect.size.height - size.height) / 2.0), size: size))
            }
        case let .color(color):
            c.setFillColor(UIColor(rgb: color).cgColor)
            c.fill(drawingRect)
        case let .gradient(_, colors, _):
            if colors.count >= 3 {
                let image = GradientBackgroundNode.generatePreview(size: CGSize(width: 60.0, height: 60.0), colors: colors.map(UIColor.init(rgb:)))
                c.draw(image.cgImage!, in: drawingRect)
            } else if colors.count >= 2 {
                let gradientColors = colors.map({ UIColor(rgb: $0).cgColor }) as CFArray
                var locations: [CGFloat] = [0.0, 1.0]
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
                c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: drawingRect.height), end: CGPoint(x: 0.0, y: 0.0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else if colors.count >= 1 {
                let gradientColors = [UIColor(rgb: colors[0]), UIColor(rgb: colors[0])] as CFArray
                var locations: [CGFloat] = [0.0, 1.0]
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
                c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: drawingRect.height), end: CGPoint(x: 0.0, y: 0.0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case let .file(_, _, _, _, isPattern, _, _, _, settings):
            if isPattern, let intensity = settings.intensity, intensity < 0 {
                c.setFillColor(UIColor.black.cgColor)
                c.fill(CGRect(origin: CGPoint(), size: size))
            } else {
                if let image = wallpaperImage, let cgImage = image.cgImage {
                    let size = image.size.aspectFilled(drawingRect.size)
                    c.draw(cgImage, in: CGRect(origin: CGPoint(x: (drawingRect.size.width - size.width) / 2.0, y: (drawingRect.size.height - size.height) / 2.0), size: size))
                }
            }
            c.setFillColor(theme.chatList.backgroundColor.cgColor)
        default:
            break
    }
    
    c.setFillColor(theme.rootController.navigationBar.opaqueBackgroundColor.cgColor)
    c.fill(CGRect(origin: CGPoint(x: 0.0, y: drawingRect.height - 42.0), size: CGSize(width: drawingRect.width, height: 42.0)))
    
    c.setFillColor(theme.rootController.navigationBar.separatorColor.cgColor)
    c.fill(CGRect(origin: CGPoint(x: 1.0, y: drawingRect.height - 42.0 - UIScreenPixel), size: CGSize(width: drawingRect.width - 2.0, height: UIScreenPixel)))
    
    c.setFillColor(theme.rootController.navigationBar.secondaryTextColor.cgColor)
    c.fillEllipse(in: CGRect(origin: CGPoint(x: drawingRect.width - 28.0 - 7.0, y: drawingRect.height - 7.0 - 28.0 - UIScreenPixel), size: CGSize(width: 28.0, height: 28.0)))
    
    if let arrow = generateBackArrowImage(color: theme.rootController.navigationBar.buttonColor), let image = arrow.cgImage {
        c.draw(image, in: CGRect(x: 9.0, y: drawingRect.height - 11.0 - 22.0 + UIScreenPixel, width: 13.0, height: 22.0))
    }
    
    if case let .color(color) = theme.chat.defaultWallpaper, UIColor(rgb: color).isEqual(theme.chat.inputPanel.panelBackgroundColorNoWallpaper) {
        c.setFillColor(theme.chat.inputPanel.panelBackgroundColorNoWallpaper.cgColor)
        c.fill(CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: drawingRect.width, height: 42.0)))
    } else {
        c.setFillColor(theme.chat.inputPanel.panelBackgroundColor.cgColor)
        c.fill(CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: drawingRect.width, height: 42.0)))
        
        c.setFillColor(theme.chat.inputPanel.panelSeparatorColor.cgColor)
        c.fill(CGRect(origin: CGPoint(x: 1.0, y: 42.0), size: CGSize(width: drawingRect.width - 2.0, height: UIScreenPixel)))
    }
    
    c.setFillColor(theme.chat.inputPanel.inputBackgroundColor.cgColor)
    c.setStrokeColor(theme.chat.inputPanel.inputStrokeColor.cgColor)
    
    c.setLineWidth(1.0)
    let path = UIBezierPath(roundedRect: CGRect(x: 34.0, y: 6.0, width: drawingRect.width - 34.0 * 2.0, height: 31.0), cornerRadius: 15.5)
    c.addPath(path.cgPath)
    c.drawPath(using: .fillStroke)
    
    if let attachment = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconAttachment"), color: theme.chat.inputPanel.panelControlColor), let image = attachment.cgImage {
        c.draw(image, in: CGRect(origin: CGPoint(x: 3.0, y: 6.0 + UIScreenPixel), size: attachment.size.fitted(CGSize(width: 30.0, height: 30.0))))
    }
    
    if let microphone = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconMicrophone"), color: theme.chat.inputPanel.panelControlColor), let image = microphone.cgImage {
        c.draw(image, in: CGRect(origin: CGPoint(x: drawingRect.width - 3.0 - 29.0, y: 7.0 + UIScreenPixel), size: microphone.size.fitted(CGSize(width: 30.0, height: 30.0))))
    }
    
    let incoming = theme.chat.message.incoming.bubble.withoutWallpaper
    let outgoing = theme.chat.message.outgoing.bubble.withoutWallpaper
    
    c.saveGState()

    c.translateBy(x: 5.0, y: 65.0)
    c.translateBy(x: 114.0, y: 32.0)
    c.scaleBy(x: 1.0, y: -1.0)
    c.translateBy(x: -114.0, y: -32.0)
    
    let _ = try? drawSvgPath(c, path: "M98.0061174,0 C106.734138,0 113.82927,6.99200411 113.996965,15.6850616 L114,16 C114,24.836556 106.830179,32 98.0061174,32 L21.9938826,32 C18.2292665,32 14.7684355,30.699197 12.0362474,28.5221601 C8.56516444,32.1765452 -1.77635684e-15,31.9985981 -1.77635684e-15,31.9985981 C5.69252399,28.6991366 5.98604874,24.4421608 5.99940747,24.1573436 L6,24.1422468 L6,16 C6,7.163444 13.1698213,0 21.9938826,0 L98.0061174,0 ")
    if incoming.fill.rgb != incoming.gradientFill.rgb {
        c.clip()
        
        let gradientColors = [incoming.fill.withAlphaComponent(1.0), incoming.gradientFill.withAlphaComponent(1.0)].map { $0.cgColor } as CFArray
        var locations: [CGFloat] = [0.0, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: 32.0), options: CGGradientDrawingOptions())
    } else {
        c.setFillColor(incoming.fill.cgColor)
        c.setStrokeColor(incoming.stroke.cgColor)
    
        c.strokePath()
        let _ = try? drawSvgPath(c, path: "M98.0061174,0 C106.734138,0 113.82927,6.99200411 113.996965,15.6850616 L114,16 C114,24.836556 106.830179,32 98.0061174,32 L21.9938826,32 C18.2292665,32 14.7684355,30.699197 12.0362474,28.5221601 C8.56516444,32.1765452 -1.77635684e-15,31.9985981 -1.77635684e-15,31.9985981 C5.69252399,28.6991366 5.98604874,24.4421608 5.99940747,24.1573436 L6,24.1422468 L6,16 C6,7.163444 13.1698213,0 21.9938826,0 L98.0061174,0 ")
        c.fillPath()
    }
    c.restoreGState()
    
    c.saveGState()

    c.translateBy(x: drawingRect.width - 114.0 - 5.0, y: 25.0)
    c.translateBy(x: 114.0, y: 32.0)
    c.scaleBy(x: -1.0, y: -1.0)
    c.translateBy(x: 0, y: -32.0)
    
    let _ = try? drawSvgPath(c, path: "M98.0061174,0 C106.734138,0 113.82927,6.99200411 113.996965,15.6850616 L114,16 C114,24.836556 106.830179,32 98.0061174,32 L21.9938826,32 C18.2292665,32 14.7684355,30.699197 12.0362474,28.5221601 C8.56516444,32.1765452 -1.77635684e-15,31.9985981 -1.77635684e-15,31.9985981 C5.69252399,28.6991366 5.98604874,24.4421608 5.99940747,24.1573436 L6,24.1422468 L6,16 C6,7.163444 13.1698213,0 21.9938826,0 L98.0061174,0 ")
    if outgoing.fill.rgb != outgoing.gradientFill.rgb {
        c.clip()
        
        let gradientColors = [outgoing.fill.withAlphaComponent(1.0), outgoing.gradientFill.withAlphaComponent(1.0)].map { $0.cgColor } as CFArray
        var locations: [CGFloat] = [0.0, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: 32.0), options: CGGradientDrawingOptions())
    } else {
        c.setFillColor(outgoing.fill.cgColor)
        c.setStrokeColor(outgoing.stroke.cgColor)

        c.strokePath()
        let _ = try? drawSvgPath(c, path: "M98.0061174,0 C106.734138,0 113.82927,6.99200411 113.996965,15.6850616 L114,16 C114,24.836556 106.830179,32 98.0061174,32 L21.9938826,32 C18.2292665,32 14.7684355,30.699197 12.0362474,28.5221601 C8.56516444,32.1765452 -1.77635684e-15,31.9985981 -1.77635684e-15,31.9985981 C5.69252399,28.6991366 5.98604874,24.4421608 5.99940747,24.1573436 L6,24.1422468 L6,16 C6,7.163444 13.1698213,0 21.9938826,0 L98.0061174,0 ")
        c.fillPath()
    }
    
    c.restoreGState()
}

public enum ThemeImageSource {
    case file(FileMediaReference)
    case settings(TelegramThemeSettings)
}

public func themeImage(account: Account, accountManager: AccountManager, source: ThemeImageSource, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let theme: Signal<(PresentationTheme?, Data?), NoError>
    
    switch source {
        case let .file(fileReference):
            let isSupportedTheme = fileReference.media.mimeType == "application/x-tgtheme-ios"
            let maybeFetched = accountManager.mediaBox.resourceData(fileReference.media.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad)
            theme = maybeFetched
            |> take(1)
            |> mapToSignal { maybeData -> Signal<(PresentationTheme?, Data?), NoError> in
                if maybeData.complete && isSupportedTheme {
                    let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                    return .single((loadedData.flatMap { makePresentationTheme(data: $0) }, nil))
                } else {
                    let decodedThumbnailData = fileReference.media.immediateThumbnailData.flatMap(decodeTinyThumbnail)
                    
                    let previewRepresentation = fileReference.media.previewRepresentations.first
                    let fetchedThumbnail: Signal<FetchResourceSourceType, FetchResourceError>
                    if let previewRepresentation = previewRepresentation {
                        fetchedThumbnail = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: fileReference.resourceReference(previewRepresentation.resource))
                    } else {
                        fetchedThumbnail = .complete()
                    }
                    
                    let thumbnailData: Signal<Data?, NoError>
                    if let previewRepresentation = previewRepresentation {
                        thumbnailData = Signal<Data?, NoError> { subscriber in
                            let fetchedDisposable = fetchedThumbnail.start()
                            let thumbnailDisposable = account.postbox.mediaBox.resourceData(previewRepresentation.resource).start(next: { next in
                                let data = next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])
                                if let data = data, data.count > 0 {
                                    subscriber.putNext(data)
                                } else {
                                    subscriber.putNext(decodedThumbnailData)
                                }
                            }, error: subscriber.putError, completed: subscriber.putCompletion)
                            
                            return ActionDisposable {
                                fetchedDisposable.dispose()
                                thumbnailDisposable.dispose()
                            }
                        }
                    } else {
                        thumbnailData = .single(decodedThumbnailData)
                    }
                    
                    let reference = fileReference.resourceReference(fileReference.media.resource)
                    let fullSizeData: Signal<Data?, NoError>
                    if isSupportedTheme {
                        fullSizeData = Signal { subscriber in
                            let fetch = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: reference).start()
                            let disposable = (account.postbox.mediaBox.resourceData(reference.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
                                |> map { data -> Data? in
                                    return data.complete ? try? Data(contentsOf: URL(fileURLWithPath: data.path)) : nil
                                }).start(next: { next in
                                    if let data = next {
                                        accountManager.mediaBox.storeResourceData(reference.resource.id, data: data)
                                    }
                                    subscriber.putNext(next)
                                }, error: { _ in
                                }, completed: {
                                    subscriber.putCompletion()
                                })
                            return ActionDisposable {
                                fetch.dispose()
                                disposable.dispose()
                            }
                        }
                    } else {
                         fullSizeData = .single(nil)
                    }
                    
                    return thumbnailData |> mapToSignal { thumbnailData in
                        return fullSizeData |> map { fullSizeData in
                            return (fullSizeData.flatMap { makePresentationTheme(data: $0) }, thumbnailData)
                        }
                    }
                }
            }
        case let .settings(settings):
            theme = .single((makePresentationTheme(mediaBox: accountManager.mediaBox, themeReference: .builtin(PresentationBuiltinThemeReference(baseTheme: settings.baseTheme)), accentColor: UIColor(argb: settings.accentColor), backgroundColors: [], bubbleColors: settings.messageColors.flatMap { (UIColor(argb: $0.top), UIColor(argb: $0.bottom)) }, wallpaper: settings.wallpaper, serviceBackgroundColor: nil, preview: false), nil))
    }

    enum WallpaperImage {
        case image(UIImage)
        case pattern(data: Data, colors: [UInt32], intensity: Int32)
    }
    
    let data = theme
    |> mapToSignal { (theme, thumbnailData) -> Signal<(PresentationTheme?, WallpaperImage?, Data?), NoError> in
        if let theme = theme {
            if case let .file(_, _, _, _, _, _, slug, _, settings) = theme.chat.defaultWallpaper {
                return cachedWallpaper(account: account, slug: slug, settings: settings)
                |> mapToSignal { wallpaper -> Signal<(PresentationTheme?, WallpaperImage?, Data?), NoError> in
                    if let wallpaper = wallpaper, case let .file(_, _, _, _, _, _, slug, file, settings) = wallpaper.wallpaper {
                        var convertedRepresentations: [ImageRepresentationWithReference] = []
                        convertedRepresentations.append(ImageRepresentationWithReference(representation: TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 100, height: 100), resource: file.resource, progressiveSizes: [], immediateThumbnailData: nil), reference: .wallpaper(wallpaper: .slug(slug), resource: file.resource)))
                        return wallpaperDatas(account: account, accountManager: accountManager, fileReference: .standalone(media: file), representations: convertedRepresentations, alwaysShowThumbnailFirst: false, thumbnail: false, onlyFullSize: true, autoFetchFullSize: true, synchronousLoad: false)
                        |> mapToSignal { _, fullSizeData, complete -> Signal<(PresentationTheme?, WallpaperImage?, Data?), NoError> in
                            guard complete, let fullSizeData = fullSizeData else {
                                return .complete()
                            }
                            accountManager.mediaBox.storeResourceData(file.resource.id, data: fullSizeData)
                            let _ = accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: true, fetch: true).start()
                            
                            if wallpaper.wallpaper.isPattern, !settings.colors.isEmpty, let intensity = settings.intensity {
                                return accountManager.mediaBox.resourceData(file.resource)
                                |> mapToSignal { data in
                                    if data.complete, let imageData = try? Data(contentsOf: URL(fileURLWithPath: data.path)) {
                                        return .single((theme, .pattern(data: imageData, colors: settings.colors, intensity: intensity), thumbnailData))
                                    } else {
                                        return .complete()
                                    }
                                }
                            } else if settings.blur {
                                return accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedBlurredWallpaperRepresentation(), complete: true, fetch: true)
                                |> mapToSignal { data in
                                    if data.complete, let data = try? Data(contentsOf: URL(fileURLWithPath: data.path)), let image = UIImage(data: data) {
                                        return .single((theme, .image(image), thumbnailData))
                                    } else {
                                        return .complete()
                                    }
                                }
                            } else if let image = UIImage(data: fullSizeData) {
                                return .single((theme, .image(image), thumbnailData))
                            } else {
                                return .complete()
                            }
                        }
                    } else {
                        return .single((theme, nil, thumbnailData))
                    }
                }
            } else {
                return .single((theme, nil, thumbnailData))
            }
        } else {
            return .single((nil, nil, thumbnailData))
        }
    }
    return data
    |> map { theme, wallpaperImage, thumbnailData in
        return { arguments in
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                if thumbnailSize.width > 200.0 {
                    blurredThumbnailImage = UIImage(cgImage: thumbnailImage)
                } else {
                    let initialThumbnailContextFittingSize = arguments.imageSize.fitted(CGSize(width: 90.0, height: 90.0))
                    
                    let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                    let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                    thumbnailContext.withFlippedContext { c in
                        c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                    }
                    telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                    telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                    var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                    if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                        thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                    }
                    
                    blurredThumbnailImage = thumbnailContext.generateImage()
                }
            }
            
            let drawingRect = arguments.drawingRect
            if let blurredThumbnailImage = blurredThumbnailImage, theme == nil {
                let context = DrawingContext(size: arguments.drawingSize, scale: 0.0, clear: true)
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)
                    if let cgImage = blurredThumbnailImage.cgImage {
                        c.interpolationQuality = .none
                        let fittedSize = blurredThumbnailImage.size.aspectFilled(arguments.drawingSize)
                        drawImage(context: c, image: cgImage, orientation: .up, in: CGRect(origin: CGPoint(x: (drawingRect.width - fittedSize.width) / 2.0, y: (drawingRect.height - fittedSize.height) / 2.0), size: fittedSize))
                        c.setBlendMode(.normal)
                    }
                }
                addCorners(context, arguments: arguments)
                return context
            }
            
            let context = DrawingContext(size: arguments.drawingSize, scale: 0.0, clear: true)
            if let theme = theme {
                context.withFlippedContext { c in
                    c.setBlendMode(.normal)

                    switch wallpaperImage {
                    case let .image(image):
                        drawThemeImage(context: c, theme: theme, wallpaperImage: image, size: arguments.drawingSize)
                    case let .pattern(data, colors, intensity):
                        let wallpaperImage = generateImage(arguments.drawingSize, rotatedContext: { size, context in
                            drawWallpaperGradientImage(colors.map(UIColor.init(rgb:)), context: context, size: size)
                            if let unpackedData = TGGUnzipData(data, 2 * 1024 * 1024), let image = drawSvgImage(unpackedData, arguments.drawingSize, .clear, .black) {
                                context.setBlendMode(.softLight)
                                context.setAlpha(abs(CGFloat(intensity)) / 100.0)
                                context.draw(image.cgImage!, in: CGRect(origin: CGPoint(), size: arguments.drawingSize))
                            } else if let image = UIImage(data: data) {
                                context.setBlendMode(.softLight)
                                context.setAlpha(abs(CGFloat(intensity)) / 100.0)
                                context.draw(image.cgImage!, in: CGRect(origin: CGPoint(), size: arguments.drawingSize))
                            }
                        })
                        drawThemeImage(context: c, theme: theme, wallpaperImage: wallpaperImage, size: arguments.drawingSize)
                    case .none:
                        drawThemeImage(context: c, theme: theme, wallpaperImage: nil, size: arguments.drawingSize)
                    }
                    
                    c.setStrokeColor(theme.rootController.navigationBar.separatorColor.cgColor)
                    c.setLineWidth(2.0)
                    let borderPath = UIBezierPath(roundedRect: drawingRect, cornerRadius: 4.0)
                    c.addPath(borderPath.cgPath)
                    c.drawPath(using: .stroke)
                }
            }
            addCorners(context, arguments: arguments)
            return context
        }
    }
}

public func themeIconImage(account: Account, accountManager: AccountManager, theme: PresentationThemeReference, color: PresentationThemeAccentColor?, wallpaper: TelegramWallpaper? = nil) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let colorsSignal: Signal<((UIColor, UIColor?, [UInt32]), (UIColor, UIColor), (UIColor, UIColor), UIImage?, Int32?), NoError>

    var reference: MediaResourceReference?
    if case let .local(theme) = theme {
        reference = .standalone(resource: theme.resource)
    } else if case let .cloud(theme) = theme, let resource = theme.theme.file?.resource {
        reference = .theme(theme: .slug(theme.theme.slug), resource: resource)
    }

    let themeSignal: Signal<PresentationTheme?, NoError>
    if case let .builtin(theme) = theme {
        themeSignal = .single(makeDefaultPresentationTheme(reference: theme, serviceBackgroundColor: nil))
    } else if case let .cloud(theme) = theme, let settings = theme.theme.settings {
        themeSignal = Signal { subscriber in
            let theme = makePresentationTheme(mediaBox: accountManager.mediaBox, themeReference: .builtin(PresentationBuiltinThemeReference(baseTheme: settings.baseTheme)), accentColor: UIColor(argb: settings.accentColor), backgroundColors: [], bubbleColors: settings.messageColors.flatMap { (UIColor(argb: $0.top), UIColor(argb: $0.bottom)) }, wallpaper: settings.wallpaper, serviceBackgroundColor: nil, preview: false)
            subscriber.putNext(theme)
            subscriber.putCompletion()
            
            return EmptyDisposable
        }
    } else if let reference = reference {
        themeSignal = telegramThemeData(account: account, accountManager: accountManager, reference: reference, synchronousLoad: false)
        |> map { data -> PresentationTheme? in
            if let data = data, let theme = makePresentationTheme(data: data) {
                return theme
            } else {
                return nil
            }
        }
    } else {
        themeSignal = .never()
    }
        
    colorsSignal = themeSignal
    |> mapToSignal { theme -> Signal<((UIColor, UIColor?, [UInt32]), (UIColor, UIColor), (UIColor, UIColor), UIImage?, Int32?), NoError> in
        if let theme = theme {
            var wallpaperSignal: Signal<((UIColor, UIColor?, [UInt32]), (UIColor, UIColor), (UIColor, UIColor), UIImage?, Int32?), NoError> = .complete()
            var rotation: Int32?
            var backgroundColor: (UIColor, UIColor?, [UInt32])
            let incomingColor = (theme.chat.message.incoming.bubble.withoutWallpaper.fill, theme.chat.message.incoming.bubble.withoutWallpaper.gradientFill)
            let outgoingColor = (theme.chat.message.outgoing.bubble.withoutWallpaper.fill, theme.chat.message.outgoing.bubble.withoutWallpaper.gradientFill)
            let wallpaper = wallpaper ?? theme.chat.defaultWallpaper
            switch wallpaper {
                case .builtin:
                    backgroundColor = (UIColor(rgb: 0xd6e2ee), nil, [])
                case let .color(color):
                    backgroundColor = (UIColor(rgb: color), nil, [])
                case let .gradient(_, colors, settings):
                    if colors.count >= 2 {
                        backgroundColor = (UIColor(rgb: colors[0]), UIColor(rgb: colors[1]), colors)
                    } else {
                        backgroundColor = (.white, nil, [])
                    }
                    rotation = settings.rotation
                case .image:
                    backgroundColor = (.black, nil, [])
                case let .file(_, _, _, _, isPattern, _, slug, _, settings):
                    rotation = settings.rotation
                    if isPattern, let intensity = settings.intensity, intensity < 0 {
                        backgroundColor = (.black, nil, [])
                    } else if !settings.colors.isEmpty {
                        var bottomColor: UIColor?
                        if settings.colors.count >= 2 {
                            bottomColor = UIColor(rgb: settings.colors[1])
                        }
                        backgroundColor = (UIColor(rgb: settings.colors[0]), bottomColor, settings.colors)
                    } else {
                        backgroundColor = (theme.chatList.backgroundColor, nil, [])
                    }
                    wallpaperSignal = cachedWallpaper(account: account, slug: slug, settings: settings)
                    |> mapToSignal { wallpaper in
                        if let wallpaper = wallpaper, case let .file(_, _, _, _, _, _, _, file, settings) = wallpaper.wallpaper {
                            var effectiveBackgroundColor = backgroundColor
                            if !settings.colors.isEmpty {
                                var bottomColor: UIColor?
                                if settings.colors.count >= 2 {
                                    bottomColor = UIColor(rgb: settings.colors[1])
                                }
                                effectiveBackgroundColor = (UIColor(rgb: settings.colors[0]), bottomColor, settings.colors)
                            }
                            
                            var convertedRepresentations: [ImageRepresentationWithReference] = []
                            convertedRepresentations.append(ImageRepresentationWithReference(representation: TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 100, height: 100), resource: file.resource, progressiveSizes: [], immediateThumbnailData: nil), reference: .wallpaper(wallpaper: .slug(slug), resource: file.resource)))
                            return wallpaperDatas(account: account, accountManager: accountManager, fileReference: .standalone(media: file), representations: convertedRepresentations, alwaysShowThumbnailFirst: false, thumbnail: false, onlyFullSize: true, autoFetchFullSize: true, synchronousLoad: false)
                            |> mapToSignal { _, fullSizeData, complete -> Signal<((UIColor, UIColor?, [UInt32]), (UIColor, UIColor), (UIColor, UIColor), UIImage?, Int32?), NoError> in
                                guard complete, let fullSizeData = fullSizeData else {
                                    return .complete()
                                }
                                accountManager.mediaBox.storeResourceData(file.resource.id, data: fullSizeData)
                                let _ = accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: true, fetch: true).start()
                                
                                if wallpaper.wallpaper.isPattern {
                                    if !settings.colors.isEmpty, let intensity = settings.intensity {
                                        if intensity < 0 {
                                            return .single(((.black, nil, []), incomingColor, outgoingColor, nil, rotation))
                                        } else {
                                            return .single((effectiveBackgroundColor, incomingColor, outgoingColor, nil, rotation))
                                        }
                                    } else {
                                        return .complete()
                                    }
                                } else if settings.blur {
                                    return accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedBlurredWallpaperRepresentation(), complete: true, fetch: true)
                                    |> mapToSignal { _ in
                                        if let image = UIImage(data: fullSizeData) {
                                            return .single((backgroundColor, incomingColor, outgoingColor, image, rotation))
                                        } else {
                                            return .complete()
                                        }
                                    }
                                } else if let image = UIImage(data: fullSizeData) {
                                    return .single((backgroundColor, incomingColor, outgoingColor, image, rotation))
                                } else {
                                    return .complete()
                                }
                            }
                        } else {
                            return .complete()
                        }
                    }
            }
            return .single((backgroundColor, incomingColor, outgoingColor, nil, rotation))
            |> then(wallpaperSignal)
        } else {
            return .complete()
        }
    }

    return colorsSignal
    |> map { colors in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: arguments.scale ?? 0.0, clear: arguments.emptyColor == nil)
            let drawingRect = arguments.drawingRect
            
            context.withContext { c in
                if colors.0.2.count >= 3 {
                    let image = GradientBackgroundNode.generatePreview(size: CGSize(width: 60.0, height: 60.0), colors: colors.0.2.map(UIColor.init(rgb:)))
                    c.draw(image.cgImage!, in: drawingRect)
                } else if let secondBackgroundColor = colors.0.1 {
                    let gradientColors = [colors.0.0, secondBackgroundColor].map { $0.cgColor } as CFArray
                    var locations: [CGFloat] = [0.0, 1.0]
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
                    c.saveGState()
                    if let rotation = colors.4 {
                        c.translateBy(x: drawingRect.width / 2.0, y: drawingRect.height / 2.0)
                        c.rotate(by: CGFloat(rotation) * CGFloat.pi / 180.0)
                        c.translateBy(x: -drawingRect.width / 2.0, y: -drawingRect.height / 2.0)
                    }
                    c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: drawingRect.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    c.restoreGState()
                } else {
                    c.setFillColor(colors.0.0.cgColor)
                    c.fill(drawingRect)
                }
                
                if let image = colors.3 {
                    let initialThumbnailContextFittingSize = arguments.imageSize.fitted(CGSize(width: 90.0, height: 90.0))
                    let thumbnailContextSize = image.size.aspectFilled(initialThumbnailContextFittingSize)
                    let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                    thumbnailContext.withFlippedContext { c in
                        c.draw(image.cgImage!, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                    }
                    telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                    if let blurredThumbnailImage = thumbnailContext.generateImage(), let cgImage = blurredThumbnailImage.cgImage {
                        let fittedSize = thumbnailContext.size.aspectFilled(CGSize(width: drawingRect.size.width + 1.0, height: drawingRect.size.height + 1.0))
                        c.saveGState()
                        c.translateBy(x: drawingRect.width / 2.0, y: drawingRect.height / 2.0)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.width / 2.0, y: -drawingRect.height / 2.0)
                        c.draw(cgImage, in: CGRect(origin: CGPoint(x: (drawingRect.size.width - fittedSize.width) / 2.0, y: (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize))
                        c.restoreGState()
                    }
                }
                
                let incomingColors = [colors.1.0, colors.1.1]
                let incoming = generateGradientTintedImage(image: UIImage(bundleImageName: "Settings/ThemeBubble"), colors: incomingColors)
                
                let outgoingColors = [colors.2.0, colors.2.1]
                let outgoing = generateGradientTintedImage(image: UIImage(bundleImageName: "Settings/ThemeBubble"), colors: outgoingColors)
                
                c.translateBy(x: drawingRect.width / 2.0, y: drawingRect.height / 2.0)
                c.scaleBy(x: 1.0, y: -1.0)
                c.translateBy(x: -drawingRect.width / 2.0, y: -drawingRect.height / 2.0)
                c.draw(incoming!.cgImage!, in: CGRect(x: 9.0, y: 34.0, width: 57.0, height: 16.0))
                
                c.translateBy(x: drawingRect.width / 2.0, y: drawingRect.height / 2.0)
                c.scaleBy(x: -1.0, y: 1.0)
                c.translateBy(x: -drawingRect.width / 2.0, y: -drawingRect.height / 2.0)
                c.draw(outgoing!.cgImage!, in: CGRect(x: 9.0, y: 12.0, width: 57.0, height: 16.0))
            }
            addCorners(context, arguments: arguments)
            return context
        }
    }
}

public func wallpaperThumbnail(account: Account, accountManager: AccountManager, fileReference: FileMediaReference, wallpaper: TelegramWallpaper, synchronousLoad: Bool) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    switch wallpaper {
    case let .file(_, _, _, _, _, _, _, file, settings):
        guard let thumbnail = smallestImageRepresentation(file.previewRepresentations) else {
            return .single({ _ in nil })
        }
        let signal: Signal<Data?, NoError> = Signal { subscriber in
            let data = account.postbox.mediaBox.resourceData(thumbnail.resource).start(next: { data in
                if data.complete {
                    if let fileData = try? Data(contentsOf: URL(fileURLWithPath: data.path)) {
                        subscriber.putNext(fileData)
                    }
                }
            })
            let fetch = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: fileReference.resourceReference(thumbnail.resource)).start()

            return ActionDisposable {
                data.dispose()
                fetch.dispose()
            }
        }
        return signal
        |> map { thumbnailData in
            return { arguments in
                let drawingRect = arguments.drawingRect

                var thumbnailImage: CGImage?
                if let thumbnailData = thumbnailData {
                    if let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                        thumbnailImage = image
                    }
                }

                let context = DrawingContext(size: arguments.boundingSize, clear: true)

                context.withFlippedContext { c in
                    let colors = settings.colors.map(UIColor.init(rgb:))

                    if colors.count == 1 {
                        c.setFillColor(colors[0].cgColor)
                        c.fill(arguments.drawingRect)
                    } else if settings.colors.count >= 3 {
                        let image = GradientBackgroundNode.generatePreview(size: CGSize(width: 60.0, height: 60.0), colors: colors)
                        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                        c.draw(image.cgImage!, in: drawingRect)
                        c.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                        c.scaleBy(x: 1.0, y: -1.0)
                        c.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                    } else if settings.colors.count >= 2 {
                        let gradientColors = settings.colors.map { UIColor(rgb: $0).cgColor } as CFArray
                        let delta: CGFloat = 1.0 / (CGFloat(settings.colors.count) - 1.0)

                        var locations: [CGFloat] = []
                        for i in 0 ..< settings.colors.count {
                            locations.append(delta * CGFloat(i))
                        }
                        let colorSpace = CGColorSpaceCreateDeviceRGB()
                        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!

                        c.saveGState()
                        c.translateBy(x: arguments.drawingSize.width / 2.0, y: arguments.drawingSize.height / 2.0)
                        c.rotate(by: CGFloat(settings.rotation ?? 0) * CGFloat.pi / -180.0)
                        c.translateBy(x: -arguments.drawingSize.width / 2.0, y: -arguments.drawingSize.height / 2.0)

                        c.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: arguments.drawingSize.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                        c.restoreGState()
                    }

                    if let thumbnailImage = thumbnailImage {
                        let fittedSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height).aspectFilled(arguments.boundingSize)
                        let fittedRect = CGRect(origin: CGPoint(x: (arguments.boundingSize.width - fittedSize.width) / 2.0, y: (arguments.boundingSize.height - fittedSize.height) / 2.0), size: fittedSize)

                        c.clip(to: fittedRect, mask: thumbnailImage)

                        c.setBlendMode(.softLight)

                        if UIColor.average(of: colors).hsb.b > 0.3 {
                            c.setFillColor(UIColor(white: 0.0, alpha: 0.6).cgColor)
                        } else {
                            c.setFillColor(UIColor(white: 1.0, alpha: 0.6).cgColor)
                        }
                        c.fill(fittedRect)
                    }
                }

                addCorners(context, arguments: arguments)

                return context
            }
        }
    default:
        return .single({ _ in nil })
    }
}
