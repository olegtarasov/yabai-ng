#import <Cocoa/Cocoa.h>

// A disposable real app for exercising WindowServer and AX notification delivery.
// Commands arrive over stdin; no Accessibility input synthesis is involved.
static NSWindow *primary;
static NSWindow *secondary;

static NSWindow *make_window(NSString *title)
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 600, 500)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered defer:NO];
    window.title = title;
    window.releasedWhenClosed = NO;
    return window;
}

int main(void)
{
    @autoreleasepool {
        setbuf(stdout, NULL);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        dispatch_async(dispatch_get_main_queue(), ^{
            primary = make_window(@"Visibility primary");
            [primary makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            printf("primary %ld\n", (long)primary.windowNumber);
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char line[64];
            while (fgets(line, sizeof(line), stdin)) {
                NSString *command = [[NSString alloc] initWithUTF8String:line];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([command hasPrefix:@"new"]) {
                        secondary = make_window(@"Visibility secondary");
                        [secondary makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"out"]) {
                        [secondary orderOut:nil];
                    } else if ([command hasPrefix:@"in"]) {
                        [secondary makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"background-out"]) {
                        [primary orderOut:nil];
                    } else if ([command hasPrefix:@"background-in"]) {
                        [primary orderFront:nil];
                    } else if ([command hasPrefix:@"minimize"]) {
                        [secondary miniaturize:nil];
                    } else if ([command hasPrefix:@"restore"]) {
                        [secondary deminiaturize:nil];
                    } else if ([command hasPrefix:@"destroy"]) {
                        [secondary close];
                        [secondary release];
                        secondary = nil;
                    } else if ([command hasPrefix:@"hide"]) {
                        [NSApp hide:nil];
                    } else if ([command hasPrefix:@"show"]) {
                        [NSApp unhide:nil];
                    } else if ([command hasPrefix:@"quit"]) {
                        [NSApp terminate:nil];
                    }
                    printf("secondary %ld\n", secondary ? (long)secondary.windowNumber : 0L);
                    [command release];
                });
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
        [NSApp run];
    }
    return 0;
}
