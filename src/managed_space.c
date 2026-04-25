extern struct event_loop g_event_loop;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern int g_connection;

#define MANAGED_SPACE_MAX_RECONCILE_PASSES 80

static void managed_space_entry_destroy(struct managed_space_entry *entry)
{
    if (entry->uuid) CFRelease(entry->uuid);
    if (entry->preferred_display_uuid) CFRelease(entry->preferred_display_uuid);
    if (entry->label) free(entry->label);
    memset(entry, 0, sizeof(struct managed_space_entry));
}

static void managed_window_entry_destroy(struct managed_window_entry *entry)
{
    if (entry->space_uuid) CFRelease(entry->space_uuid);
    memset(entry, 0, sizeof(struct managed_window_entry));
}

static void managed_space_clear(struct managed_space *ms)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        managed_space_entry_destroy(&ms->spaces[i]);
    }

    for (int i = 0; i < buf_len(ms->windows); ++i) {
        managed_window_entry_destroy(&ms->windows[i]);
    }

    buf_free(ms->spaces);
    buf_free(ms->windows);
    ms->spaces = NULL;
    ms->windows = NULL;
    ms->pending_user_creates = 0;
    ms->last_extra_count = 0;
    ms->last_repaired_window_count = 0;
    ms->last_managed_count = 0;
    ms->last_active_order = 0;
    ms->topology_grace = false;
}

static CFStringRef managed_space_uuid_for_sid(uint64_t sid)
{
    struct view *view = table_find(&g_space_manager.view, &sid);
    if (view && view->uuid) return CFRetain(view->uuid);

    return SLSSpaceCopyName(g_connection, sid);
}

static void managed_space_refresh_label(struct managed_space_entry *entry)
{
    if (entry->label) {
        free(entry->label);
        entry->label = NULL;
    }

    if (!entry->sid) return;

    struct space_label *label = space_manager_get_label_for_space(&g_space_manager, entry->sid);
    entry->label = label ? string_copy(label->label) : string_copy("");
}

static void managed_space_set_preferred_display(struct managed_space_entry *entry, uint32_t did)
{
    if (entry->preferred_display_uuid) {
        CFRelease(entry->preferred_display_uuid);
        entry->preferred_display_uuid = NULL;
    }

    if (did) {
        entry->preferred_display_uuid = display_uuid(did);
    }
}

static struct managed_space_entry *managed_space_find_by_uuid(struct managed_space *ms, CFStringRef uuid)
{
    if (!uuid) return NULL;

    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        if (ms->spaces[i].uuid && CFEqual(ms->spaces[i].uuid, uuid)) {
            return &ms->spaces[i];
        }
    }

    return NULL;
}

static struct managed_space_entry *managed_space_find_by_sid_internal(struct managed_space *ms, uint64_t sid)
{
    if (!sid) return NULL;

    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        if (ms->spaces[i].sid == sid) {
            return &ms->spaces[i];
        }
    }

    return NULL;
}

static struct managed_window_entry *managed_space_find_window_entry(struct managed_space *ms, uint32_t wid)
{
    for (int i = 0; i < buf_len(ms->windows); ++i) {
        if (ms->windows[i].wid == wid) {
            return &ms->windows[i];
        }
    }

    return NULL;
}

static void managed_space_renumber(struct managed_space *ms)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        ms->spaces[i].order = i + 1;
    }
}

static struct managed_space_entry *managed_space_add_entry(struct managed_space *ms, uint64_t sid)
{
    if (!sid || !space_is_user(sid)) return NULL;

    CFStringRef uuid = managed_space_uuid_for_sid(sid);
    if (!uuid) return NULL;

    struct managed_space_entry *existing = managed_space_find_by_uuid(ms, uuid);
    if (existing) {
        existing->sid = sid;
        if (!existing->preferred_display_uuid) {
            managed_space_set_preferred_display(existing, space_display_id(sid));
        }
        managed_space_refresh_label(existing);
        CFRelease(uuid);
        return existing;
    }

    struct managed_space_entry entry = {0};
    entry.uuid = uuid;
    entry.sid = sid;
    entry.order = buf_len(ms->spaces) + 1;
    entry.preferred_display_uuid = display_uuid(space_display_id(sid));
    managed_space_refresh_label(&entry);

    buf_push(ms->spaces, entry);
    ms->last_managed_count = buf_len(ms->spaces);

    return &ms->spaces[buf_len(ms->spaces) - 1];
}

static bool managed_space_remove_entry(struct managed_space *ms, uint64_t sid)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        if (ms->spaces[i].sid == sid) {
            managed_space_entry_destroy(&ms->spaces[i]);
            buf_del(ms->spaces, i);
            managed_space_renumber(ms);
            ms->last_managed_count = buf_len(ms->spaces);
            return true;
        }
    }

    return false;
}

static void managed_space_set_window_namespace(struct managed_space *ms, struct managed_window_entry *window_entry, uint32_t wid, CFStringRef space_uuid)
{
    if (!space_uuid) return;

    if (!window_entry) {
        struct managed_window_entry entry = { .wid = wid, .space_uuid = CFRetain(space_uuid) };
        buf_push(ms->windows, entry);
        return;
    }

    if (window_entry->space_uuid && CFEqual(window_entry->space_uuid, space_uuid)) return;

    if (window_entry->space_uuid) CFRelease(window_entry->space_uuid);
    window_entry->space_uuid = CFRetain(space_uuid);
}

static bool managed_space_window_is_actionable(struct window *window)
{
    if (!window) return false;
    if (!window->id) return false;
    if (!window->application) return false;
    if (window->application->is_hidden) return false;
    if (!window->is_root) return false;
    if (!window_is_standard(window)) return false;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return false;
    if (window_check_flag(window, WINDOW_FULLSCREEN)) return false;
    return true;
}

static bool managed_space_display_uuid_is_active(CFStringRef uuid)
{
    if (!uuid) return false;
    return display_id(uuid) != 0;
}

static bool managed_space_has_preferred_display(struct managed_space *ms, CFStringRef uuid)
{
    if (!uuid) return false;

    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        if (ms->spaces[i].preferred_display_uuid &&
            CFEqual(ms->spaces[i].preferred_display_uuid, uuid)) {
            return true;
        }
    }

    return false;
}

static bool managed_space_has_absent_preferred_display(struct managed_space *ms)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        if (ms->spaces[i].preferred_display_uuid &&
            !managed_space_display_uuid_is_active(ms->spaces[i].preferred_display_uuid)) {
            return true;
        }
    }

    return false;
}

static void managed_space_refresh_sids(struct managed_space *ms)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        ms->spaces[i].sid = 0;
    }

    table_for (struct view *view, g_space_manager.view, {
        if (!view->uuid) continue;

        struct managed_space_entry *entry = managed_space_find_by_uuid(ms, view->uuid);
        if (entry) {
            entry->sid = view->sid;
            managed_space_refresh_label(entry);
        }
    })
}

static int managed_space_count_for_display(struct managed_space *ms, uint32_t did)
{
    int result = 0;

    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        uint64_t sid = ms->spaces[i].sid;
        if (!sid) continue;
        if (!space_is_user(sid)) continue;
        if (space_is_fullscreen(sid)) continue;
        if (space_display_id(sid) == did) ++result;
    }

    return result;
}

static bool managed_space_display_has_managed_user_space(struct managed_space *ms, uint32_t did)
{
    return managed_space_count_for_display(ms, did) > 0;
}

static bool managed_space_is_raw_empty(uint64_t sid)
{
    int window_count = 0;
    space_window_list(sid, &window_count, true);
    return window_count == 0;
}

static struct managed_space_entry *managed_space_select_donor(struct managed_space *ms, uint32_t target_did, bool prefer_empty)
{
    struct managed_space_entry *fallback = NULL;

    for (int i = buf_len(ms->spaces) - 1; i >= 0; --i) {
        struct managed_space_entry *entry = &ms->spaces[i];
        uint64_t sid = entry->sid;
        if (!sid) continue;
        if (!space_is_user(sid)) continue;
        if (space_is_fullscreen(sid)) continue;
        if (space_display_id(sid) == target_did) continue;
        if (prefer_empty && !managed_space_is_raw_empty(sid)) continue;

        bool only_managed_on_source = managed_space_count_for_display(ms, space_display_id(sid)) <= 1;
        if (!only_managed_on_source) return entry;
        if (!fallback) fallback = entry;
    }

    return fallback;
}

static struct managed_space_entry *managed_space_closest_managed_space(struct managed_space *ms, uint64_t sid)
{
    int target_index = space_manager_mission_control_index(sid);
    if (!target_index) return NULL;

    struct managed_space_entry *best = NULL;
    int best_delta = INT_MAX;
    int best_index = 0;

    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_entry *entry = &ms->spaces[i];
        if (!entry->sid) continue;
        if (!space_is_user(entry->sid)) continue;
        if (space_is_fullscreen(entry->sid)) continue;

        int index = space_manager_mission_control_index(entry->sid);
        if (!index) continue;

        int delta = abs(index - target_index);
        bool better = delta < best_delta;
        if (!better && delta == best_delta) {
            better = index < target_index && (best_index > target_index || index > best_index);
        }

        if (better) {
            best = entry;
            best_delta = delta;
            best_index = index;
        }
    }

    return best;
}

static bool managed_space_any_display_animating(void)
{
    int display_count = 0;
    uint32_t *display_list = display_manager_active_display_list(&display_count);

    for (int i = 0; i < display_count; ++i) {
        if (display_manager_display_is_animating(display_list[i])) {
            return true;
        }
    }

    return false;
}

static bool managed_space_move_preferred_spaces_back(struct managed_space *ms, bool *changed)
{
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_entry *entry = &ms->spaces[i];
        if (!entry->sid) continue;
        if (!entry->preferred_display_uuid) continue;

        uint32_t preferred_did = display_id(entry->preferred_display_uuid);
        if (!preferred_did) continue;

        uint32_t current_did = space_display_id(entry->sid);
        if (current_did == preferred_did) continue;

        enum space_op_error result = space_manager_move_space_to_display(&g_space_manager, entry->sid, preferred_did);
        if (result == SPACE_OP_ERROR_SUCCESS) {
            *changed = true;
            return true;
        }

        if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING ||
            result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
            ms->pending_reconcile = true;
            return true;
        }
    }

    return false;
}

static bool managed_space_ensure_display_coverage(struct managed_space *ms, bool *changed)
{
    int display_count = 0;
    uint32_t *display_list = display_manager_active_display_list(&display_count);

    for (int i = 0; i < display_count; ++i) {
        uint32_t did = display_list[i];
        if (managed_space_display_has_managed_user_space(ms, did)) continue;

        CFStringRef target_uuid = display_uuid(did);
        bool target_has_affinity = managed_space_has_preferred_display(ms, target_uuid);

        struct managed_space_entry *donor = managed_space_select_donor(ms, did, true);
        if (!donor) donor = managed_space_select_donor(ms, did, false);
        if (!donor) {
            if (target_uuid) CFRelease(target_uuid);
            continue;
        }

        bool donor_preferred_active = managed_space_display_uuid_is_active(donor->preferred_display_uuid);
        enum space_op_error result = space_manager_move_space_to_display(&g_space_manager, donor->sid, did);
        if (result == SPACE_OP_ERROR_SUCCESS) {
            if (!target_has_affinity && donor_preferred_active) {
                if (donor->preferred_display_uuid) CFRelease(donor->preferred_display_uuid);
                donor->preferred_display_uuid = target_uuid ? CFRetain(target_uuid) : NULL;
            }
            if (target_uuid) CFRelease(target_uuid);
            *changed = true;
            return true;
        }

        if (target_uuid) CFRelease(target_uuid);
        if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING ||
            result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
            ms->pending_reconcile = true;
            return true;
        }
    }

    return false;
}

static int managed_space_pending_window_repairs(struct managed_space *ms)
{
    int result = 0;

    for (int i = 0; i < buf_len(ms->windows); ++i) {
        struct managed_window_entry *window_entry = &ms->windows[i];
        struct window *window = window_manager_find_window(&g_window_manager, window_entry->wid);
        if (!managed_space_window_is_actionable(window)) continue;

        struct managed_space_entry *target = managed_space_find_by_uuid(ms, window_entry->space_uuid);
        if (!target || !target->sid) continue;

        uint64_t current_sid = window_space(window->id);
        struct managed_space_entry *current = managed_space_find_by_sid_internal(ms, current_sid);
        if (!current || current != target) ++result;
    }

    return result;
}

static int managed_space_repair_windows(struct managed_space *ms, bool *changed)
{
    int repaired_count = 0;

    for (int i = 0; i < buf_len(ms->windows); ++i) {
        struct managed_window_entry *window_entry = &ms->windows[i];
        struct window *window = window_manager_find_window(&g_window_manager, window_entry->wid);
        if (!managed_space_window_is_actionable(window)) continue;

        struct managed_space_entry *target = managed_space_find_by_uuid(ms, window_entry->space_uuid);
        if (!target || !target->sid) continue;
        if (space_is_fullscreen(target->sid)) continue;

        uint64_t current_sid = window_space(window->id);
        struct managed_space_entry *current = managed_space_find_by_sid_internal(ms, current_sid);
        if (current == target) continue;

        window_manager_send_window_to_space(&g_space_manager, &g_window_manager, window, target->sid, false);
        ++repaired_count;
        *changed = true;
    }

    return repaired_count;
}

static bool managed_space_cleanup_one_extra(struct managed_space *ms, bool *changed)
{
    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (!space_is_user(sid)) continue;
        if (space_is_fullscreen(sid)) continue;
        if (managed_space_find_by_sid_internal(ms, sid)) continue;

        int window_count = 0;
        uint32_t *window_list = space_window_list(sid, &window_count, true);
        if (window_count > 0) {
            struct managed_space_entry *target = managed_space_closest_managed_space(ms, sid);
            if (!target || !target->sid) continue;

            space_manager_move_window_list_to_space(target->sid, window_list, window_count);
            *changed = true;
            return true;
        }

        enum space_op_error result = space_manager_destroy_space(sid);
        if (result == SPACE_OP_ERROR_SUCCESS) {
            *changed = true;
            return true;
        }

        if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING ||
            result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
            ms->pending_reconcile = true;
            return true;
        }
    }

    return false;
}

static void managed_space_prune_missing_windows(struct managed_space *ms)
{
    for (int i = 0; i < buf_len(ms->windows); ++i) {
        if (!window_manager_find_window(&g_window_manager, ms->windows[i].wid)) {
            managed_window_entry_destroy(&ms->windows[i]);
            if (buf_del(ms->windows, i)) --i;
        }
    }
}

static void managed_space_update_window_cache(struct managed_space *ms, bool preserve_existing)
{
    managed_space_prune_missing_windows(ms);

    table_for (struct window *window, g_window_manager.window, {
        if (!managed_space_window_is_actionable(window)) continue;

        uint64_t sid = window_space(window->id);
        struct managed_space_entry *space_entry = managed_space_find_by_sid_internal(ms, sid);
        if (!space_entry || !space_entry->uuid) continue;

        struct managed_window_entry *window_entry = managed_space_find_window_entry(ms, window->id);
        if (preserve_existing && window_entry) continue;

        managed_space_set_window_namespace(ms, window_entry, window->id, space_entry->uuid);
    })
}

static int managed_space_compute_extra_count(struct managed_space *ms)
{
    int result = 0;

    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (!space_is_user(sid)) continue;
        if (space_is_fullscreen(sid)) continue;
        if (!managed_space_find_by_sid_internal(ms, sid)) ++result;
    }

    return result;
}

static void managed_space_refresh_topology_grace(struct managed_space *ms)
{
    bool absent_display = managed_space_has_absent_preferred_display(ms);
    int pending_window_repairs = managed_space_pending_window_repairs(ms);
    ms->topology_grace = absent_display || pending_window_repairs > 0;
}

void managed_space_init(struct managed_space *ms)
{
    memset(ms, 0, sizeof(struct managed_space));
}

void managed_space_set_enabled(struct managed_space *ms, bool enabled)
{
    if (ms->enabled == enabled) return;

    managed_space_clear(ms);
    ms->enabled = enabled;

    if (!enabled) {
        event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
        return;
    }

    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (!space_is_user(sid)) continue;

        space_manager_find_view(&g_space_manager, sid);
        managed_space_add_entry(ms, sid);
    }

    managed_space_update_window_cache(ms, false);
    ms->last_extra_count = managed_space_compute_extra_count(ms);
    ms->last_managed_count = buf_len(ms->spaces);
    ms->last_active_order = managed_space_active_order(ms);
    event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
    managed_space_request_reconcile(ms);
}

void managed_space_query(FILE *rsp, struct managed_space *ms)
{
    managed_space_refresh_sids(ms);
    managed_space_refresh_topology_grace(ms);

    fprintf(rsp,
            "{\n"
            "\t\"enabled\":%s,\n"
            "\t\"managed-space-count\":%d,\n"
            "\t\"extra-space-count\":%d,\n"
            "\t\"remembered-window-count\":%d,\n"
            "\t\"pending-window-repair-count\":%d,\n"
            "\t\"pending-user-create-count\":%d,\n"
            "\t\"topology-grace\":%s,\n"
            "\t\"last-repaired-window-count\":%d,\n"
            "\t\"active-managed-order\":%d,\n"
            "\t\"spaces\":[",
            json_bool(ms->enabled),
            buf_len(ms->spaces),
            managed_space_compute_extra_count(ms),
            buf_len(ms->windows),
            managed_space_pending_window_repairs(ms),
            ms->pending_user_creates,
            json_bool(ms->topology_grace),
            ms->last_repaired_window_count,
            managed_space_active_order(ms));

    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_entry *entry = &ms->spaces[i];

        char *uuid = entry->uuid ? ts_cfstring_copy(entry->uuid) : NULL;
        char *preferred_uuid = entry->preferred_display_uuid ? ts_cfstring_copy(entry->preferred_display_uuid) : NULL;
        int index = entry->sid ? space_manager_mission_control_index(entry->sid) : 0;
        uint32_t did = entry->sid ? space_display_id(entry->sid) : 0;
        int display = did ? display_manager_display_id_arrangement(did) : 0;
        int preferred_display = entry->preferred_display_uuid ? display_manager_display_id_arrangement(display_id(entry->preferred_display_uuid)) : 0;
        int window_count = 0;
        if (entry->sid) space_window_list(entry->sid, &window_count, true);

        fprintf(rsp,
                "%s{\n"
                "\t\t\"order\":%d,\n"
                "\t\t\"id\":%lld,\n"
                "\t\t\"uuid\":\"%s\",\n"
                "\t\t\"index\":%d,\n"
                "\t\t\"label\":\"%s\",\n"
                "\t\t\"display\":%d,\n"
                "\t\t\"preferred-display\":%d,\n"
                "\t\t\"preferred-display-uuid\":\"%s\",\n"
                "\t\t\"preferred-display-active\":%s,\n"
                "\t\t\"missing\":%s,\n"
                "\t\t\"native-fullscreen\":%s,\n"
                "\t\t\"window-count\":%d\n"
                "\t}",
                i ? "," : "",
                entry->order,
                entry->sid,
                uuid ? uuid : "",
                index,
                entry->label ? entry->label : "",
                display,
                preferred_display,
                preferred_uuid ? preferred_uuid : "",
                json_bool(managed_space_display_uuid_is_active(entry->preferred_display_uuid)),
                json_bool(entry->sid == 0),
                json_bool(entry->sid && space_is_fullscreen(entry->sid)),
                window_count);
    }

    fprintf(rsp, "],\n\t\"windows\":[");

    for (int i = 0; i < buf_len(ms->windows); ++i) {
        struct managed_window_entry *window_entry = &ms->windows[i];
        struct managed_space_entry *space_entry = managed_space_find_by_uuid(ms, window_entry->space_uuid);
        char *space_uuid = window_entry->space_uuid ? ts_cfstring_copy(window_entry->space_uuid) : NULL;

        fprintf(rsp,
                "%s{\n"
                "\t\t\"id\":%d,\n"
                "\t\t\"managed-order\":%d,\n"
                "\t\t\"managed-space-uuid\":\"%s\",\n"
                "\t\t\"missing\":%s\n"
                "\t}",
                i ? "," : "",
                window_entry->wid,
                space_entry ? space_entry->order : 0,
                space_uuid ? space_uuid : "",
                json_bool(window_manager_find_window(&g_window_manager, window_entry->wid) == NULL));
    }

    fprintf(rsp, "]\n}\n");
}

void managed_space_prepare_user_space_create(struct managed_space *ms)
{
    if (!ms->enabled) return;
    ++ms->pending_user_creates;
}

void managed_space_cancel_user_space_create(struct managed_space *ms)
{
    if (!ms->enabled) return;
    if (ms->pending_user_creates > 0) --ms->pending_user_creates;
}

void managed_space_note_user_space_destroyed(struct managed_space *ms, uint64_t sid)
{
    if (!ms->enabled) return;

    if (managed_space_remove_entry(ms, sid)) {
        event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
    }

    managed_space_request_reconcile(ms);
}

void managed_space_note_user_space_display_changed(struct managed_space *ms, uint64_t sid, uint32_t did)
{
    if (!ms->enabled) return;

    struct managed_space_entry *entry = managed_space_find_by_sid_internal(ms, sid);
    if (!entry) return;

    managed_space_set_preferred_display(entry, did);
    managed_space_request_reconcile(ms);
}

void managed_space_note_space_label_changed(struct managed_space *ms, uint64_t sid)
{
    if (!ms->enabled) return;

    struct managed_space_entry *entry = managed_space_find_by_sid_internal(ms, sid);
    if (!entry) return;

    managed_space_refresh_label(entry);
}

void managed_space_note_user_window_space_changed(struct managed_space *ms, struct window *window, uint64_t sid)
{
    if (!ms->enabled) return;
    if (!managed_space_window_is_actionable(window)) return;

    struct managed_space_entry *space_entry = managed_space_find_by_sid_internal(ms, sid);
    if (!space_entry || !space_entry->uuid) return;

    struct managed_window_entry *window_entry = managed_space_find_window_entry(ms, window->id);
    managed_space_set_window_namespace(ms, window_entry, window->id, space_entry->uuid);
    managed_space_request_reconcile(ms);
}

void managed_space_handle_space_created(struct managed_space *ms, uint64_t sid)
{
    if (!ms->enabled) return;
    if (!sid || !space_is_user(sid)) return;

    if (ms->pending_user_creates > 0) {
        --ms->pending_user_creates;
        managed_space_add_entry(ms, sid);
        event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
    }

    managed_space_request_reconcile(ms);
}

void managed_space_handle_space_destroyed(struct managed_space *ms, uint64_t sid)
{
    if (!ms->enabled) return;

    struct managed_space_entry *entry = managed_space_find_by_sid_internal(ms, sid);
    if (entry) {
        entry->sid = 0;
        event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
    }

    managed_space_request_reconcile(ms);
}

void managed_space_note_topology_event(struct managed_space *ms)
{
    if (!ms->enabled) return;

    ms->topology_grace = true;
    managed_space_request_reconcile(ms);
}

void managed_space_request_reconcile(struct managed_space *ms)
{
    if (!ms->enabled) return;

    if (ms->is_reconciling) {
        ms->pending_reconcile = true;
        return;
    }

    if (!ms->event_posted) {
        ms->event_posted = true;
        event_loop_post(&g_event_loop, MANAGED_SPACES_RECONCILE, NULL, 0);
    }
}

void managed_space_reconcile(struct managed_space *ms)
{
    ms->event_posted = false;
    if (!ms->enabled) return;

    if (ms->is_reconciling) {
        ms->pending_reconcile = true;
        return;
    }

    ms->is_reconciling = true;
    ms->pending_reconcile = false;

    bool changed = false;
    bool deferred = false;
    int repaired_count = 0;

    for (int pass = 0; pass < MANAGED_SPACE_MAX_RECONCILE_PASSES; ++pass) {
        managed_space_refresh_sids(ms);
        managed_space_refresh_topology_grace(ms);

        if (mission_control_is_active() || managed_space_any_display_animating()) {
            ms->pending_reconcile = true;
            deferred = true;
            break;
        }

        if (managed_space_move_preferred_spaces_back(ms, &changed)) continue;
        if (managed_space_ensure_display_coverage(ms, &changed)) continue;

        if (ms->topology_grace) {
            int repaired = managed_space_repair_windows(ms, &changed);
            repaired_count += repaired;
            if (repaired) continue;
        }

        if (managed_space_cleanup_one_extra(ms, &changed)) continue;

        break;
    }

    managed_space_refresh_sids(ms);
    managed_space_refresh_topology_grace(ms);
    managed_space_update_window_cache(ms, ms->topology_grace);

    ms->last_extra_count = managed_space_compute_extra_count(ms);
    ms->last_repaired_window_count = repaired_count;
    ms->last_managed_count = buf_len(ms->spaces);
    ms->last_active_order = managed_space_active_order(ms);

    if (changed || repaired_count > 0) {
        event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
    }

    ms->is_reconciling = false;

    if (ms->pending_reconcile && !deferred) {
        ms->pending_reconcile = false;
        managed_space_request_reconcile(ms);
    }
}

bool managed_space_is_enabled(struct managed_space *ms)
{
    return ms->enabled;
}

bool managed_space_is_managed_sid(struct managed_space *ms, uint64_t sid)
{
    return managed_space_find_by_sid_internal(ms, sid) != NULL;
}

int managed_space_order_for_sid(struct managed_space *ms, uint64_t sid)
{
    struct managed_space_entry *entry = managed_space_find_by_sid_internal(ms, sid);
    return entry ? entry->order : 0;
}

int managed_space_count(struct managed_space *ms)
{
    return buf_len(ms->spaces);
}

int managed_space_extra_count(struct managed_space *ms)
{
    return ms->last_extra_count;
}

int managed_space_repaired_window_count(struct managed_space *ms)
{
    return ms->last_repaired_window_count;
}

int managed_space_active_order(struct managed_space *ms)
{
    return managed_space_order_for_sid(ms, g_space_manager.current_space_id);
}
