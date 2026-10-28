#define NATIVE_TAB_AX_TAB_GROUP_ROLE CFSTR("AXTabGroup")
#define NATIVE_TAB_AX_TABS_ATTRIBUTE CFSTR("AXTabs")
#define NATIVE_TAB_AX_CHILDREN_IN_NAVIGATION_ORDER_ATTRIBUTE CFSTR("AXChildrenInNavigationOrder")

static bool native_tab_same_space(struct window *a, struct window *b)
{
    uint64_t a_sid = window_space(a->id);
    uint64_t b_sid = window_space(b->id);
    return !a_sid || !b_sid || a_sid == b_sid;
}

static bool native_tab_ax_role_is(AXUIElementRef element, CFStringRef expected_role)
{
    CFTypeRef role = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) != kAXErrorSuccess || !role) return false;

    bool result = CFGetTypeID(role) == CFStringGetTypeID() && CFEqual(role, expected_role);
    CFRelease(role);
    return result;
}

static CFArrayRef native_tab_copy_array_attribute(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return NULL;

    if (CFGetTypeID(value) != CFArrayGetTypeID()) {
        CFRelease(value);
        return NULL;
    }

    return value;
}

static AXUIElementRef native_tab_copy_tab_group(AXUIElementRef window_ref)
{
    CFStringRef child_attributes[] = {
        kAXChildrenAttribute,
        NATIVE_TAB_AX_CHILDREN_IN_NAVIGATION_ORDER_ATTRIBUTE
    };

    for (int attr_index = 0; attr_index < array_count(child_attributes); ++attr_index) {
        CFArrayRef children = native_tab_copy_array_attribute(window_ref, child_attributes[attr_index]);
        if (!children) continue;

        int child_count = CFArrayGetCount(children);
        for (int child_index = 0; child_index < child_count; ++child_index) {
            AXUIElementRef child = (AXUIElementRef) CFArrayGetValueAtIndex(children, child_index);
            if (!native_tab_ax_role_is(child, NATIVE_TAB_AX_TAB_GROUP_ROLE)) continue;

            CFArrayRef tabs = native_tab_copy_array_attribute(child, NATIVE_TAB_AX_TABS_ATTRIBUTE);
            bool has_tabs = tabs && CFArrayGetCount(tabs) > 1;
            if (tabs) CFRelease(tabs);
            if (!has_tabs) continue;

            CFRetain(child);
            CFRelease(children);
            return child;
        }

        CFRelease(children);
    }

    return NULL;
}

static CFArrayRef native_tab_copy_tabs(struct window *window)
{
    if (!window || !window->ref) return NULL;

    AXUIElementRef tab_group = native_tab_copy_tab_group(window->ref);
    if (!tab_group) return NULL;

    CFArrayRef tabs = native_tab_copy_array_attribute(tab_group, NATIVE_TAB_AX_TABS_ATTRIBUTE);
    CFRelease(tab_group);

    if (!tabs) return NULL;
    if (CFArrayGetCount(tabs) <= 1) {
        CFRelease(tabs);
        return NULL;
    }

    return tabs;
}

static bool native_tab_tabs_contain_title(CFArrayRef tabs, CFStringRef title)
{
    if (!tabs || !title || CFStringGetLength(title) == 0) return false;

    int matches = 0;
    int tab_count = CFArrayGetCount(tabs);
    for (int i = 0; i < tab_count; ++i) {
        AXUIElementRef tab = (AXUIElementRef) CFArrayGetValueAtIndex(tabs, i);

        CFTypeRef tab_title = NULL;
        if (AXUIElementCopyAttributeValue(tab, kAXTitleAttribute, &tab_title) != kAXErrorSuccess || !tab_title) continue;

        bool title_matches = CFGetTypeID(tab_title) == CFStringGetTypeID() &&
                             CFStringCompare(title, tab_title, 0) == kCFCompareEqualTo;
        CFRelease(tab_title);

        if (title_matches) ++matches;
    }

    return matches == 1;
}

static bool native_tab_tabs_contain_window_title(CFArrayRef tabs, struct window *window)
{
    return window && native_tab_tabs_contain_title(tabs, window->title);
}

static bool native_tab_tabs_match_windows(CFArrayRef tabs, struct window *a, struct window *b)
{
    return a->title && b->title && !CFEqual(a->title, b->title) &&
           native_tab_tabs_contain_window_title(tabs, a) &&
           native_tab_tabs_contain_window_title(tabs, b);
}

static bool native_tab_windows_share_ax_tab_group(struct window *a, struct window *b)
{
    CFArrayRef a_tabs = native_tab_copy_tabs(a);
    if (a_tabs) {
        bool result = native_tab_tabs_match_windows(a_tabs, a, b);
        CFRelease(a_tabs);
        if (result) return true;
    }

    CFArrayRef b_tabs = native_tab_copy_tabs(b);
    if (b_tabs) {
        bool result = native_tab_tabs_match_windows(b_tabs, a, b);
        CFRelease(b_tabs);
        if (result) return true;
    }

    return false;
}

// The selected native tab owns the group's BSP slot. Transferring that slot in
// place keeps splits, stack order, zoom and insertion state stable across tabs.
static bool native_tab_is_live(struct window *window)
{
    return window && window->id && window->id_ptr;
}

static bool native_tab_is_ordered_in(struct window *window)
{
    uint8_t ordered_in = 0;
    return native_tab_is_live(window) &&
           SLSWindowIsOrderedIn(g_connection, window->id, &ordered_in) == kCGErrorSuccess && ordered_in;
}

static uint32_t native_tab_group_id(struct window *window)
{
    if (!window || !window_check_rule_flag(window, WINDOW_RULE_TAB)) return 0;
    if (window_check_flag(window, WINDOW_TAB)) return window->tab_parent_id;
    return window_check_flag(window, WINDOW_TAB_PARENT) ? window->id : 0;
}

static bool native_tab_window_is_in_group(struct window *window, uint32_t group_id)
{
    return group_id && (window->id == group_id ||
           (window_check_flag(window, WINDOW_TAB) && window->tab_parent_id == group_id));
}

bool native_tab_windows_share_group(struct window *a, struct window *b)
{
    return a && b && a->application == b->application && native_tab_group_id(a) &&
           native_tab_group_id(a) == native_tab_group_id(b);
}

struct window *native_tab_managed_window(struct window_manager *wm, struct window *window)
{
    if (!window || !window_check_flag(window, WINDOW_TAB)) return window;
    struct window *parent = window_manager_find_window(wm, window->tab_parent_id);
    return native_tab_is_live(parent) && parent->application == window->application ? parent : window;
}

bool native_tab_set_group_opacity(struct window_manager *wm, struct window *window, float opacity)
{
    uint32_t group_id = native_tab_group_id(window);
    if (!group_id) return false;
    table_for (struct window *candidate, wm->window, {
        if (candidate->application != window->application || !native_tab_window_is_in_group(candidate, group_id)) continue;
        window_manager_set_window_opacity(wm, candidate, opacity);
    })
    return true;
}

void native_tab_sync_group_float(struct window_manager *wm, struct window *window)
{
    uint32_t group_id = native_tab_group_id(window);
    if (!group_id) return;
    table_for (struct window *candidate, wm->window, {
        if (candidate->application != window->application || !native_tab_window_is_in_group(candidate, group_id)) continue;
        if (window_check_flag(window, WINDOW_FLOAT)) window_set_flag(candidate, WINDOW_FLOAT);
        else window_clear_flag(candidate, WINDOW_FLOAT);
    })
}

static bool native_tab_parent_has_children(struct window_manager *wm, struct window *parent, uint32_t ignored_id)
{
    table_for (struct window *candidate, wm->window, {
        if (candidate->id == ignored_id || candidate->application != parent->application) continue;
        if (native_tab_is_live(candidate) && window_check_flag(candidate, WINDOW_TAB) && candidate->tab_parent_id == parent->id) return true;
    })
    return false;
}

static void native_tab_refresh_parent_flag(struct window_manager *wm, struct window *parent, uint32_t ignored_id)
{
    if (!parent) return;
    if (native_tab_parent_has_children(wm, parent, ignored_id)) window_set_flag(parent, WINDOW_TAB_PARENT);
    else window_clear_flag(parent, WINDOW_TAB_PARENT);
}

static void native_tab_mark_child(struct window *window, struct window *parent)
{
    window_set_flag(window, WINDOW_TAB);
    window_clear_flag(window, WINDOW_TAB_PARENT);
    window->tab_parent_id = parent->id;
    window_set_flag(parent, WINDOW_TAB_PARENT);
    if (window_check_flag(parent, WINDOW_FLOAT)) window_set_flag(window, WINDOW_FLOAT);
    else window_clear_flag(window, WINDOW_FLOAT);
}

static void native_tab_reparent_members(struct window_manager *wm, struct window *parent, struct window *selected, bool retiring)
{
    if (window_check_flag(parent, WINDOW_FLOAT)) window_set_flag(selected, WINDOW_FLOAT);
    else window_clear_flag(selected, WINDOW_FLOAT);
    table_for (struct window *candidate, wm->window, {
        if (candidate == selected || candidate == parent || candidate->application != parent->application) continue;
        if (window_check_flag(candidate, WINDOW_TAB) && candidate->tab_parent_id == parent->id) native_tab_mark_child(candidate, selected);
    })
    window_clear_flag(selected, WINDOW_TAB);
    selected->tab_parent_id = 0;
    window_clear_flag(parent, WINDOW_TAB_PARENT);
    if (!retiring) native_tab_mark_child(parent, selected);
    native_tab_refresh_parent_flag(wm, selected, 0);
}

static void native_tab_replace_node_window(struct view *view, struct window_node *node, uint32_t old_id, uint32_t new_id)
{
    for (int i = 0; i < node->window_count; ++i) {
        if (node->window_list[i] == old_id) node->window_list[i] = new_id;
        if (node->window_order[i] == old_id) node->window_order[i] = new_id;
    }
    if (view->insertion_point == old_id) view->insertion_point = new_id;
}

static void native_tab_refresh_ax_reference(struct window *window)
{
    CFArrayRef windows = application_window_list(window->application);
    if (!windows) return;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); ++i) {
        AXUIElementRef ref = (AXUIElementRef) CFArrayGetValueAtIndex(windows, i);
        if (ax_window_id(ref) != window->id) continue;
        if (!CFEqual(ref, window->ref)) {
            window_unobserve(window);
            CFRelease(window->ref);
            window->ref = (AXUIElementRef) CFRetain(ref);
            window_observe(window);
        }
        break;
    }
    CFRelease(windows);
}

static bool native_tab_promote_window(struct window_manager *wm, struct window *parent, struct window *selected, bool retiring)
{
    struct view *view = window_manager_find_managed_window(wm, parent);
    struct view *selected_view = window_manager_find_managed_window(wm, selected);
    if (selected_view) {
        space_manager_untile_window(selected_view, selected);
        window_manager_remove_managed_window(wm, selected->id);
    }
    struct window_node *node = view ? view_find_window_node(view, parent->id) : NULL;
    if (node) {
        bool feedback = node->feedback_window.id != 0;
        if (feedback) insert_feedback_destroy(node);
        native_tab_replace_node_window(view, node, parent->id, selected->id);
        window_manager_remove_managed_window(wm, parent->id);
        window_manager_add_managed_window(wm, selected, view);
        if (feedback) insert_feedback_show(node);
    }
    native_tab_reparent_members(wm, parent, selected, retiring);
    native_tab_refresh_ax_reference(selected);
    if (node) {
        // Apply the existing slot to the new AX window, including zoom geometry.
        if (native_tab_is_ordered_in(selected) && !selected->application->is_hidden &&
            !window_check_flag(selected, WINDOW_MINIMIZE) && !window_check_flag(selected, WINDOW_FULLSCREEN)) {
            window_node_flush(node);
        } else {
            view_set_flag(view, VIEW_IS_DIRTY);
        }
        event_signal_push(SIGNAL_SPACE_STACKS_CHANGED, (void *)(uintptr_t) view->sid);
    }
    managed_space_request_reconcile(&g_managed_space);
    return true;
}

static bool native_tab_is_parent_candidate(struct window_manager *wm, struct window *window, struct window *candidate)
{
    if (!native_tab_is_live(candidate) || candidate == window || candidate->application != window->application) return false;
    if (!window_check_rule_flag(candidate, WINDOW_RULE_TAB) || window_check_flag(candidate, WINDOW_TAB)) return false;
    if (window_check_flag(candidate, WINDOW_FULLSCREEN) || window_check_flag(window, WINDOW_FULLSCREEN)) return false;
    if (!window_is_standard(candidate) || !window_is_standard(window) || !native_tab_same_space(window, candidate)) return false;
    if (!window_manager_find_managed_window(wm, candidate) && !window_check_flag(candidate, WINDOW_TAB_PARENT)) return false;
    return true;
}

static struct window *native_tab_find_parent(struct window_manager *wm, struct window *window)
{
    // Geometry and app/space coincidence are not evidence of native tabbing.
    table_for (struct window *candidate, wm->window, {
        if (!native_tab_is_parent_candidate(wm, window, candidate)) continue;
        if (!native_tab_windows_share_ax_tab_group(candidate, window)) continue;
        if (native_tab_is_ordered_in(candidate) && native_tab_is_ordered_in(window)) continue;
        return candidate;
    })
    return NULL;
}

static void native_tab_clear_child(struct window_manager *wm, struct window *window)
{
    struct window *parent = window_manager_find_window(wm, window->tab_parent_id);
    window_clear_flag(window, WINDOW_TAB);
    window->tab_parent_id = 0;
    native_tab_refresh_parent_flag(wm, parent, window->id);
}

static bool native_tab_convert_to_child(struct window_manager *wm, struct window *window, struct window *parent)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_purify_window(wm, window);
    }
    native_tab_mark_child(window, parent);
    return true;
}

bool native_tab_repair_window(struct window_manager *wm, struct window *window)
{
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB) || !native_tab_is_live(window)) return false;
    if (window_check_flag(window, WINDOW_FULLSCREEN) || window_check_flag(window, WINDOW_MINIMIZE) || window->application->is_hidden) return false;
    bool repaired = false;
    if (window_check_flag(window, WINDOW_TAB)) {
        struct window *parent = window_manager_find_window(wm, window->tab_parent_id);
        if (parent && parent->application != window->application) parent = NULL;
        if (parent && !native_tab_is_live(parent) && native_tab_is_ordered_in(window)) {
            // AX may invalidate the old representative before its queued destroy
            // event. Transfer the whole recorded group before admitting a new tile.
            repaired = native_tab_promote_window(wm, parent, window, true);
        } else if (!parent && native_tab_is_ordered_in(window)) {
            // A missed/queued destruction must not strand a selected orphan.
            native_tab_clear_child(wm, window);
            if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(wm, window)) {
                struct view *view = space_manager_tile_window_on_space(&g_space_manager, window, window_space(window->id));
                window_manager_add_managed_window(wm, window, view);
            }
            repaired = true;
        } else if (parent && native_tab_is_ordered_in(window) &&
            (!native_tab_is_ordered_in(parent) || application_focused_window(window->application) == window->id)) {
            // Validate with the current AX element before reusing a recorded group.
            native_tab_refresh_ax_reference(window);
            if (native_tab_windows_share_ax_tab_group(parent, window)) {
                repaired = native_tab_promote_window(wm, parent, window, false);
            } else {
                native_tab_clear_child(wm, window);
                if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(wm, window)) {
                    struct view *view = space_manager_tile_window_on_space(&g_space_manager, window, window_space(window->id));
                    window_manager_add_managed_window(wm, window, view);
                }
                repaired = true;
            }
        } else return false;
    }
    if (!window_manager_find_managed_window(wm, window) && !window_check_flag(window, WINDOW_TAB_PARENT)) return repaired;
    table_for (struct window *candidate, wm->window, {
        if (!native_tab_is_live(candidate) || candidate == window || candidate->application != window->application) continue;
        if (!window_check_rule_flag(candidate, WINDOW_RULE_TAB)) continue;
        if (!window_is_standard(candidate) || window_check_flag(candidate, WINDOW_FULLSCREEN)) continue;
        if (window_check_flag(candidate, WINDOW_TAB) && candidate->tab_parent_id == window->id) {
            // Detaching the representative can expose a different member while
            // both retain their WindowServer IDs. Do not keep that window hidden
            // behind the representative's presentation/tiling identity.
            if (native_tab_is_ordered_in(window) && native_tab_is_ordered_in(candidate) &&
                !native_tab_windows_share_ax_tab_group(window, candidate)) {
                native_tab_clear_child(wm, candidate);
                if (window_manager_should_manage_window(candidate) && !window_manager_find_managed_window(wm, candidate)) {
                    struct view *view = space_manager_tile_window_on_space(&g_space_manager, candidate, window_space(candidate->id));
                    window_manager_add_managed_window(wm, candidate, view);
                }
                repaired = true;
            }
            continue;
        }
        if (window_check_flag(candidate, WINDOW_TAB_PARENT) || !native_tab_same_space(window, candidate)) continue;
        if (native_tab_is_ordered_in(window) && native_tab_is_ordered_in(candidate)) continue;
        if (!native_tab_windows_share_ax_tab_group(window, candidate)) continue;
        if (window_check_flag(candidate, WINDOW_TAB)) native_tab_clear_child(wm, candidate);
        native_tab_convert_to_child(wm, candidate, window);
        repaired = true;
    })
    if (repaired) {
        native_tab_set_group_opacity(wm, window, native_tab_focused_window(wm, window)
            ? wm->active_window_opacity : wm->normal_window_opacity);
        managed_space_request_reconcile(&g_managed_space);
    }
    return repaired;
}

bool native_tab_handle_window_created(struct window_manager *wm, struct window *window)
{
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB) || !window_is_standard(window)) return false;
    struct window *parent = native_tab_find_parent(wm, window);
    if (!parent) return false;
    native_tab_mark_child(window, parent);
    native_tab_repair_window(wm, window);
    return true;
}

static bool native_tab_handle_window_frame_changed(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB)) return false;
    native_tab_repair_window(wm, window);
    if (!window_check_flag(window, WINDOW_TAB)) return false;
    struct window *parent = native_tab_find_parent(wm, window);
    if (parent) return true; // Inactive member; the selected member owns the BSP slot.
    native_tab_clear_child(wm, window);
    if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(wm, window)) {
        struct view *view = space_manager_tile_window_on_space(sm, window, window_space(window->id));
        window_manager_add_managed_window(wm, window, view);
    }
    return true;
}

bool native_tab_handle_window_moved(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    return native_tab_handle_window_frame_changed(sm, wm, window);
}

bool native_tab_handle_window_resized(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    return native_tab_handle_window_frame_changed(sm, wm, window);
}

void native_tab_handle_window_destroyed(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t destroyed_sid)
{
    if (window_check_flag(window, WINDOW_TAB)) {
        native_tab_refresh_parent_flag(wm, window_manager_find_window(wm, window->tab_parent_id), window->id);
        return;
    }
    if (!window_check_flag(window, WINDOW_TAB_PARENT)) return;
    struct window *replacement = NULL;
    table_for (struct window *candidate, wm->window, {
        if (!native_tab_is_live(candidate) || candidate == window || candidate->application != window->application) continue;
        if (!window_check_flag(candidate, WINDOW_TAB) || candidate->tab_parent_id != window->id) continue;
        if (!replacement || native_tab_is_ordered_in(candidate)) replacement = candidate;
    })
    if (!replacement) return;
    native_tab_promote_window(wm, window, replacement, true);
    if (!window_manager_find_managed_window(wm, replacement) && window_manager_should_manage_window(replacement) && native_tab_is_ordered_in(replacement)) {
        uint64_t sid = destroyed_sid ? destroyed_sid : window_space(replacement->id);
        struct view *view = space_manager_tile_window_on_space(sm, replacement, sid);
        window_manager_add_managed_window(wm, replacement, view);
    }
}

void native_tab_forget_window(struct window_manager *wm, struct window *window)
{
    if (window_check_flag(window, WINDOW_TAB)) native_tab_clear_child(wm, window);
    table_for (struct window *candidate, wm->window, {
        if (candidate->application != window->application) continue;
        if (window_check_flag(candidate, WINDOW_TAB) && candidate->tab_parent_id == window->id) native_tab_clear_child(wm, candidate);
    })
    window_clear_flag(window, WINDOW_TAB_PARENT);
}

struct window *native_tab_focused_window(struct window_manager *wm, struct window *window)
{
    if (!window || !native_tab_group_id(window) || !application_is_frontmost(window->application)) return NULL;
    struct window *focused = window_manager_find_window(wm, application_focused_window(window->application));
    return focused && native_tab_windows_share_group(window, focused) ? focused : NULL;
}

bool native_tab_should_preserve_parent(struct window_manager *wm, struct window *window)
{
    return window && window_check_flag(window, WINDOW_TAB_PARENT) && native_tab_parent_has_children(wm, window, 0);
}

bool native_tab_is_presentation_window(struct window_manager *wm, struct window *window)
{
    uint32_t group_id = native_tab_group_id(window);
    if (!group_id) return true;
    // During queued focus/order transitions, choose exactly one ordered member.
    struct window *selected = NULL;
    table_for (struct window *candidate, wm->window, {
        if (candidate->application != window->application || !native_tab_window_is_in_group(candidate, group_id)) continue;
        if (candidate->application->is_hidden || window_check_flag(candidate, WINDOW_MINIMIZE) || !native_tab_is_ordered_in(candidate)) continue;
        if (candidate->id == group_id) return candidate == window;
        if (!selected || candidate->id < selected->id) selected = candidate;
    })
    return selected == window;
}

void native_tab_discover_application_windows(struct window_manager *wm, struct application *application, uint32_t ignored_id)
{
    if (!application) return;
    bool enabled = false;
    table_for (struct window *window, wm->window, {
        if (window->application == application && window_check_rule_flag(window, WINDOW_RULE_TAB)) enabled = true;
    })
    struct window probe = { .application = application };
    for (int i = 0; !enabled && i < buf_len(wm->rules); ++i) {
        if (wm->rules[i].effects.manage == RULE_PROP_TAB &&
            window_manager_rule_matches_window(&wm->rules[i], &probe, "", "AXWindow", "AXStandardWindow")) enabled = true;
    }
    if (!enabled) return;
    CFArrayRef windows = application_window_list(application);
    if (!windows) return;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); ++i) {
        AXUIElementRef ref = (AXUIElementRef) CFArrayGetValueAtIndex(windows, i);
        uint32_t wid = ax_window_id(ref);
        if (!wid || wid == ignored_id || window_manager_find_window(wm, wid)) continue;
        int connection = 0;
        pid_t pid = 0;
        if (SLSGetWindowOwner(g_connection, wid, &connection) != kCGErrorSuccess ||
            SLSConnectionGetPID(connection, &pid) != kCGErrorSuccess || pid != application->pid) continue;
        debug("%s: discovering recreated %s window %u\n", __FUNCTION__, application->name, wid);
        event_loop_post(&g_event_loop, WINDOW_CREATED, (void *) CFRetain(ref), 0);
    }
    CFRelease(windows);
}
