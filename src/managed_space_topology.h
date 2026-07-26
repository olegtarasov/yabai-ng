#ifndef MANAGED_SPACE_TOPOLOGY_H
#define MANAGED_SPACE_TOPOLOGY_H

enum managed_space_topology_backend_policy
{
    MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO,
    MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION,
    MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE,
    MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY
};

enum managed_space_topology_provider
{
    MANAGED_SPACE_TOPOLOGY_PROVIDER_DISABLED,
    MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION,
    MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE
};

enum managed_space_topology_selection_reason
{
    MANAGED_SPACE_TOPOLOGY_SELECTION_DISABLED,
    MANAGED_SPACE_TOPOLOGY_SELECTION_COMPATIBLE_HANDSHAKE,
    MANAGED_SPACE_TOPOLOGY_SELECTION_HANDSHAKE_UNAVAILABLE,
    MANAGED_SPACE_TOPOLOGY_SELECTION_VERSION_MISMATCH,
    MANAGED_SPACE_TOPOLOGY_SELECTION_CAPABILITIES_MISSING,
    MANAGED_SPACE_TOPOLOGY_SELECTION_FORCED_POLICY
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

enum managed_space_topology_provider_error
{
    MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_NONE          = 0,
    MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_LIMIT_REACHED = 12,
    MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_ACCESSIBILITY = 13,
    MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND       = 14
};

struct managed_space_topology_result
{
    enum space_op_error space_error;
    enum managed_space_topology_provider_error provider_error;
    bool queued;
};

struct managed_space_topology
{
    bool enabled;
    enum managed_space_topology_backend_policy policy;
    enum managed_space_topology_provider provider;
    enum managed_space_topology_selection_reason selection_reason;
    enum scripting_addition_probe_status scripting_addition_status;
    char scripting_addition_version[64];
    uint32_t scripting_addition_capabilities;
};

extern struct managed_space_topology g_managed_space_topology;

static inline struct managed_space_topology_result
managed_space_topology_result_completed(void)
{
    return (struct managed_space_topology_result) {
        .space_error = SPACE_OP_ERROR_SUCCESS
    };
}

static inline struct managed_space_topology_result
managed_space_topology_result_space_error(enum space_op_error error)
{
    return (struct managed_space_topology_result) {
        .space_error = error
    };
}

static inline struct managed_space_topology_result
managed_space_topology_result_provider_error(enum managed_space_topology_provider_error error)
{
    return (struct managed_space_topology_result) {
        .space_error = SPACE_OP_ERROR_SUCCESS,
        .provider_error = error
    };
}

static inline struct managed_space_topology_result
managed_space_topology_result_queued(void)
{
    return (struct managed_space_topology_result) {
        .space_error = SPACE_OP_ERROR_SUCCESS,
        .queued = true
    };
}

static inline bool
managed_space_topology_result_is_success(struct managed_space_topology_result result)
{
    return result.space_error == SPACE_OP_ERROR_SUCCESS &&
           result.provider_error == MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_NONE;
}

static inline bool
managed_space_topology_result_is_completed(struct managed_space_topology_result result)
{
    return managed_space_topology_result_is_success(result) && !result.queued;
}

static inline int
managed_space_topology_result_error_code(struct managed_space_topology_result result)
{
    if (result.space_error != SPACE_OP_ERROR_SUCCESS) return result.space_error;
    return result.provider_error;
}

void managed_space_topology_init(struct managed_space_topology *topology);
void managed_space_topology_destroy(struct managed_space_topology *topology);
void managed_space_topology_set_enabled(struct managed_space_topology *topology, bool enabled);
bool managed_space_topology_is_enabled(struct managed_space_topology *topology);
bool managed_space_topology_uses_scripting_addition(struct managed_space_topology *topology);
bool managed_space_topology_uses_sip_safe(struct managed_space_topology *topology);
void managed_space_topology_note_configuration_changed(struct managed_space_topology *topology);

const char *managed_space_topology_backend_policy_name(enum managed_space_topology_backend_policy policy);
bool managed_space_topology_backend_policy_from_string(char *value, enum managed_space_topology_backend_policy *policy);
bool managed_space_topology_set_backend_policy(struct managed_space_topology *topology,
                                               enum managed_space_topology_backend_policy policy);
enum managed_space_topology_backend_policy managed_space_topology_backend_policy(struct managed_space_topology *topology);
const char *managed_space_topology_provider_name(enum managed_space_topology_provider provider);
const char *managed_space_topology_selection_reason_name(enum managed_space_topology_selection_reason reason);
const char *managed_space_topology_operation_name(enum managed_space_topology_operation operation);
const char *managed_space_topology_origin_name(enum managed_space_topology_origin origin);

struct managed_space_topology_result
managed_space_topology_create(struct managed_space_topology *topology,
                              enum managed_space_topology_origin origin,
                              uint64_t acting_sid);
struct managed_space_topology_result
managed_space_topology_destroy_space(struct managed_space_topology *topology,
                                     enum managed_space_topology_origin origin,
                                     uint64_t sid);
struct managed_space_topology_result
managed_space_topology_move_space(struct managed_space_topology *topology,
                                  enum managed_space_topology_origin origin,
                                  uint64_t sid,
                                  uint64_t target_sid);
struct managed_space_topology_result
managed_space_topology_swap_spaces(struct managed_space_topology *topology,
                                   enum managed_space_topology_origin origin,
                                   uint64_t sid,
                                   uint64_t target_sid);
struct managed_space_topology_result
managed_space_topology_move_space_to_display(struct managed_space_topology *topology,
                                             enum managed_space_topology_origin origin,
                                             uint64_t sid,
                                             uint32_t did,
                                             bool placeholder_required);

bool managed_space_topology_space_limit_reached_for_display(struct managed_space_topology *topology, uint32_t did);
void managed_space_topology_handle_space_created(struct managed_space_topology *topology, uint64_t sid);
void managed_space_topology_handle_space_destroyed(struct managed_space_topology *topology, uint64_t sid);
void managed_space_topology_handle_focus_changed(struct managed_space_topology *topology);
void managed_space_topology_handle_mission_control_enter(struct managed_space_topology *topology);
void managed_space_topology_handle_mission_control_exit(struct managed_space_topology *topology);
void managed_space_topology_handle_dock_restart(struct managed_space_topology *topology);
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
