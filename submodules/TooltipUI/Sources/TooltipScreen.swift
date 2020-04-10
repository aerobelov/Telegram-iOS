import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import AnimatedStickerNode
import AppBundle
import SyncCore
import TelegramCore
import TextFormat

private final class TooltipScreenNode: ViewControllerTracingNode {
    private let icon: TooltipScreen.Icon?
    private let location: CGRect
    private let shouldDismissOnTouch: (CGPoint) -> TooltipScreen.DismissOnTouch
    private let requestDismiss: () -> Void
    
    private let scrollingContainer: ASDisplayNode
    private let containerNode: ASDisplayNode
    private let backgroundNode: ASImageNode
    private let arrowNode: ASImageNode
    private let arrowContainer: ASDisplayNode
    private let animatedStickerNode: AnimatedStickerNode
    private let textNode: ImmediateTextNode
    
    private var isArrowInverted: Bool = false
    
    init(text: String, textEntities: [MessageTextEntity], icon: TooltipScreen.Icon?, location: CGRect, shouldDismissOnTouch: @escaping (CGPoint) -> TooltipScreen.DismissOnTouch, requestDismiss: @escaping () -> Void, openUrl: @escaping (String) -> Void) {
        self.icon = icon
        self.location = location
        self.shouldDismissOnTouch = shouldDismissOnTouch
        self.requestDismiss = requestDismiss
        
        self.containerNode = ASDisplayNode()
        
        let fillColor = UIColor(white: 0.0, alpha: 0.8)
        
        self.scrollingContainer = ASDisplayNode()
        
        self.backgroundNode = ASImageNode()
        self.backgroundNode.image = generateAdjustedStretchableFilledCircleImage(diameter: 15.0, color: fillColor)
        
        self.arrowNode = ASImageNode()
        let arrowSize = CGSize(width: 29.0, height: 10.0)
        self.arrowNode.image = generateImage(arrowSize, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(fillColor.cgColor)
            context.scaleBy(x: 0.333, y: 0.333)
            let _ = try? drawSvgPath(context, path: "M85.882251,0 C79.5170552,0 73.4125613,2.52817247 68.9116882,7.02834833 L51.4264069,24.5109211 C46.7401154,29.1964866 39.1421356,29.1964866 34.4558441,24.5109211 L16.9705627,7.02834833 C12.4696897,2.52817247 6.36519576,0 0,0 L85.882251,0 ")
            context.fillPath()
        })
        
        self.arrowContainer = ASDisplayNode()
        
        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.maximumNumberOfLines = 0
        
        self.textNode.attributedText = stringWithAppliedEntities(text, entities: textEntities, baseColor: .white, linkColor: .white, baseFont: Font.regular(14.0), linkFont: Font.regular(14.0), boldFont: Font.semibold(14.0), italicFont: Font.italic(14.0), boldItalicFont: Font.semiboldItalic(14.0), fixedFont: Font.monospace(14.0), blockQuoteFont: Font.regular(14.0), underlineLinks: true, external: false)
        
        self.animatedStickerNode = AnimatedStickerNode()
        switch icon {
        case .none:
            break
        case .chatListPress:
            if let path = getAppBundle().path(forResource: "ChatListFoldersTooltip", ofType: "json") {
                self.animatedStickerNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: Int(70 * UIScreenScale), height: Int(70 * UIScreenScale), playbackMode: .once, mode: .direct)
                self.animatedStickerNode.automaticallyLoadFirstFrame = true
            }
        case .info:
            if let path = getAppBundle().path(forResource: "anim_infotip", ofType: "json") {
                self.animatedStickerNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: Int(70 * UIScreenScale), height: Int(70 * UIScreenScale), playbackMode: .once, mode: .direct)
                self.animatedStickerNode.automaticallyLoadFirstFrame = true
            }
        }
        
        super.init()
        
        self.arrowContainer.addSubnode(self.arrowNode)
        self.backgroundNode.addSubnode(self.arrowContainer)
        self.containerNode.addSubnode(self.backgroundNode)
        self.containerNode.addSubnode(self.textNode)
        self.containerNode.addSubnode(self.animatedStickerNode)
        self.scrollingContainer.addSubnode(self.containerNode)
        self.addSubnode(self.scrollingContainer)
        
        self.textNode.linkHighlightColor = UIColor.white.withAlphaComponent(0.5)
        self.textNode.highlightAttributeAction = { attributes in
            let highlightedAttributes = [
                TelegramTextAttributes.URL,
                TelegramTextAttributes.PeerMention,
                TelegramTextAttributes.PeerTextMention,
                TelegramTextAttributes.BotCommand,
                TelegramTextAttributes.Hashtag,
                TelegramTextAttributes.Timecode
            ]
            
            for attribute in highlightedAttributes {
                if let _ = attributes[NSAttributedString.Key(rawValue: attribute)] {
                    return NSAttributedString.Key(rawValue: attribute)
                }
            }
            return nil
        }
        self.textNode.tapAttributeAction = { [weak self] attributes in
            guard let strongSelf = self else {
                return
            }
            if let url = attributes[NSAttributedString.Key(rawValue: TelegramTextAttributes.URL)] as? String {
                openUrl(url)
            }
        }
    }
    
    func updateLayout(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.scrollingContainer.frame = CGRect(origin: CGPoint(), size: layout.size)
        
        let sideInset: CGFloat = 13.0
        let bottomInset: CGFloat = 10.0
        let contentInset: CGFloat = 9.0
        let contentVerticalInset: CGFloat = 11.0
        let animationSize: CGSize
        let animationInset: CGFloat
        let animationSpacing: CGFloat
        
        switch self.icon {
        case .none:
            animationSize = CGSize()
            animationInset = 0.0
            animationSpacing = 0.0
        case .chatListPress:
            animationSize = CGSize(width: 32.0, height: 32.0)
            animationInset = (70.0 - animationSize.width) / 2.0
            animationSpacing = 8.0
        case .info:
            animationSize = CGSize(width: 32.0, height: 32.0)
            animationInset = 0.0
            animationSpacing = 8.0
        }
        
        let textSize = self.textNode.updateLayout(CGSize(width: layout.size.width - contentInset * 2.0 - sideInset * 2.0 - animationSize.width - animationSpacing, height: .greatestFiniteMagnitude))
        
        let backgroundWidth = textSize.width + contentInset * 2.0 + sideInset * 2.0 + animationSize.width + animationSpacing
        let backgroundHeight = max(animationSize.height, textSize.height) + contentVerticalInset * 2.0
        var backgroundFrame = CGRect(origin: CGPoint(x: self.location.midX - backgroundWidth / 2.0, y: self.location.minY - bottomInset - backgroundHeight), size: CGSize(width: backgroundWidth, height: backgroundHeight))
        if backgroundFrame.minX < sideInset {
            backgroundFrame.origin.x = sideInset
        }
        if backgroundFrame.maxX > layout.size.width - sideInset {
            backgroundFrame.origin.x = layout.size.width - sideInset - backgroundFrame.width
        }
        var invertArrow = false
        if backgroundFrame.minY < layout.insets(options: .statusBar).top {
            backgroundFrame.origin.y = self.location.maxY + bottomInset
            invertArrow = true
        }
        self.isArrowInverted = invertArrow
        
        transition.updateFrame(node: self.containerNode, frame: backgroundFrame)
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: backgroundFrame.size))
        if let image = self.arrowNode.image {
            let arrowSize = image.size
            let arrowCenterX = self.location.midX
            
            let arrowFrame: CGRect
            
            if invertArrow {
                arrowFrame = CGRect(origin: CGPoint(x: floor(arrowCenterX - arrowSize.width / 2.0), y: -arrowSize.height), size: arrowSize)
            } else {
                arrowFrame = CGRect(origin: CGPoint(x: floor(arrowCenterX - arrowSize.width / 2.0), y: backgroundFrame.height), size: arrowSize)
            }
            
            transition.updateFrame(node: self.arrowContainer, frame: arrowFrame.offsetBy(dx: -backgroundFrame.minX, dy: 0.0))
            
            ContainedViewLayoutTransition.immediate.updateTransformScale(node: self.arrowContainer, scale: CGPoint(x: 1.0, y: invertArrow ? -1.0 : 1.0))
            
            self.arrowNode.frame = CGRect(origin: CGPoint(), size: arrowFrame.size)
        }
        
        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: contentInset + animationSize.width + animationSpacing, y: floor((backgroundHeight - textSize.height) / 2.0)), size: textSize))
        
        transition.updateFrame(node: self.animatedStickerNode, frame: CGRect(origin: CGPoint(x: contentInset - animationInset, y: floor((backgroundHeight - animationSize.height) / 2.0) - animationInset), size: CGSize(width: animationSize.width + animationInset * 2.0, height: animationSize.height + animationInset * 2.0)))
        self.animatedStickerNode.updateLayout(size: CGSize(width: animationSize.width + animationInset * 2.0, height: animationSize.height + animationInset * 2.0))
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event = event {
            if let result = self.textNode.hitTest(self.view.convert(point, to: self.textNode.view), with: event) {
                return result
            }
            
            var eventIsPresses = false
            if #available(iOSApplicationExtension 9.0, iOS 9.0, *) {
                eventIsPresses = event.type == .presses
            }
            if event.type == .touches || eventIsPresses {
                switch self.shouldDismissOnTouch(point) {
                case .ignore:
                    break
                case let .dismiss(consume):
                    self.requestDismiss()
                    if consume {
                        return self.view
                    }
                }
                return nil
            }
        }
        return super.hitTest(point, with: event)
    }
    
    func animateIn() {
        self.containerNode.layer.animateSpring(from: NSNumber(value: Float(0.01)), to: NSNumber(value: Float(1.0)), keyPath: "transform.scale", duration: 0.6)
        let arrowY: CGFloat = self.isArrowInverted ? self.arrowContainer.frame.minY : self.arrowContainer.frame.maxY
        self.containerNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: self.arrowContainer.frame.midX - self.containerNode.bounds.width / 2.0, y: arrowY - self.containerNode.bounds.height / 2.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.6, additive: true)
        self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        
        let animationDelay: Double
        switch self.icon {
        case .chatListPress:
            animationDelay = 0.6
        case .info:
            animationDelay = 0.2
        case .none:
            animationDelay = 0.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + animationDelay, execute: { [weak self] in
            self?.animatedStickerNode.visibility = true
        })
    }
    
    func animateOut(completion: @escaping () -> Void) {
        self.containerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { _ in
            completion()
        })
        self.containerNode.layer.animateScale(from: 1.0, to: 0.01, duration: 0.2, removeOnCompletion: false)
        
        let arrowY: CGFloat = self.isArrowInverted ? self.arrowContainer.frame.minY : self.arrowContainer.frame.maxY
        self.containerNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: self.arrowContainer.frame.midX - self.containerNode.bounds.width / 2.0, y: arrowY - self.containerNode.bounds.height / 2.0), duration: 0.2, removeOnCompletion: false, additive: true)
    }
    
    func addRelativeScrollingOffset(_ value: CGFloat) {
        self.scrollingContainer.bounds = self.scrollingContainer.bounds.offsetBy(dx: 0.0, dy: value)
    }
}

public final class TooltipScreen: ViewController {
    public enum Icon {
        case info
        case chatListPress
    }
    
    public enum DismissOnTouch {
        case ignore
        case dismiss(consume: Bool)
    }
    
    private let text: String
    private let textEntities: [MessageTextEntity]
    private let icon: TooltipScreen.Icon?
    private let location: CGRect
    private let shouldDismissOnTouch: (CGPoint) -> TooltipScreen.DismissOnTouch
    private let openUrl: (String) -> Void
    
    private var controllerNode: TooltipScreenNode {
        return self.displayNode as! TooltipScreenNode
    }
    
    private var validLayout: ContainerViewLayout?
    private var isDismissed: Bool = false
    
    public var becameDismissed: ((TooltipScreen) -> Void)?
    
    public init(text: String, textEntities: [MessageTextEntity] = [], icon: TooltipScreen.Icon?, location: CGRect, shouldDismissOnTouch: @escaping (CGPoint) -> TooltipScreen.DismissOnTouch, openUrl: @escaping (String) -> Void = { _ in }) {
        self.text = text
        self.textEntities = textEntities
        self.icon = icon
        self.location = location
        self.shouldDismissOnTouch = shouldDismissOnTouch
        self.openUrl = openUrl
        
        super.init(navigationBarPresentationData: nil)
        
        self.statusBar.statusBarStyle = .Ignore
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.controllerNode.animateIn()
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 20.0, execute: { [weak self] in
            self?.dismiss()
        })
    }
    
    override public func loadDisplayNode() {
        self.displayNode = TooltipScreenNode(text: self.text, textEntities: self.textEntities, icon: self.icon, location: self.location, shouldDismissOnTouch: self.shouldDismissOnTouch, requestDismiss: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.dismiss()
        }, openUrl: self.openUrl)
        self.displayNodeDidLoad()
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        if let validLayout = self.validLayout {
            if validLayout.size.width != layout.size.width {
                self.dismiss()
            }
        }
        self.validLayout = layout
        
        self.controllerNode.updateLayout(layout: layout, transition: transition)
    }
    
    public func addRelativeScrollingOffset(_ value: CGFloat) {
        self.controllerNode.addRelativeScrollingOffset(value)
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        if self.isDismissed {
            return
        }
        self.isDismissed = true
        self.controllerNode.animateOut(completion: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            let becameDismissed = strongSelf.becameDismissed
            strongSelf.presentingViewController?.dismiss(animated: false, completion: nil)
            becameDismissed?(strongSelf)
        })
    }
}
