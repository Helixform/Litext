//
//  Created by Cyandev on 2022/5/8.
//  Copyright (c) 2024 ktiays. All rights reserved.
//

#import <TargetConditionals.h>

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#import "LTXAttachment.h"
#import "LTXHighlightRegion+Private.h"
#import "LTXLabel.h"
#import "LTXTextLayout.h"

#if TARGET_OS_OSX
#import "NSBezierPath+Litext.h"

NS_INLINE NSString *NSStringFromCGRect(CGRect rect) {
    NSStringFromRect(NSRectFromCGRect(rect));
}

@interface NSValue (Litext)

@property (nonatomic, assign, readonly) CGRect CGRectValue;

@end

@implementation NSValue (Litext)

- (CGRect)CGRectValue {
    return NSRectToCGRect(self.rectValue);
}

@end
#endif

NSString *const LTXReplacementText = @"\uFFFC";

@implementation LTXLabel {
    LTXTextLayout *_textLayout;
    NSMutableSet<LTXPlatformView *> *_attachmentViews;
    NSArray<LTXHighlightRegion *> *_highlightRegions;
    LTXHighlightRegion *_activeHighlightRegion;
    CGPoint _initialTouchLocation;
    CGSize _lastContainerSize;
    struct {
        BOOL layoutIsDirty : 1;
        BOOL needsUpdateHighlightRegions : 1;
    } _flags;
    BOOL _isTouchSequenceActive;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self _commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self _commonInit];
    }
    return self;
}

- (void)_commonInit {
#if TARGET_OS_OSX
    self.wantsLayer = YES;
#endif
    _attachmentViews = [NSMutableSet set];
}

#if TARGET_OS_OSX
- (BOOL)isFlipped {
    return YES;
}
#endif

- (void)setAttributedText:(NSAttributedString *)attributedText {
    _textLayout = [LTXTextLayout textLayoutWithAttributedString:attributedText];
    [self _invalidateTextLayout];
}

- (NSAttributedString *)attributedText {
    return _textLayout.attributedString;
}

- (void)setPreferredMaxLayoutWidth:(CGFloat)preferredMaxLayoutWidth {
    _preferredMaxLayoutWidth = preferredMaxLayoutWidth;
    [self _invalidateTextLayout];
}

- (BOOL)isTouchSequenceActive {
    return _isTouchSequenceActive;
}

#pragma mark - Layout & Auto Layout Supports

- (CGSize)intrinsicContentSize {
    CGSize constraintSize = {CGFLOAT_MAX, CGFLOAT_MAX};
    CGFloat preferredMaxLayoutWidth = _preferredMaxLayoutWidth;
    if (preferredMaxLayoutWidth > 0) {
        constraintSize.width = preferredMaxLayoutWidth;
    } else if (_lastContainerSize.width > 0) {
        // We have an inferred layout width here.
        constraintSize.width = _lastContainerSize.width;
    }
    return [_textLayout suggestContainerSizeWithSize:constraintSize];
}

#if TARGET_OS_IOS
- (void)layoutSubviews {
    [super layoutSubviews];
#elif TARGET_OS_OSX
- (void)layout {
    [super layout];
#endif

    // Only update layout when the view's bounds changed.
    CGSize containerSize = self.bounds.size;
    if (_flags.layoutIsDirty || !CGSizeEqualToSize(_lastContainerSize, containerSize)) {
        if (_flags.layoutIsDirty || containerSize.width != _lastContainerSize.width) {
            // This is the magic that makes Auto Layout works with this view.
            // See `intrinsicContentSize` method for more details.
            [self invalidateIntrinsicContentSize];
        }

        _lastContainerSize = containerSize;
        _textLayout.containerSize = containerSize;
        _flags.needsUpdateHighlightRegions = YES;
        _flags.layoutIsDirty = NO;

        // Must display once after the layout changed, that will also update
        // the text layout and highlight regions.
        [self _setNeedsDisplay];
    }
}

#if TARGET_OS_IOS
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self _invalidateTextLayout];
}
#endif

- (void)_setNeedsLayout {
#if TARGET_OS_IOS
    [self setNeedsLayout];
#elif TARGET_OS_OSX
    self.needsLayout = YES;
#endif
}

- (void)_setNeedsDisplay {
#if TARGET_OS_IOS
    [self setNeedsDisplay];
#elif TARGET_OS_OSX
    self.needsDisplay = YES;
#endif
}

#pragma mark - Rendering

#if TARGET_OS_IOS
- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
#elif TARGET_OS_OSX
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
#endif

    if (_flags.needsUpdateHighlightRegions) {
        // We need to update highlight regions within `drawRect:` because an
        // `CGContextRef` is required for getting the image bounds of glyph
        // runs. This process will make our view's layout dirty, but that will
        // not trigger this process again, which is ensured by `layoutSubviews`
        // implementation.
        [_textLayout updateHighlightRegionsWithContext:context];
        _highlightRegions = _textLayout.highlightRegions;

        // Also update attachment views when highlight regions changed.
        [self _updateAttachmentViews];

        _flags.needsUpdateHighlightRegions = NO;
    }

    [_textLayout drawInContext:context];
}

#pragma mark - Interaction Handling

#if TARGET_OS_IOS
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!CGRectContainsPoint(self.bounds, point)) {
        return NO;
    }

    return [self _highlightRegionAtPoint:point] != nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *firstTouch = [touches allObjects].firstObject;
    CGPoint touchLocation = [firstTouch locationInView:self];

    _initialTouchLocation = touchLocation;
    
    __auto_type hitHighlightRegion = [self _highlightRegionAtPoint:touchLocation];
    if (hitHighlightRegion) {
        [self _addActiveHighlightRegion:hitHighlightRegion];
    }
    _isTouchSequenceActive = YES;
}
    
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_activeHighlightRegion) { return; }
    
    UITouch *firstTouch = [touches allObjects].firstObject;
    CGPoint currentLocation = [firstTouch locationInView:self];
    
    CGFloat distance = hypot(currentLocation.x - _initialTouchLocation.x, 
                           currentLocation.y - _initialTouchLocation.y);
    
    if (distance > 8.0) { // touch really moved
        [self _removeActiveHighlightRegion];
        _isTouchSequenceActive = NO;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    __auto_type activeHighlightRegion = _activeHighlightRegion;
    if (!activeHighlightRegion) {
        _isTouchSequenceActive = NO;
        return;
    }

    // FIXME: this will only support one touch point.
    UITouch *firstTouch = [touches allObjects].firstObject;
    CGPoint touchLocation = [firstTouch locationInView:self];

    if ([self _isHighlightRegion:activeHighlightRegion containsPoint:touchLocation]) {
        __auto_type tapHandler = self.tapHandler;
        if (tapHandler) {
            tapHandler(activeHighlightRegion, touchLocation);
        }
    }

    [self _removeActiveHighlightRegion];
    _isTouchSequenceActive = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self _removeActiveHighlightRegion];
}
#elif TARGET_OS_OSX
#endif

#pragma mark - Debugging & Reflection

- (NSString *)debugDescription {
    NSMutableString *description = [NSMutableString string];
    [description appendFormat:@"<%@: %p;", NSStringFromClass([self class]), self];
    [description appendFormat:@" frame = %@;", NSStringFromCGRect(self.frame)];
#if TARGET_OS_IOS
    [description appendFormat:@" userInteractionEnabled = %@;", self.userInteractionEnabled ? @"YES" : @"NO"];
#endif
    [description appendFormat:@" attributedText = %@;", self.attributedText];
    [description appendFormat:@" layer = %@>", self.layer];
    return [description copy];
}

#pragma mark - Text Layout

- (void)_invalidateTextLayout {
    _flags.layoutIsDirty = YES;
    [self _setNeedsLayout];
    [self invalidateIntrinsicContentSize];
}

#pragma mark - Highlight Region

- (LTXHighlightRegion *)_highlightRegionAtPoint:(CGPoint)point {
    for (LTXHighlightRegion *highlightRegion in _highlightRegions) {
        if ([self _isHighlightRegion:highlightRegion containsPoint:point]) {
            return highlightRegion;
        }
    }
    return nil;
}

- (BOOL)_isHighlightRegion:(LTXHighlightRegion *)highlightRegion containsPoint:(CGPoint)point {
    for (NSValue *boxedRect in highlightRegion.rects) {
        CGRect convertedRect = [self _convertRectFromTextLayout:boxedRect.CGRectValue forInteraction:YES];
        if (CGRectContainsPoint(convertedRect, point)) {
            return YES;
        }
    }
    return NO;
}

- (CGRect)_convertRectFromTextLayout:(CGRect)rect forInteraction:(BOOL)interaction {
    rect.origin.y = CGRectGetHeight(self.bounds) - rect.origin.y - rect.size.height;
    if (interaction) {
        rect = CGRectInset(rect, -4, -4);
    }
    return rect;
}

- (void)_addActiveHighlightRegion:(LTXHighlightRegion *)highlightRegion {
    [self _removeActiveHighlightRegion];

    if (!highlightRegion) {
        return;
    }

    _activeHighlightRegion = highlightRegion;

    // Construct the highlight path.
    LTXPlatformBezierPath *highlightPath = [[LTXPlatformBezierPath alloc] init];
    for (NSValue *boxedRect in highlightRegion.rects) {
        CGRect convertedRect = [self _convertRectFromTextLayout:boxedRect.CGRectValue forInteraction:YES];
        LTXPlatformBezierPath *subpath = [LTXPlatformBezierPath bezierPathWithRoundedRect:convertedRect cornerRadius:4];
        [highlightPath appendPath:subpath];
    }

    // Determine the highlight color.
    PlatformColor *highlightColor = highlightRegion.attributes[NSForegroundColorAttributeName];
    if (!highlightColor) {
        highlightColor = [PlatformColor linkColor];
    }

    CAShapeLayer *highlightLayer = [CAShapeLayer layer];
#if TARGET_OS_OSX
    highlightLayer.path = [highlightPath quartzPath];
#else
    highlightLayer.path = highlightPath.CGPath;
#endif
    highlightLayer.fillColor = [highlightColor colorWithAlphaComponent:0.1].CGColor;
    [self.layer addSublayer:highlightLayer];

    highlightRegion.associatedObject = highlightLayer;
}

- (void)_removeActiveHighlightRegion {
    __auto_type activeHighlightRegion = _activeHighlightRegion;
    if (!activeHighlightRegion) {
        return;
    }

    CALayer *highlightLayer = activeHighlightRegion.associatedObject;
    highlightLayer.opacity = 0;
    // Defer the remove operation for implicit animations.
    [NSTimer scheduledTimerWithTimeInterval:0.4
                                    repeats:NO
                                      block:^(NSTimer *timer) {
                                          [highlightLayer removeFromSuperlayer];
                                      }];
    activeHighlightRegion.associatedObject = nil;

    _activeHighlightRegion = nil;
}

#pragma mark - Attachment

- (void)_updateAttachmentViews {
    // The set holds views that are no longer reusable by the new layout. Reusable
    // views are updated in-place without being removed from its superview, which
    // can improve the updating performance.
    NSMutableSet<LTXPlatformView *> *viewsToRemove = [_attachmentViews mutableCopy];

    for (LTXHighlightRegion *highlightRegion in _highlightRegions) {
        LTXAttachment *attachment = highlightRegion.attributes[LTXAttachmentAttributeName];
        if (!attachment) {
            continue;
        }

        LTXPlatformView *view = attachment.view;
        if (view.superview == self) {
            // The view is reused, remove it from the garbage set.
            [viewsToRemove removeObject:view];
        } else {
            [self addSubview:view];
            [_attachmentViews addObject:view];
        }

        CGRect convertedRect = [self _convertRectFromTextLayout:highlightRegion.rects.firstObject.CGRectValue forInteraction:NO];
        view.frame = convertedRect;
    }

    // Evict the garbage views.
    __auto_type attachmentViews = _attachmentViews;
    [viewsToRemove enumerateObjectsUsingBlock:^(LTXPlatformView *obj, BOOL *stop) {
        [obj removeFromSuperview];
        [attachmentViews removeObject:obj];
    }];
}

@end
