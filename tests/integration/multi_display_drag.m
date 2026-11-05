#import <Cocoa/Cocoa.h>

// Owns every test window. Stdin commands exercise AppKit and never synthesize input.
static NSWindow *primary, *anchor, *auxiliary, *tab;
static unsigned int sequence;

static NSWindow *make_window(NSString *title, NSString *group)
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 650, 500)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = title;
    window.releasedWhenClosed = NO;
    window.tabbingMode = group ? NSWindowTabbingModePreferred : NSWindowTabbingModeDisallowed;
    if (group) window.tabbingIdentifier = group;

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 170, 570, 200)];
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = [NSFont systemFontOfSize:22];
    label.stringValue = [NSString stringWithFormat:@"%@\n\nDrag the title bar between displays.\nThis window contains only test content.", title];
    [window.contentView addSubview:label];
    [label release];
    return window;
}

static void close_window(NSWindow **window)
{
    [*window close];
    [*window release];
    *window = nil;
}

static void report(void)
{
    printf("{\"sequence\":%u,\"primary\":%ld,\"anchor\":%ld,\"auxiliary\":%ld,\"tab\":%ld}\n",
        sequence++, primary ? (long)primary.windowNumber : 0,
        anchor ? (long)anchor.windowNumber : 0,
        auxiliary ? (long)auxiliary.windowNumber : 0,
        tab ? (long)tab.windowNumber : 0);
}

int main(void)
{
    @autoreleasepool {
        setbuf(stdout, NULL);
        [NSApplication sharedApplication];
        NSWindow.allowsAutomaticWindowTabbing = NO;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        dispatch_async(dispatch_get_main_queue(), ^{
            primary = make_window(@"Drag primary", @"multi-display-primary");
            [primary makeKeyAndOrderFront:nil];
            anchor = make_window(@"Drag anchor", nil);
            [anchor makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            report();
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char line[64];
            while (fgets(line, sizeof(line), stdin)) {
                NSString *command = [[[NSString stringWithUTF8String:line]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([command isEqualToString:@"auxiliary"] && !auxiliary) {
                        auxiliary = make_window(@"Drag reconciliation trigger", nil);
                        [auxiliary makeKeyAndOrderFront:nil];
                    } else if ([command isEqualToString:@"close-auxiliary"]) {
                        close_window(&auxiliary);
                    } else if ([command isEqualToString:@"add-tab"] && !tab) {
                        tab = make_window(@"Drag native tab", primary.tabbingIdentifier);
                        [primary addTabbedWindow:tab ordered:NSWindowAbove];
                        [tab makeKeyAndOrderFront:nil];
                    } else if ([command isEqualToString:@"primary"]) {
                        [primary makeKeyAndOrderFront:nil];
                    } else if ([command isEqualToString:@"tab"]) {
                        [tab makeKeyAndOrderFront:nil];
                    } else if ([command isEqualToString:@"detach-tab"]) {
                        [tab.tabGroup removeWindow:tab];
                        [tab makeKeyAndOrderFront:nil];
                    } else if ([command isEqualToString:@"quit"]) {
                        [NSApp terminate:nil];
                    }
                    report();
                    [command release];
                });
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
        [NSApp run];
    }
    return 0;
}
