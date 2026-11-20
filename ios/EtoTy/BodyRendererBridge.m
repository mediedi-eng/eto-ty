#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "EtoTy-Swift.h"
#import "BodyRenderer.h"

@interface ETBodyRenderer : NSObject <ETBodyRendering>
@end

@implementation ETBodyRenderer
+ (int32_t)renderMesh:(const void *)mesh length:(NSInteger)length
                rgba:(uint8_t *)rgba regions:(uint8_t *)regions
               width:(int32_t)width height:(int32_t)height
                 yaw:(float)yaw zoom:(float)zoom selection:(int32_t)selection {
    return body_render(mesh, (size_t)length, rgba, regions, width, height, yaw, zoom, selection);
}
@end
