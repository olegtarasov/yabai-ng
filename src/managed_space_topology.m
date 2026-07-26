extern struct event_loop g_event_loop;
extern struct managed_space g_managed_space;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern int g_connection;

#define MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS 0.30
#define MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS 0.35
#define MANAGED_SPACE_TOPOLOGY_SPACES_BAR_DELAY_SECONDS 0.60
#define MANAGED_SPACE_TOPOLOGY_WATCHDOG_SECONDS 2.50
#define MANAGED_SPACE_TOPOLOGY_DRAG_INITIAL_DELAY_US 50000
#define MANAGED_SPACE_TOPOLOGY_DRAG_HOLD_DELAY_US 120000
#define MANAGED_SPACE_TOPOLOGY_DRAG_STEP_DELAY_US 20000
#define MANAGED_SPACE_TOPOLOGY_DRAG_DROP_DELAY_US 180000
#define MANAGED_SPACE_TOPOLOGY_DRAG_RELEASE_DELAY_US 50000
#define MANAGED_SPACE_TOPOLOGY_MOUSE_EVENT_TAG 0x5941424149544f50ULL
#define MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT 16
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_CREATE 0x01
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_DESTROY 0x02
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_REORDER 0x04
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY 0x08

typedef id (*managed_space_topology_synchronous_bridge_fn)(void *);

static managed_space_topology_synchronous_bridge_fn managed_space_topology_synchronous_bridge;

static void managed_space_topology_start_next(struct managed_space_topology *topology);
static bool managed_space_topology_mission_control_ui_exists(void);
static int managed_space_topology_copy_matching_spaces(uint64_t *source,
                                                       int source_count,
                                                       uint64_t *destination,
                                                       bool (*matches)(uint64_t));

#ifdef TESTS
static bool managed_space_topology_test_snapshot_override_enabled;
static uint64_t managed_space_topology_test_snapshot_override;
#endif

static uint64_t managed_space_topology_hash_u64(uint64_t hash, uint64_t value)
{
    for (int byte = 0; byte < 8; ++byte) {
        hash ^= value & 0xff;
        hash *= 1099511628211ULL;
        value >>= 8;
    }

    return hash;
}

static uint64_t managed_space_topology_snapshot_hash(void)
{
#ifdef TESTS
    if (managed_space_topology_test_snapshot_override_enabled) {
        return managed_space_topology_test_snapshot_override;
    }
#endif

    uint64_t hash = 1469598103934665603ULL;

    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;
        if (!space_is_user(sid)) continue;

        hash = managed_space_topology_hash_u64(hash, sid);
        hash = managed_space_topology_hash_u64(hash, space_display_id(sid));
        hash = managed_space_topology_hash_u64(hash, index);
    }

    return hash;
}

static void managed_space_topology_copy_space_uuid(uint64_t sid, char uuid[64])
{
    if (!sid) return;

    CFStringRef uuid_ref = SLSSpaceCopyName(g_connection, sid);
    if (!uuid_ref) return;
    CFStringGetCString(uuid_ref, uuid, 64, kCFStringEncodingUTF8);
    CFRelease(uuid_ref);
}

void managed_space_topology_discard_request(struct managed_space_topology_request *request)
{
    if (request->desired_order) free(request->desired_order);
    memset(request, 0, sizeof(struct managed_space_topology_request));
}

static void managed_space_topology_clear_queue(struct managed_space_topology *topology)
{
    managed_space_topology_discard_request(&topology->current);
    for (int i = 0; i < buf_len(topology->queue); ++i) {
        managed_space_topology_discard_request(&topology->queue[i]);
    }

    buf_free(topology->queue);
    topology->queue = NULL;
}

static void managed_space_topology_schedule_step(struct managed_space_topology *topology, double delay)
{
    uint64_t token = ++topology->step_token;
    topology->step_generation = topology->current.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, MANAGED_SPACE_TOPOLOGY_STEP, (void *)(uintptr_t) token, 0);
    });
}

static void managed_space_topology_schedule_watchdog(struct managed_space_topology *topology)
{
    uint64_t token = ++topology->watchdog_token;
    topology->watchdog_generation = topology->current.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MANAGED_SPACE_TOPOLOGY_WATCHDOG_SECONDS * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, MANAGED_SPACE_TOPOLOGY_WATCHDOG, (void *)(uintptr_t) token, 0);
    });
}

static void managed_space_topology_cancel_step(struct managed_space_topology *topology)
{
    ++topology->step_token;
}

static void managed_space_topology_cancel_watchdog(struct managed_space_topology *topology)
{
    ++topology->watchdog_token;
}

static void managed_space_topology_record_space_limit(struct managed_space_topology *topology,
                                                      uint32_t did,
                                                      int count)
{
    topology->space_limit_reached = true;
    topology->space_limit_did = did;
    topology->space_limit_count = count;
}

static void managed_space_topology_stop_ax_observer(struct managed_space_topology *topology)
{
    if (topology->ax_observer) {
        CFRunLoopSourceRef source = AXObserverGetRunLoopSource(topology->ax_observer);
        if (source) CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    }

    if (topology->ax_observed_element) CFRelease(topology->ax_observed_element);
    if (topology->ax_observer) CFRelease(topology->ax_observer);
    topology->ax_observed_element = NULL;
    topology->ax_observer = NULL;
    topology->observed_dock_pid = 0;
}

const char *managed_space_topology_backend_policy_name(enum managed_space_topology_backend_policy policy)
{
    switch (policy) {
    case MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO:               return "auto";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION: return "scripting-addition";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE:             return "bridge";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY:      return "accessibility";
    }

    return "unknown";
}

bool managed_space_topology_backend_policy_from_string(char *value, enum managed_space_topology_backend_policy *policy)
{
    if (string_equals(value, "auto")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO;
    } else if (string_equals(value, "scripting-addition")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION;
    } else if (string_equals(value, "bridge")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE;
    } else if (string_equals(value, "accessibility")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY;
    } else {
        return false;
    }

    return true;
}

const char *managed_space_topology_backend_name(enum managed_space_topology_backend backend)
{
    switch (backend) {
    case MANAGED_SPACE_TOPOLOGY_BACKEND_NONE:                       return "none";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION: return "scripting-addition";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE:             return "bridge";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY:      return "accessibility";
    }

    return "unknown";
}

const char *managed_space_topology_operation_name(enum managed_space_topology_operation operation)
{
    switch (operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:         return "none";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:       return "create";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:      return "destroy";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:      return "reorder";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:         return "swap";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY: return "move-display";
    }

    return "unknown";
}

const char *managed_space_topology_origin_name(enum managed_space_topology_origin origin)
{
    switch (origin) {
    case MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE: return "reconcile";
    case MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND:   return "command";
    }

    return "unknown";
}

const char *managed_space_topology_state_name(enum managed_space_topology_state state)
{
    switch (state) {
    case MANAGED_SPACE_TOPOLOGY_STATE_IDLE:                             return "idle";
    case MANAGED_SPACE_TOPOLOGY_STATE_QUEUED:                           return "queued";
    case MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_USER_MISSION_CONTROL: return "waiting-for-user-mission-control";
    case MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL:      return "waiting-for-mission-control";
    case MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY:        return "waiting-for-accessibility";
    case MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT:                return "waiting-for-event";
    case MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE:               return "waiting-for-settle";
    case MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT: return "waiting-for-mission-control-exit";
    case MANAGED_SPACE_TOPOLOGY_STATE_FAILED:                           return "failed";
    }

    return "unknown";
}

static uint32_t managed_space_topology_known_bridge_operations(char *os_build)
{
    //
    // Populated only after a reversible runtime validation on the exact OS build.
    // Forced "bridge" mode remains available for running that validation matrix.
    //
    if (string_equals(os_build, "25E253")) {
        return MANAGED_SPACE_TOPOLOGY_BRIDGE_CREATE |
               MANAGED_SPACE_TOPOLOGY_BRIDGE_DESTROY |
               MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY;
    }
    return 0;
}

static uint32_t managed_space_topology_operation_bridge_bit(enum managed_space_topology_operation operation)
{
    switch (operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:       return MANAGED_SPACE_TOPOLOGY_BRIDGE_CREATE;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:      return MANAGED_SPACE_TOPOLOGY_BRIDGE_DESTROY;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:         return MANAGED_SPACE_TOPOLOGY_BRIDGE_REORDER;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY: return MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:         return 0;
    }

    return 0;
}

static bool managed_space_topology_bridge_symbol_available(enum managed_space_topology_operation operation)
{
    if (!SLSPerformAsynchronousBridgedWindowManagementOperation) return false;

    switch (operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        return managed_space_topology_synchronous_bridge &&
               objc_getClass("SLSBridgedSpaceCreateOperation") &&
               objc_getClass("SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        return objc_getClass("SLSBridgedSpaceDestroyOperation") != Nil;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:
        return objc_getClass("SLSBridgedSpaceSetOrderingWeightOperation") != Nil;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        return objc_getClass("SLSBridgedMoveManagedSpaceToDisplayIndexOperation") != Nil;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:         return false;
    }

    return false;
}

static enum managed_space_topology_backend managed_space_topology_select_fallback_backend(struct managed_space_topology *topology,
                                                                                           enum managed_space_topology_operation operation)
{
    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION) {
        return MANAGED_SPACE_TOPOLOGY_BACKEND_NONE;
    }

    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE) {
        return managed_space_topology_bridge_symbol_available(operation)
            ? MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE
            : MANAGED_SPACE_TOPOLOGY_BACKEND_NONE;
    }

    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY) {
        return MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY;
    }

    uint32_t known_operations = managed_space_topology_known_bridge_operations(topology->os_build);
    uint32_t operation_bit = managed_space_topology_operation_bridge_bit(operation);
    if ((known_operations & operation_bit) && managed_space_topology_bridge_symbol_available(operation)) {
        return MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE;
    }

    return MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY;
}

static enum managed_space_topology_backend managed_space_topology_select_initial_backend(struct managed_space_topology *topology,
                                                                                          enum managed_space_topology_operation operation)
{
    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO ||
        topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION) {
        return MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION;
    }

    return managed_space_topology_select_fallback_backend(topology, operation);
}

void managed_space_topology_init(struct managed_space_topology *topology)
{
    memset(topology, 0, sizeof(struct managed_space_topology));
    topology->policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO;
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;

    size_t os_build_size = sizeof(topology->os_build);
    if (sysctlbyname("kern.osversion", topology->os_build, &os_build_size, NULL, 0) != 0) {
        topology->os_build[0] = '\0';
    }
    topology->os_build[sizeof(topology->os_build) - 1] = '\0';

    char *skylight_path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
    if (!SLSPerformAsynchronousBridgedWindowManagementOperation) {
        SLSPerformAsynchronousBridgedWindowManagementOperation = macho_find_symbol(
            skylight_path,
            "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    }
    managed_space_topology_synchronous_bridge = macho_find_symbol(
        skylight_path,
        "__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation");
}

void managed_space_topology_destroy(struct managed_space_topology *topology)
{
    managed_space_topology_stop_ax_observer(topology);
    managed_space_topology_cancel_step(topology);
    managed_space_topology_cancel_watchdog(topology);
    managed_space_topology_clear_queue(topology);
    memset(topology, 0, sizeof(struct managed_space_topology));
}

void managed_space_topology_set_enabled(struct managed_space_topology *topology, bool enabled)
{
    topology->enabled = enabled;
    if (enabled) return;

    managed_space_topology_stop_ax_observer(topology);
    managed_space_topology_cancel_step(topology);
    managed_space_topology_cancel_watchdog(topology);
    managed_space_topology_clear_queue(topology);
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;
    topology->command_origin = false;

    if (topology->owns_mission_control &&
        (mission_control_is_active() || managed_space_topology_mission_control_ui_exists())) {
        CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
    }

    topology->owns_mission_control = false;
    topology->finish_batch_requested = false;
    topology->space_limit_reached = false;
    topology->space_limit_did = 0;
    topology->space_limit_count = 0;
    topology->reconciliation_blocked = false;
}

bool managed_space_topology_is_enabled(struct managed_space_topology *topology)
{
    return topology->enabled;
}

void managed_space_topology_note_configuration_changed(struct managed_space_topology *topology)
{
    topology->space_limit_reached = false;
    topology->space_limit_did = 0;
    topology->space_limit_count = 0;
    topology->reconciliation_blocked = false;
}

void managed_space_topology_set_backend_policy(struct managed_space_topology *topology, enum managed_space_topology_backend_policy policy)
{
    if (topology->policy == policy) return;

    topology->policy = policy;
    topology->operation_error[0] = '\0';
    managed_space_topology_note_configuration_changed(topology);
    managed_space_request_reconcile(&g_managed_space);
}

enum managed_space_topology_backend_policy managed_space_topology_backend_policy(struct managed_space_topology *topology)
{
    return topology->policy;
}

void managed_space_topology_begin_command(struct managed_space_topology *topology)
{
    topology->command_origin = true;
}

void managed_space_topology_end_command(struct managed_space_topology *topology)
{
    topology->command_origin = false;
}

bool managed_space_topology_request_is_satisfied(struct managed_space_topology_request *request)
{
    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        return request->created_sid &&
               space_is_user(request->created_sid) &&
               space_display_id(request->created_sid) == request->target_did;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        return space_manager_mission_control_index(request->sid) == 0;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP: {
        uint32_t did = request->sid ? space_display_id(request->sid) : 0;
        int space_count = 0;
        uint64_t *space_list = did ? display_space_list(did, &space_count) : NULL;
        if (!space_list) return false;

        int user_index = 0;
        for (int i = 0; i < space_count; ++i) {
            if (!space_is_user(space_list[i])) continue;
            if (user_index >= request->desired_order_count ||
                space_list[i] != request->desired_order[user_index]) {
                return false;
            }
            ++user_index;
        }

        return user_index == request->desired_order_count;
    }
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        return request->sid && space_display_id(request->sid) == request->target_did;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        return true;
    }

    return false;
}

static void managed_space_topology_restore_pending_focus(struct managed_space_topology *topology)
{
    uint64_t sid = topology->pending_focus_sid;
    if (!sid) return;
    if (mission_control_is_active() || managed_space_topology_mission_control_ui_exists()) return;
    if (!space_manager_mission_control_index(sid)) {
        topology->pending_focus_sid = 0;
        return;
    }

    enum space_op_error result = space_manager_focus_space(sid);
    if (result == SPACE_OP_ERROR_SUCCESS || result == SPACE_OP_ERROR_SAME_SPACE) {
        topology->pending_focus_sid = 0;
    }
}

void managed_space_topology_handle_focus_changed(struct managed_space_topology *topology)
{
    managed_space_topology_restore_pending_focus(topology);
}

static void managed_space_topology_complete_current(struct managed_space_topology *topology)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;

    managed_space_topology_cancel_step(topology);
    managed_space_topology_cancel_watchdog(topology);

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY) {
        uint64_t validation_sid = space_manager_find_first_user_space_for_display(topology->current.target_did);
        if (validation_sid) {
            window_manager_validate_and_check_for_windows_on_space(&g_space_manager,
                                                                   &g_window_manager,
                                                                   validation_sid);
        }
    } else if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY) {
        space_manager_mark_view_invalid(&g_space_manager, topology->current.sid);
        if (topology->current.focus_space) {
            topology->pending_focus_sid = topology->current.sid;
        } else if (topology->current.restore_focus_sid) {
            topology->pending_focus_sid = topology->current.restore_focus_sid;
        }
        managed_space_topology_restore_pending_focus(topology);
    }

    managed_space_handle_topology_operation_completed(&g_managed_space, &topology->current);
    topology->reconciliation_blocked = false;
    managed_space_topology_discard_request(&topology->current);
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;
    topology->operation_error[0] = '\0';

    if (buf_len(topology->queue) > 0) {
        managed_space_topology_start_next(topology);
    } else {
        managed_space_request_reconcile(&g_managed_space);
    }
}

static void managed_space_topology_close_owned_mission_control(struct managed_space_topology *topology)
{
    if (!topology->owns_mission_control) return;
    if (!mission_control_is_active() && !managed_space_topology_mission_control_ui_exists()) {
        topology->owns_mission_control = false;
        return;
    }

    CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
}

static void managed_space_topology_fail_current(struct managed_space_topology *topology, char *error)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;

    bool space_limit_failure = string_equals(error, "space-limit-reached");
    uint32_t space_limit_did = topology->current.target_did;
    int space_limit_count = topology->space_limit_count;

    snprintf(topology->last_error, sizeof(topology->last_error), "%s", error);
    topology->last_failed_operation = topology->current.operation;
    topology->last_failed_backend = topology->current.backend;
    topology->last_failed_generation = topology->current.generation;
    if (topology->current.origin == MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE) {
        topology->reconciliation_blocked = true;
    }
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_FAILED;
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        topology->current.restore_focus_sid) {
        topology->pending_focus_sid = topology->current.restore_focus_sid;
    }
    managed_space_topology_cancel_step(topology);
    managed_space_topology_cancel_watchdog(topology);

    if (topology->active_submission_generation != topology->current.generation) {
        managed_space_handle_topology_operation_failed(&g_managed_space, &topology->current);
    }
    event_signal_push(SIGNAL_MANAGED_SPACE_TOPOLOGY_FAILED, topology);

    bool wait_for_exit = topology->owns_mission_control &&
                         (mission_control_is_active() || managed_space_topology_mission_control_ui_exists());
    if (wait_for_exit) {
        topology->finish_batch_requested = true;
        managed_space_topology_close_owned_mission_control(topology);
        return;
    }

    topology->owns_mission_control = false;
    managed_space_topology_discard_request(&topology->current);
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;
    managed_space_topology_restore_pending_focus(topology);
    if (space_limit_failure) {
        managed_space_topology_record_space_limit(topology,
                                                  space_limit_did,
                                                  space_limit_count);
    }
    managed_space_topology_start_next(topology);
    managed_space_request_reconcile(&g_managed_space);
}

static uint64_t *managed_space_topology_copy_display_order(uint32_t did, int *count)
{
    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list || space_count <= 0) return NULL;

    uint64_t *result = malloc(sizeof(uint64_t) * space_count);
    if (!result) return NULL;

    int user_count = managed_space_topology_copy_matching_spaces(space_list,
                                                                 space_count,
                                                                 result,
                                                                 space_is_user);

    if (user_count == 0) {
        free(result);
        return NULL;
    }

    *count = user_count;
    return result;
}

static int managed_space_topology_find_sid(uint64_t *space_list, int count, uint64_t sid)
{
    for (int i = 0; i < count; ++i) {
        if (space_list[i] == sid) return i;
    }

    return -1;
}

static int managed_space_topology_copy_matching_spaces(uint64_t *source,
                                                       int source_count,
                                                       uint64_t *destination,
                                                       bool (*matches)(uint64_t))
{
    int destination_count = 0;
    for (int i = 0; i < source_count; ++i) {
        if (matches(source[i])) destination[destination_count++] = source[i];
    }

    return destination_count;
}

static bool managed_space_topology_move_order_in_place(uint64_t *order,
                                                       int count,
                                                       uint64_t sid,
                                                       uint64_t target_sid,
                                                       bool *place_after,
                                                       int *final_index)
{
    int source_index = managed_space_topology_find_sid(order, count, sid);
    int target_index = managed_space_topology_find_sid(order, count, target_sid);
    if (source_index < 0 || target_index < 0 || source_index == target_index) return false;

    *place_after = source_index < target_index;
    uint64_t moved_sid = order[source_index];
    if (source_index < count - 1) {
        memmove(order + source_index,
                order + source_index + 1,
                sizeof(uint64_t) * (count - source_index - 1));
    }

    target_index = managed_space_topology_find_sid(order, count - 1, target_sid);
    int insertion_index = target_index + (*place_after ? 1 : 0);
    if (insertion_index < count - 1) {
        memmove(order + insertion_index + 1,
                order + insertion_index,
                sizeof(uint64_t) * (count - insertion_index - 1));
    }

    order[insertion_index] = moved_sid;
    *final_index = insertion_index;
    return true;
}

static bool managed_space_topology_swap_order_in_place(uint64_t *order,
                                                       int count,
                                                       uint64_t sid,
                                                       uint64_t target_sid,
                                                       int *target_index)
{
    int source_index = managed_space_topology_find_sid(order, count, sid);
    *target_index = managed_space_topology_find_sid(order, count, target_sid);
    if (source_index < 0 || *target_index < 0 || source_index == *target_index) return false;

    uint64_t temp = order[source_index];
    order[source_index] = order[*target_index];
    order[*target_index] = temp;
    return true;
}

static bool managed_space_topology_build_move_order(struct managed_space_topology_request *request)
{
    uint32_t did = space_display_id(request->sid);
    if (!did || did != space_display_id(request->target_sid)) return false;

    request->desired_order = managed_space_topology_copy_display_order(did, &request->desired_order_count);
    if (!request->desired_order) return false;

    return managed_space_topology_move_order_in_place(request->desired_order,
                                                      request->desired_order_count,
                                                      request->sid,
                                                      request->target_sid,
                                                      &request->place_after,
                                                      &request->target_index);
}

static bool managed_space_topology_build_swap_order(struct managed_space_topology_request *request)
{
    uint32_t did = space_display_id(request->sid);
    if (!did || did != space_display_id(request->target_sid)) return false;

    request->desired_order = managed_space_topology_copy_display_order(did, &request->desired_order_count);
    if (!request->desired_order) return false;

    return managed_space_topology_swap_order_in_place(request->desired_order,
                                                      request->desired_order_count,
                                                      request->sid,
                                                      request->target_sid,
                                                      &request->target_index);
}

static bool managed_space_topology_create_is_blocked(struct managed_space_topology *topology, uint32_t did)
{
    return topology->space_limit_reached && topology->space_limit_did == did;
}

bool managed_space_topology_space_limit_reached_for_display(struct managed_space_topology *topology, uint32_t did)
{
    return managed_space_topology_create_is_blocked(topology, did);
}

void managed_space_topology_prepare_request(struct managed_space_topology *topology,
                                            struct managed_space_topology_request *request)
{
    if (request->generation) return;

    request->origin = topology->command_origin
        ? MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND
        : MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE;
    request->generation = ++topology->next_generation;
    request->precondition_hash = managed_space_topology_snapshot_hash();
    managed_space_topology_copy_space_uuid(request->sid, request->sid_uuid);
    managed_space_topology_copy_space_uuid(request->target_sid, request->target_uuid);
}

static void managed_space_topology_record_immediate_failure(struct managed_space_topology *topology,
                                                            struct managed_space_topology_request *request,
                                                            char *error)
{
    topology->last_failed_operation = request->operation;
    topology->last_failed_backend = request->backend;
    topology->last_failed_generation = request->generation;
    if (request->origin == MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE) {
        topology->reconciliation_blocked = true;
    }
    snprintf(topology->last_error, sizeof(topology->last_error), "%s", error);
#ifndef TESTS
    event_signal_push(SIGNAL_MANAGED_SPACE_TOPOLOGY_FAILED, topology);
#endif
}

enum space_op_error managed_space_topology_submit_request(struct managed_space_topology *topology, struct managed_space_topology_request request)
{
    if (!topology->enabled) {
        managed_space_topology_discard_request(&request);
        return SPACE_OP_ERROR_SCRIPTING_ADDITION;
    }

    managed_space_topology_prepare_request(topology, &request);
    if (request.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_NONE) {
        request.backend = managed_space_topology_select_initial_backend(topology, request.operation);
    }

    if (request.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_NONE) {
        bool should_restore_order = request.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER ||
                                    request.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP;
        bool forced_bridge = topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE;
        managed_space_topology_record_immediate_failure(
            topology,
            &request,
            forced_bridge ? "bridge-operation-unavailable" : "scripting-addition-unavailable");
        managed_space_topology_discard_request(&request);
        if (should_restore_order) managed_space_request_reconcile(&g_managed_space);
        return forced_bridge
            ? SPACE_OP_ERROR_TOPOLOGY_BACKEND
            : SPACE_OP_ERROR_SCRIPTING_ADDITION;
    }

    if (request.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY &&
        !AXIsProcessTrusted()) {
        managed_space_topology_record_immediate_failure(topology,
                                                        &request,
                                                        "accessibility-permission-missing");
        managed_space_topology_discard_request(&request);
        return SPACE_OP_ERROR_ACCESSIBILITY;
    }

    if (request.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE &&
        managed_space_topology_create_is_blocked(topology, request.target_did)) {
        managed_space_topology_discard_request(&request);
        return SPACE_OP_ERROR_LIMIT_REACHED;
    }

    uint64_t request_generation = request.generation;
    buf_push(topology->queue, request);
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT) {
        topology->active_submission_generation = request_generation;
        managed_space_topology_start_next(topology);
        topology->active_submission_generation = 0;
    }

    if (topology->last_failed_generation == request_generation) {
        if (topology->last_failed_backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY &&
            string_equals(topology->last_error, "accessibility-permission-missing")) {
            return SPACE_OP_ERROR_ACCESSIBILITY;
        }
        if (topology->last_failed_backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION &&
            string_equals(topology->last_error, "scripting-addition-unavailable")) {
            return SPACE_OP_ERROR_SCRIPTING_ADDITION;
        }
        return SPACE_OP_ERROR_TOPOLOGY_BACKEND;
    }

    return SPACE_OP_ERROR_QUEUED;
}

enum space_op_error managed_space_topology_create(struct managed_space_topology *topology, uint64_t acting_sid)
{
    uint32_t did = space_display_id(acting_sid);
    if (!did) return SPACE_OP_ERROR_MISSING_SRC;

    struct managed_space_topology_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
        .sid = acting_sid,
        .target_did = did
    };

    return managed_space_topology_submit_request(topology, request);
}

enum space_op_error managed_space_topology_destroy_space(struct managed_space_topology *topology, uint64_t sid)
{
    struct managed_space_topology_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
        .sid = sid,
        .target_did = space_display_id(sid)
    };

    return managed_space_topology_submit_request(topology, request);
}

bool managed_space_topology_prepare_move_request(struct managed_space_topology_request *request, uint64_t sid, uint64_t target_sid)
{
    *request = (struct managed_space_topology_request) {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER,
        .sid = sid,
        .target_sid = target_sid
    };

    if (!space_is_user(sid) || !space_is_user(target_sid)) return false;
    return managed_space_topology_build_move_order(request);
}

enum space_op_error managed_space_topology_move_space(struct managed_space_topology *topology, uint64_t sid, uint64_t target_sid)
{
    if (!space_is_user(sid) || !space_is_user(target_sid)) return SPACE_OP_ERROR_INVALID_TYPE;

    struct managed_space_topology_request request;
    if (!managed_space_topology_prepare_move_request(&request, sid, target_sid)) {
        managed_space_topology_discard_request(&request);
        return SPACE_OP_ERROR_INVALID_DST;
    }

    return managed_space_topology_submit_request(topology, request);
}

bool managed_space_topology_prepare_swap_request(struct managed_space_topology_request *request, uint64_t sid, uint64_t target_sid)
{
    *request = (struct managed_space_topology_request) {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP,
        .sid = sid,
        .target_sid = target_sid
    };

    if (!space_is_user(sid) || !space_is_user(target_sid)) return false;
    return managed_space_topology_build_swap_order(request);
}

enum space_op_error managed_space_topology_swap_spaces(struct managed_space_topology *topology, uint64_t sid, uint64_t target_sid)
{
    if (!space_is_user(sid) || !space_is_user(target_sid)) return SPACE_OP_ERROR_INVALID_TYPE;

    struct managed_space_topology_request request;
    if (!managed_space_topology_prepare_swap_request(&request, sid, target_sid)) {
        managed_space_topology_discard_request(&request);
        return SPACE_OP_ERROR_INVALID_DST;
    }

    return managed_space_topology_submit_request(topology, request);
}

enum space_op_error managed_space_topology_move_space_to_display(struct managed_space_topology *topology,
                                                                uint64_t sid,
                                                                uint32_t did,
                                                                bool placeholder_required)
{
    if (!space_is_user(sid)) return SPACE_OP_ERROR_INVALID_TYPE;

    struct managed_space_topology_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY,
        .sid = sid,
        .target_did = did,
        .focus_space = sid == space_manager_active_space(),
        .placeholder_required = placeholder_required
    };

    return managed_space_topology_submit_request(topology, request);
}

static bool managed_space_topology_execute_scripting_addition(struct managed_space_topology *topology)
{
    struct managed_space_topology_request *request = &topology->current;
    bool success = false;

    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        success = scripting_addition_create_space(request->sid);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        success = scripting_addition_destroy_space(request->sid);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:
        success = request->desired_order_count > 1;
        for (int i = 1; success && i < request->desired_order_count; ++i) {
            uint64_t sid = request->desired_order[i];
            success = scripting_addition_move_space_after_space(sid,
                                                                 request->desired_order[i - 1],
                                                                 sid == space_manager_active_space());
            if (success) request->mutation_started = true;
        }
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY: {
        uint64_t destination_sid = display_space_id(request->target_did);
        if (!destination_sid) return false;
        success = scripting_addition_move_space_to_display(
            request->sid,
            destination_sid,
            request->focus_space ? space_manager_prev_space(request->sid) : 0,
            request->focus_space);
    } break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        return false;
    }

    if (!success) return false;

    request->mutation_started = true;
    if (request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE ||
        request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY) {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT;
    } else {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    }

    managed_space_topology_schedule_watchdog(topology);
    return true;
}

static bool managed_space_topology_execute_bridge(struct managed_space_topology *topology)
{
    struct managed_space_topology_request *request = &topology->current;

    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE: {
        Class create_class = objc_getClass("SLSBridgedSpaceCreateOperation");
        if (!create_class || !managed_space_topology_synchronous_bridge) return false;

        NSString *uuid = [[NSUUID UUID] UUIDString];
        NSDictionary *values = @{ @"type": @0, @"uuid": uuid };
        SEL selector = sel_registerName("initWithOptions:values:");
        id operation = ((id (*)(id, SEL, uint32_t, id)) objc_msgSend)([create_class alloc],
                                                                      selector,
                                                                      0,
                                                                      values);
        if (!operation) return false;

        id result = managed_space_topology_synchronous_bridge(operation);
        if (result && [result respondsToSelector:@selector(spaceID)]) {
            request->created_sid = ((uint64_t (*)(id, SEL)) objc_msgSend)(result, @selector(spaceID));
        }
        [operation release];
        if (!request->created_sid) return false;

        request->mutation_started = true;
        if (space_display_id(request->created_sid) != request->target_did) {
            Class move_class = objc_getClass("SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
            CFStringRef display_identifier = display_uuid(request->target_did);
            if (!move_class || !display_identifier ||
                !SLSPerformAsynchronousBridgedWindowManagementOperation) {
                if (display_identifier) CFRelease(display_identifier);
                return false;
            }

            uint32_t target_index = display_space_count(request->target_did);
            SEL move_selector = sel_registerName("initWithSpaceID:displayIdentifier:index:");
            id move_operation = ((id (*)(id, SEL, uint64_t, id, uint32_t)) objc_msgSend)(
                [move_class alloc],
                move_selector,
                request->created_sid,
                (__bridge id) display_identifier,
                target_index);
            CFRelease(display_identifier);
            if (!move_operation) return false;
            SLSPerformAsynchronousBridgedWindowManagementOperation(move_operation);
            [move_operation release];
        }

        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    } break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY: {
        Class operation_class = objc_getClass("SLSBridgedSpaceDestroyOperation");
        if (!operation_class || !SLSPerformAsynchronousBridgedWindowManagementOperation) return false;
        SEL selector = sel_registerName("initWithSpaceID:");
        id operation = ((id (*)(id, SEL, uint64_t)) objc_msgSend)([operation_class alloc],
                                                                  selector,
                                                                  request->sid);
        if (!operation) return false;
        SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
        [operation release];
        request->mutation_started = true;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT;
    } break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP: {
        Class operation_class = objc_getClass("SLSBridgedSpaceSetOrderingWeightOperation");
        if (!operation_class || !SLSPerformAsynchronousBridgedWindowManagementOperation) return false;
        int space_count = 0;
        uint64_t *space_list = display_space_list(space_display_id(request->sid), &space_count);
        int user_index = 0;
        for (int i = 0; space_list && i < space_count && user_index < request->desired_order_count; ++i) {
            if (!space_is_user(space_list[i])) continue;
            SEL selector = sel_registerName("initWithSpaceID:weight:");
            id operation = ((id (*)(id, SEL, uint64_t, int32_t)) objc_msgSend)(
                [operation_class alloc],
                selector,
                request->desired_order[user_index++],
                i + 1);
            if (!operation) return false;
            SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
            [operation release];
        }
        if (user_index != request->desired_order_count) return false;
        request->mutation_started = true;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    } break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY: {
        Class operation_class = objc_getClass("SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
        CFStringRef display_identifier = display_uuid(request->target_did);
        if (!operation_class || !display_identifier ||
            !SLSPerformAsynchronousBridgedWindowManagementOperation) {
            if (display_identifier) CFRelease(display_identifier);
            return false;
        }

        uint32_t target_index = display_space_count(request->target_did);
        SEL selector = sel_registerName("initWithSpaceID:displayIdentifier:index:");
        id operation = ((id (*)(id, SEL, uint64_t, id, uint32_t)) objc_msgSend)(
            [operation_class alloc],
            selector,
            request->sid,
            (__bridge id) display_identifier,
            target_index);
        CFRelease(display_identifier);
        if (!operation) return false;
        SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
        [operation release];
        request->mutation_started = true;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    } break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        return false;
    }

    managed_space_topology_schedule_watchdog(topology);
    return true;
}

static AXUIElementRef managed_space_topology_copy_ax_child(AXUIElementRef parent, CFStringRef identifier)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute, &value) != kAXErrorSuccess || !value) {
        return NULL;
    }

    AXUIElementRef result = NULL;
    CFArrayRef children = value;
    int child_count = CFArrayGetCount(children);

    for (int i = 0; i < child_count; ++i) {
        AXUIElementRef child = (AXUIElementRef) CFArrayGetValueAtIndex(children, i);
        CFTypeRef child_identifier = NULL;
        if (AXUIElementCopyAttributeValue(child, CFSTR("AXIdentifier"), &child_identifier) == kAXErrorSuccess &&
            child_identifier && CFGetTypeID(child_identifier) == CFStringGetTypeID() &&
            CFEqual(child_identifier, identifier)) {
            result = CFRetain(child);
        }

        if (child_identifier) CFRelease(child_identifier);
        if (result) break;
    }

    CFRelease(children);
    return result;
}

static bool managed_space_topology_ax_display_value_matches(CFTypeRef value, uint32_t did)
{
    if (!value || !did) return false;

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringRef uuid = display_uuid(did);
        bool result = uuid && CFEqual(value, uuid);
        if (uuid) CFRelease(uuid);
        return result;
    }

    int64_t value_did = 0;
    return CFGetTypeID(value) == CFNumberGetTypeID() &&
           CFNumberGetValue(value, kCFNumberSInt64Type, &value_did) &&
           value_did == did;
}

static bool managed_space_topology_ax_display_matches(AXUIElementRef element, uint32_t did)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXDisplayID"), &value) != kAXErrorSuccess || !value) {
        return false;
    }

    bool result = managed_space_topology_ax_display_value_matches(value, did);
    CFRelease(value);
    return result;
}

static AXUIElementRef managed_space_topology_copy_ax_display(AXUIElementRef mission_control, uint32_t did)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(mission_control, kAXChildrenAttribute, &value) != kAXErrorSuccess || !value) {
        return NULL;
    }

    AXUIElementRef result = NULL;
    CFArrayRef children = value;
    int child_count = CFArrayGetCount(children);

    for (int i = 0; i < child_count; ++i) {
        AXUIElementRef child = (AXUIElementRef) CFArrayGetValueAtIndex(children, i);
        CFTypeRef identifier = NULL;
        bool is_display = AXUIElementCopyAttributeValue(child, CFSTR("AXIdentifier"), &identifier) == kAXErrorSuccess &&
                          identifier && CFGetTypeID(identifier) == CFStringGetTypeID() &&
                          CFEqual(identifier, CFSTR("mc.display"));
        if (identifier) CFRelease(identifier);

        if (is_display && managed_space_topology_ax_display_matches(child, did)) {
            result = CFRetain(child);
            break;
        }
    }

    CFRelease(children);
    return result;
}

static AXUIElementRef managed_space_topology_copy_ax_spaces_group(AXUIElementRef mission_control, uint32_t did)
{
    AXUIElementRef display = managed_space_topology_copy_ax_display(mission_control, did);
    if (!display) return NULL;

    AXUIElementRef spaces = managed_space_topology_copy_ax_child(display, CFSTR("mc.spaces"));
    CFRelease(display);
    return spaces;
}

static AXUIElementRef managed_space_topology_copy_mission_control(pid_t *dock_pid)
{
    NSArray *dock_applications = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    NSRunningApplication *dock = [dock_applications firstObject];
    if (!dock) return NULL;

    *dock_pid = dock.processIdentifier;
    AXUIElementRef dock_element = AXUIElementCreateApplication(*dock_pid);
    if (!dock_element) return NULL;

    AXUIElementRef mission_control = managed_space_topology_copy_ax_child(dock_element, CFSTR("mc"));
    CFRelease(dock_element);
    return mission_control;
}

static bool managed_space_topology_mission_control_ui_exists(void)
{
    pid_t dock_pid = 0;
    AXUIElementRef mission_control = managed_space_topology_copy_mission_control(&dock_pid);
    if (!mission_control) return false;

    CFRelease(mission_control);
    return true;
}

static enum managed_space_topology_state managed_space_topology_accessibility_session_state(bool mission_control_active,
                                                                                             bool owns_mission_control)
{
    if (!mission_control_active) return MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL;
    return owns_mission_control
        ? MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY
        : MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_USER_MISSION_CONTROL;
}

static void managed_space_topology_ax_notification(AXObserverRef observer,
                                                   AXUIElementRef element,
                                                   CFStringRef notification,
                                                   void *context)
{
    (void) observer;
    (void) element;
    (void) notification;

    struct managed_space_topology *topology = context;
    if (!topology) return;
    if (topology->current.backend != MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY) return;
    if (topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE) return;

    managed_space_topology_schedule_step(topology, 0.08);
}

static void managed_space_topology_observe_mission_control(struct managed_space_topology *topology,
                                                           pid_t dock_pid,
                                                           AXUIElementRef mission_control)
{
    if (topology->ax_observer && topology->observed_dock_pid == dock_pid) return;
    managed_space_topology_stop_ax_observer(topology);

    AXObserverRef observer = NULL;
    if (AXObserverCreate(dock_pid, managed_space_topology_ax_notification, &observer) != kAXErrorSuccess ||
        !observer) {
        return;
    }

    bool observing = false;
    observing |= AXObserverAddNotification(observer, mission_control, kAXLayoutChangedNotification, topology) == kAXErrorSuccess;
    observing |= AXObserverAddNotification(observer, mission_control, kAXCreatedNotification, topology) == kAXErrorSuccess;
    observing |= AXObserverAddNotification(observer, mission_control, kAXUIElementDestroyedNotification, topology) == kAXErrorSuccess;
    if (!observing) {
        CFRelease(observer);
        return;
    }

    topology->ax_observer = observer;
    topology->ax_observed_element = CFRetain(mission_control);
    topology->observed_dock_pid = dock_pid;
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
}

static AXUIElementRef managed_space_topology_copy_ax_list_child(AXUIElementRef list, int index)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(list, kAXChildrenAttribute, &value) != kAXErrorSuccess || !value) {
        return NULL;
    }

    CFArrayRef children = value;
    int child_count = CFArrayGetCount(children);
    AXUIElementRef result = index >= 0 && index < child_count
        ? CFRetain((AXUIElementRef) CFArrayGetValueAtIndex(children, index))
        : NULL;
    CFRelease(children);
    return result;
}

static bool managed_space_topology_ax_frame(AXUIElementRef element, CGRect *frame)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXFrame"), &value) != kAXErrorSuccess || !value) {
        return false;
    }

    bool result = CFGetTypeID(value) == AXValueGetTypeID() &&
                  AXValueGetType(value) == kAXValueCGRectType &&
                  AXValueGetValue(value, kAXValueCGRectType, frame);
    CFRelease(value);
    return result;
}

static void managed_space_topology_post_mouse_event(CGEventType type, CGPoint point)
{
    CGMouseButton button = kCGMouseButtonLeft;
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, button);
    if (!event) return;

    CGEventSetIntegerValueField(event, kCGEventSourceUserData, MANAGED_SPACE_TOPOLOGY_MOUSE_EVENT_TAG);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void managed_space_topology_drag(CGPoint source, CGPoint destination)
{
    CGEventRef current_event = CGEventCreate(NULL);
    CGPoint original = current_event ? CGEventGetLocation(current_event) : source;
    if (current_event) CFRelease(current_event);

    managed_space_topology_post_mouse_event(kCGEventMouseMoved, source);
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_INITIAL_DELAY_US);
    managed_space_topology_post_mouse_event(kCGEventLeftMouseDown, source);
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_HOLD_DELAY_US);

    for (int i = 1; i <= 12; ++i) {
        double progress = (double) i / 12.0;
        CGPoint point = {
            .x = source.x + (destination.x - source.x) * progress,
            .y = source.y + (destination.y - source.y) * progress
        };
        managed_space_topology_post_mouse_event(kCGEventLeftMouseDragged, point);
        usleep(MANAGED_SPACE_TOPOLOGY_DRAG_STEP_DELAY_US);
    }

    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_DROP_DELAY_US);
    managed_space_topology_post_mouse_event(kCGEventLeftMouseUp, destination);
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_RELEASE_DELAY_US);
    managed_space_topology_post_mouse_event(kCGEventMouseMoved, original);
}

static bool managed_space_topology_ax_create(struct managed_space_topology *topology, AXUIElementRef mission_control)
{
    AXUIElementRef spaces = managed_space_topology_copy_ax_spaces_group(mission_control, topology->current.target_did);
    if (!spaces) return false;

    AXUIElementRef add = managed_space_topology_copy_ax_child(spaces, CFSTR("mc.spaces.add"));
    CFRelease(spaces);
    int space_count = display_space_count(topology->current.target_did);
    if (!add) {
        if (space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            managed_space_topology_record_space_limit(topology,
                                                      topology->current.target_did,
                                                      space_count);
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "space-limit-reached");
        } else {
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-add-control-unavailable");
        }
        return false;
    }

    CFTypeRef enabled_value = NULL;
    bool enabled = true;
    if (AXUIElementCopyAttributeValue(add, kAXEnabledAttribute, &enabled_value) == kAXErrorSuccess && enabled_value) {
        enabled = CFGetTypeID(enabled_value) != CFBooleanGetTypeID() || CFBooleanGetValue(enabled_value);
        CFRelease(enabled_value);
    }

    AXError result = enabled ? AXUIElementPerformAction(add, kAXPressAction) : kAXErrorActionUnsupported;
    CFRelease(add);
    if (result != kAXErrorSuccess) {
        if (!enabled && space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            managed_space_topology_record_space_limit(topology,
                                                      topology->current.target_did,
                                                      space_count);
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "space-limit-reached");
        } else if (!enabled) {
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-add-control-disabled");
        }
        return false;
    }

    topology->current.mutation_started = true;
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT;
    return true;
}

static bool managed_space_topology_ax_destroy(struct managed_space_topology *topology, AXUIElementRef mission_control)
{
    uint32_t did = space_display_id(topology->current.sid);
    int count = 0;
    uint64_t *space_list = display_space_list(did, &count);
    int index = managed_space_topology_find_sid(space_list, count, topology->current.sid);
    if (index < 0) return false;

    AXUIElementRef spaces = managed_space_topology_copy_ax_spaces_group(mission_control, did);
    if (!spaces) return false;

    AXUIElementRef list = managed_space_topology_copy_ax_child(spaces, CFSTR("mc.spaces.list"));
    CFRelease(spaces);
    if (!list) return false;

    AXUIElementRef child = managed_space_topology_copy_ax_list_child(list, index);
    CFRelease(list);
    if (!child) return false;

    AXError result = AXUIElementPerformAction(child, CFSTR("AXRemoveDesktop"));
    CFRelease(child);
    if (result != kAXErrorSuccess) return false;

    topology->current.mutation_started = true;
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT;
    return true;
}

static bool managed_space_topology_ax_reorder(struct managed_space_topology *topology, AXUIElementRef mission_control)
{
    struct managed_space_topology_request *request = &topology->current;
    uint32_t did = space_display_id(request->sid);
    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return false;

    int mismatch_index = -1;
    int target_index = -1;
    int user_index = 0;
    for (int i = 0; i < space_count; ++i) {
        if (!space_is_user(space_list[i])) continue;
        if (user_index >= request->desired_order_count) return false;
        if (mismatch_index < 0 && space_list[i] != request->desired_order[user_index]) {
            mismatch_index = user_index;
            target_index = i;
            break;
        }
        ++user_index;
    }

    if (mismatch_index < 0) {
        if (user_index != request->desired_order_count) return false;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, 0);
        return true;
    }

    int source_index = managed_space_topology_find_sid(space_list, space_count, request->desired_order[mismatch_index]);
    if (source_index < 0 || source_index == target_index) return false;
    if (++request->phase > request->desired_order_count + 1) return false;

    AXUIElementRef spaces = managed_space_topology_copy_ax_spaces_group(mission_control, did);
    if (!spaces) return false;
    AXUIElementRef list = managed_space_topology_copy_ax_child(spaces, CFSTR("mc.spaces.list"));
    CFRelease(spaces);
    if (!list) return false;

    AXUIElementRef source = managed_space_topology_copy_ax_list_child(list, source_index);
    AXUIElementRef target = managed_space_topology_copy_ax_list_child(list, target_index);
    CFRelease(list);
    if (!source || !target) {
        if (source) CFRelease(source);
        if (target) CFRelease(target);
        return false;
    }

    CGRect source_frame;
    CGRect target_frame;
    bool have_frames = managed_space_topology_ax_frame(source, &source_frame) &&
                       managed_space_topology_ax_frame(target, &target_frame);
    CFRelease(source);
    CFRelease(target);
    if (!have_frames) return false;

    CGRect display_frame = CGDisplayBounds(did);
    bool frames_visible = CGRectIntersectsRect(source_frame, display_frame) &&
                          CGRectIntersectsRect(target_frame, display_frame);
    if (!frames_visible) {
        if (request->ax_spaces_bar_hovered) {
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-spaces-bar-unavailable");
            return false;
        }

        CGPoint hover_point = {
            CGRectGetMidX(display_frame),
            CGRectGetMinY(display_frame) + 1.0
        };
        request->ax_spaces_bar_hovered = true;
        managed_space_topology_post_mouse_event(kCGEventMouseMoved, hover_point);
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_SPACES_BAR_DELAY_SECONDS);
        return true;
    }

    CGPoint source_point = {
        CGRectGetMidX(source_frame),
        CGRectGetMidY(source_frame)
    };
    CGPoint target_point = {
        source_index > target_index
            ? CGRectGetMinX(target_frame) + CGRectGetWidth(target_frame) * 0.20
            : CGRectGetMaxX(target_frame) - CGRectGetWidth(target_frame) * 0.20,
        CGRectGetMidY(target_frame)
    };

    debug("managed_space_topology_ax_reorder: dragging space %llu from child %d "
          "(%.1f, %.1f, %.1f, %.1f) to child %d (%.1f, %.1f, %.1f, %.1f), "
          "points (%.1f, %.1f) -> (%.1f, %.1f)\n",
          request->desired_order[mismatch_index],
          source_index,
          source_frame.origin.x,
          source_frame.origin.y,
          source_frame.size.width,
          source_frame.size.height,
          target_index,
          target_frame.origin.x,
          target_frame.origin.y,
          target_frame.size.width,
          target_frame.size.height,
          source_point.x,
          source_point.y,
          target_point.x,
          target_point.y);

    managed_space_topology_drag(source_point, target_point);
    request->mutation_started = true;
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
    managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    return true;
}

static bool managed_space_topology_ax_move_display(struct managed_space_topology *topology, AXUIElementRef mission_control)
{
    struct managed_space_topology_request *request = &topology->current;
    if (space_display_id(request->sid) == request->target_did) {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, 0);
        return true;
    }

    uint32_t source_did = space_display_id(request->sid);
    int source_count = 0;
    uint64_t *source_space_list = display_space_list(source_did, &source_count);
    int source_index = managed_space_topology_find_sid(source_space_list, source_count, request->sid);
    if (source_index < 0) return false;

    AXUIElementRef source_spaces = managed_space_topology_copy_ax_spaces_group(mission_control, source_did);
    AXUIElementRef target_spaces = managed_space_topology_copy_ax_spaces_group(mission_control, request->target_did);
    if (!source_spaces || !target_spaces) {
        if (source_spaces) CFRelease(source_spaces);
        if (target_spaces) CFRelease(target_spaces);
        return false;
    }

    AXUIElementRef source_list = managed_space_topology_copy_ax_child(source_spaces, CFSTR("mc.spaces.list"));
    AXUIElementRef target_list = managed_space_topology_copy_ax_child(target_spaces, CFSTR("mc.spaces.list"));
    CFRelease(source_spaces);
    CFRelease(target_spaces);
    if (!source_list || !target_list) {
        if (source_list) CFRelease(source_list);
        if (target_list) CFRelease(target_list);
        return false;
    }

    AXUIElementRef source = managed_space_topology_copy_ax_list_child(source_list, source_index);
    CFRelease(source_list);
    if (!source) {
        CFRelease(target_list);
        return false;
    }

    int target_count = 0;
    display_space_list(request->target_did, &target_count);
    AXUIElementRef target = managed_space_topology_copy_ax_list_child(target_list, MAX(0, target_count - 1));
    CFRelease(target_list);
    if (!target) {
        CFRelease(source);
        return false;
    }

    CGRect source_frame;
    CGRect target_frame;
    bool have_frames = managed_space_topology_ax_frame(source, &source_frame) &&
                       managed_space_topology_ax_frame(target, &target_frame);
    CFRelease(source);
    CFRelease(target);
    if (!have_frames) return false;

    CGRect source_display_frame = CGDisplayBounds(source_did);
    if (!CGRectIntersectsRect(source_frame, source_display_frame)) {
        if (request->ax_spaces_bar_hovered) {
            debug("managed_space_topology_ax_move_display: source space %llu frame "
                  "(%.1f, %.1f, %.1f, %.1f) did not expand on display %u\n",
                  request->sid,
                  source_frame.origin.x,
                  source_frame.origin.y,
                  source_frame.size.width,
                  source_frame.size.height,
                  source_did);
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-spaces-bar-unavailable");
            return false;
        }

        CGPoint hover_point = {
            CGRectGetMidX(source_display_frame),
            CGRectGetMinY(source_display_frame) + 1.0
        };
        request->ax_spaces_bar_hovered = true;
        managed_space_topology_post_mouse_event(kCGEventMouseMoved, hover_point);
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_SPACES_BAR_DELAY_SECONDS);
        return true;
    }

    if (request->mutation_started) return false;

    CGRect target_display_frame = CGDisplayBounds(request->target_did);
    bool target_frame_visible = CGRectIntersectsRect(target_frame, target_display_frame);
    CGPoint source_point = { CGRectGetMidX(source_frame), CGRectGetMidY(source_frame) };
    CGPoint target_point = {
        CGRectGetMidX(target_frame),
        target_frame_visible
            ? CGRectGetMidY(target_frame)
            : CGRectGetMinY(target_display_frame) + 60.0
    };
    debug("managed_space_topology_ax_move_display: dragging space %llu from display %u "
          "(%.1f, %.1f, %.1f, %.1f) to display %u "
          "(%.1f, %.1f, %.1f, %.1f), points (%.1f, %.1f) -> (%.1f, %.1f)\n",
          request->sid,
          source_did,
          source_frame.origin.x,
          source_frame.origin.y,
          source_frame.size.width,
          source_frame.size.height,
          request->target_did,
          target_frame.origin.x,
          target_frame.origin.y,
          target_frame.size.width,
          target_frame.size.height,
          source_point.x,
          source_point.y,
          target_point.x,
          target_point.y);
    managed_space_topology_drag(source_point, target_point);
    request->mutation_started = true;
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
    managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    return true;
}

static bool managed_space_topology_execute_accessibility(struct managed_space_topology *topology)
{
    if (managed_space_topology_request_is_satisfied(&topology->current)) {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, 0);
        return true;
    }

    if (!topology->current.mutation_started &&
        topology->current.precondition_hash != managed_space_topology_snapshot_hash()) {
        snprintf(topology->operation_error,
                 sizeof(topology->operation_error),
                 "%s",
                 "stale-topology");
        return false;
    }

    pid_t dock_pid = 0;
    AXUIElementRef mission_control = managed_space_topology_copy_mission_control(&dock_pid);
    if (!mission_control) return false;
    managed_space_topology_observe_mission_control(topology, dock_pid, mission_control);

    bool result = false;
    switch (topology->current.operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        result = managed_space_topology_ax_create(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        result = managed_space_topology_ax_destroy(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:
        result = managed_space_topology_ax_reorder(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        result = managed_space_topology_ax_move_display(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        break;
    }

    CFRelease(mission_control);
    if (result && topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) {
        managed_space_topology_schedule_watchdog(topology);
    }
    return result;
}

static uint64_t managed_space_topology_other_user_space(uint32_t did, uint64_t sid)
{
    int count = 0;
    uint64_t *space_list = display_space_list(did, &count);

    for (int i = 0; i < count; ++i) {
        uint64_t candidate_sid = space_list[i];
        if (candidate_sid != sid && space_is_user(candidate_sid)) return candidate_sid;
    }

    return 0;
}

static void managed_space_topology_start_accessibility(struct managed_space_topology *topology)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY &&
        topology->current.phase == 0 &&
        display_space_id(topology->current.target_did) == topology->current.sid) {
        uint64_t focus_sid = managed_space_topology_other_user_space(topology->current.target_did,
                                                                     topology->current.sid);
        enum space_op_error result = focus_sid
            ? space_manager_focus_space(focus_sid)
            : SPACE_OP_ERROR_MISSING_DST;
        if (result != SPACE_OP_ERROR_SUCCESS && result != SPACE_OP_ERROR_SAME_SPACE) {
            managed_space_topology_fail_current(topology, "could-not-focus-destroy-target");
            return;
        }

        topology->current.phase = 1;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY;
        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
        managed_space_topology_schedule_watchdog(topology);
        return;
    }

    bool mission_control_active = mission_control_is_active() ||
                                  managed_space_topology_mission_control_ui_exists();
    if (mission_control_active) {
        topology->state = managed_space_topology_accessibility_session_state(true,
                                                                              topology->owns_mission_control);
        if (!topology->owns_mission_control) {
            return;
        }

        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
        managed_space_topology_schedule_watchdog(topology);
        return;
    }

    topology->owns_mission_control = true;
    topology->state = managed_space_topology_accessibility_session_state(false, true);
    CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
    managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
    managed_space_topology_schedule_watchdog(topology);
}

static void managed_space_topology_begin_current(struct managed_space_topology *topology)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        topology->current.placeholder_required &&
        space_manager_is_space_last_user_space(topology->current.sid)) {
        managed_space_topology_fail_current(topology, "placeholder-create-failed");
        return;
    }

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY) {
        uint32_t source_did = space_display_id(topology->current.sid);
        bool source_is_active = display_space_id(source_did) == topology->current.sid;

        if (topology->current.phase == 0 && source_is_active) {
            if (topology->owns_mission_control &&
                (mission_control_is_active() || managed_space_topology_mission_control_ui_exists())) {
                topology->current.phase = -1;
                topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT;
                managed_space_topology_close_owned_mission_control(topology);
                managed_space_topology_schedule_watchdog(topology);
                return;
            }

            uint64_t focus_sid = managed_space_topology_other_user_space(source_did,
                                                                         topology->current.sid);
            if (!focus_sid) {
                managed_space_topology_fail_current(topology, "could-not-deactivate-move-source");
                return;
            }

            topology->current.restore_focus_sid = space_manager_active_space();
            enum space_op_error result = space_manager_focus_space(focus_sid);
            if (result != SPACE_OP_ERROR_SUCCESS && result != SPACE_OP_ERROR_SAME_SPACE) {
                managed_space_topology_fail_current(topology, "could-not-deactivate-move-source");
                return;
            }

            topology->current.phase = 1;
            topology->state = MANAGED_SPACE_TOPOLOGY_STATE_QUEUED;
            managed_space_topology_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
            managed_space_topology_schedule_watchdog(topology);
            return;
        }

        if (topology->current.phase == 1) {
            if (source_is_active) {
                managed_space_topology_fail_current(topology, "could-not-deactivate-move-source");
                return;
            }

            uint64_t restore_sid = topology->current.restore_focus_sid;
            if (!topology->current.focus_space &&
                restore_sid &&
                restore_sid != space_manager_active_space()) {
                enum space_op_error result = space_manager_focus_space(restore_sid);
                if (result != SPACE_OP_ERROR_SUCCESS && result != SPACE_OP_ERROR_SAME_SPACE) {
                    managed_space_topology_fail_current(topology, "could-not-restore-focus-before-move");
                    return;
                }
                topology->current.restore_focus_sid = 0;
            }
            topology->current.phase = 2;
        }
    }

    if (managed_space_topology_request_is_satisfied(&topology->current)) {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
        managed_space_topology_schedule_step(topology, 0);
        managed_space_topology_schedule_watchdog(topology);
        return;
    }

    if (topology->current.precondition_hash != managed_space_topology_snapshot_hash()) {
        managed_space_topology_fail_current(topology, "stale-topology");
        return;
    }

    if ((mission_control_is_active() || managed_space_topology_mission_control_ui_exists()) &&
        !topology->owns_mission_control) {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_USER_MISSION_CONTROL;
        managed_space_topology_cancel_watchdog(topology);
        return;
    }

    if (topology->owns_mission_control &&
        topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION &&
        topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO) {
        topology->current.backend = managed_space_topology_select_fallback_backend(
            topology,
            topology->current.operation);
    }

    if (topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION) {
        if (managed_space_topology_execute_scripting_addition(topology)) return;

        if (topology->current.mutation_started) {
            managed_space_topology_fail_current(topology, "scripting-addition-partial-failure");
            return;
        }

        topology->current.backend = managed_space_topology_select_fallback_backend(
            topology,
            topology->current.operation);
        if (topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_NONE) {
            managed_space_topology_fail_current(topology, "scripting-addition-unavailable");
            return;
        }
    }

    if (topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE) {
        if (!managed_space_topology_execute_bridge(topology)) {
            managed_space_topology_fail_current(topology, "bridge-operation-failed");
        }
    } else if (topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY) {
        if (!AXIsProcessTrusted()) {
            managed_space_topology_fail_current(topology, "accessibility-permission-missing");
        } else {
            managed_space_topology_start_accessibility(topology);
        }
    } else {
        managed_space_topology_fail_current(topology, "backend-unavailable");
    }
}

static void managed_space_topology_start_next(struct managed_space_topology *topology)
{
    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;
    if (buf_len(topology->queue) == 0) return;

    topology->current = topology->queue[0];
    if (buf_len(topology->queue) > 1) {
        memmove(topology->queue,
                topology->queue + 1,
                sizeof(struct managed_space_topology_request) * (buf_len(topology->queue) - 1));
    }
    --buf__hdr(topology->queue)->len;

    topology->current.precondition_hash = managed_space_topology_snapshot_hash();
    managed_space_topology_copy_space_uuid(topology->current.sid, topology->current.sid_uuid);
    managed_space_topology_copy_space_uuid(topology->current.target_sid, topology->current.target_uuid);
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY) {
        topology->current.focus_space = topology->current.sid == space_manager_active_space();
    }
    topology->operation_error[0] = '\0';
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_QUEUED;
    managed_space_topology_begin_current(topology);
}

static bool managed_space_topology_event_matches(struct managed_space_topology_request *request,
                                                 enum managed_space_topology_operation operation,
                                                 uint64_t sid)
{
    if (request->operation != operation) return false;
    if (operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE) {
        return !request->created_sid || request->created_sid == sid;
    }

    return request->sid == sid;
}

void managed_space_topology_handle_space_created(struct managed_space_topology *topology, uint64_t sid)
{
    if (topology->space_limit_reached) {
        int space_count = display_space_count(topology->space_limit_did);
        if (space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            topology->space_limit_count = space_count;
        } else {
            managed_space_topology_note_configuration_changed(topology);
        }
    }

    if (!managed_space_topology_event_matches(&topology->current,
                                              MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
                                              sid)) {
        if (!topology->space_limit_reached) {
            managed_space_topology_note_configuration_changed(topology);
        }
        return;
    }
    topology->current.created_sid = sid;
    managed_space_topology_copy_space_uuid(sid, topology->current.sid_uuid);
    if (!managed_space_topology_request_is_satisfied(&topology->current)) return;

    managed_space_topology_complete_current(topology);
}

void managed_space_topology_handle_space_destroyed(struct managed_space_topology *topology, uint64_t sid)
{
    if (topology->space_limit_reached) {
        int space_count = display_space_count(topology->space_limit_did);
        if (space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            topology->space_limit_count = space_count;
        } else {
            managed_space_topology_note_configuration_changed(topology);
        }
    }

    if (!managed_space_topology_event_matches(&topology->current,
                                              MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
                                              sid)) {
        if (!topology->space_limit_reached) {
            managed_space_topology_note_configuration_changed(topology);
        }
        return;
    }

    managed_space_topology_complete_current(topology);
}

void managed_space_topology_handle_mission_control_enter(struct managed_space_topology *topology)
{
    if (topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL) return;
    if (!topology->owns_mission_control) return;

    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY;
    managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
}

void managed_space_topology_handle_mission_control_exit(struct managed_space_topology *topology)
{
    bool space_limit_failure =
        topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE &&
        string_equals(topology->operation_error, "space-limit-reached");
    uint32_t space_limit_did = topology->current.target_did;
    int space_limit_count = topology->space_limit_count;

    managed_space_topology_stop_ax_observer(topology);
    bool finish_batch = topology->finish_batch_requested;
    topology->finish_batch_requested = false;
    topology->owns_mission_control = false;
    managed_space_topology_restore_pending_focus(topology);

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) {
        managed_space_topology_note_configuration_changed(topology);
    }

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        topology->state == MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT &&
        topology->current.phase == -1) {
        topology->current.phase = 0;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_QUEUED;
        managed_space_topology_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
        return;
    }

    if (topology->state == MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_USER_MISSION_CONTROL) {
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_QUEUED;
        managed_space_topology_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
        return;
    }

    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY &&
        managed_space_topology_request_is_satisfied(&topology->current)) {
        managed_space_topology_complete_current(topology);
        return;
    }

    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->state == MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT) {
        managed_space_topology_fail_current(topology, "topology-postcondition-failed");
        return;
    }

    if (topology->state == MANAGED_SPACE_TOPOLOGY_STATE_FAILED || finish_batch) {
        managed_space_topology_discard_request(&topology->current);
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;
        if (space_limit_failure) {
            managed_space_topology_record_space_limit(topology,
                                                      space_limit_did,
                                                      space_limit_count);
        }
        managed_space_topology_start_next(topology);
        managed_space_request_reconcile(&g_managed_space);
        return;
    }

    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY) {
        managed_space_topology_fail_current(topology, "mission-control-exited");
    }
}

void managed_space_topology_handle_dock_restart(struct managed_space_topology *topology)
{
    managed_space_topology_stop_ax_observer(topology);
    managed_space_topology_note_configuration_changed(topology);
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) {
        topology->owns_mission_control = false;
        topology->finish_batch_requested = false;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;
        managed_space_request_reconcile(&g_managed_space);
        return;
    }
    managed_space_topology_fail_current(topology, "dock-restarted");
}

void managed_space_topology_note_input_event(struct managed_space_topology *topology, CGEventRef event)
{
    if (!topology->owns_mission_control) return;
    if (!event || topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == MANAGED_SPACE_TOPOLOGY_MOUSE_EVENT_TAG) return;

    event_loop_post(&g_event_loop,
                    MANAGED_SPACE_TOPOLOGY_USER_INPUT,
                    (void *)(uintptr_t) topology->current.generation,
                    0);
}

void managed_space_topology_handle_user_interruption(struct managed_space_topology *topology, uint64_t generation)
{
    if (!topology->owns_mission_control) return;
    if (topology->current.generation != generation) return;

    topology->owns_mission_control = false;
    topology->finish_batch_requested = false;
    managed_space_topology_stop_ax_observer(topology);
    managed_space_topology_fail_current(topology, "user-interrupted");
}

void managed_space_topology_step(struct managed_space_topology *topology, uint64_t token)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;
    if (token != topology->step_token) return;
    if (topology->current.generation != topology->step_generation) return;

    if (topology->state == MANAGED_SPACE_TOPOLOGY_STATE_QUEUED) {
        managed_space_topology_begin_current(topology);
        return;
    }

    if (topology->state == MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL) {
        if (!topology->owns_mission_control) return;
        if (!mission_control_is_active() && !managed_space_topology_mission_control_ui_exists()) return;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY;
    }

    if (topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION ||
        topology->current.backend == MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE) {
        if (topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE) return;
        if (managed_space_topology_request_is_satisfied(&topology->current)) {
            managed_space_topology_complete_current(topology);
        }
        return;
    }

    if (topology->current.backend != MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY) return;

    if (topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY &&
        topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE) return;

    bool was_waiting_for_settle = topology->state == MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_SETTLE;
    if (was_waiting_for_settle && managed_space_topology_request_is_satisfied(&topology->current)) {
        managed_space_topology_complete_current(topology);
        return;
    }

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY &&
        topology->current.phase == 1 &&
        !mission_control_is_active()) {
        managed_space_topology_start_accessibility(topology);
        return;
    }

    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY;
    if (!managed_space_topology_execute_accessibility(topology)) {
        char *error = topology->operation_error[0]
            ? topology->operation_error
            : "accessibility-operation-failed";
        managed_space_topology_fail_current(topology, error);
    }
}

void managed_space_topology_watchdog(struct managed_space_topology *topology, uint64_t token)
{
    if (token != topology->watchdog_token) return;
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) {
        if (topology->state != MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT) return;

        snprintf(topology->last_error, sizeof(topology->last_error), "%s", "mission-control-exit-timed-out");
        topology->last_failed_operation = MANAGED_SPACE_TOPOLOGY_OPERATION_NONE;
        topology->last_failed_backend = MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY;
        event_signal_push(SIGNAL_MANAGED_SPACE_TOPOLOGY_FAILED, topology);
        managed_space_topology_close_owned_mission_control(topology);
        topology->owns_mission_control = false;
        topology->finish_batch_requested = false;
        topology->state = MANAGED_SPACE_TOPOLOGY_STATE_IDLE;
        managed_space_topology_start_next(topology);
        managed_space_request_reconcile(&g_managed_space);
        return;
    }
    if (topology->current.generation != topology->watchdog_generation) return;

    if (managed_space_topology_request_is_satisfied(&topology->current)) {
        managed_space_topology_complete_current(topology);
    } else {
        managed_space_topology_fail_current(topology, "operation-timed-out");
    }
}

bool managed_space_topology_operation_pending(struct managed_space_topology *topology)
{
    return topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE ||
           buf_len(topology->queue) > 0;
}

bool managed_space_topology_reconciliation_blocked(struct managed_space_topology *topology)
{
    return topology->reconciliation_blocked;
}

bool managed_space_topology_owns_mission_control(struct managed_space_topology *topology)
{
    return topology->owns_mission_control;
}

void managed_space_topology_finish_batch(struct managed_space_topology *topology)
{
    if (!topology->owns_mission_control) return;
    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;

    topology->finish_batch_requested = true;
    topology->state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL_EXIT;
    managed_space_topology_close_owned_mission_control(topology);
    managed_space_topology_schedule_watchdog(topology);
}

void managed_space_topology_write_query(FILE *rsp, struct managed_space_topology *topology)
{
    struct managed_space_topology_request *request = &topology->current;
    char target_display_uuid[64] = {0};
    if (request->target_did) {
        CFStringRef uuid = display_uuid(request->target_did);
        if (uuid) {
            CFStringGetCString(uuid,
                               target_display_uuid,
                               sizeof(target_display_uuid),
                               kCFStringEncodingUTF8);
            CFRelease(uuid);
        }
    }
    uint32_t known_bridge_operations = managed_space_topology_known_bridge_operations(topology->os_build);
    enum managed_space_topology_operation operations[] = {
        MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
        MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
        MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER,
        MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY
    };

    fprintf(rsp,
            "\t\"topology-backend-policy\":\"%s\",\n"
            "\t\"topology-os-build\":\"%s\",\n"
            "\t\"topology-accessibility-trusted\":%s,\n"
            "\t\"topology-capabilities\":{",
            managed_space_topology_backend_policy_name(topology->policy),
            topology->os_build,
            json_bool(AXIsProcessTrusted()));

    for (int i = 0; i < array_count(operations); ++i) {
        enum managed_space_topology_operation operation = operations[i];
        enum managed_space_topology_backend fallback = managed_space_topology_select_fallback_backend(topology, operation);
        bool bridge_available = managed_space_topology_bridge_symbol_available(operation);
        bool bridge_validated = (known_bridge_operations & managed_space_topology_operation_bridge_bit(operation)) != 0;
        const char *primary = "scripting-addition";
        const char *fallback_name = "none";

        if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE ||
            topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY) {
            primary = managed_space_topology_backend_name(fallback);
        } else if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO) {
            fallback_name = managed_space_topology_backend_name(fallback);
        }

        fprintf(rsp,
                "%s\"%s\":{\"primary\":\"%s\",\"fallback\":\"%s\",\"bridge-available\":%s,\"bridge-validated\":%s,\"accessibility\":true}",
                i ? "," : "",
                managed_space_topology_operation_name(operation),
                primary,
                fallback_name,
                json_bool(bridge_available),
                json_bool(bridge_validated));
    }

    fprintf(rsp,
            "},\n"
            "\t\"topology-state\":\"%s\",\n"
            "\t\"topology-operation\":\"%s\",\n"
            "\t\"topology-operation-origin\":\"%s\",\n"
            "\t\"topology-operation-backend\":\"%s\",\n"
            "\t\"topology-operation-generation\":%llu,\n"
            "\t\"topology-operation-precondition-hash\":\"%016llx\",\n"
            "\t\"topology-operation-space\":%llu,\n"
            "\t\"topology-operation-space-uuid\":\"%s\",\n"
            "\t\"topology-operation-target-space\":%llu,\n"
            "\t\"topology-operation-target-space-uuid\":\"%s\",\n"
            "\t\"topology-operation-created-space\":%llu,\n"
            "\t\"topology-operation-target-display\":%d,\n"
            "\t\"topology-operation-target-display-uuid\":\"%s\",\n"
            "\t\"topology-operation-phase\":%d,\n"
            "\t\"topology-operation-mutation-started\":%s,\n"
            "\t\"topology-queue-depth\":%d,\n"
            "\t\"topology-owns-mission-control\":%s,\n"
            "\t\"topology-reconciliation-blocked\":%s,\n"
            "\t\"topology-space-limit-reached\":%s,\n"
            "\t\"topology-space-limit-display\":%d,\n"
            "\t\"topology-space-limit-count\":%d,\n"
            "\t\"topology-last-failed-generation\":%llu,\n"
            "\t\"topology-last-failed-operation\":\"%s\",\n"
            "\t\"topology-last-failed-backend\":\"%s\",\n"
            "\t\"topology-last-error\":\"%s\",\n",
            managed_space_topology_state_name(topology->state),
            managed_space_topology_operation_name(request->operation),
            request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE
                ? "none"
                : managed_space_topology_origin_name(request->origin),
            managed_space_topology_backend_name(request->backend),
            request->generation,
            request->precondition_hash,
            request->sid,
            request->sid_uuid,
            request->target_sid,
            request->target_uuid,
            request->created_sid,
            request->target_did ? display_manager_display_id_arrangement(request->target_did) : 0,
            target_display_uuid,
            request->phase,
            json_bool(request->mutation_started),
            buf_len(topology->queue),
            json_bool(topology->owns_mission_control),
            json_bool(topology->reconciliation_blocked),
            json_bool(topology->space_limit_reached),
            topology->space_limit_did ? display_manager_display_id_arrangement(topology->space_limit_did) : 0,
            topology->space_limit_count,
            topology->last_failed_generation,
            managed_space_topology_operation_name(topology->last_failed_operation),
            managed_space_topology_backend_name(topology->last_failed_backend),
            topology->last_error);
}
