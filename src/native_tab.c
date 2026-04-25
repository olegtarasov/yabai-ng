#define NATIVE_TAB_POS_TOL 10.0f
#define NATIVE_TAB_SIZE_TOL 35.0f

static inline bool native_tab_near(float a, float b, float tolerance)
{
    return AX_ABS(a, b) < tolerance;
}

static bool native_tab_same_space(struct window *a, struct window *b)
{
    uint64_t a_sid = window_space(a->id);
    uint64_t b_sid = window_space(b->id);
    return !a_sid || !b_sid || a_sid == b_sid;
}

static bool native_tab_frames_match(CGRect a, CGRect b)
{
    return native_tab_near(a.origin.x,    b.origin.x,    NATIVE_TAB_POS_TOL)  &&
           native_tab_near(a.origin.y,    b.origin.y,    NATIVE_TAB_POS_TOL)  &&
           native_tab_near(a.size.width,  b.size.width,  NATIVE_TAB_SIZE_TOL) &&
           native_tab_near(a.size.height, b.size.height, NATIVE_TAB_SIZE_TOL);
}

static bool native_tab_is_managed_parent_candidate(struct window_manager *wm, struct window *window, struct window *candidate)
{
    if (!candidate) return false;
    if (candidate == window) return false;
    if (candidate->application != window->application) return false;
    if (window_check_flag(candidate, WINDOW_TAB)) return false;
    if (!window_manager_find_managed_window(wm, candidate)) return false;
    if (!native_tab_same_space(window, candidate)) return false;
    return true;
}

static bool native_tab_parent_has_children(struct window_manager *wm, struct window *parent, uint32_t ignored_child_id)
{
    table_for (struct window *window, wm->window, {
        if (window->id == ignored_child_id) continue;
        if (window_check_flag(window, WINDOW_TAB) && window->tab_parent_id == parent->id) {
            return true;
        }
    })

    return false;
}

static uint32_t native_tab_group_id(struct window *window)
{
    if (!window) return 0;
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB)) return 0;
    if (window_check_flag(window, WINDOW_TAB)) return window->tab_parent_id;
    if (window_check_flag(window, WINDOW_TAB_PARENT)) return window->id;
    return 0;
}

static bool native_tab_window_is_in_group(struct window *window, uint32_t group_id)
{
    if (!group_id) return false;
    if (window_check_flag(window, WINDOW_TAB)) return window->tab_parent_id == group_id;
    return window->id == group_id;
}

bool native_tab_windows_share_group(struct window *a, struct window *b)
{
    if (!a || !b) return false;
    if (a->application != b->application) return false;

    uint32_t a_group_id = native_tab_group_id(a);
    uint32_t b_group_id = native_tab_group_id(b);
    return a_group_id && a_group_id == b_group_id;
}

bool native_tab_set_group_opacity(struct window_manager *wm, struct window *window, float opacity)
{
    uint32_t group_id = native_tab_group_id(window);
    if (!group_id) return false;

    table_for (struct window *candidate, wm->window, {
        if (candidate->application != window->application) continue;
        if (!native_tab_window_is_in_group(candidate, group_id)) continue;

        window_manager_set_window_opacity(wm, candidate, opacity);
    })

    return true;
}

static void native_tab_refresh_parent_flag(struct window_manager *wm, struct window *parent, uint32_t ignored_child_id)
{
    if (!parent) return;

    if (native_tab_parent_has_children(wm, parent, ignored_child_id)) {
        window_set_flag(parent, WINDOW_TAB_PARENT);
    } else {
        window_clear_flag(parent, WINDOW_TAB_PARENT);
    }
}

static struct window *native_tab_find_recorded_parent(struct window_manager *wm, struct window *window)
{
    if (!window->tab_parent_id) return NULL;

    struct window *parent = window_manager_find_window(wm, window->tab_parent_id);
    if (!native_tab_is_managed_parent_candidate(wm, window, parent)) return NULL;
    if (!native_tab_frames_match(window->frame, parent->frame)) return NULL;

    return parent;
}

static struct window *native_tab_find_frame_parent(struct window_manager *wm, struct window *window)
{
    struct window *recorded_parent = native_tab_find_recorded_parent(wm, window);
    if (recorded_parent) return recorded_parent;

    int window_count;
    struct window **window_list = window_manager_find_application_windows(wm, window->application, &window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *candidate = window_list[i];
        if (!native_tab_is_managed_parent_candidate(wm, window, candidate)) continue;
        if (!native_tab_frames_match(window->frame, candidate->frame)) continue;
        return candidate;
    }

    return NULL;
}

static struct window *native_tab_find_managed_sibling(struct window_manager *wm, struct window *window)
{
    uint64_t sid = window_space(window->id);

    int window_count;
    struct window **window_list = window_manager_find_application_windows(wm, window->application, &window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *candidate = window_list[i];
        if (!native_tab_is_managed_parent_candidate(wm, window, candidate)) continue;
        if (sid && window_space(candidate->id) != sid) continue;
        return candidate;
    }

    return NULL;
}

static void native_tab_mark_child(struct window *window, struct window *parent)
{
    window_set_flag(window, WINDOW_TAB);
    window_clear_flag(window, WINDOW_TAB_PARENT);
    window->tab_parent_id = parent->id;
    window_set_flag(parent, WINDOW_TAB_PARENT);
}

static void native_tab_sync_children_to_parent(struct window_manager *wm, struct window *parent)
{
    if (!parent) return;

    table_for (struct window *child, wm->window, {
        if (!window_check_flag(child, WINDOW_TAB)) continue;
        if (child->tab_parent_id != parent->id) continue;
        if (native_tab_frames_match(child->frame, parent->frame)) continue;

        debug("%s: resizing native tab %d to parent %d frame\n", __FUNCTION__, child->id, parent->id);
        window_manager_set_window_frame(child, parent->frame.origin.x, parent->frame.origin.y, parent->frame.size.width, parent->frame.size.height);
        child->frame = parent->frame;
    })
}

static void native_tab_clear_child(struct window_manager *wm, struct window *window)
{
    uint32_t parent_id = window->tab_parent_id;

    window_clear_flag(window, WINDOW_TAB);
    window->tab_parent_id = 0;

    struct window *parent = parent_id ? window_manager_find_window(wm, parent_id) : NULL;
    native_tab_refresh_parent_flag(wm, parent, window->id);
}

static bool native_tab_convert_to_child(struct window_manager *wm, struct window *window, struct window *parent)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        debug("%s: managed window %d now matches native tab parent %d\n", __FUNCTION__, window->id, parent->id);
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_purify_window(wm, window);
    } else {
        debug("%s: unmanaged window %d now matches native tab parent %d\n", __FUNCTION__, window->id, parent->id);
    }

    native_tab_mark_child(window, parent);
    return true;
}

static bool native_tab_tile_detached_child(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    debug("%s: native tab %d detached, tiling as a normal window\n", __FUNCTION__, window->id);

    uint32_t parent_id = window->tab_parent_id;
    struct window *parent = parent_id ? window_manager_find_window(wm, parent_id) : NULL;

    native_tab_clear_child(wm, window);

    if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(wm, window)) {
        uint64_t sid = window_space(window->id);
        if (!sid) sid = sm->current_space_id;

        struct view *view = space_manager_tile_window_on_space(sm, window, sid);
        window_manager_add_managed_window(wm, window, view);
    }

    native_tab_sync_children_to_parent(wm, parent);

    return true;
}

bool native_tab_handle_window_created(struct window_manager *wm, struct window *window)
{
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB)) return false;

    struct window *parent = native_tab_find_frame_parent(wm, window);
    if (!parent && window_is_standard(window)) {
        parent = native_tab_find_managed_sibling(wm, window);
        if (parent) {
            debug("%s: native tab assumed for %s %d using managed sibling %d\n", __FUNCTION__, window->application->name, window->id, parent->id);
            window_manager_set_window_frame(window, parent->frame.origin.x, parent->frame.origin.y, parent->frame.size.width, parent->frame.size.height);
            window->frame = parent->frame;
        }
    }

    if (!parent) return false;

    debug("%s: native tab detected for %s %d with parent %d\n", __FUNCTION__, window->application->name, window->id, parent->id);
    native_tab_mark_child(window, parent);
    native_tab_sync_children_to_parent(wm, parent);
    if (native_tab_focused_window(wm, window)) {
        native_tab_set_group_opacity(wm, window, wm->active_window_opacity);
    }
    return true;
}

static bool native_tab_handle_window_frame_changed(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB)) return false;

    if (window_check_flag(window, WINDOW_TAB_PARENT)) {
        native_tab_sync_children_to_parent(wm, window);
    }

    if (window_check_flag(window, WINDOW_TAB)) {
        struct window *parent = native_tab_find_frame_parent(wm, window);
        return parent ? true : native_tab_tile_detached_child(sm, wm, window);
    }

    struct window *parent = native_tab_find_frame_parent(wm, window);
    if (!parent) return false;

    return native_tab_convert_to_child(wm, window, parent);
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
        uint32_t parent_id = window->tab_parent_id;
        struct window *parent = parent_id ? window_manager_find_window(wm, parent_id) : NULL;
        native_tab_refresh_parent_flag(wm, parent, window->id);
        return;
    }

    if (!window_check_flag(window, WINDOW_TAB_PARENT)) return;

    table_for (struct window *sibling, wm->window, {
        if (sibling == window) continue;
        if (!window_check_flag(sibling, WINDOW_TAB)) continue;
        if (sibling->tab_parent_id && sibling->tab_parent_id != window->id) continue;
        if (sibling->application != window->application) continue;
        if (!native_tab_frames_match(sibling->frame, window->frame)) continue;

        debug("%s: promoting native tab %d to replace destroyed parent %d\n", __FUNCTION__, sibling->id, window->id);

        window_clear_flag(sibling, WINDOW_TAB);
        sibling->tab_parent_id = 0;

        if (window_manager_should_manage_window(sibling) && !window_manager_find_managed_window(wm, sibling)) {
            struct view *view = space_manager_tile_window_on_space(sm, sibling, destroyed_sid);
            window_manager_add_managed_window(wm, sibling, view);
        }

        native_tab_refresh_parent_flag(wm, sibling, 0);
        return;
    })
}

struct window *native_tab_focused_window(struct window_manager *wm, struct window *window)
{
    if (!window) return NULL;
    if (!window_check_rule_flag(window, WINDOW_RULE_TAB)) return NULL;
    if (!application_is_frontmost(window->application)) return NULL;

    uint32_t focused_window_id = application_focused_window(window->application);
    if (!focused_window_id) return NULL;

    struct window *focused_window = window_manager_find_window(wm, focused_window_id);
    if (!focused_window) return NULL;
    if (focused_window->application != window->application) return NULL;
    if (!window_check_rule_flag(focused_window, WINDOW_RULE_TAB)) return NULL;
    if (!native_tab_same_space(window, focused_window)) return NULL;

    if (window_check_flag(focused_window, WINDOW_TAB)) {
        return native_tab_find_frame_parent(wm, focused_window) ? focused_window : NULL;
    }

    if (window_check_flag(focused_window, WINDOW_TAB_PARENT)) {
        return native_tab_parent_has_children(wm, focused_window, 0) ? focused_window : NULL;
    }

    return NULL;
}

bool native_tab_should_preserve_parent(struct window_manager *wm, struct window *window)
{
    if (!window) return false;
    if (!window_check_flag(window, WINDOW_TAB_PARENT)) return false;
    return native_tab_parent_has_children(wm, window, 0);
}
