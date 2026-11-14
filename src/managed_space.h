#ifndef MANAGED_SPACE_H
#define MANAGED_SPACE_H

enum managed_space_display_affinity
{
    MANAGED_SPACE_DISPLAY_FOLLOW_MAIN,
    MANAGED_SPACE_DISPLAY_FIXED
};

struct managed_space_entry
{
    CFStringRef uuid;
    CFStringRef preferred_display_uuid;
    uint64_t sid;
    int order;
    enum managed_space_display_affinity display_affinity;
    char *name;
    char *label;
};

struct managed_space_create_request
{
    CFStringRef display_uuid;
    uint64_t sequence;
    enum managed_space_display_affinity display_affinity;
    bool managed;
    CFStringRef replacement_uuid;
    CFStringRef *known_space_uuids;
};

struct managed_window_entry
{
    uint32_t wid;
    // Managed recovery home; an explicit secondary residence temporarily takes precedence.
    CFStringRef space_uuid;
    CFStringRef secondary_space_uuid;
    // A shared bridged transfer may settle after the command or drag commits.
    CFStringRef pending_space_uuid;
    uint64_t pending_source_sid;
};

struct managed_secondary_workspace
{
    // Keep the reserved workspace stable across Mission Control reordering and SID refresh.
    CFStringRef display_uuid;
    CFStringRef space_uuid;
};

struct managed_space
{
    bool enabled;
    bool event_posted;
    bool is_reconciling;
    bool pending_reconcile;
    bool topology_grace;
    bool scripting_addition_ready;
    struct scripting_addition_probe_result scripting_addition;
    int pending_user_creates;
    enum space_op_error last_error;
    int last_extra_count;
    int last_placeholder_count;
    int last_repaired_window_count;
    int last_managed_count;
    int last_active_order;
    uint64_t last_focused_sid;
    uint64_t last_presentation_hash;
    uint64_t next_create_sequence;
    uint64_t window_repair_attempt_count;
    uint64_t last_action_observation;
    uint64_t last_action_key;
    CFStringRef fullscreen_origin_uuid;
    struct managed_space_entry *spaces;
    struct managed_space_create_request *pending_creates;
    struct managed_window_entry *windows;
    struct managed_secondary_workspace *secondary_workspaces;
    uint32_t *drag_windows;
    CFStringRef *replacement_receipts;
    char **names;
    enum managed_space_display_affinity display_policy;
};

extern struct managed_space g_managed_space;

void managed_space_init(struct managed_space *ms);
void managed_space_destroy(struct managed_space *ms);
bool managed_space_set_enabled(struct managed_space *ms, bool enabled);
void managed_space_note_topology_result(struct managed_space *ms, enum space_op_error result);
bool managed_space_refresh_scripting_addition(struct managed_space *ms);
bool managed_space_scripting_addition_is_ready(struct managed_space *ms);
void managed_space_handle_dock_restart(struct managed_space *ms);
enum space_op_error managed_space_validate_topology_command(struct managed_space *ms,
                                                            uint64_t sid, uint64_t target_sid,
                                                            bool requires_scripting_addition);
void managed_space_note_user_space_order_changed(struct managed_space *ms);
void managed_space_set_names(struct managed_space *ms, char *names);
void managed_space_write_names(FILE *rsp, struct managed_space *ms);
void managed_space_set_display_policy(struct managed_space *ms, enum managed_space_display_affinity display_policy);
enum managed_space_display_affinity managed_space_display_policy(struct managed_space *ms);
const char *managed_space_display_affinity_name(enum managed_space_display_affinity display_affinity);
void managed_space_query(FILE *rsp, struct managed_space *ms);

void managed_space_prepare_user_space_create(struct managed_space *ms, uint32_t did, enum managed_space_display_affinity display_affinity);
void managed_space_cancel_user_space_create(struct managed_space *ms);
enum space_op_error managed_space_prepare_move_placeholder(struct managed_space *ms,
                                                           uint64_t sid,
                                                           uint32_t target_did,
                                                           bool *required);
void managed_space_note_user_space_destroyed(struct managed_space *ms, uint64_t sid);
void managed_space_note_user_space_display_changed(struct managed_space *ms, uint64_t sid, uint32_t did);
void managed_space_note_space_label_changed(struct managed_space *ms, uint64_t sid);
void managed_space_note_user_window_list_space_changed(struct managed_space *ms, uint32_t *windows, int count, uint64_t sid);
void managed_space_note_user_window_space_changed(struct managed_space *ms, struct window *window, uint64_t sid);
void managed_space_begin_window_drag(struct managed_space *ms, struct window *window);
void managed_space_track_window_drag(struct managed_space *ms, struct window *window);
void managed_space_end_window_drag(struct managed_space *ms, bool commit);
bool managed_space_cancel_window_drag(struct managed_space *ms, uint32_t wid);
void managed_space_replace_window(struct managed_space *ms, uint32_t old_id, uint32_t new_id);
void managed_space_note_focus_changed(struct managed_space *ms);

void managed_space_handle_space_created(struct managed_space *ms, uint64_t sid);
void managed_space_handle_space_destroyed(struct managed_space *ms, uint64_t sid);
void managed_space_handle_window_ordered(struct managed_space *ms, uint32_t wid);
void managed_space_note_topology_event(struct managed_space *ms);
void managed_space_request_reconcile(struct managed_space *ms);
void managed_space_reconcile(struct managed_space *ms);

bool managed_space_is_enabled(struct managed_space *ms);
bool managed_space_is_managed_sid(struct managed_space *ms, uint64_t sid);
int managed_space_order_for_sid(struct managed_space *ms, uint64_t sid);
char *managed_space_name_for_sid(struct managed_space *ms, uint64_t sid);
uint64_t managed_space_sid_for_name(struct managed_space *ms, char *name);
int managed_space_count(struct managed_space *ms);
int managed_space_extra_count(struct managed_space *ms);
int managed_space_repaired_window_count(struct managed_space *ms);
int managed_space_active_order(struct managed_space *ms);
int managed_space_active_index(struct managed_space *ms);
int managed_space_active_display(struct managed_space *ms);
char *managed_space_active_name(struct managed_space *ms);
uint64_t managed_space_next_fullscreen_target(struct managed_space *ms, uint64_t acting_sid);
uint64_t managed_space_prev_fullscreen_target(struct managed_space *ms, uint64_t acting_sid);

struct managed_space_presentation
{
    uint32_t *windows;
    char **apps;
};
void managed_space_capture_presentation(uint64_t sid, struct managed_space_presentation *presentation);
void managed_space_destroy_presentation(struct managed_space_presentation *presentation);
void managed_space_serialize_presentation_windows(FILE *rsp, struct managed_space_presentation *presentation);
void managed_space_serialize_presentation_apps(FILE *rsp, struct managed_space_presentation *presentation);
bool managed_space_window_is_displayable(struct window *window);
int managed_space_displayable_window_count(uint64_t sid);
void managed_space_serialize_displayable_windows(FILE *rsp, uint64_t sid);
void managed_space_serialize_displayable_apps(FILE *rsp, uint64_t sid);

#endif
