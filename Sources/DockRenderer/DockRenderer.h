#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface GELayerRenderer : NSObject
+ (nullable GELayerRenderer *)rendererWithScale:(CGFloat)scale frame:(CGRect)frame NS_SWIFT_NAME(make(scale:frame:));
@property(nonatomic, readonly) CALayer *layer;
@property(nonatomic) NSInteger selection;
@property(nonatomic, readonly) CGRect bezelFrame;
- (BOOL)setBezelFrame:(CGRect)frame tileSize:(unsigned int)tileSize;
- (BOOL)hideBezelMaterial;
- (CGRect)iconFrameAtIndex:(NSInteger)index image:(CGImageRef)image NS_SWIFT_NAME(iconFrame(at:image:));
- (void)addIcon:(CGImageRef)icon title:(NSString *)title NS_SWIFT_NAME(addIcon(_:title:));
- (void)layout;
- (NSInteger)itemAtPoint:(CGPoint)point NS_SWIFT_NAME(item(at:));
@end

NS_ASSUME_NONNULL_END
