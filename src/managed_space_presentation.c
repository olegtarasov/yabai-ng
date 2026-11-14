// Presentation is a projection of observations. Serializers never update registry or intent.
static bool managed_space_window_is_ordered_in(struct window *window)
{
    uint8_t ordered = 0;
    SLSWindowIsOrderedIn(g_connection, window->id, &ordered);
    return ordered;
}

static bool managed_space_window_is_presentable(struct window *window)
{
    return window && window->id && window->application && !window->application->is_hidden && window->is_root &&
        window_is_standard(window) && !window_check_flag(window, WINDOW_STICKY) && !window_is_sticky(window->id) &&
        !window_check_flag(window, WINDOW_MINIMIZE);
}

bool managed_space_window_is_displayable(struct window *window)
{
    return managed_space_window_is_presentable(window) && native_tab_is_presentation_window(&g_window_manager, window) &&
        managed_space_window_is_ordered_in(window);
}

static void managed_space_presentation_add(struct managed_space_presentation *p, struct window *window)
{
    if (!managed_space_window_is_displayable(window)) return;
    for (int i = 0; i < buf_len(p->windows); ++i) if (p->windows[i] == window->id) return;
    buf_push(p->windows, window->id);
    if (!window->application->name) return;
    for (int i = 0; i < buf_len(p->apps); ++i) if (string_equals(p->apps[i], window->application->name)) return;
    buf_push(p->apps, string_copy(window->application->name));
}

void managed_space_capture_presentation(uint64_t sid, struct managed_space_presentation *p)
{
    memset(p, 0, sizeof(*p));
    int count = 0;
    uint32_t *windows = space_window_list(sid, &count, true);
    for (int i = 0; i < count; ++i) managed_space_presentation_add(p, window_manager_find_window(&g_window_manager, windows[i]));
    struct view *view = space_is_fullscreen(sid) ? NULL : space_manager_query_view(&g_space_manager, sid);
    if (view) {
        int retained_count = 0;
        uint32_t *retained = view_find_window_list(view, &retained_count);
        for (int i = 0; i < retained_count; ++i) {
            struct window *window = window_manager_find_window(&g_window_manager, retained[i]);
            if (window && native_tab_should_preserve_parent(&g_window_manager, window)) managed_space_presentation_add(p, window);
        }
    }
}

void managed_space_destroy_presentation(struct managed_space_presentation *p)
{
    for (int i = 0; i < buf_len(p->apps); ++i) free(p->apps[i]);
    buf_free(p->apps); buf_free(p->windows);
    memset(p, 0, sizeof(*p));
}

void managed_space_serialize_presentation_windows(FILE *rsp, struct managed_space_presentation *p)
{
    fprintf(rsp, "[");
    for (int i = 0; i < buf_len(p->windows); ++i) fprintf(rsp, "%s%u", i ? ", " : "", p->windows[i]);
    fprintf(rsp, "]");
}

void managed_space_serialize_presentation_apps(FILE *rsp, struct managed_space_presentation *p)
{
    fprintf(rsp, "[");
    for (int i = 0; i < buf_len(p->apps); ++i) {
        char *app = ts_string_escape(p->apps[i]);
        fprintf(rsp, "%s\"%s\"", i ? ", " : "", app ? app : p->apps[i]);
    }
    fprintf(rsp, "]");
}

int managed_space_displayable_window_count(uint64_t sid)
{
    struct managed_space_presentation p; managed_space_capture_presentation(sid, &p);
    int result = buf_len(p.windows); managed_space_destroy_presentation(&p); return result;
}

void managed_space_serialize_displayable_windows(FILE *rsp, uint64_t sid)
{
    struct managed_space_presentation p; managed_space_capture_presentation(sid, &p);
    managed_space_serialize_presentation_windows(rsp, &p); managed_space_destroy_presentation(&p);
}

void managed_space_serialize_displayable_apps(FILE *rsp, uint64_t sid)
{
    struct managed_space_presentation p; managed_space_capture_presentation(sid, &p);
    managed_space_serialize_presentation_apps(rsp, &p); managed_space_destroy_presentation(&p);
}

static uint64_t managed_space_presentation_hash(struct managed_space *ms)
{
    uint64_t hash = managed_space_hash_u64(1469598103934665603ULL, ms->enabled);
    hash = managed_space_hash_u64(hash, ms->scripting_addition_ready);
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_entry *entry = &ms->spaces[i];
        hash = managed_space_hash_u64(hash, entry->sid);
        hash = managed_space_hash_u64(hash, entry->order);
        hash = managed_space_hash_u64(hash, entry->sid ? space_manager_mission_control_index(entry->sid) : 0);
        hash = managed_space_hash_u64(hash, entry->sid ? space_display_id(entry->sid) : 0);
        hash = managed_space_hash_u64(hash, entry->display_affinity);
        hash = managed_space_hash_string(hash, entry->name);
        hash = managed_space_hash_string(hash, entry->label);
        struct managed_space_presentation p; managed_space_capture_presentation(entry->sid, &p);
        hash = managed_space_hash_u64(hash, buf_len(p.windows));
        hash = managed_space_hash_u64(hash, entry->sid && space_is_visible(entry->sid));
        for (int j = 0; j < buf_len(p.apps); ++j) hash = managed_space_hash_string(hash, p.apps[j]);
        managed_space_destroy_presentation(&p);
    }
    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (!space_is_fullscreen(sid)) continue;
        hash = managed_space_hash_u64(hash, sid);
        hash = managed_space_hash_u64(hash, index);
        hash = managed_space_hash_u64(hash, space_display_id(sid));
        hash = managed_space_hash_u64(hash, space_is_visible(sid));
        struct managed_space_presentation p; managed_space_capture_presentation(sid, &p);
        hash = managed_space_hash_u64(hash, buf_len(p.windows));
        for (int j = 0; j < buf_len(p.apps); ++j) hash = managed_space_hash_string(hash, p.apps[j]);
        managed_space_destroy_presentation(&p);
    }
    return hash;
}

static void managed_space_publish_presentation_if_needed(struct managed_space *ms)
{
    uint64_t hash = managed_space_presentation_hash(ms);
    if (hash == ms->last_presentation_hash) return;
    ms->last_presentation_hash = hash;
    event_signal_push(SIGNAL_MANAGED_SPACES_CHANGED, ms);
}

static const char *managed_space_scripting_addition_status_name(enum scripting_addition_probe_status status)
{
    switch (status) {
    case SCRIPTING_ADDITION_PROBE_UNAVAILABLE: return "unavailable";
    case SCRIPTING_ADDITION_PROBE_COMPATIBLE: return "compatible";
    case SCRIPTING_ADDITION_PROBE_VERSION_MISMATCH: return "version-mismatch";
    case SCRIPTING_ADDITION_PROBE_CAPABILITIES_MISSING: return "capabilities-missing";
    }
    return "unavailable";
}

void managed_space_query(FILE *rsp, struct managed_space *ms)
{
    struct managed_space_observation o; managed_space_capture_observation(ms, &o);
    int extra = 0, placeholders = 0, repairs = 0;
    for (int i = 0; i < buf_len(o.spaces); ++i) {
        struct managed_space_observed_space *space = &o.spaces[i];
        if (!space->normal || managed_space_find_by_uuid(ms, space->uuid)) continue;
        if (managed_space_observed_reserved(ms, &o, space)) ++placeholders; else ++extra;
    }
    for (int i = 0; i < buf_len(o.windows); ++i) {
        struct managed_space_observed_window *window = &o.windows[i];
        struct managed_window_entry *entry = managed_space_find_window_entry(ms, window->wid);
        if (!window->actionable || !entry) continue;
        struct managed_space_observed_space *target = managed_space_observed_uuid(&o, entry->secondary_space_uuid ? entry->secondary_space_uuid : entry->space_uuid);
        if (target && target->normal && target->sid != window->sid) ++repairs;
    }
    fprintf(rsp, "{\n\t\"enabled\":%s,\n\t\"scripting-addition-ready\":%s,\n\t\"scripting-addition-status\":\"%s\",\n"
        "\t\"scripting-addition-version\":\"%s\",\n\t\"scripting-addition-capabilities\":\"0x%08x\",\n\t\"last-error\":%d,\n"
        "\t\"managed-space-display-policy\":\"%s\",\n\t\"managed-space-count\":%d,\n\t\"extra-space-count\":%d,\n\t\"placeholder-space-count\":%d,\n"
        "\t\"remembered-window-count\":%d,\n\t\"dragged-window-count\":%d,\n\t\"pending-window-repair-count\":%d,\n"
        "\t\"pending-user-create-count\":%d,\n\t\"pending-create-count\":%d,\n\t\"last-repaired-window-count\":%d,\n\t\"window-repair-attempt-count\":%llu,\n"
        "\t\"active-managed-order\":%d,\n\t\"managed-space-names\":[",
        json_bool(ms->enabled), json_bool(ms->scripting_addition_ready), managed_space_scripting_addition_status_name(ms->scripting_addition.status),
        ms->scripting_addition.version, ms->scripting_addition.capabilities, ms->last_error,
        managed_space_display_affinity_name(ms->display_policy), buf_len(ms->spaces), extra, placeholders,
        buf_len(ms->windows), buf_len(ms->drag_windows), repairs, ms->pending_user_creates, buf_len(ms->pending_creates),
        ms->last_repaired_window_count, ms->window_repair_attempt_count, managed_space_active_order(ms));
    for (int i = 0; i < buf_len(ms->names); ++i) {
        char *name = ts_string_escape(ms->names[i]); fprintf(rsp, "%s\"%s\"", i ? "," : "", name ? name : ms->names[i]);
    }
    fprintf(rsp, "],\n\t\"spaces\":[");
    for (int i = 0; i < buf_len(ms->spaces); ++i) {
        struct managed_space_entry *entry = &ms->spaces[i];
        struct managed_space_observed_space *space = managed_space_observed_uuid(&o, entry->uuid);
        uint32_t did = managed_space_observed_target_display(entry, &o);
        char *uuid = entry->uuid ? ts_cfstring_copy(entry->uuid) : "";
        char *name = ts_string_escape(entry->name), *label = ts_string_escape(entry->label);
        struct managed_space_observed_display *target_display = managed_space_observed_display(&o, did);
        CFStringRef target_uuid = target_display ? target_display->uuid : entry->preferred_display_uuid;
        char *preferred = target_uuid ? ts_cfstring_copy(target_uuid) : "";
        fprintf(rsp, "%s{\"order\":%d,\"id\":%llu,\"uuid\":\"%s\",\"index\":%d,\"name\":\"%s\",\"label\":\"%s\","
            "\"display\":%d,\"preferred-display\":%d,\"preferred-display-uuid\":\"%s\",\"preferred-display-active\":%s,"
            "\"display-affinity\":\"%s\",\"missing\":%s,\"native-fullscreen\":%s,\"window-count\":%d}",
            i ? "," : "", entry->order, space ? space->sid : 0, uuid ? uuid : "", space ? space->index : 0,
            name ? name : "", label ? label : "", space ? display_manager_display_id_arrangement(space->did) : 0,
            did ? display_manager_display_id_arrangement(did) : 0, preferred ? preferred : "", json_bool(did != 0),
            managed_space_display_affinity_name(entry->display_affinity), json_bool(!space), json_bool(space && space->fullscreen), space ? buf_len(space->windows) : 0);
    }
    fprintf(rsp, "],\n\t\"windows\":[");
    for (int i = 0; i < buf_len(ms->windows); ++i) {
        struct managed_window_entry *entry = &ms->windows[i];
        struct managed_space_entry *home = managed_space_find_by_uuid(ms, entry->space_uuid);
        char *uuid = entry->space_uuid ? ts_cfstring_copy(entry->space_uuid) : "";
        char *secondary = entry->secondary_space_uuid ? ts_cfstring_copy(entry->secondary_space_uuid) : "";
        char *pending = entry->pending_space_uuid ? ts_cfstring_copy(entry->pending_space_uuid) : "";
        fprintf(rsp, "%s{\"id\":%u,\"managed-order\":%d,\"managed-space-uuid\":\"%s\",\"secondary-space-uuid\":\"%s\",\"pending-space-uuid\":\"%s\",\"missing\":%s}",
            i ? "," : "", entry->wid, home ? home->order : 0, uuid ? uuid : "", secondary ? secondary : "", pending ? pending : "",
            json_bool(!window_manager_find_window(&g_window_manager, entry->wid)));
    }
    fprintf(rsp, "],\n\t\"secondary-workspaces\":[");
    for (int i = 0; i < buf_len(ms->secondary_workspaces); ++i) {
        struct managed_secondary_workspace *workspace = &ms->secondary_workspaces[i];
        char *display = ts_cfstring_copy(workspace->display_uuid);
        char *uuid = workspace->space_uuid ? ts_cfstring_copy(workspace->space_uuid) : "";
        fprintf(rsp, "%s{\"display-uuid\":\"%s\",\"space-uuid\":\"%s\"}", i ? "," : "", display ? display : "", uuid ? uuid : "");
    }
    fprintf(rsp, "]\n}\n");
    managed_space_destroy_observation(&o);
}
