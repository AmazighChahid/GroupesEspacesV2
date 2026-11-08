#import "DockRenderer.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@interface CALayer (NativeBezel)
- (instancetype)initWithScaleFactor:(float)scale supportsHDR:(BOOL)hdr
               hasSpecialFirstItem:(BOOL)special rtl:(BOOL)rtl delegate:(id)delegate;
- (void)addIcon:(id)image usesGlass:(BOOL)glass glassCompositingFilter:(id)filter
          title:(NSString *)title label:(id)label progress:(float)progress
          screenTimeRestriction:(NSInteger)restriction;
- (void)layout;
- (NSInteger)selectedIndex;
- (void)setSelectedIndex:(NSInteger)index;
- (NSArray<CALayer *> *)axItemLayers;
- (CALayer *)_materialRootLayer;
- (void)_setMaterialLayerFrame:(CGRect)frame tileSize:(unsigned int)tileSize;
@end

@interface NSObject (DockMaterialEnvironment)
- (void)setDisplayScale:(CGFloat)scale;
- (void)setColorScheme:(NSInteger)scheme;
- (void)setColorSchemeContrast:(NSInteger)contrast;
- (void)setAccessibilityReduceTransparency:(BOOL)enabled;
@end

static CGFloat displayScale = 2;

static id StandaloneEnvironment(id cls, SEL selector, NSInteger scheme) {
    id environment = [NSClassFromString(@"DockGlassMaterialEnvironment") new];
    [environment setDisplayScale:displayScale];
    [environment setColorScheme:scheme];
    [environment setColorSchemeContrast:NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast];
    [environment setAccessibilityReduceTransparency:NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency];
    return environment;
}

static BOOL LoadDockLayers(void) {
    static dispatch_once_t once;
    static BOOL available;
    dispatch_once(&once, ^{
        const char *path = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";
        if (dlopen(path, RTLD_NOW | RTLD_LOCAL) == NULL) return;
        Class provider = NSClassFromString(@"DockGlassMaterialLayerController");
        Class environment = NSClassFromString(@"DockGlassMaterialEnvironment");
        Class bezel = NSClassFromString(@"BezelIconListLayer");
        Method method = class_getClassMethod(provider, NSSelectorFromString(@"currentDockMaterialEnvironmentWithColorScheme:"));
        Method initializer = class_getInstanceMethod(bezel,
            @selector(initWithScaleFactor:supportsHDR:hasSpecialFirstItem:rtl:delegate:));
        Method addIcon = class_getInstanceMethod(bezel,
            @selector(addIcon:usesGlass:glassCompositingFilter:title:label:progress:screenTimeRestriction:));
        if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8q16") || !environment ||
            !initializer || strcmp(method_getTypeEncoding(initializer), "@40@0:8f16B20B24B28@32") ||
            !addIcon || strcmp(method_getTypeEncoding(addIcon), "v64@0:8@16B24@28@36@44f52q56")) return;
        // The replacement affects only this app's copy of the Objective-C class.
        method_setImplementation(method, (IMP)StandaloneEnvironment);
        available = YES;
    });
    return available;
}

@implementation GELayerRenderer

+ (instancetype)rendererWithScale:(CGFloat)scale frame:(CGRect)frame {
    if (!LoadDockLayers()) return nil;
    displayScale = scale;
    GELayerRenderer *renderer = [GELayerRenderer new];
    renderer->_layer = [[NSClassFromString(@"BezelIconListLayer") alloc]
        initWithScaleFactor:(float)scale supportsHDR:NO hasSpecialFirstItem:NO rtl:NO delegate:nil];
    if (!renderer->_layer) return nil;
    renderer->_layer.contentsScale = scale;
    renderer->_layer.frame = frame;
    return renderer;
}

- (void)addIcon:(CGImageRef)icon title:(NSString *)title {
    [_layer addIcon:(__bridge id)icon usesGlass:NO glassCompositingFilter:nil
              title:title label:nil progress:-1 screenTimeRestriction:0];
}

- (void)layout {
    [_layer layout];
    [_layer setSelectedIndex:-1];
}

- (NSInteger)selection { return [_layer selectedIndex]; }

- (void)setSelection:(NSInteger)selection { [_layer setSelectedIndex:selection]; }

- (CGRect)bezelFrame {
    if (![_layer respondsToSelector:@selector(_materialRootLayer)]) return CGRectNull;
    CALayer *material = [_layer _materialRootLayer];
    return material ? [_layer convertRect:material.bounds fromLayer:material] : CGRectNull;
}

- (BOOL)setBezelFrame:(CGRect)frame tileSize:(unsigned int)tileSize {
    SEL selector = @selector(_setMaterialLayerFrame:tileSize:);
    Method method = class_getInstanceMethod(_layer.class, selector);
    if (!method || strcmp(method_getTypeEncoding(method), "v52@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16I48")) {
        return NO;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_layer _setMaterialLayerFrame:frame tileSize:tileSize];
    [CATransaction commit];
    return YES;
}

- (CGRect)itemFrameAtIndex:(NSInteger)index {
    NSArray<CALayer *> *tiles = [_layer axItemLayers];
    if (index < 0 || (NSUInteger)index >= tiles.count) return CGRectNull;
    CALayer *tile = tiles[index];
    return [_layer convertRect:tile.bounds fromLayer:tile];
}

- (NSInteger)itemAtPoint:(CGPoint)point {
    NSArray<CALayer *> *tiles = [_layer axItemLayers];
    for (NSUInteger index = 0; index < tiles.count; ++index) {
        CALayer *tile = tiles[index];
        if (CGRectContainsPoint([_layer convertRect:tile.bounds fromLayer:tile], point)) {
            return (NSInteger)index;
        }
    }
    return NSNotFound;
}

@end
