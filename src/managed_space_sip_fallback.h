#ifndef MANAGED_SPACE_SIP_FALLBACK_H
#define MANAGED_SPACE_SIP_FALLBACK_H

enum managed_space_sip_fallback_policy
{
    MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO,
    MANAGED_SPACE_SIP_FALLBACK_POLICY_BRIDGE,
    MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY
};

enum managed_space_sip_fallback_backend
{
    MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE,
    MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE,
    MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY
};

enum managed_space_sip_fallback_state
{
    MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE,
    MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED,
    MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_USER_MISSION_CONTROL,
    MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL,
    MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY,
    MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT,
    MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE,
    MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT,
    MANAGED_SPACE_SIP_FALLBACK_STATE_FAILED
};

struct managed_space_sip_fallback_request
{
    enum managed_space_topology_operation operation;
    enum managed_space_topology_origin origin;
    enum managed_space_sip_fallback_backend backend;
    uint64_t generation;
    uint64_t precondition_hash;
    uint64_t sid;
    uint64_t target_sid;
    uint64_t created_sid;
    uint64_t restore_focus_sid;
    uint64_t *pre_source_order;
    uint64_t *pre_target_order;
    uint32_t source_did;
    uint32_t target_did;
    int pre_source_count;
    int pre_target_count;
    int ax_source_count_before;
    int ax_target_count_before;
    int target_index;
    int phase;
    bool place_after;
    bool mutation_started;
    bool topology_event_observed;
    bool ax_precondition_observed;
    bool ax_postcondition_observed;
    bool dock_postcondition_observed;
    bool readiness_retry_scheduled;
    bool focus_space;
    bool ax_spaces_bar_hovered;
    bool placeholder_required;
    char sid_uuid[64];
    char target_uuid[64];
    uint64_t *desired_order;
    int desired_order_count;
};

struct managed_space_sip_fallback
{
    bool enabled;
    bool owns_mission_control;
    bool finish_batch_requested;
    bool space_limit_reached;
    bool reconciliation_blocked;
    uint64_t next_generation;
    uint64_t step_token;
    uint64_t step_generation;
    uint64_t watchdog_token;
    uint64_t watchdog_generation;
    uint64_t last_failed_generation;
    uint64_t active_submission_generation;
    uint64_t pending_focus_sid;
    enum managed_space_sip_fallback_policy policy;
    enum managed_space_sip_fallback_state state;
    struct managed_space_sip_fallback_request current;
    struct managed_space_sip_fallback_request *queue;
    uint32_t space_limit_did;
    uint32_t authority_did;
    int space_limit_count;
    int authority_sls_count;
    int authority_ax_count;
    bool authority_observed;
    bool authority_consistent;
    pid_t observed_dock_pid;
    AXObserverRef ax_observer;
    AXUIElementRef ax_observed_element;
    CFMachPortRef input_event_tap;
    CFRunLoopSourceRef input_event_source;
    char os_build[32];
    char operation_error[128];
    char last_error[128];
    enum managed_space_topology_operation last_failed_operation;
    enum managed_space_sip_fallback_backend last_failed_backend;
};

extern struct managed_space_sip_fallback g_managed_space_sip_fallback;

void managed_space_sip_fallback_init(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_destroy(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_set_enabled(struct managed_space_sip_fallback *topology, bool enabled);
bool managed_space_sip_fallback_is_enabled(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_note_configuration_changed(struct managed_space_sip_fallback *topology);

void managed_space_sip_fallback_set_backend_policy(
    struct managed_space_sip_fallback *topology,
    enum managed_space_sip_fallback_policy policy);

const char *managed_space_sip_fallback_backend_name(enum managed_space_sip_fallback_backend backend);
const char *managed_space_sip_fallback_state_name(enum managed_space_sip_fallback_state state);

void managed_space_sip_fallback_prepare_request(
    struct managed_space_sip_fallback *topology,
    struct managed_space_sip_fallback_request *request,
    enum managed_space_topology_origin origin);

struct managed_space_topology_result managed_space_sip_fallback_create(
    struct managed_space_sip_fallback *topology,
    enum managed_space_topology_origin origin,
    uint64_t acting_sid);
struct managed_space_topology_result managed_space_sip_fallback_destroy_space(
    struct managed_space_sip_fallback *topology,
    enum managed_space_topology_origin origin,
    uint64_t sid);
struct managed_space_topology_result managed_space_sip_fallback_move_space(
    struct managed_space_sip_fallback *topology,
    enum managed_space_topology_origin origin,
    uint64_t sid,
    uint64_t target_sid);
struct managed_space_topology_result managed_space_sip_fallback_swap_spaces(
    struct managed_space_sip_fallback *topology,
    enum managed_space_topology_origin origin,
    uint64_t sid,
    uint64_t target_sid);
struct managed_space_topology_result managed_space_sip_fallback_move_space_to_display(
    struct managed_space_sip_fallback *topology,
    enum managed_space_topology_origin origin,
    uint64_t sid,
    uint32_t did,
    bool placeholder_required);
bool managed_space_sip_fallback_prepare_move_request(struct managed_space_sip_fallback_request *request, uint64_t sid, uint64_t target_sid);
bool managed_space_sip_fallback_prepare_swap_request(struct managed_space_sip_fallback_request *request, uint64_t sid, uint64_t target_sid);
struct managed_space_topology_result managed_space_sip_fallback_submit_request(
    struct managed_space_sip_fallback *topology,
    struct managed_space_sip_fallback_request request,
    enum managed_space_topology_origin origin);
void managed_space_sip_fallback_discard_request(struct managed_space_sip_fallback_request *request);
bool managed_space_sip_fallback_request_is_satisfied(struct managed_space_sip_fallback_request *request);
bool managed_space_sip_fallback_space_limit_reached_for_display(struct managed_space_sip_fallback *topology, uint32_t did);

void managed_space_sip_fallback_handle_space_created(struct managed_space_sip_fallback *topology, uint64_t sid);
void managed_space_sip_fallback_handle_space_destroyed(struct managed_space_sip_fallback *topology, uint64_t sid);
void managed_space_sip_fallback_handle_focus_changed(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_handle_mission_control_enter(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_handle_mission_control_exit(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_handle_dock_restart(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_note_input_event(struct managed_space_sip_fallback *topology, CGEventRef event);
void managed_space_sip_fallback_handle_user_interruption(struct managed_space_sip_fallback *topology, uint64_t generation);
void managed_space_sip_fallback_step(struct managed_space_sip_fallback *topology, uint64_t token);
void managed_space_sip_fallback_watchdog(struct managed_space_sip_fallback *topology, uint64_t token);

bool managed_space_sip_fallback_operation_pending(struct managed_space_sip_fallback *topology);
bool managed_space_sip_fallback_reconciliation_blocked(struct managed_space_sip_fallback *topology);
bool managed_space_sip_fallback_owns_mission_control(struct managed_space_sip_fallback *topology);
bool managed_space_sip_fallback_defers_destroy_membership(struct managed_space_sip_fallback *topology, uint64_t sid);
void managed_space_sip_fallback_finish_batch(struct managed_space_sip_fallback *topology);
void managed_space_sip_fallback_write_query(FILE *rsp, struct managed_space_sip_fallback *topology);

#endif
