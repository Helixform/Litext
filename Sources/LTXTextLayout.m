//
//  Created by Cyandev on 2022/5/8.
//  Copyright (c) 2024 ktiays. All rights reserved.
//

#import <CoreText/CoreText.h>

#import "LTXAttachment.h"
#import "LTXHighlightRegion+Private.h"
#import "LTXLineDrawingAction.h"
#import "LTXTextLayout.h"

static const CFRange kZeroRange = {0, 0};
static NSString *const kTruncationToken = @"\u2026";

static BOOL _hasHighlightAttributes(NSDictionary *attributes) {
    if ([attributes objectForKey:NSLinkAttributeName]) {
        return YES;
    }
    if ([attributes objectForKey:LTXAttachmentAttributeName]) {
        return YES;
    }
    return NO;
}

static _Nullable CTLineRef _createTruncatedLine(CTLineRef lastLine, NSAttributedString *attrString, CGFloat width) {
    // Determine the truncation token attributes. We use the last run's
    // attributes (if any) and strip some unsupported attribute keys.
    NSMutableDictionary *truncationTokenAttributes = [NSMutableDictionary dictionary];
    NSArray *lastLineGlyphRuns = (NSArray *) CTLineGetGlyphRuns(lastLine);
    CTRunRef lastGlyphRun = (__bridge CTRunRef) lastLineGlyphRuns.lastObject;
    if (lastGlyphRun) {
        NSDictionary *lastRunAttributes = (NSDictionary *) CTRunGetAttributes(lastGlyphRun);
#define _COPY_ATTR(key) \
    do { \
        id attr = lastRunAttributes[(key)]; \
        if (attr) { \
            truncationTokenAttributes[(key)] = attr; \
        } \
    } while (0)

        _COPY_ATTR(NSFontAttributeName);
        _COPY_ATTR(NSForegroundColorAttributeName);
        _COPY_ATTR(NSParagraphStyleAttributeName);

#undef _COPY_ATTR
    }

    NSAttributedString *truncationTokenString = [[NSAttributedString alloc] initWithString:kTruncationToken attributes:truncationTokenAttributes];
    CTLineRef truncationLine = CTLineCreateWithAttributedString((CFAttributedStringRef) truncationTokenString);

    CFRange lastLineStringCFRange = CTLineGetStringRange(lastLine);
    NSRange lastLineStringRange = {lastLineStringCFRange.location, lastLineStringCFRange.length};
    NSMutableAttributedString *lastLineString = [[attrString attributedSubstringFromRange:lastLineStringRange] mutableCopy];
    [lastLineString appendAttributedString:truncationTokenString];
    // Note: a new object allocated.
    lastLine = CTLineCreateWithAttributedString((CFAttributedStringRef) lastLineString);

    CTLineRef truncatedLine = CTLineCreateTruncatedLine(lastLine, width, kCTLineTruncationEnd, truncationLine);

    CFRelease(truncationLine);
    CFRelease(lastLine);

    return truncatedLine;
}

@interface LTXTextLayout ()

@property (nonatomic, readwrite, copy) NSAttributedString *attributedString;

@end

@implementation LTXTextLayout {
    CTFramesetterRef _framesetter;
    CTFrameRef _ctFrame;
    NSArray *_lines;
    NSMutableDictionary<NSNumber *, LTXHighlightRegion *> *_highlightRegions;
    NSMutableSet<LTXLineDrawingAction *> *_lineDrawingActions;
}

+ (instancetype)textLayoutWithAttributedString:(NSAttributedString *)attributedString {
    return [[self alloc] initWithAttributedString:attributedString];
}

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString {
    self = [super init];
    if (self) {
        _attributedString = attributedString;
        _framesetter = CTFramesetterCreateWithAttributedString((CFAttributedStringRef) _attributedString);
        _highlightRegions = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    if (_framesetter) {
        CFRelease(_framesetter);
        _framesetter = NULL;
    }
    
    if (_ctFrame) {
        CFRelease(_ctFrame);
        _ctFrame = NULL;
    }
    
    [_highlightRegions removeAllObjects];
    _highlightRegions = nil;
    
    [_lineDrawingActions removeAllObjects];
    _lineDrawingActions = nil;
    
    _lines = nil;
    _attributedString = nil;
}

- (NSArray<LTXHighlightRegion *> *)highlightRegions {
    return [_highlightRegions allValues];
}

- (void)setContainerSize:(CGSize)containerSize {
    _containerSize = containerSize;
    [self _generateLayout];
}

- (void)invalidateLayout {
    [self _generateLayout];
}

- (CGSize)suggestContainerSizeWithSize:(CGSize)size {
    return CTFramesetterSuggestFrameSizeWithConstraints(_framesetter, kZeroRange, NULL, size, NULL);
}

- (void)drawInContext:(CGContextRef)context {
    if (!_lineDrawingActions) {
        _lineDrawingActions = [NSMutableSet set];
    }
    [_lineDrawingActions removeAllObjects];

    CGContextSaveGState(context);

    // Flip the rendering coordinate.
    CGSize containerSize = _containerSize;
    CGContextTranslateCTM(context, 0, containerSize.height);
    CGContextScaleCTM(context, 1, -1);

    CTFrameDraw(_ctFrame, context);

    [self _enumerateLinesUsingBlock:^(CTLineRef line, NSUInteger idx, CGPoint lineOrigin) {
        NSArray *glyphRuns = (NSArray *) CTLineGetGlyphRuns(line);

        [glyphRuns enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            CTRunRef glyphRun = (__bridge CTRunRef) obj;

            NSDictionary *attributes = (NSDictionary *) CTRunGetAttributes(glyphRun);
            LTXLineDrawingAction *action;
            if ((action = [attributes objectForKey:LTXLineDrawingCallbackName])) {
                if ([_lineDrawingActions containsObject:action]) {
                    return;
                }
                CGContextSaveGState(context);
                action.action(context, line, lineOrigin);
                CGContextRestoreGState(context);
                if (action.performOncePerAttribute) {
                    [_lineDrawingActions addObject:action];
                }
            }
        }];
    }];

    CGContextRestoreGState(context);
}

- (void)updateHighlightRegionsWithContext:(CGContextRef)context {
    [_highlightRegions removeAllObjects];
    [self _extractHighlightRegionsWithContext:context];
}

- (void)_generateLayout {
    if (_ctFrame) {
        CFRelease(_ctFrame);
        _ctFrame = nil;
        _lines = nil;
    }

    CGRect containerBounds = {.origin = CGPointZero, .size = _containerSize};
    CGPathRef containerPath = CGPathCreateWithRect(containerBounds, NULL);
    _ctFrame = CTFramesetterCreateFrame(_framesetter, kZeroRange, containerPath, NULL);
    _lines = (NSArray *) CTFrameGetLines(_ctFrame);

    // Handle line truncation.
    CFRange visibleRange = CTFrameGetVisibleStringRange(_ctFrame);
    if (visibleRange.length == _attributedString.length || _lines.count == 0) {
        CGPathRelease(containerPath);
        return;
    }

    CTLineRef lastLine = (__bridge CTLineRef) _lines.lastObject;
    CTLineRef truncatedLine = _createTruncatedLine(lastLine, _attributedString, CGRectGetWidth(containerBounds));

    if (truncatedLine) {
        NSMutableArray *lines = [_lines mutableCopy];
        lines[lines.count - 1] = (__bridge_transfer id) truncatedLine;
        _lines = [lines copy];
    }
    CGPathRelease(containerPath);
}

- (void)_extractHighlightRegionsWithContext:(CGContextRef)context {
    __auto_type attributedString = _attributedString;
    __auto_type highlightRegions = _highlightRegions;

    [self _enumerateLinesUsingBlock:^(CTLineRef line, NSUInteger idx, CGPoint lineOrigin) {
        NSArray *glyphRuns = (NSArray *) CTLineGetGlyphRuns(line);

        [glyphRuns enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            CTRunRef glyphRun = (__bridge CTRunRef) obj;
            NSDictionary *attributes = (NSDictionary *) CTRunGetAttributes(glyphRun);
            if (!_hasHighlightAttributes(attributes)) {
                return;
            }

            NSRange effectiveRange;
            CFRange cfStringRange = CTRunGetStringRange(glyphRun);
            NSRange stringRange = {cfStringRange.location, cfStringRange.length};
            [attributedString attributesAtIndex:stringRange.location effectiveRange:&effectiveRange];

            // Merge all highlight regions by attribute groups (with the same effective range).
            LTXHighlightRegion *highlightRegion = highlightRegions[@(effectiveRange.location)];
            if (!highlightRegion) {
                highlightRegion = [[LTXHighlightRegion alloc] initWithAttributes:attributes stringRange:stringRange];
                highlightRegions[@(effectiveRange.location)] = highlightRegion;
            }

            CGRect runBounds = CTRunGetImageBounds(glyphRun, context, kZeroRange);
            LTXAttachment *attachment;
            if ((attachment = [attributes objectForKey:LTXAttachmentAttributeName])) {
                runBounds.size = attachment.size;
                runBounds.origin.y -= attachment.size.height * 0.1;
            }
            runBounds.origin.x += lineOrigin.x;
            runBounds.origin.y += lineOrigin.y;
            [highlightRegion addRect:runBounds];
        }];
    }];
}

- (void)_enumerateLinesUsingBlock:(void (^)(CTLineRef line, NSUInteger idx, CGPoint origin))block {
    NSArray *lines = _lines;
    CGPoint *lineOrigins = malloc(sizeof(CGPoint) * lines.count);
    CTFrameGetLineOrigins(_ctFrame, kZeroRange, lineOrigins);

    [lines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        CTLineRef line = (__bridge CTLineRef) obj;
        CGPoint lineOrigin = lineOrigins[idx];
        block(line, idx, lineOrigin);
    }];

    free(lineOrigins);
}

@end
