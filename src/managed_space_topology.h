#ifndef MANAGED_SPACE_TOPOLOGY_H
#define MANAGED_SPACE_TOPOLOGY_H

enum managed_space_topology_backend_policy
{
    MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO,
    MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION,
    MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE,
    MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY
};

enum managed_space_topology_backend
{
    MANAGED_SPACE_TOPOLOGY_BACKEND_NONE,
    MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION,
    MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE,
    MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY
};

enum managed_space_topology_operation
{
    MANAGED_SPACE_TOPOLOGY_OPERATION_NONE,
    MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
    MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
    MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER,
    MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP,
    MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY
};

enum managed_space_topology_origin
{
    MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE,
    MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND
};

enum managed_space_topology_state
{
    MANAGED_SPACE_TOPOLOGY_STATE_IDLE,
    MANAGED_SPACE_TOPOLOGY_STATE_QUEUED,
    MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_USER_MISSION_CONTROL,
    MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL,
    MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY,
    MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT,
    MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE,
    MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT,
    MANAGED_SPACE_TOPOLOGY_STATE_FAILED
};

struct managed_space_topology_request
{
    enum managed_space_topology_operation operation;
    enum managed_space_topology_origin origin;
    enum managed_space_topology_backend backend;
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

struct managed_space_topology
{
    bool enabled;
    bool command_origin;
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
    enum managed_space_topology_backend_policy policy;
    enum managed_space_topology_state state;
    struct managed_space_topology_request current;
    struct managed_space_topology_request *queue;
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
    char os_build[32];
    char operation_error[128];
    char last_error[128];
    enum managed_space_topology_operation last_failed_operation;
    enum managed_space_topology_backend last_failed_backend;
};

extern struct managed_space_topology g_managed_space_topology;

void managed_space_topology_init(struct managed_space_topology *topology);
void managed_space_topology_destroy(struct managed_space_topology *topology);
void managed_space_topology_set_enabled(struct managed_space_topology *topology, bool enabled);
bool managed_space_topology_is_enabled(struct managed_space_topology *topology);
void managed_space_topology_note_configuration_changed(struct managed_space_topology *topology);

const char *managed_space_topology_backend_policy_name(enum managed_space_topology_backend_policy policy);
bool managed_space_topology_backend_policy_from_string(char *value, enum managed_space_topology_backend_policy *policy);
void managed_space_topology_set_backend_policy(struct managed_space_topology *topology, enum managed_space_topology_backend_policy policy);
enum managed_space_topology_backend_policy managed_space_topology_backend_policy(struct managed_space_topology *topology);

const char *managed_space_topology_backend_name(enum managed_space_topology_backend backend);
const char *managed_space_topology_operation_name(enum managed_space_topology_operation operation);
const char *managed_space_topology_origin_name(enum managed_space_topology_origin origin);
const char *managed_space_topology_state_name(enum managed_space_topology_state state);

void managed_space_topology_begin_command(struct managed_space_topology *topology);
void managed_space_topology_end_command(struct managed_space_topology *topology);
void managed_space_topology_prepare_request(struct managed_space_topology *topology, struct managed_space_topology_request *request);

enum space_op_error managed_space_topology_create(struct managed_space_topology *topology, uint64_t acting_sid);
enum space_op_error managed_space_topology_destroy_space(struct managed_space_topology *topology, uint64_t sid);
enum space_op_error managed_space_topology_move_space(struct managed_space_topology *topology, uint64_t sid, uint64_t target_sid);
enum space_op_error managed_space_topology_swap_spaces(struct managed_space_topology *topology, uint64_t sid, uint64_t target_sid);
enum space_op_error managed_space_topology_move_space_to_display(struct managed_space_topology *topology,
                                                                uint64_t sid,
                                                                uint32_t did,
                                                                bool placeholder_required);
bool managed_space_topology_prepare_move_request(struct managed_space_topology_request *request, uint64_t sid, uint64_t target_sid);
bool managed_space_topology_prepare_swap_request(struct managed_space_topology_request *request, uint64_t sid, uint64_t target_sid);
enum space_op_error managed_space_topology_submit_request(struct managed_space_topology *topology, struct managed_space_topology_request request);
void managed_space_topology_discard_request(struct managed_space_topology_request *request);
bool managed_space_topology_request_is_satisfied(struct managed_space_topology_request *request);
bool managed_space_topology_space_limit_reached_for_display(struct managed_space_topology *topology, uint32_t did);

void managed_space_topology_handle_space_created(struct managed_space_topology *topology, uint64_t sid);
void managed_space_topology_handle_space_destroyed(struct managed_space_topology *topology, uint64_t sid);
void managed_space_topology_handle_focus_changed(struct managed_space_topology *topology);
void managed_space_topology_handle_mission_control_enter(struct managed_space_topology *topology);
void managed_space_topology_handle_mission_control_exit(struct managed_space_topology *topology);
void managed_space_topology_handle_dock_restart(struct managed_space_topology *topology);
void managed_space_topology_note_input_event(struct managed_space_topology *topology, CGEventRef event);
void managed_space_topology_handle_user_interruption(struct managed_space_topology *topology, uint64_t generation);
void managed_space_topology_step(struct managed_space_topology *topology, uint64_t token);
void managed_space_topology_watchdog(struct managed_space_topology *topology, uint64_t token);

bool managed_space_topology_operation_pending(struct managed_space_topology *topology);
bool managed_space_topology_reconciliation_blocked(struct managed_space_topology *topology);
bool managed_space_topology_owns_mission_control(struct managed_space_topology *topology);
bool managed_space_topology_defers_destroy_membership(struct managed_space_topology *topology, uint64_t sid);
void managed_space_topology_finish_batch(struct managed_space_topology *topology);
void managed_space_topology_write_query(FILE *rsp, struct managed_space_topology *topology);

#endif
