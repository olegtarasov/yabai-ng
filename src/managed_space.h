#ifndef MANAGED_SPACE_H
#define MANAGED_SPACE_H

struct managed_space_entry
{
    CFStringRef uuid;
    CFStringRef preferred_display_uuid;
    uint64_t sid;
    int order;
    char *name;
    char *label;
};

struct managed_window_entry
{
    uint32_t wid;
    CFStringRef space_uuid;
};

struct managed_space
{
    bool enabled;
    bool event_posted;
    bool is_reconciling;
    bool pending_reconcile;
    bool topology_grace;
    bool replacement_retry_posted;
    int pending_user_creates;
    int pending_replacement_order;
    int pending_replacement_retries;
    int last_replacement_error;
    int last_extra_count;
    int last_repaired_window_count;
    int last_managed_count;
    int last_active_order;
    uint64_t last_focused_sid;
    uint64_t last_presentation_hash;
    CFStringRef fullscreen_origin_uuid;
    struct managed_space_entry *spaces;
    struct managed_window_entry *windows;
    char **names;
};

extern struct managed_space g_managed_space;

void managed_space_init(struct managed_space *ms);
void managed_space_destroy(struct managed_space *ms);
void managed_space_set_enabled(struct managed_space *ms, bool enabled);
void managed_space_set_names(struct managed_space *ms, char *names);
void managed_space_write_names(FILE *rsp, struct managed_space *ms);
void managed_space_query(FILE *rsp, struct managed_space *ms);

void managed_space_prepare_user_space_create(struct managed_space *ms);
void managed_space_cancel_user_space_create(struct managed_space *ms);
void managed_space_note_user_space_destroyed(struct managed_space *ms, uint64_t sid);
void managed_space_note_user_space_display_changed(struct managed_space *ms, uint64_t sid, uint32_t did);
void managed_space_note_space_label_changed(struct managed_space *ms, uint64_t sid);
void managed_space_note_user_window_space_changed(struct managed_space *ms, struct window *window, uint64_t sid);
void managed_space_note_focus_changed(struct managed_space *ms);

void managed_space_handle_space_created(struct managed_space *ms, uint64_t sid);
void managed_space_handle_space_destroyed(struct managed_space *ms, uint64_t sid);
void managed_space_note_topology_event(struct managed_space *ms);
void managed_space_request_reconcile(struct managed_space *ms);
void managed_space_reconcile(struct managed_space *ms);

bool managed_space_is_enabled(struct managed_space *ms);
bool managed_space_is_managed_sid(struct managed_space *ms, uint64_t sid);
int managed_space_order_for_sid(struct managed_space *ms, uint64_t sid);
char *managed_space_name_for_sid(struct managed_space *ms, uint64_t sid);
int managed_space_count(struct managed_space *ms);
int managed_space_extra_count(struct managed_space *ms);
int managed_space_repaired_window_count(struct managed_space *ms);
int managed_space_active_order(struct managed_space *ms);
int managed_space_active_index(struct managed_space *ms);
int managed_space_active_display(struct managed_space *ms);
char *managed_space_active_name(struct managed_space *ms);
uint64_t managed_space_next_fullscreen_target(struct managed_space *ms, uint64_t acting_sid);
uint64_t managed_space_prev_fullscreen_target(struct managed_space *ms, uint64_t acting_sid);

bool managed_space_window_is_displayable(struct window *window);
int managed_space_displayable_window_count(uint64_t sid);
void managed_space_serialize_displayable_windows(FILE *rsp, uint64_t sid);
void managed_space_serialize_displayable_apps(FILE *rsp, uint64_t sid);

#endif
