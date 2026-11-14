#ifndef MANAGED_SPACE_INTERNAL_H
#define MANAGED_SPACE_INTERNAL_H

// One observation is owned by a reconcile pass; policy does not query macOS while planning.
struct managed_space_observed_display {
    uint32_t did;
    CFStringRef uuid;
    uint64_t active_sid;
    bool main;
    bool animating;
};
struct managed_space_observed_space {
    uint64_t sid;
    CFStringRef uuid;
    uint32_t did;
    int index;
    bool normal;
    bool fullscreen;
    uint32_t *windows;
};
struct managed_space_observed_window {
    uint32_t wid;
    uint64_t sid;
    bool actionable;
    bool fullscreen;
    bool dragged;
};
struct managed_space_observation {
    struct managed_space_observed_display *displays;
    struct managed_space_observed_space *spaces;
    struct managed_space_observed_window *windows;
    uint64_t hash;
    bool valid;
    bool blocked;
};
enum managed_space_action_type {
    MANAGED_SPACE_ACTION_NONE,
    MANAGED_SPACE_ACTION_CREATE,
    MANAGED_SPACE_ACTION_BIND,
    MANAGED_SPACE_ACTION_MOVE_DISPLAY,
    MANAGED_SPACE_ACTION_REORDER,
    MANAGED_SPACE_ACTION_REPAIR_WINDOW,
    MANAGED_SPACE_ACTION_EVACUATE,
    MANAGED_SPACE_ACTION_DESTROY
};
struct managed_space_action {
    enum managed_space_action_type type;
    uint64_t sid;
    uint64_t target_sid;
    uint32_t did;
    uint32_t wid;
    CFStringRef replacement_uuid;
    bool managed;
};

static void managed_window_entry_destroy(struct managed_window_entry *entry);
static void managed_space_create_request_destroy(struct managed_space_create_request *request);
static uint64_t managed_space_hash_u64(uint64_t hash, uint64_t value);
static uint64_t managed_space_hash_string(uint64_t hash, char *value);
static void managed_space_publish_presentation_if_needed(struct managed_space *ms);
static bool managed_space_window_can_track(struct window *window);
static uint64_t managed_space_required_placeholder_sid(struct managed_space *ms, uint32_t did);
static int managed_space_placeholder_count(struct managed_space *ms);
static int managed_space_compute_extra_count(struct managed_space *ms);
static bool managed_space_is_required_placeholder(struct managed_space *ms, uint64_t sid);
static bool managed_space_has_target_display(struct managed_space *ms, uint32_t did);
static void managed_space_update_window_cache(struct managed_space *ms, bool preserve_existing);
static int managed_space_normal_space_count(void);
static void managed_space_remove_pending_create_at_index(struct managed_space *ms, int index);
static void managed_space_add_pending_create(struct managed_space *ms, uint32_t did, enum managed_space_display_affinity affinity, bool managed);
static void managed_space_set_pending_placement(struct managed_window_entry *entry, uint64_t source_sid, CFStringRef target_uuid);
static void managed_space_clear_pending_placement(struct managed_window_entry *entry);
static void managed_space_capture_observation(struct managed_space *ms, struct managed_space_observation *observation);
static void managed_space_destroy_observation(struct managed_space_observation *observation);
static struct managed_space_observed_space *managed_space_observed_sid(struct managed_space_observation *observation, uint64_t sid);
static struct managed_space_observed_space *managed_space_observed_uuid(struct managed_space_observation *observation, CFStringRef uuid);
static struct managed_space_observed_display *managed_space_observed_display(struct managed_space_observation *observation, uint32_t did);
static struct managed_space_action managed_space_plan(struct managed_space *ms, struct managed_space_observation *observation);
static uint64_t managed_space_action_key(struct managed_space_action action);
static bool managed_space_admit_observed_creates(struct managed_space *ms, struct managed_space_observation *observation);
static void managed_space_refresh_observed_intent(struct managed_space *ms, struct managed_space_observation *observation);
static int managed_space_pending_window_repairs(struct managed_space *ms);
#endif
