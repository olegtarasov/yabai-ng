// Observation, bounded policy planning, and execution through upstream shared operations.
#define MANAGED_SPACE_ACTION_BUDGET 80

static uint64_t managed_space_hash_u64(uint64_t hash, uint64_t value)
{
    for (int i = 0; i < 8; ++i) { hash ^= (value >> (8*i)) & 255; hash *= 1099511628211ULL; }
    return hash;
}

static uint64_t managed_space_hash_string(uint64_t hash, char *value)
{
    for (char *at = value ? value : ""; *at; ++at) { hash ^= (uint8_t)*at; hash *= 1099511628211ULL; }
    return managed_space_hash_u64(hash, 255);
}

static bool managed_space_window_can_track(struct window *window)
{
    return window && window->id && window->application && window->is_root && window_is_standard(window) &&
        !window_check_flag(window, WINDOW_STICKY) && !window_is_sticky(window->id) &&
        !window_check_flag(window, WINDOW_TAB);
}

static struct managed_space_observed_space *managed_space_observed_sid(struct managed_space_observation *o, uint64_t sid)
{
    for (int i = 0; i < buf_len(o->spaces); ++i) if (o->spaces[i].sid == sid) return &o->spaces[i];
    return NULL;
}

static struct managed_space_observed_space *managed_space_observed_uuid(struct managed_space_observation *o, CFStringRef uuid)
{
    for (int i = 0; uuid && i < buf_len(o->spaces); ++i) if (CFEqual(o->spaces[i].uuid, uuid)) return &o->spaces[i];
    return NULL;
}

static struct managed_space_observed_display *managed_space_observed_display(struct managed_space_observation *o, uint32_t did)
{
    for (int i = 0; i < buf_len(o->displays); ++i) if (o->displays[i].did == did) return &o->displays[i];
    return NULL;
}

static void managed_space_capture_observation(struct managed_space *ms, struct managed_space_observation *o)
{
    memset(o, 0, sizeof(*o));
    o->hash = 1469598103934665603ULL;
    int count = 0;
    uint32_t *displays = display_manager_active_display_list(&count);
    o->valid = displays && count > 0;
    o->blocked = mission_control_is_active();
    uint32_t main_did = display_manager_main_display_id();
    int index = 0;
    for (int i = 0; i < count; ++i) {
        struct managed_space_observed_display display = {
            .did = displays[i], .uuid = display_uuid(displays[i]), .main = displays[i] == main_did,
            .active_sid = display_space_id(displays[i]), .animating = display_manager_display_is_animating(displays[i])
        };
        if (!display.uuid) { o->valid = false; continue; }
        buf_push(o->displays, display);
        o->hash = managed_space_hash_u64(o->hash, display.did);
        o->hash = managed_space_hash_u64(o->hash, display.main);
        o->blocked |= display.animating;
        int space_count = 0;
        uint64_t *spaces = display_space_list(displays[i], &space_count);
        if (!spaces || !space_count) { o->valid = false; continue; }
        for (int j = 0; j < space_count; ++j) {
            struct managed_space_observed_space space = {
                .sid = spaces[j], .uuid = managed_space_uuid_for_sid(spaces[j]), .did = displays[i], .index = ++index,
                .normal = space_is_user(spaces[j]) && !space_is_fullscreen(spaces[j]), .fullscreen = space_is_fullscreen(spaces[j])
            };
            if (!space.uuid) { o->valid = false; continue; }
            int window_count = 0;
            bool windows_valid = false;
            uint32_t *windows = space_window_list_with_status(space.sid, &window_count, true, &windows_valid);
            if (!windows_valid) o->valid = false;
            for (int k = 0; k < window_count; ++k) buf_push(space.windows, windows[k]);
            buf_push(o->spaces, space);
            o->hash = managed_space_hash_u64(o->hash, space.sid);
            o->hash = managed_space_hash_u64(o->hash, space.normal);
            o->hash = managed_space_hash_u64(o->hash, space.fullscreen);
            for (int k = 0; k < window_count; ++k) o->hash = managed_space_hash_u64(o->hash, windows[k]);
        }
    }
    table_for (struct window *window, g_window_manager.window, {
        if (!managed_space_window_can_track(window)) continue;
        struct managed_space_observed_window observed = ((struct managed_space_observed_window) { .wid = window->id });
        // Raw membership never substitutes the display's active Space. Missing
        // or unknown membership defers only this window, not unrelated repairs.
        observed.sid = window_manager_observe_window_space(window, &observed.fullscreen);
        struct managed_space_observed_space *space = managed_space_observed_sid(o, observed.sid);
        observed.dragged = managed_space_window_is_dragged(ms, window);
        observed.actionable = space && space->normal && !observed.fullscreen && !observed.dragged &&
            !window->application->is_hidden && !window_check_flag(window, WINDOW_MINIMIZE);
        buf_push(o->windows, observed);
        o->hash = managed_space_hash_u64(o->hash, observed.wid);
        o->hash = managed_space_hash_u64(o->hash, observed.sid);
        o->hash = managed_space_hash_u64(o->hash, observed.fullscreen);
        o->hash = managed_space_hash_u64(o->hash, observed.actionable);
    })
}

static void managed_space_destroy_observation(struct managed_space_observation *o)
{
    for (int i = 0; i < buf_len(o->displays); ++i) CFRelease(o->displays[i].uuid);
    for (int i = 0; i < buf_len(o->spaces); ++i) { CFRelease(o->spaces[i].uuid); buf_free(o->spaces[i].windows); }
    buf_free(o->displays); buf_free(o->spaces); buf_free(o->windows);
    memset(o, 0, sizeof(*o));
}

static uint32_t managed_space_observed_target_display(struct managed_space_entry *entry, struct managed_space_observation *o)
{
    for (int i = 0; i < buf_len(o->displays); ++i) {
        struct managed_space_observed_display *display = &o->displays[i];
        if (entry->display_affinity == MANAGED_SPACE_DISPLAY_FOLLOW_MAIN ? display->main :
            entry->preferred_display_uuid && CFEqual(entry->preferred_display_uuid, display->uuid)) return display->did;
    }
    return 0;
}

static bool managed_space_observed_display_has_target(struct managed_space *ms, struct managed_space_observation *o, uint32_t did)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) if (managed_space_observed_target_display(&ms->spaces[i], o) == did) return true;
    return false;
}

static bool managed_space_reserved_uuid(struct managed_space *ms, CFStringRef uuid)
{
    for (int i = 0; uuid && i < buf_len(ms->secondary_workspaces); ++i) {
        if (ms->secondary_workspaces[i].space_uuid && CFEqual(ms->secondary_workspaces[i].space_uuid, uuid)) return true;
    }
    return false;
}

static bool managed_space_observed_reserved(struct managed_space *ms, struct managed_space_observation *o, struct managed_space_observed_space *space)
{
    struct managed_space_observed_display *display = managed_space_observed_display(o, space->did);
    return display && !display->main && !managed_space_observed_display_has_target(ms, o, display->did) &&
        managed_space_reserved_uuid(ms, space->uuid);
}

static uint64_t managed_space_required_placeholder_sid(struct managed_space *ms, uint32_t did)
{
    if (!managed_space_display_requires_placeholder(ms, did)) return 0;
    CFStringRef name = display_uuid(did);
    uint64_t result = 0;
    for (int i = 0; name && i < buf_len(ms->secondary_workspaces); ++i) {
        struct managed_secondary_workspace *workspace = &ms->secondary_workspaces[i];
        if (!workspace->space_uuid || !CFEqual(name, workspace->display_uuid)) continue;
        int count = 0; uint64_t *spaces = display_space_list(did, &count);
        for (int j = 0; j < count; ++j) {
            CFStringRef uuid = managed_space_uuid_for_sid(spaces[j]);
            if (uuid && CFEqual(uuid, workspace->space_uuid) && space_is_user(spaces[j]) && !space_is_fullscreen(spaces[j])) result = spaces[j];
            if (uuid) CFRelease(uuid);
        }
    }
    if (name) CFRelease(name);
    return result;
}

static int managed_space_placeholder_count(struct managed_space *ms)
{
    int result = 0, count = 0; uint32_t *displays = display_manager_active_display_list(&count);
    for (int i = 0; i < count; ++i) if (managed_space_required_placeholder_sid(ms, displays[i])) ++result;
    return result;
}




static bool managed_space_admit_observed_creates(struct managed_space *ms, struct managed_space_observation *o)
{
    bool changed = false;
    for (int i = 0; i < buf_len(o->spaces); ++i) {
        struct managed_space_observed_space *space = &o->spaces[i];
        struct managed_space_observed_display *display = managed_space_observed_display(o, space->did);
        if (!space->normal || !display) continue;
        if (managed_space_admit_create(ms, space->sid, space->uuid, display->uuid)) {
            buf_push(ms->replacement_receipts, CFRetain(space->uuid));
            changed = true;
        }
    }
    return changed;
}

static void managed_space_refresh_observed_bindings(struct managed_space *ms, struct managed_space_observation *o)
{
    if (!o->valid) return;
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_observed_space *space = managed_space_observed_uuid(o, ms->spaces[i].uuid);
        ms->spaces[i].sid = space && space->normal ? space->sid : 0;
        managed_space_refresh_label(&ms->spaces[i]);
    }
}

static void managed_space_refresh_observed_intent(struct managed_space *ms, struct managed_space_observation *o)
{
    if (!o->valid) return;
    managed_space_refresh_observed_bindings(ms, o);
    // Reserve an existing normal workspace on each unowned secondary display.
    for (int i = 0; i < buf_len(o->displays); ++i) {
        struct managed_space_observed_display *display = &o->displays[i];
        if (display->main || managed_space_observed_display_has_target(ms, o, display->did)) continue;
        CFStringRef *candidates = NULL;
        for (int j = 0; j < buf_len(o->spaces); ++j) {
            struct managed_space_observed_space *space = &o->spaces[j];
            if (space->did != display->did || !space->normal || managed_space_find_by_uuid(ms, space->uuid)) continue;
            if (managed_space_display_has_pending_create(ms, display->uuid) && !managed_space_reserved_uuid(ms, space->uuid)) continue;
            buf_push(candidates, space->uuid);
        }
        managed_space_select_secondary_workspace(ms, display->uuid, candidates, buf_len(candidates));
        buf_free(candidates);
    }
    for (int i = 0; i < buf_len(ms->windows); ++i) {
        struct managed_window_entry *entry = &ms->windows[i];
        if (entry->secondary_space_uuid) {
            struct managed_space_observed_space *resident = managed_space_observed_uuid(o, entry->secondary_space_uuid);
            if (!resident || !resident->normal || !managed_space_observed_reserved(ms, o, resident)) managed_space_clear_secondary_residence(entry);
        }
        if (entry->pending_space_uuid) {
            struct managed_space_observed_space *target = managed_space_observed_uuid(o, entry->pending_space_uuid);
            bool reached = false;
            for (int j = 0; j < buf_len(o->windows); ++j) {
                if (o->windows[j].wid == entry->wid && target && o->windows[j].sid == target->sid) reached = true;
            }
            if (!target || reached) managed_space_clear_pending_placement(entry);
        }
    }
}

static void managed_space_update_window_cache(struct managed_space *ms, bool preserve_existing)
{
    (void)preserve_existing;
    // Intent is changed by accepted commands/drops, not overwritten by arbitrary observations.
    for (int i = 0; i < buf_len(ms->windows); ++i) {
        if (!window_manager_find_window(&g_window_manager, ms->windows[i].wid)) {
            managed_window_entry_destroy(&ms->windows[i]); buf_del(ms->windows, i); --i;
        }
    }
    table_for (struct window *window, g_window_manager.window, {
        if (!managed_space_window_can_track(window) || managed_space_window_is_dragged(ms, window)) continue;
        if (managed_space_find_window_entry(ms, window->id)) continue;
        bool fullscreen = false;
        uint64_t sid = window_manager_observe_window_space(window, &fullscreen);
        if (!sid || fullscreen) continue;
        struct managed_space_entry *home = managed_space_find_by_sid_internal(ms, sid);
        if (home) managed_space_set_window_namespace(ms, NULL, window->id, home->uuid);
    })
}

static bool managed_space_pending_replacement(struct managed_space *ms, CFStringRef uuid)
{
    for (int i = 0; i < buf_len(ms->pending_creates); ++i) {
        if (uuid && ms->pending_creates[i].replacement_uuid && CFEqual(uuid, ms->pending_creates[i].replacement_uuid)) return true;
    }
    return false;
}

static struct managed_space_action managed_space_plan(struct managed_space *ms, struct managed_space_observation *o)
{
    struct managed_space_action none = {0};
    if (!ms->enabled || !ms->scripting_addition_ready || !o->valid || o->blocked) return none;
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_entry *entry = &ms->spaces[i];
        uint32_t did = managed_space_observed_target_display(entry, o);
        struct managed_space_observed_space *space = managed_space_observed_uuid(o, entry->uuid);
        if (space && (!space->normal || !did)) continue;
        if (!space) {
            // A missing fixed-affinity slot still needs a usable replacement while
            // its preferred display is disconnected. Preserve the preference for replug.
            if (!did && buf_len(o->displays)) {
                did = o->displays[0].did;
                for (int j = 0; j < buf_len(o->displays); ++j) if (o->displays[j].main) did = o->displays[j].did;
            }
            if (!did) continue;
            if (managed_space_pending_replacement(ms, entry->uuid)) continue;
            for (int j = 0; j < buf_len(o->spaces); ++j) {
                struct managed_space_observed_space *candidate = &o->spaces[j];
                struct managed_space_observed_display *display = managed_space_observed_display(o, candidate->did);
                if (!candidate->normal || managed_space_find_by_uuid(ms, candidate->uuid) ||
                    managed_space_observed_reserved(ms, o, candidate) || !display ||
                    managed_space_display_has_pending_create(ms, display->uuid)) continue;
                return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_BIND, .sid = candidate->sid, .replacement_uuid = entry->uuid };
            }
            struct managed_space_observed_display *display = managed_space_observed_display(o, did);
            if (display && !managed_space_display_has_pending_create(ms, display->uuid))
                return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_CREATE, .sid = display->active_sid, .did = did, .managed = true, .replacement_uuid = entry->uuid };
            continue;
        }
        if (space->did == did) continue;
        int normals = 0;
        for (int j = 0; j < buf_len(o->spaces); ++j) if (o->spaces[j].did == space->did && o->spaces[j].normal) ++normals;
        if (normals <= 1) {
            struct managed_space_observed_display *source = managed_space_observed_display(o, space->did);
            if (source && !managed_space_display_has_pending_create(ms, source->uuid))
                return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_CREATE, .sid = source->active_sid, .did = source->did };
            continue;
        }
        return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_MOVE_DISPLAY, .sid = space->sid, .did = did };
    }
    // Do not clean up or reorder around an unresolved missing slot.
    for (int i = 0; i < buf_len(ms->spaces); ++i) if (!managed_space_observed_uuid(o, ms->spaces[i].uuid)) return none;
    for (int i = 1; i < buf_len(ms->spaces); ++i) {
        struct managed_space_observed_space *left = managed_space_observed_uuid(o, ms->spaces[i-1].uuid);
        struct managed_space_observed_space *right = managed_space_observed_uuid(o, ms->spaces[i].uuid);
        if (left && right && left->normal && right->normal && left->did == right->did && left->index > right->index)
            return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_REORDER, .sid = left->sid, .target_sid = right->sid };
    }
    for (int i = 0; i < buf_len(o->windows); ++i) {
        struct managed_space_observed_window *window = &o->windows[i];
        struct managed_space_observed_space *source = managed_space_observed_sid(o, window->sid);
        if (!source || !source->normal || source->fullscreen || !window->actionable || window->fullscreen || window->dragged) continue;
        struct managed_window_entry *entry = managed_space_find_window_entry(ms, window->wid);
        if (!entry) continue;
        struct managed_space_observed_space *target = managed_space_observed_uuid(o, entry->secondary_space_uuid ? entry->secondary_space_uuid : entry->space_uuid);
        if (!target || !target->normal || target->sid == window->sid) continue;
        if (entry->pending_space_uuid && CFEqual(entry->pending_space_uuid, target->uuid) && entry->pending_source_sid == window->sid) continue;
        return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_REPAIR_WINDOW, .wid = window->wid, .sid = window->sid, .target_sid = target->sid };
    }
    for (int i = 0; i < buf_len(o->spaces); ++i) {
        struct managed_space_observed_space *space = &o->spaces[i];
        struct managed_space_observed_display *display = managed_space_observed_display(o, space->did);
        if (!space->normal || managed_space_find_by_uuid(ms, space->uuid) || managed_space_observed_reserved(ms, o, space) ||
            !display || managed_space_display_has_pending_create(ms, display->uuid)) continue;
        if (buf_len(space->windows)) {
            uint64_t target = 0;
            for (int j = 0; j < buf_len(ms->spaces); ++j) {
                struct managed_space_observed_space *candidate = managed_space_observed_uuid(o, ms->spaces[j].uuid);
                if (candidate && candidate->normal && (!target || candidate->did == space->did)) target = candidate->sid;
            }
            if (target) return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_EVACUATE, .sid = space->sid, .target_sid = target };
        } else return (struct managed_space_action) { .type = MANAGED_SPACE_ACTION_DESTROY, .sid = space->sid };
    }
    return none;
}

static uint64_t managed_space_action_key(struct managed_space_action action)
{
    uint64_t hash = managed_space_hash_u64(1469598103934665603ULL, action.type);
    hash = managed_space_hash_u64(hash, action.sid); hash = managed_space_hash_u64(hash, action.target_sid);
    hash = managed_space_hash_u64(hash, action.wid); hash = managed_space_hash_u64(hash, action.did);
    return managed_space_hash_u64(hash, action.managed);
}

static bool managed_space_should_execute_action(struct managed_space *ms, struct managed_space_observation *o, struct managed_space_action action)
{
    return action.type != MANAGED_SPACE_ACTION_NONE &&
        (ms->last_action_key != managed_space_action_key(action) || ms->last_action_observation != o->hash);
}

static enum space_op_error managed_space_execute(struct managed_space *ms, struct managed_space_observation *o, struct managed_space_action action)
{
    switch (action.type) {
    case MANAGED_SPACE_ACTION_CREATE: {
        managed_space_add_pending_create(ms, action.did, ms->display_policy, action.managed);
        struct managed_space_create_request *request = &buf_last(ms->pending_creates);
        if (action.replacement_uuid) {
            request->replacement_uuid = CFRetain(action.replacement_uuid);
            ms->pending_user_creates = managed_space_pending_user_create_count(ms);
        }
        if (!action.managed) request->display_affinity = MANAGED_SPACE_DISPLAY_FIXED;
        enum space_op_error error = space_manager_add_space(action.sid);
        if (error != SPACE_OP_ERROR_SUCCESS) managed_space_remove_pending_create_at_index(ms, buf_len(ms->pending_creates)-1);
        return error;
    }
    case MANAGED_SPACE_ACTION_BIND: {
        struct managed_space_entry *entry = managed_space_find_by_uuid(ms, action.replacement_uuid);
        return managed_space_rebind_missing_entry(ms, entry, action.sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_MISSING_DST;
    }
    case MANAGED_SPACE_ACTION_MOVE_DISPLAY: return space_manager_move_space_to_display(&g_space_manager, action.sid, action.did);
    case MANAGED_SPACE_ACTION_REORDER: return space_manager_move_space_to_space(action.sid, action.target_sid);
    case MANAGED_SPACE_ACTION_DESTROY: return space_manager_destroy_space(action.sid);
    case MANAGED_SPACE_ACTION_REPAIR_WINDOW: {
        struct managed_window_entry *entry = managed_space_find_window_entry(ms, action.wid);
        struct window *window = window_manager_find_window(&g_window_manager, action.wid);
        struct managed_space_observed_space *target = managed_space_observed_sid(o, action.target_sid);
        // Guard the execution boundary too: a native transition may have begun since capture.
        bool current_fullscreen = false;
        uint64_t current_sid = window ? window_manager_observe_window_space(window, &current_fullscreen) : 0;
        if (!entry || !window || !target || !current_sid || current_fullscreen || space_is_fullscreen(current_sid) ||
            !space_is_user(action.target_sid) || space_is_fullscreen(action.target_sid)) return SPACE_OP_ERROR_INVALID_TYPE;
        managed_space_set_pending_placement(entry, current_sid, target->uuid);
        ++ms->window_repair_attempt_count;
        window_manager_send_window_to_space(&g_space_manager, &g_window_manager, window, action.target_sid, false);
        return SPACE_OP_ERROR_SUCCESS;
    }
    case MANAGED_SPACE_ACTION_EVACUATE: {
        struct managed_space_observed_space *source = managed_space_observed_sid(o, action.sid);
        if (!source || !source->normal || !space_is_user(action.sid) || space_is_fullscreen(action.sid) ||
            !space_is_user(action.target_sid) || space_is_fullscreen(action.target_sid)) return SPACE_OP_ERROR_INVALID_TYPE;
        uint32_t *windows = NULL;
        for (int i = 0; source && i < buf_len(source->windows); ++i) {
            struct window *window = window_manager_find_window(&g_window_manager, source->windows[i]);
            uint64_t current_sid = window_space(source->windows[i]);
            if (current_sid != action.sid || space_is_fullscreen(current_sid) ||
                (window && window_is_fullscreen(window)) || managed_space_window_is_dragged(ms, window)) continue;
            buf_push(windows, source->windows[i]);
        }
        if (buf_len(windows)) space_manager_move_window_list_to_space(action.target_sid, windows, buf_len(windows));
        buf_free(windows);
        return SPACE_OP_ERROR_SUCCESS;
    }
    case MANAGED_SPACE_ACTION_NONE: return SPACE_OP_ERROR_SUCCESS;
    }
    return SPACE_OP_ERROR_INVALID_TYPE;
}

static int managed_space_pending_window_repairs(struct managed_space *ms)
{
    struct managed_space_observation o; managed_space_capture_observation(ms, &o);
    int count = 0;
    for (int i = 0; i < buf_len(o.windows); ++i) {
        struct managed_space_observed_window *window = &o.windows[i];
        struct managed_window_entry *entry = managed_space_find_window_entry(ms, window->wid);
        if (!window->actionable || !entry) continue;
        struct managed_space_observed_space *target = managed_space_observed_uuid(&o, entry->secondary_space_uuid ? entry->secondary_space_uuid : entry->space_uuid);
        if (target && target->normal && target->sid != window->sid) ++count;
    }
    managed_space_destroy_observation(&o);
    return count;
}

static int managed_space_compute_extra_count(struct managed_space *ms)
{
    int result = 0;
    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (space_is_user(sid) && !space_is_fullscreen(sid) && !managed_space_find_by_sid_internal(ms, sid) && !managed_space_is_required_placeholder(ms, sid)) ++result;
    }
    return result;
}

enum space_op_error managed_space_prepare_move_placeholder(struct managed_space *ms, uint64_t sid, uint32_t target_did, bool *required)
{
    if (required) *required = false;
    if (!ms->enabled || !sid || !target_did) return SPACE_OP_ERROR_SUCCESS;
    if (!ms->scripting_addition_ready) return SPACE_OP_ERROR_SCRIPTING_ADDITION;
    uint32_t did = space_display_id(sid);
    if (!did || did == target_did || did == display_manager_main_display_id() || managed_space_normal_space_count_for_display(did) > 1) return SPACE_OP_ERROR_SUCCESS;
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        if (ms->spaces[i].sid != sid && managed_space_target_display_id(&ms->spaces[i]) == did) return SPACE_OP_ERROR_SUCCESS;
    }
    if (required) *required = true;
    if (managed_space_find_pending_placeholder_create(ms, did)) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;
    managed_space_add_pending_create(ms, did, MANAGED_SPACE_DISPLAY_FIXED, false);
    enum space_op_error result = space_manager_add_space(display_space_id(did));
    if (result != SPACE_OP_ERROR_SUCCESS) managed_space_remove_pending_create_at_index(ms, buf_len(ms->pending_creates)-1);
    return result;
}

void managed_space_reconcile(struct managed_space *ms)
{
    ms->event_posted = false;
    if (!ms->enabled || ms->is_reconciling) return;
    ms->is_reconciling = true; ms->pending_reconcile = false;
    ms->last_repaired_window_count = 0;
    for (int pass = 0; pass < MANAGED_SPACE_ACTION_BUDGET; ++pass) {
        struct managed_space_observation o; managed_space_capture_observation(ms, &o);
        if (!o.valid || o.blocked) { managed_space_destroy_observation(&o); break; }
        managed_space_refresh_observed_bindings(ms, &o);
        managed_space_admit_observed_creates(ms, &o);
        managed_space_refresh_observed_intent(ms, &o);
        managed_space_update_window_cache(ms, true);
        struct managed_space_action action = managed_space_plan(ms, &o);
        uint64_t key = managed_space_action_key(action);
        if (!managed_space_should_execute_action(ms, &o, action)) {
            managed_space_destroy_observation(&o); break;
        }
        ms->last_action_key = key; ms->last_action_observation = o.hash;
        enum space_op_error result = managed_space_execute(ms, &o, action);
        ms->last_error = result;
        if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) ms->scripting_addition_ready = false;
        // Count only placements that became observable, not attempts queued into the window bridge.
        if (result == SPACE_OP_ERROR_SUCCESS && action.type == MANAGED_SPACE_ACTION_REPAIR_WINDOW && window_space(action.wid) == action.target_sid) ++ms->last_repaired_window_count;
        bool wait = result != SPACE_OP_ERROR_SUCCESS ||
            (action.type == MANAGED_SPACE_ACTION_REPAIR_WINDOW && window_space(action.wid) != action.target_sid) ||
            action.type == MANAGED_SPACE_ACTION_EVACUATE;
        managed_space_destroy_observation(&o);
        if (wait) break;
    }
    ms->last_extra_count = managed_space_compute_extra_count(ms);
    ms->last_placeholder_count = managed_space_placeholder_count(ms);
    ms->last_managed_count = buf_len(ms->spaces);
    ms->last_active_order = managed_space_active_order(ms);
    ms->topology_grace = managed_space_has_absent_preferred_display(ms) || managed_space_pending_window_repairs(ms) > 0;
    managed_space_publish_presentation_if_needed(ms);
    ms->is_reconciling = false;
    // Deferred work resumes through topology/window/drag events, never a timer or a busy retry.
    ms->pending_reconcile = false;
}

static int managed_space_normal_space_count(void)
{
    int count = 0;
    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (space_is_user(sid) && !space_is_fullscreen(sid)) ++count;
    }
    return count;
}
