//
//  Created by Cyandev on 2022/5/8.
//  Copyright (c) 2024 ktiays. All rights reserved.
//

#import "LTXPlatformTypes.h"

@class LTXHighlightRegion;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const LTXReplacementText;

typedef void (^LTXLabelTapHandler)(LTXHighlightRegion *_Nullable highlightRegion);

/// A view that displays the multiline rich text.
@interface LTXLabel : LTXPlatformView

/// The styled text that the label displays.
@property (nonatomic, nullable, copy) NSAttributedString *attributedText;

/// The preferred maximum width, in points, for a multiline label.
@property (nonatomic, assign) CGFloat preferredMaxLayoutWidth;

/// A block that is invoked when the user taps an interactive element.
@property (nonatomic, copy) LTXLabelTapHandler tapHandler;

/// A value indicating whether the label is waiting to perform operations on highlighted items.
@property (nonatomic, readonly) BOOL isTouchSequenceActive;

@end

NS_ASSUME_NONNULL_END
