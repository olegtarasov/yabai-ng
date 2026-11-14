#import <Cocoa/Cocoa.h>

// The app enters native fullscreen itself. It never repairs focus after the
// transition, so an external window manager stealing focus stays observable.
static NSWindow *window;

static void report(const char *event)
{
    printf("state %s %ld %d %d %d\n", event, (long)window.windowNumber,
           (window.styleMask & NSWindowStyleMaskFullScreen) != 0,
           window.isKeyWindow, NSApp.isActive);
}

@interface FullscreenDelegate : NSObject <NSWindowDelegate>
@end
@implementation FullscreenDelegate
- (void)windowDidEnterFullScreen:(NSNotification *)notification { report("enter"); }
- (void)windowDidExitFullScreen:(NSNotification *)notification { report("exit"); }
- (void)windowDidFailToEnterFullScreen:(NSWindow *)sender { report("failed-enter"); }
- (void)windowDidFailToExitFullScreen:(NSWindow *)sender { report("failed-exit"); }
@end

int main(void)
{
    @autoreleasepool {
        setbuf(stdout, NULL);
        [NSApplication sharedApplication];
        NSWindow.allowsAutomaticWindowTabbing = NO;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        FullscreenDelegate *delegate = [FullscreenDelegate new];
        dispatch_async(dispatch_get_main_queue(), ^{
            window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 700, 500)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            window.title = @"Unmanaged fullscreen fixture";
            window.tabbingMode = NSWindowTabbingModeDisallowed;
            window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
            window.delegate = delegate;
            window.releasedWhenClosed = NO;
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            report("ready");
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char line[64];
            while (fgets(line, sizeof(line), stdin)) {
                NSString *command = [[NSString alloc] initWithUTF8String:line];
                dispatch_async(dispatch_get_main_queue(), ^{
                    bool fullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
                    if ([command hasPrefix:@"enter"] && !fullscreen) [window toggleFullScreen:nil];
                    else if ([command hasPrefix:@"exit"] && fullscreen) [window toggleFullScreen:nil];
                    else if ([command hasPrefix:@"quit"]) [NSApp terminate:nil];
                    else report("status");
                    [command release];
                });
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
        [NSApp run];
        [delegate release];
    }
    return 0;
}
