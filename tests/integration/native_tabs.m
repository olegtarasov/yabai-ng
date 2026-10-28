#import <Cocoa/Cocoa.h>

// Real native tab groups. Commands exercise the app, not synthetic AX input.
static NSWindow *first, *second, *third, *independent;
static int generation;

static NSWindow *make_window(NSString *title, NSString *group)
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 650, 500)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = title;
    window.releasedWhenClosed = NO;
    window.tabbingMode = NSWindowTabbingModePreferred;
    window.tabbingIdentifier = group;
    return window;
}

static void create_group(void)
{
    NSString *group = [NSString stringWithFormat:@"fixture-%d", ++generation];
    first = make_window(@"Tab first", group);
    [first makeKeyAndOrderFront:nil];
}

static void close_window(NSWindow **window)
{
    [*window close]; [*window release]; *window = nil;
}

static void report(void)
{
    printf("state %ld %ld %ld %ld\n", first ? (long)first.windowNumber : 0,
        second ? (long)second.windowNumber : 0, third ? (long)third.windowNumber : 0,
        independent ? (long)independent.windowNumber : 0);
}

int main(void)
{
    @autoreleasepool {
        setbuf(stdout, NULL);
        [NSApplication sharedApplication];
        NSWindow.allowsAutomaticWindowTabbing = NO;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        dispatch_async(dispatch_get_main_queue(), ^{
            create_group(); [NSApp activateIgnoringOtherApps:YES]; report();
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char line[64];
            while (fgets(line, sizeof(line), stdin)) {
                NSString *command = [[NSString alloc] initWithUTF8String:line];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([command hasPrefix:@"add-second"]) {
                        second = make_window(@"Tab second", first.tabbingIdentifier);
                        [first addTabbedWindow:second ordered:NSWindowAbove];
                        [second makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"add-third"]) {
                        third = make_window(@"Tab third", first.tabbingIdentifier);
                        [first addTabbedWindow:third ordered:NSWindowAbove];
                        [third makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"first"]) {
                        [first makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"second"]) {
                        [second makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"third"]) {
                        [third makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"independent"]) {
                        independent = make_window(@"Independent", @"independent");
                        independent.tabbingMode = NSWindowTabbingModeDisallowed;
                        [independent makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"detach-second"]) {
                        [second.tabGroup removeWindow:second]; [second makeKeyAndOrderFront:nil];
                    } else if ([command hasPrefix:@"displace"]) {
                        [NSApp.keyWindow setFrame:NSMakeRect(120, 120, 700, 600) display:YES];
                    } else if ([command hasPrefix:@"close-first"]) {
                        close_window(&first);
                    } else if ([command hasPrefix:@"close-independent"]) {
                        close_window(&independent);
                    } else if ([command hasPrefix:@"recreate"]) {
                        close_window(&third); close_window(&second); close_window(&first);
                        create_group();
                    } else if ([command hasPrefix:@"hide"]) {
                        [NSApp hide:nil];
                    } else if ([command hasPrefix:@"show"]) {
                        [NSApp unhide:nil];
                    } else if ([command hasPrefix:@"quit"]) {
                        [NSApp terminate:nil];
                    }
                    report(); [command release];
                });
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
        [NSApp run];
    }
    return 0;
}
