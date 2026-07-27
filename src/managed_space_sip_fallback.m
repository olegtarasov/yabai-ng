// Full-SIP fallback topology implementation. This file must only be reached
// through the managed-space topology provider.
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
#define MANAGED_SPACE_TOPOLOGY_PHASE_CLOSE_MISSION_CONTROL -1
#define MANAGED_SPACE_TOPOLOGY_PHASE_DEACTIVATE_IN_MISSION_CONTROL -2
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_CREATE 0x01
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_DESTROY 0x02
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_REORDER 0x04
#define MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY 0x08

enum managed_space_sip_fallback_ax_result
{
    MANAGED_SPACE_TOPOLOGY_AX_FAILED,
    MANAGED_SPACE_TOPOLOGY_AX_WAITING,
    MANAGED_SPACE_TOPOLOGY_AX_STARTED
};

typedef id (*managed_space_sip_fallback_synchronous_bridge_fn)(void *);

static managed_space_sip_fallback_synchronous_bridge_fn managed_space_sip_fallback_synchronous_bridge;
static bool managed_space_sip_fallback_bridge_symbols_resolved;

static void managed_space_sip_fallback_start_next(struct managed_space_sip_fallback *topology);
static bool managed_space_sip_fallback_mission_control_ui_exists(void);
static int managed_space_sip_fallback_copy_matching_spaces(uint64_t *source,
                                                           int source_count,
                                                           uint64_t *destination,
                                                           bool (*matches)(uint64_t));

#ifdef TESTS
static bool managed_space_sip_fallback_test_snapshot_override_enabled;
static uint64_t managed_space_sip_fallback_test_snapshot_override;
#endif

static uint64_t managed_space_sip_fallback_hash_u64(uint64_t hash, uint64_t value)
{
    for (int byte = 0; byte < 8; ++byte) {
        hash ^= value & 0xff;
        hash *= 1099511628211ULL;
        value >>= 8;
    }

    return hash;
}

static uint64_t managed_space_sip_fallback_snapshot_hash(void)
{
#ifdef TESTS
    if (managed_space_sip_fallback_test_snapshot_override_enabled) {
        return managed_space_sip_fallback_test_snapshot_override;
    }
#endif

    uint64_t hash = 1469598103934665603ULL;

    for (int index = 1;; ++index) {
        uint64_t sid = space_manager_mission_control_space(index);
        if (!sid) break;

        hash = managed_space_sip_fallback_hash_u64(hash, sid);
        hash = managed_space_sip_fallback_hash_u64(hash, space_display_id(sid));
        hash = managed_space_sip_fallback_hash_u64(hash, index);
        hash = managed_space_sip_fallback_hash_u64(hash, SLSSpaceGetType(g_connection, sid));
    }

    return hash;
}

static void managed_space_sip_fallback_copy_space_uuid(uint64_t sid, char uuid[64])
{
    if (!sid) return;

    CFStringRef uuid_ref = SLSSpaceCopyName(g_connection, sid);
    if (!uuid_ref) return;
    CFStringGetCString(uuid_ref, uuid, 64, kCFStringEncodingUTF8);
    CFRelease(uuid_ref);
}

void managed_space_sip_fallback_discard_request(struct managed_space_sip_fallback_request *request)
{
    if (request->desired_order) free(request->desired_order);
    if (request->pre_source_order) free(request->pre_source_order);
    if (request->pre_target_order) free(request->pre_target_order);
    memset(request, 0, sizeof(struct managed_space_sip_fallback_request));
}

static void managed_space_sip_fallback_clear_queue(struct managed_space_sip_fallback *topology)
{
    managed_space_sip_fallback_discard_request(&topology->current);
    for (int i = 0; i < buf_len(topology->queue); ++i) {
        managed_space_sip_fallback_discard_request(&topology->queue[i]);
    }

    buf_free(topology->queue);
    topology->queue = NULL;
}

static void managed_space_sip_fallback_schedule_step(struct managed_space_sip_fallback *topology, double delay)
{
    uint64_t token = ++topology->step_token;
    topology->step_generation = topology->current.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, MANAGED_SPACE_TOPOLOGY_STEP, (void *)(uintptr_t) token, 0);
    });
}

static void managed_space_sip_fallback_schedule_watchdog(struct managed_space_sip_fallback *topology)
{
    uint64_t token = ++topology->watchdog_token;
    topology->watchdog_generation = topology->current.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MANAGED_SPACE_TOPOLOGY_WATCHDOG_SECONDS * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, MANAGED_SPACE_TOPOLOGY_WATCHDOG, (void *)(uintptr_t) token, 0);
    });
}

static void managed_space_sip_fallback_cancel_step(struct managed_space_sip_fallback *topology)
{
    ++topology->step_token;
}

static void managed_space_sip_fallback_cancel_watchdog(struct managed_space_sip_fallback *topology)
{
    ++topology->watchdog_token;
}

static void managed_space_sip_fallback_record_space_limit(struct managed_space_sip_fallback *topology,
                                                      uint32_t did,
                                                      int count)
{
    topology->space_limit_reached = true;
    topology->space_limit_did = did;
    topology->space_limit_count = count;
}

static void managed_space_sip_fallback_stop_ax_observer(struct managed_space_sip_fallback *topology)
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

static void managed_space_sip_fallback_stop_input_event_tap(struct managed_space_sip_fallback *topology)
{
    if (topology->input_event_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              topology->input_event_source,
                              kCFRunLoopCommonModes);
        CFRelease(topology->input_event_source);
    }
    if (topology->input_event_tap) CFRelease(topology->input_event_tap);
    topology->input_event_source = NULL;
    topology->input_event_tap = NULL;
}

static CGEventRef managed_space_sip_fallback_input_event_callback(CGEventTapProxy proxy,
                                                              CGEventType type,
                                                              CGEventRef event,
                                                              void *context)
{
    (void) proxy;
    struct managed_space_sip_fallback *topology = context;
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (topology->input_event_tap) CGEventTapEnable(topology->input_event_tap, true);
        return event;
    }

    managed_space_sip_fallback_note_input_event(topology, event);
    return event;
}

static bool managed_space_sip_fallback_start_input_event_tap(struct managed_space_sip_fallback *topology)
{
    if (topology->input_event_tap) return true;

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventFlagsChanged) |
                       CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventRightMouseDown);
    topology->input_event_tap = CGEventTapCreate(kCGSessionEventTap,
                                                 kCGHeadInsertEventTap,
                                                 kCGEventTapOptionListenOnly,
                                                 mask,
                                                 managed_space_sip_fallback_input_event_callback,
                                                 topology);
    if (!topology->input_event_tap) return false;

    topology->input_event_source = CFMachPortCreateRunLoopSource(NULL,
                                                                 topology->input_event_tap,
                                                                 0);
    if (!topology->input_event_source) {
        managed_space_sip_fallback_stop_input_event_tap(topology);
        return false;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(),
                       topology->input_event_source,
                       kCFRunLoopCommonModes);
    CGEventTapEnable(topology->input_event_tap, true);
    return true;
}

static void managed_space_sip_fallback_release_mission_control_ownership(struct managed_space_sip_fallback *topology)
{
    topology->owns_mission_control = false;
    managed_space_sip_fallback_stop_input_event_tap(topology);
}

const char *managed_space_sip_fallback_backend_name(enum managed_space_sip_fallback_backend backend)
{
    switch (backend) {
    case MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE:          return "none";
    case MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE:        return "bridge";
    case MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY: return "accessibility";
    }

    return "unknown";
}

const char *managed_space_sip_fallback_state_name(enum managed_space_sip_fallback_state state)
{
    switch (state) {
    case MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE:                             return "idle";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED:                           return "queued";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_USER_MISSION_CONTROL: return "waiting-for-user-mission-control";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL:      return "waiting-for-mission-control";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY:        return "waiting-for-accessibility";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT:                return "waiting-for-event";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE:               return "waiting-for-settle";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT: return "waiting-for-mission-control-exit";
    case MANAGED_SPACE_SIP_FALLBACK_STATE_FAILED:                           return "failed";
    }

    return "unknown";
}

static uint32_t managed_space_sip_fallback_known_bridge_operations(char *os_build)
{
    (void) os_build;

    //
    // Populated only after a reversible runtime validation on the exact OS build.
    // Forced "bridge" mode remains available for running that validation matrix.
    //
    // 25E253 was previously listed here after its bridge objects appeared in
    // SLSCopyManagedDisplaySpaces. A Dock AX snapshot and the persisted
    // com.apple.spaces topology later proved that create had produced
    // WindowServer-only spaces. No mutation on this build has passed the full
    // SLS + Dock + restart validation matrix, so none are enabled for auto.
    //
    return 0;
}

static uint32_t managed_space_sip_fallback_operation_bridge_bit(enum managed_space_topology_operation operation)
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

static void managed_space_sip_fallback_resolve_bridge_symbols(void)
{
    if (managed_space_sip_fallback_bridge_symbols_resolved) return;
    managed_space_sip_fallback_bridge_symbols_resolved = true;

    char *skylight_path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
    if (!SLSPerformAsynchronousBridgedWindowManagementOperation) {
        SLSPerformAsynchronousBridgedWindowManagementOperation = macho_find_symbol(
            skylight_path,
            "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    }
    managed_space_sip_fallback_synchronous_bridge = macho_find_symbol(
        skylight_path,
        "__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation");
}

static bool managed_space_sip_fallback_bridge_symbol_available(enum managed_space_topology_operation operation)
{
    managed_space_sip_fallback_resolve_bridge_symbols();
    if (!SLSPerformAsynchronousBridgedWindowManagementOperation) return false;

    switch (operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        return managed_space_sip_fallback_synchronous_bridge &&
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

static enum managed_space_sip_fallback_backend managed_space_sip_fallback_select_backend(struct managed_space_sip_fallback *topology,
                                                                                           enum managed_space_topology_operation operation)
{
    if (topology->policy == MANAGED_SPACE_SIP_FALLBACK_POLICY_BRIDGE) {
        return managed_space_sip_fallback_bridge_symbol_available(operation)
            ? MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE
            : MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE;
    }

    if (topology->policy == MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY) {
        return MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY;
    }

    uint32_t known_operations = managed_space_sip_fallback_known_bridge_operations(topology->os_build);
    uint32_t operation_bit = managed_space_sip_fallback_operation_bridge_bit(operation);
    if ((known_operations & operation_bit) && managed_space_sip_fallback_bridge_symbol_available(operation)) {
        return MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE;
    }

    return MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY;
}

void managed_space_sip_fallback_init(struct managed_space_sip_fallback *topology)
{
    memset(topology, 0, sizeof(struct managed_space_sip_fallback));
    topology->policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;

    size_t os_build_size = sizeof(topology->os_build);
    if (sysctlbyname("kern.osversion", topology->os_build, &os_build_size, NULL, 0) != 0) {
        topology->os_build[0] = '\0';
    }
    topology->os_build[sizeof(topology->os_build) - 1] = '\0';

}

void managed_space_sip_fallback_destroy(struct managed_space_sip_fallback *topology)
{
    managed_space_sip_fallback_stop_ax_observer(topology);
    managed_space_sip_fallback_stop_input_event_tap(topology);
    managed_space_sip_fallback_cancel_step(topology);
    managed_space_sip_fallback_cancel_watchdog(topology);
    managed_space_sip_fallback_clear_queue(topology);
    memset(topology, 0, sizeof(struct managed_space_sip_fallback));
}

void managed_space_sip_fallback_set_enabled(struct managed_space_sip_fallback *topology, bool enabled)
{
    topology->enabled = enabled;
    if (enabled) return;

    managed_space_sip_fallback_stop_ax_observer(topology);
    managed_space_sip_fallback_stop_input_event_tap(topology);
    managed_space_sip_fallback_cancel_step(topology);
    managed_space_sip_fallback_cancel_watchdog(topology);
    managed_space_sip_fallback_clear_queue(topology);
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;
    if (topology->owns_mission_control &&
        (mission_control_is_active() || managed_space_sip_fallback_mission_control_ui_exists())) {
        CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
    }

    managed_space_sip_fallback_release_mission_control_ownership(topology);
    topology->finish_batch_requested = false;
    topology->space_limit_reached = false;
    topology->space_limit_did = 0;
    topology->space_limit_count = 0;
    topology->reconciliation_blocked = false;
    topology->pending_focus_sid = 0;
}

bool managed_space_sip_fallback_is_enabled(struct managed_space_sip_fallback *topology)
{
    return topology->enabled;
}

void managed_space_sip_fallback_note_configuration_changed(struct managed_space_sip_fallback *topology)
{
    topology->space_limit_reached = false;
    topology->space_limit_did = 0;
    topology->space_limit_count = 0;
    topology->reconciliation_blocked = false;
}

void managed_space_sip_fallback_set_backend_policy(struct managed_space_sip_fallback *topology,
                                               enum managed_space_sip_fallback_policy policy)
{
    if (topology->policy == policy) return;

    topology->policy = policy;
    topology->operation_error[0] = '\0';
    managed_space_sip_fallback_note_configuration_changed(topology);
}

bool managed_space_sip_fallback_request_is_satisfied(struct managed_space_sip_fallback_request *request)
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

static void managed_space_sip_fallback_restore_pending_focus(struct managed_space_sip_fallback *topology)
{
    uint64_t sid = topology->pending_focus_sid;
    if (!sid) return;
    if (mission_control_is_active() || managed_space_sip_fallback_mission_control_ui_exists()) return;
    if (!space_manager_mission_control_index(sid)) {
        topology->pending_focus_sid = 0;
        return;
    }

    enum space_op_error result = space_manager_focus_space(sid);
    if (result == SPACE_OP_ERROR_SUCCESS || result == SPACE_OP_ERROR_SAME_SPACE) {
        topology->pending_focus_sid = 0;
    }
}

void managed_space_sip_fallback_handle_focus_changed(struct managed_space_sip_fallback *topology)
{
    if (!topology->enabled) return;
    managed_space_sip_fallback_restore_pending_focus(topology);
}

static void managed_space_sip_fallback_complete_current(struct managed_space_sip_fallback *topology)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;

    managed_space_sip_fallback_cancel_step(topology);
    managed_space_sip_fallback_cancel_watchdog(topology);

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY) {
        uint64_t validation_sid = space_manager_find_first_user_space_for_display(topology->current.target_did);
        if (validation_sid) {
            window_manager_validate_and_check_for_windows_on_space(&g_space_manager,
                                                                   &g_window_manager,
                                                                   validation_sid);
        }
        if (topology->current.restore_focus_sid) {
            topology->pending_focus_sid = topology->current.restore_focus_sid;
        }
        managed_space_sip_fallback_restore_pending_focus(topology);
    } else if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY) {
        space_manager_mark_view_invalid(&g_space_manager, topology->current.sid);
        if (topology->current.focus_space) {
            topology->pending_focus_sid = topology->current.sid;
        } else if (topology->current.restore_focus_sid) {
            topology->pending_focus_sid = topology->current.restore_focus_sid;
        }
        managed_space_sip_fallback_restore_pending_focus(topology);
    }

    managed_space_handle_sip_fallback_operation_completed(&g_managed_space, &topology->current);
    topology->reconciliation_blocked = false;
    managed_space_sip_fallback_discard_request(&topology->current);
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;
    topology->operation_error[0] = '\0';

    if (buf_len(topology->queue) > 0) {
        managed_space_sip_fallback_start_next(topology);
    } else {
        managed_space_request_reconcile(&g_managed_space);
    }
}

static void managed_space_sip_fallback_close_owned_mission_control(struct managed_space_sip_fallback *topology)
{
    if (!topology->owns_mission_control) return;
    if (!mission_control_is_active() && !managed_space_sip_fallback_mission_control_ui_exists()) {
        managed_space_sip_fallback_release_mission_control_ownership(topology);
        return;
    }

    CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
}

static void managed_space_sip_fallback_schedule_owned_mission_control_exit(
    struct managed_space_sip_fallback *topology)
{
    topology->current.phase = MANAGED_SPACE_TOPOLOGY_PHASE_CLOSE_MISSION_CONTROL;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT;
    managed_space_sip_fallback_schedule_step(topology,
                                         MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
    managed_space_sip_fallback_schedule_watchdog(topology);
}

static void managed_space_sip_fallback_schedule_owned_mission_control_deactivation(
    struct managed_space_sip_fallback *topology)
{
    topology->current.phase = MANAGED_SPACE_TOPOLOGY_PHASE_DEACTIVATE_IN_MISSION_CONTROL;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT;
    managed_space_sip_fallback_schedule_step(topology,
                                         MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    managed_space_sip_fallback_schedule_watchdog(topology);
}

static void managed_space_sip_fallback_fail_current(struct managed_space_sip_fallback *topology, char *error)
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
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_FAILED;
    if ((topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY ||
         topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY) &&
        topology->current.restore_focus_sid) {
        topology->pending_focus_sid = topology->current.restore_focus_sid;
    }
    managed_space_sip_fallback_cancel_step(topology);
    managed_space_sip_fallback_cancel_watchdog(topology);

    if (topology->active_submission_generation != topology->current.generation) {
        managed_space_handle_sip_fallback_operation_failed(&g_managed_space, &topology->current);
    }
    event_signal_push(SIGNAL_MANAGED_SPACE_TOPOLOGY_FAILED, topology);

    bool wait_for_exit = topology->owns_mission_control &&
                         (mission_control_is_active() || managed_space_sip_fallback_mission_control_ui_exists());
    if (wait_for_exit) {
        topology->finish_batch_requested = true;
        managed_space_sip_fallback_close_owned_mission_control(topology);
        return;
    }

    managed_space_sip_fallback_release_mission_control_ownership(topology);
    managed_space_sip_fallback_discard_request(&topology->current);
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;
    managed_space_sip_fallback_restore_pending_focus(topology);
    if (space_limit_failure) {
        managed_space_sip_fallback_record_space_limit(topology,
                                                  space_limit_did,
                                                  space_limit_count);
    }
    managed_space_sip_fallback_start_next(topology);
    managed_space_request_reconcile(&g_managed_space);
}

static uint64_t *managed_space_sip_fallback_copy_display_order(uint32_t did, int *count)
{
    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list || space_count <= 0) return NULL;

    uint64_t *result = malloc(sizeof(uint64_t) * space_count);
    if (!result) return NULL;

    int user_count = managed_space_sip_fallback_copy_matching_spaces(space_list,
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

static int managed_space_sip_fallback_find_sid(uint64_t *space_list, int count, uint64_t sid)
{
    for (int i = 0; i < count; ++i) {
        if (space_list[i] == sid) return i;
    }

    return -1;
}

static uint64_t *managed_space_sip_fallback_copy_full_display_order(uint32_t did, int *count)
{
    *count = 0;
    if (!did) return NULL;

    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list || space_count <= 0) return NULL;

    uint64_t *result = malloc(sizeof(uint64_t) * space_count);
    if (!result) return NULL;

    memcpy(result, space_list, sizeof(uint64_t) * space_count);
    *count = space_count;
    return result;
}

static bool managed_space_sip_fallback_snapshot_contains(uint64_t *space_list, int count, uint64_t sid)
{
    return sid && managed_space_sip_fallback_find_sid(space_list, count, sid) >= 0;
}

static void managed_space_sip_fallback_capture_request_snapshot(struct managed_space_sip_fallback_request *request)
{
    if (!request->source_did && request->sid) {
        request->source_did = space_display_id(request->sid);
    }
    if (!request->target_did) {
        request->target_did = request->source_did;
    }

    request->pre_source_order = managed_space_sip_fallback_copy_full_display_order(
        request->source_did,
        &request->pre_source_count);
    request->pre_target_order = managed_space_sip_fallback_copy_full_display_order(
        request->target_did,
        &request->pre_target_count);
}

static bool managed_space_sip_fallback_copy_persisted_display_order(uint32_t did,
                                                                uint64_t **order,
                                                                int *count)
{
    *order = NULL;
    *count = 0;
    if (!did) return false;

    CFStringRef application_id = CFSTR("com.apple.spaces");
    CFStringRef preference_key = CFSTR("SpacesDisplayConfiguration");
    CFPreferencesSynchronize(application_id,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue(preference_key,
                                                     application_id,
                                                     kCFPreferencesCurrentUser,
                                                     kCFPreferencesAnyHost);
    if (!value) {
        CFPreferencesSynchronize(application_id,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesCurrentHost);
        value = CFPreferencesCopyValue(preference_key,
                                       application_id,
                                       kCFPreferencesCurrentUser,
                                       kCFPreferencesCurrentHost);
    }
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
        if (value) CFRelease(value);
        return false;
    }

    CFDictionaryRef configuration = value;
    CFTypeRef management_value = CFDictionaryGetValue(configuration, CFSTR("Management Data"));
    if (!management_value || CFGetTypeID(management_value) != CFDictionaryGetTypeID()) {
        CFRelease(value);
        return false;
    }

    CFTypeRef monitors_value = CFDictionaryGetValue(management_value, CFSTR("Monitors"));
    if (!monitors_value || CFGetTypeID(monitors_value) != CFArrayGetTypeID()) {
        CFRelease(value);
        return false;
    }

    bool is_main_display = did == display_manager_main_display_id();
    CFStringRef target_uuid = is_main_display ? NULL : display_uuid(did);
    CFArrayRef monitors = monitors_value;
    CFArrayRef spaces = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(monitors); ++i) {
        CFTypeRef monitor_value = CFArrayGetValueAtIndex(monitors, i);
        if (!monitor_value || CFGetTypeID(monitor_value) != CFDictionaryGetTypeID()) continue;

        CFDictionaryRef monitor = monitor_value;
        CFTypeRef identifier_value = CFDictionaryGetValue(monitor, CFSTR("Display Identifier"));
        if (!identifier_value || CFGetTypeID(identifier_value) != CFStringGetTypeID()) continue;

        bool matches = is_main_display
            ? CFEqual(identifier_value, CFSTR("Main"))
            : target_uuid && CFEqual(identifier_value, target_uuid);
        if (!matches) continue;

        CFTypeRef spaces_value = CFDictionaryGetValue(monitor, CFSTR("Spaces"));
        if (spaces_value && CFGetTypeID(spaces_value) == CFArrayGetTypeID()) {
            spaces = spaces_value;
        }
        break;
    }

    if (target_uuid) CFRelease(target_uuid);
    if (!spaces) {
        CFRelease(value);
        return false;
    }

    int space_count = (int) CFArrayGetCount(spaces);
    uint64_t *result = space_count > 0 ? malloc(sizeof(uint64_t) * space_count) : NULL;
    if (space_count > 0 && !result) {
        CFRelease(value);
        return false;
    }

    for (int i = 0; i < space_count; ++i) {
        CFTypeRef space_value = CFArrayGetValueAtIndex(spaces, i);
        if (!space_value || CFGetTypeID(space_value) != CFDictionaryGetTypeID()) {
            free(result);
            CFRelease(value);
            return false;
        }

        CFTypeRef sid_value = CFDictionaryGetValue(space_value, CFSTR("ManagedSpaceID"));
        if (!sid_value ||
            CFGetTypeID(sid_value) != CFNumberGetTypeID() ||
            !CFNumberGetValue(sid_value, kCFNumberSInt64Type, &result[i])) {
            free(result);
            CFRelease(value);
            return false;
        }
    }

    CFRelease(value);
    *order = result;
    *count = space_count;
    return true;
}

static bool managed_space_sip_fallback_order_preserves_snapshot(uint64_t *order,
                                                            int count,
                                                            uint64_t *snapshot,
                                                            int snapshot_count,
                                                            uint64_t excluded_sid)
{
    int order_index = 0;
    for (int i = 0; i < snapshot_count; ++i) {
        uint64_t sid = snapshot[i];
        if (sid == excluded_sid) continue;

        while (order_index < count && order[order_index] != sid) {
            ++order_index;
        }
        if (order_index == count) return false;
        ++order_index;
    }

    return true;
}

static bool managed_space_sip_fallback_persisted_orders_satisfy_request(
    struct managed_space_sip_fallback_request *request,
    uint64_t *target_order,
    int target_count,
    uint64_t *source_order,
    int source_count)
{
    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        return request->created_sid &&
               target_count == request->pre_target_count + 1 &&
               managed_space_sip_fallback_find_sid(target_order,
                                               target_count,
                                               request->created_sid) >= 0 &&
               managed_space_sip_fallback_order_preserves_snapshot(target_order,
                                                               target_count,
                                                               request->pre_target_order,
                                                               request->pre_target_count,
                                                               0);
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        return target_count == request->pre_target_count - 1 &&
               managed_space_sip_fallback_find_sid(target_order, target_count, request->sid) < 0 &&
               managed_space_sip_fallback_order_preserves_snapshot(target_order,
                                                               target_count,
                                                               request->pre_target_order,
                                                               request->pre_target_count,
                                                               request->sid);
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP: {
        if (target_count != request->pre_target_count) return false;

        int desired_index = 0;
        for (int i = 0; i < target_count; ++i) {
            int index = managed_space_sip_fallback_find_sid(request->desired_order,
                                                        request->desired_order_count,
                                                        target_order[i]);
            if (index < 0) continue;
            if (index != desired_index) return false;
            ++desired_index;
        }
        return desired_index == request->desired_order_count;
    }
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        if (request->source_did == request->target_did) {
            return target_count == request->pre_target_count &&
                   managed_space_sip_fallback_find_sid(target_order, target_count, request->sid) >= 0;
        }
        return target_count == request->pre_target_count + 1 &&
               source_count == request->pre_source_count - 1 &&
               managed_space_sip_fallback_find_sid(target_order, target_count, request->sid) >= 0 &&
               managed_space_sip_fallback_find_sid(source_order, source_count, request->sid) < 0 &&
               managed_space_sip_fallback_order_preserves_snapshot(target_order,
                                                               target_count,
                                                               request->pre_target_order,
                                                               request->pre_target_count,
                                                               0) &&
               managed_space_sip_fallback_order_preserves_snapshot(source_order,
                                                               source_count,
                                                               request->pre_source_order,
                                                               request->pre_source_count,
                                                               request->sid);
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        return true;
    }

    return false;
}

static bool managed_space_sip_fallback_persisted_orders_match_current_request(
    struct managed_space_sip_fallback_request *request,
    uint64_t *target_order,
    int target_count,
    uint64_t *source_order,
    int source_count)
{
    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        return request->created_sid &&
               managed_space_sip_fallback_find_sid(target_order,
                                               target_count,
                                               request->created_sid) >= 0;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        return managed_space_sip_fallback_find_sid(target_order,
                                               target_count,
                                               request->sid) < 0;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP: {
        int desired_index = 0;
        for (int i = 0; i < target_count; ++i) {
            int index = managed_space_sip_fallback_find_sid(request->desired_order,
                                                        request->desired_order_count,
                                                        target_order[i]);
            if (index < 0) continue;
            if (index != desired_index) return false;
            ++desired_index;
        }
        return desired_index == request->desired_order_count;
    }
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        return managed_space_sip_fallback_find_sid(target_order,
                                               target_count,
                                               request->sid) >= 0 &&
               (request->source_did == request->target_did ||
                managed_space_sip_fallback_find_sid(source_order,
                                                source_count,
                                                request->sid) < 0);
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        return true;
    }

    return false;
}

static bool managed_space_sip_fallback_observe_persisted_postcondition(
    struct managed_space_sip_fallback *topology)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
    if (request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return false;
    if (!managed_space_sip_fallback_request_is_satisfied(request)) return false;

    uint64_t *target_order = NULL;
    int target_count = 0;
    if (!managed_space_sip_fallback_copy_persisted_display_order(request->target_did,
                                                             &target_order,
                                                             &target_count)) {
        return false;
    }

    uint64_t *source_order = target_order;
    int source_count = target_count;
    if (request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        request->source_did != request->target_did) {
        source_order = NULL;
        source_count = 0;
        if (!managed_space_sip_fallback_copy_persisted_display_order(request->source_did,
                                                                 &source_order,
                                                                 &source_count)) {
            free(target_order);
            return false;
        }
    }

    bool result = request->mutation_started
        ? managed_space_sip_fallback_persisted_orders_satisfy_request(request,
                                                                  target_order,
                                                                  target_count,
                                                                  source_order,
                                                                  source_count)
        : managed_space_sip_fallback_persisted_orders_match_current_request(request,
                                                                        target_order,
                                                                        target_count,
                                                                        source_order,
                                                                        source_count);
    if (source_order != target_order) free(source_order);
    free(target_order);
    request->dock_postcondition_observed = result;
    return result;
}

static int managed_space_sip_fallback_copy_matching_spaces(uint64_t *source,
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

static bool managed_space_sip_fallback_move_order_in_place(uint64_t *order,
                                                       int count,
                                                       uint64_t sid,
                                                       uint64_t target_sid,
                                                       bool *place_after,
                                                       int *final_index)
{
    int source_index = managed_space_sip_fallback_find_sid(order, count, sid);
    int target_index = managed_space_sip_fallback_find_sid(order, count, target_sid);
    if (source_index < 0 || target_index < 0 || source_index == target_index) return false;

    *place_after = source_index < target_index;
    uint64_t moved_sid = order[source_index];
    if (source_index < count - 1) {
        memmove(order + source_index,
                order + source_index + 1,
                sizeof(uint64_t) * (count - source_index - 1));
    }

    target_index = managed_space_sip_fallback_find_sid(order, count - 1, target_sid);
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

static bool managed_space_sip_fallback_swap_order_in_place(uint64_t *order,
                                                       int count,
                                                       uint64_t sid,
                                                       uint64_t target_sid,
                                                       int *target_index)
{
    int source_index = managed_space_sip_fallback_find_sid(order, count, sid);
    *target_index = managed_space_sip_fallback_find_sid(order, count, target_sid);
    if (source_index < 0 || *target_index < 0 || source_index == *target_index) return false;

    uint64_t temp = order[source_index];
    order[source_index] = order[*target_index];
    order[*target_index] = temp;
    return true;
}

static bool managed_space_sip_fallback_build_move_order(struct managed_space_sip_fallback_request *request)
{
    uint32_t did = space_display_id(request->sid);
    if (!did || did != space_display_id(request->target_sid)) return false;

    request->source_did = did;
    request->target_did = did;
    request->desired_order = managed_space_sip_fallback_copy_display_order(did, &request->desired_order_count);
    if (!request->desired_order) return false;

    return managed_space_sip_fallback_move_order_in_place(request->desired_order,
                                                      request->desired_order_count,
                                                      request->sid,
                                                      request->target_sid,
                                                      &request->place_after,
                                                      &request->target_index);
}

static bool managed_space_sip_fallback_build_swap_order(struct managed_space_sip_fallback_request *request)
{
    uint32_t did = space_display_id(request->sid);
    if (!did || did != space_display_id(request->target_sid)) return false;

    request->source_did = did;
    request->target_did = did;
    request->desired_order = managed_space_sip_fallback_copy_display_order(did, &request->desired_order_count);
    if (!request->desired_order) return false;

    return managed_space_sip_fallback_swap_order_in_place(request->desired_order,
                                                      request->desired_order_count,
                                                      request->sid,
                                                      request->target_sid,
                                                      &request->target_index);
}

static bool managed_space_sip_fallback_create_is_blocked(struct managed_space_sip_fallback *topology, uint32_t did)
{
    return topology->space_limit_reached && topology->space_limit_did == did;
}

bool managed_space_sip_fallback_space_limit_reached_for_display(struct managed_space_sip_fallback *topology, uint32_t did)
{
    return managed_space_sip_fallback_create_is_blocked(topology, did);
}

void managed_space_sip_fallback_prepare_request(struct managed_space_sip_fallback *topology,
                                            struct managed_space_sip_fallback_request *request,
                                            enum managed_space_topology_origin origin)
{
    if (request->generation) return;

    request->origin = origin;
    request->generation = ++topology->next_generation;
    request->precondition_hash = managed_space_sip_fallback_snapshot_hash();
    managed_space_sip_fallback_copy_space_uuid(request->sid, request->sid_uuid);
    managed_space_sip_fallback_copy_space_uuid(request->target_sid, request->target_uuid);
}

static void managed_space_sip_fallback_record_immediate_failure(struct managed_space_sip_fallback *topology,
                                                            struct managed_space_sip_fallback_request *request,
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

struct managed_space_topology_result
managed_space_sip_fallback_submit_request(struct managed_space_sip_fallback *topology,
                                      struct managed_space_sip_fallback_request request,
                                      enum managed_space_topology_origin origin)
{
    if (!topology->enabled) {
        managed_space_sip_fallback_discard_request(&request);
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    managed_space_sip_fallback_prepare_request(topology, &request, origin);
    if (request.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE) {
        request.backend = managed_space_sip_fallback_select_backend(topology, request.operation);
    }

    if (request.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE) {
        bool should_restore_order = request.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER ||
                                    request.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP;
        managed_space_sip_fallback_record_immediate_failure(
            topology,
            &request,
            "bridge-operation-unavailable");
        managed_space_sip_fallback_discard_request(&request);
        if (should_restore_order) managed_space_request_reconcile(&g_managed_space);
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    if (request.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY &&
        !AXIsProcessTrusted()) {
        managed_space_sip_fallback_record_immediate_failure(topology,
                                                        &request,
                                                        "accessibility-permission-missing");
        managed_space_sip_fallback_discard_request(&request);
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_ACCESSIBILITY);
    }

    if (request.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE &&
        managed_space_sip_fallback_create_is_blocked(topology, request.target_did)) {
        managed_space_sip_fallback_discard_request(&request);
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_LIMIT_REACHED);
    }

    uint64_t request_generation = request.generation;
    buf_push(topology->queue, request);
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT) {
        topology->active_submission_generation = request_generation;
        managed_space_sip_fallback_start_next(topology);
        topology->active_submission_generation = 0;
    }

    if (topology->last_failed_generation == request_generation) {
        if (topology->last_failed_backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY &&
            string_equals(topology->last_error, "accessibility-permission-missing")) {
            return managed_space_topology_result_provider_error(
                MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_ACCESSIBILITY);
        }
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    return managed_space_topology_result_queued();
}

struct managed_space_topology_result
managed_space_sip_fallback_create(struct managed_space_sip_fallback *topology,
                              enum managed_space_topology_origin origin,
                              uint64_t acting_sid)
{
    uint32_t did = space_display_id(acting_sid);
    if (!did) return managed_space_topology_result_space_error(SPACE_OP_ERROR_MISSING_SRC);

    struct managed_space_sip_fallback_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
        .sid = acting_sid,
        .source_did = did,
        .target_did = did
    };

    return managed_space_sip_fallback_submit_request(topology, request, origin);
}

struct managed_space_topology_result
managed_space_sip_fallback_destroy_space(struct managed_space_sip_fallback *topology,
                                     enum managed_space_topology_origin origin,
                                     uint64_t sid)
{
    struct managed_space_sip_fallback_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
        .sid = sid,
        .source_did = space_display_id(sid),
        .target_did = space_display_id(sid)
    };

    return managed_space_sip_fallback_submit_request(topology, request, origin);
}

bool managed_space_sip_fallback_prepare_move_request(struct managed_space_sip_fallback_request *request, uint64_t sid, uint64_t target_sid)
{
    *request = (struct managed_space_sip_fallback_request) {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER,
        .sid = sid,
        .target_sid = target_sid
    };

    if (!space_is_user(sid) || !space_is_user(target_sid)) return false;
    return managed_space_sip_fallback_build_move_order(request);
}

struct managed_space_topology_result
managed_space_sip_fallback_move_space(struct managed_space_sip_fallback *topology,
                                  enum managed_space_topology_origin origin,
                                  uint64_t sid,
                                  uint64_t target_sid)
{
    if (!space_is_user(sid) || !space_is_user(target_sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }

    struct managed_space_sip_fallback_request request;
    if (!managed_space_sip_fallback_prepare_move_request(&request, sid, target_sid)) {
        managed_space_sip_fallback_discard_request(&request);
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_DST);
    }

    return managed_space_sip_fallback_submit_request(topology, request, origin);
}

bool managed_space_sip_fallback_prepare_swap_request(struct managed_space_sip_fallback_request *request, uint64_t sid, uint64_t target_sid)
{
    *request = (struct managed_space_sip_fallback_request) {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP,
        .sid = sid,
        .target_sid = target_sid
    };

    if (!space_is_user(sid) || !space_is_user(target_sid)) return false;
    return managed_space_sip_fallback_build_swap_order(request);
}

struct managed_space_topology_result
managed_space_sip_fallback_swap_spaces(struct managed_space_sip_fallback *topology,
                                   enum managed_space_topology_origin origin,
                                   uint64_t sid,
                                   uint64_t target_sid)
{
    if (!space_is_user(sid) || !space_is_user(target_sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }

    struct managed_space_sip_fallback_request request;
    if (!managed_space_sip_fallback_prepare_swap_request(&request, sid, target_sid)) {
        managed_space_sip_fallback_discard_request(&request);
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_DST);
    }

    return managed_space_sip_fallback_submit_request(topology, request, origin);
}

struct managed_space_topology_result
managed_space_sip_fallback_move_space_to_display(struct managed_space_sip_fallback *topology,
                                             enum managed_space_topology_origin origin,
                                             uint64_t sid,
                                             uint32_t did,
                                             bool placeholder_required)
{
    if (!space_is_user(sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }

    struct managed_space_sip_fallback_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY,
        .sid = sid,
        .source_did = space_display_id(sid),
        .target_did = did,
        .focus_space = sid == space_manager_active_space(),
        .placeholder_required = placeholder_required
    };

    return managed_space_sip_fallback_submit_request(topology, request, origin);
}

static bool managed_space_sip_fallback_execute_bridge(struct managed_space_sip_fallback *topology)
{
    struct managed_space_sip_fallback_request *request = &topology->current;

    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE: {
        Class create_class = objc_getClass("SLSBridgedSpaceCreateOperation");
        if (!create_class || !managed_space_sip_fallback_synchronous_bridge) return false;

        NSString *uuid = [[NSUUID UUID] UUIDString];
        NSDictionary *values = @{ @"type": @0, @"uuid": uuid };
        SEL selector = sel_registerName("initWithOptions:values:");
        id operation = ((id (*)(id, SEL, uint32_t, id)) objc_msgSend)([create_class alloc],
                                                                      selector,
                                                                      0,
                                                                      values);
        if (!operation) return false;

        id result = managed_space_sip_fallback_synchronous_bridge(operation);
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

        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
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
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT;
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
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
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
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    } break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        return false;
    }

    managed_space_sip_fallback_schedule_watchdog(topology);
    return true;
}

static AXUIElementRef managed_space_sip_fallback_copy_ax_child(AXUIElementRef parent, CFStringRef identifier)
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

static bool managed_space_sip_fallback_ax_display_value_matches(CFTypeRef value, uint32_t did)
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

static bool managed_space_sip_fallback_ax_display_matches(AXUIElementRef element, uint32_t did)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXDisplayID"), &value) != kAXErrorSuccess || !value) {
        return false;
    }

    bool result = managed_space_sip_fallback_ax_display_value_matches(value, did);
    CFRelease(value);
    return result;
}

static AXUIElementRef managed_space_sip_fallback_copy_ax_display(AXUIElementRef mission_control, uint32_t did)
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

        if (is_display && managed_space_sip_fallback_ax_display_matches(child, did)) {
            result = CFRetain(child);
            break;
        }
    }

    CFRelease(children);
    return result;
}

static AXUIElementRef managed_space_sip_fallback_copy_ax_spaces_group(AXUIElementRef mission_control, uint32_t did)
{
    AXUIElementRef display = managed_space_sip_fallback_copy_ax_display(mission_control, did);
    if (!display) return NULL;

    AXUIElementRef spaces = managed_space_sip_fallback_copy_ax_child(display, CFSTR("mc.spaces"));
    CFRelease(display);
    return spaces;
}

static AXUIElementRef managed_space_sip_fallback_copy_mission_control(pid_t *dock_pid)
{
    NSArray *dock_applications = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    NSRunningApplication *dock = [dock_applications firstObject];
    if (!dock) return NULL;

    *dock_pid = dock.processIdentifier;
    AXUIElementRef dock_element = AXUIElementCreateApplication(*dock_pid);
    if (!dock_element) return NULL;

    AXUIElementRef mission_control = managed_space_sip_fallback_copy_ax_child(dock_element, CFSTR("mc"));
    CFRelease(dock_element);
    return mission_control;
}

static bool managed_space_sip_fallback_mission_control_ui_exists(void)
{
    pid_t dock_pid = 0;
    AXUIElementRef mission_control = managed_space_sip_fallback_copy_mission_control(&dock_pid);
    if (!mission_control) return false;

    CFRelease(mission_control);
    return true;
}

static enum managed_space_sip_fallback_state managed_space_sip_fallback_accessibility_session_state(bool mission_control_active,
                                                                                             bool owns_mission_control)
{
    if (!mission_control_active) return MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL;
    return owns_mission_control
        ? MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY
        : MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_USER_MISSION_CONTROL;
}

static void managed_space_sip_fallback_ax_notification(AXObserverRef observer,
                                                   AXUIElementRef element,
                                                   CFStringRef notification,
                                                   void *context)
{
    (void) observer;
    (void) element;
    (void) notification;

    struct managed_space_sip_fallback *topology = context;
    if (!topology) return;
    if (topology->current.backend != MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY) return;
    if (topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY &&
        topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT &&
        topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE) {
        return;
    }

    managed_space_sip_fallback_schedule_step(topology, 0.08);
}

static void managed_space_sip_fallback_observe_mission_control(struct managed_space_sip_fallback *topology,
                                                           pid_t dock_pid,
                                                           AXUIElementRef mission_control)
{
    if (topology->ax_observer && topology->observed_dock_pid == dock_pid) return;
    managed_space_sip_fallback_stop_ax_observer(topology);

    AXObserverRef observer = NULL;
    if (AXObserverCreate(dock_pid, managed_space_sip_fallback_ax_notification, &observer) != kAXErrorSuccess ||
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

static AXUIElementRef managed_space_sip_fallback_copy_ax_list_child(AXUIElementRef list, int index)
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

static AXUIElementRef managed_space_sip_fallback_copy_ax_spaces_list(AXUIElementRef mission_control,
                                                                 uint32_t did)
{
    AXUIElementRef spaces = managed_space_sip_fallback_copy_ax_spaces_group(mission_control, did);
    if (!spaces) return NULL;

    AXUIElementRef list = managed_space_sip_fallback_copy_ax_child(spaces, CFSTR("mc.spaces.list"));
    CFRelease(spaces);
    return list;
}

static bool managed_space_sip_fallback_ax_list_count(AXUIElementRef list, int *count)
{
    *count = 0;
    if (!list) return false;

    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(list, kAXChildrenAttribute, &value) != kAXErrorSuccess ||
        !value ||
        CFGetTypeID(value) != CFArrayGetTypeID()) {
        if (value) CFRelease(value);
        return false;
    }

    *count = (int) CFArrayGetCount(value);
    CFRelease(value);
    return true;
}

static bool managed_space_sip_fallback_ax_space_count(AXUIElementRef mission_control,
                                                   uint32_t did,
                                                   int *count)
{
    AXUIElementRef list = managed_space_sip_fallback_copy_ax_spaces_list(mission_control, did);
    if (!list) return false;

    bool result = managed_space_sip_fallback_ax_list_count(list, count);
    CFRelease(list);
    return result;
}

static bool managed_space_sip_fallback_ax_frame(AXUIElementRef element, CGRect *frame)
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

static void managed_space_sip_fallback_post_mouse_event(CGEventType type, CGPoint point)
{
    CGMouseButton button = kCGMouseButtonLeft;
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, button);
    if (!event) return;

    CGEventSetIntegerValueField(event, kCGEventSourceUserData, MANAGED_SPACE_TOPOLOGY_MOUSE_EVENT_TAG);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static bool managed_space_sip_fallback_visible_intersection(CGRect frame,
                                                        CGRect display_frame,
                                                        CGRect *visible_frame)
{
    CGRect intersection = CGRectIntersection(frame, display_frame);
    if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) return false;
    if (visible_frame) *visible_frame = intersection;
    return true;
}

static CGPoint managed_space_sip_fallback_current_mouse_location(CGPoint fallback)
{
    CGEventRef current_event = CGEventCreate(NULL);
    CGPoint original = current_event ? CGEventGetLocation(current_event) : fallback;
    if (current_event) CFRelease(current_event);
    return original;
}

static void managed_space_sip_fallback_drag_segment(CGPoint source,
                                                CGPoint destination,
                                                int step_count)
{
    for (int i = 1; i <= step_count; ++i) {
        double progress = (double) i / step_count;
        CGPoint point = {
            .x = source.x + (destination.x - source.x) * progress,
            .y = source.y + (destination.y - source.y) * progress
        };
        managed_space_sip_fallback_post_mouse_event(kCGEventLeftMouseDragged, point);
        usleep(MANAGED_SPACE_TOPOLOGY_DRAG_STEP_DELAY_US);
    }
}

static void managed_space_sip_fallback_begin_drag(CGPoint source)
{
    managed_space_sip_fallback_post_mouse_event(kCGEventMouseMoved, source);
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_INITIAL_DELAY_US);
    managed_space_sip_fallback_post_mouse_event(kCGEventLeftMouseDown, source);
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_HOLD_DELAY_US);
}

static void managed_space_sip_fallback_end_drag(CGPoint destination, CGPoint original)
{
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_DROP_DELAY_US);
    managed_space_sip_fallback_post_mouse_event(kCGEventLeftMouseUp, destination);
    usleep(MANAGED_SPACE_TOPOLOGY_DRAG_RELEASE_DELAY_US);
    managed_space_sip_fallback_post_mouse_event(kCGEventMouseMoved, original);
}

static void managed_space_sip_fallback_drag(CGPoint source, CGPoint destination)
{
    CGPoint original = managed_space_sip_fallback_current_mouse_location(source);
    managed_space_sip_fallback_begin_drag(source);
    managed_space_sip_fallback_drag_segment(source, destination, 12);
    managed_space_sip_fallback_end_drag(destination, original);
}

static bool managed_space_sip_fallback_drag_to_ax_target(CGPoint source,
                                                     CGPoint target_hover,
                                                     AXUIElementRef target,
                                                     CGRect target_display_frame,
                                                     CGRect *destination_frame)
{
    CGPoint original = managed_space_sip_fallback_current_mouse_location(source);
    managed_space_sip_fallback_begin_drag(source);
    managed_space_sip_fallback_drag_segment(source, target_hover, 12);
    usleep((useconds_t) (MANAGED_SPACE_TOPOLOGY_SPACES_BAR_DELAY_SECONDS * 1000000.0));

    CGRect refreshed_frame;
    bool target_visible = managed_space_sip_fallback_ax_frame(target, &refreshed_frame) &&
                          managed_space_sip_fallback_visible_intersection(refreshed_frame,
                                                                     target_display_frame,
                                                                     NULL);
    if (!target_visible) {
        managed_space_sip_fallback_drag_segment(target_hover, source, 12);
        managed_space_sip_fallback_end_drag(source, original);
        return false;
    }

    CGPoint destination = {
        CGRectGetMidX(refreshed_frame),
        CGRectGetMidY(refreshed_frame)
    };
    managed_space_sip_fallback_drag_segment(target_hover, destination, 6);
    managed_space_sip_fallback_end_drag(destination, original);
    if (destination_frame) *destination_frame = refreshed_frame;
    return true;
}

static enum managed_space_sip_fallback_ax_result
managed_space_sip_fallback_capture_ax_precondition(struct managed_space_sip_fallback *topology,
                                               AXUIElementRef mission_control)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
    if (request->ax_precondition_observed) return MANAGED_SPACE_TOPOLOGY_AX_STARTED;

    int target_ax_count = 0;
    if (!managed_space_sip_fallback_ax_space_count(mission_control,
                                               request->target_did,
                                               &target_ax_count)) {
        return MANAGED_SPACE_TOPOLOGY_AX_WAITING;
    }

    int target_sls_count = display_space_count(request->target_did);
    topology->authority_did = request->target_did;
    topology->authority_sls_count = target_sls_count;
    topology->authority_ax_count = target_ax_count;
    topology->authority_observed = true;
    topology->authority_consistent = target_sls_count == request->pre_target_count &&
                                     target_ax_count == target_sls_count;
    if (target_sls_count != request->pre_target_count ||
        target_ax_count != target_sls_count) {
        debug("managed_space_sip_fallback_capture_ax_precondition: display %u "
              "snapshot=%d sls=%d ax=%d\n",
              request->target_did,
              request->pre_target_count,
              target_sls_count,
              target_ax_count);
        snprintf(topology->operation_error,
                 sizeof(topology->operation_error),
                 "%s",
                 "topology-authority-diverged");
        return MANAGED_SPACE_TOPOLOGY_AX_FAILED;
    }

    request->ax_target_count_before = target_ax_count;

    if (request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        request->source_did != request->target_did) {
        int source_ax_count = 0;
        if (!managed_space_sip_fallback_ax_space_count(mission_control,
                                                   request->source_did,
                                                   &source_ax_count)) {
            return MANAGED_SPACE_TOPOLOGY_AX_WAITING;
        }

        int source_sls_count = display_space_count(request->source_did);
        topology->authority_did = request->source_did;
        topology->authority_sls_count = source_sls_count;
        topology->authority_ax_count = source_ax_count;
        topology->authority_observed = true;
        topology->authority_consistent = source_sls_count == request->pre_source_count &&
                                         source_ax_count == source_sls_count;
        if (source_sls_count != request->pre_source_count ||
            source_ax_count != source_sls_count) {
            debug("managed_space_sip_fallback_capture_ax_precondition: display %u "
                  "snapshot=%d sls=%d ax=%d\n",
                  request->source_did,
                  request->pre_source_count,
                  source_sls_count,
                  source_ax_count);
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "topology-authority-diverged");
            return MANAGED_SPACE_TOPOLOGY_AX_FAILED;
        }

        request->ax_source_count_before = source_ax_count;
    } else {
        request->ax_source_count_before = target_ax_count;
    }

    request->ax_precondition_observed = true;
    return MANAGED_SPACE_TOPOLOGY_AX_STARTED;
}

static void managed_space_sip_fallback_resolve_created_sid(struct managed_space_sip_fallback_request *request)
{
    if (request->created_sid || request->operation != MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE) return;

    int current_count = 0;
    uint64_t *current_order = display_space_list(request->target_did, &current_count);
    uint64_t candidate_sid = 0;
    for (int i = 0; current_order && i < current_count; ++i) {
        uint64_t sid = current_order[i];
        if (!space_is_user(sid)) continue;
        if (managed_space_sip_fallback_snapshot_contains(request->pre_target_order,
                                                     request->pre_target_count,
                                                     sid)) {
            continue;
        }
        if (candidate_sid) return;
        candidate_sid = sid;
    }

    request->created_sid = candidate_sid;
}

static bool managed_space_sip_fallback_observe_ax_postcondition(struct managed_space_sip_fallback *topology,
                                                            AXUIElementRef mission_control)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
    if (!request->ax_precondition_observed) return false;

    managed_space_sip_fallback_resolve_created_sid(request);
    if (!managed_space_sip_fallback_request_is_satisfied(request)) return false;

    int target_ax_count = 0;
    if (!managed_space_sip_fallback_ax_space_count(mission_control,
                                               request->target_did,
                                               &target_ax_count)) {
        return false;
    }
    int target_sls_count = display_space_count(request->target_did);

    int expected_target_count = request->ax_target_count_before;
    switch (request->operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        ++expected_target_count;
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        --expected_target_count;
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        if (request->source_did != request->target_did) ++expected_target_count;
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        break;
    }

    if (target_ax_count != expected_target_count ||
        target_sls_count != expected_target_count) {
        return false;
    }

    if (request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        request->source_did != request->target_did) {
        int source_ax_count = 0;
        int expected_source_count = request->ax_source_count_before - 1;
        if (!managed_space_sip_fallback_ax_space_count(mission_control,
                                                   request->source_did,
                                                   &source_ax_count) ||
            source_ax_count != expected_source_count ||
            display_space_count(request->source_did) != expected_source_count) {
            return false;
        }
    }

    topology->authority_did = request->target_did;
    topology->authority_sls_count = target_sls_count;
    topology->authority_ax_count = target_ax_count;
    topology->authority_observed = true;
    topology->authority_consistent = true;
    request->ax_postcondition_observed = true;
    return true;
}

static bool managed_space_sip_fallback_request_postcondition_satisfied(struct managed_space_sip_fallback *topology)
{
    if (!managed_space_sip_fallback_request_is_satisfied(&topology->current)) return false;
    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY) {
        return topology->current.ax_postcondition_observed ||
               topology->current.dock_postcondition_observed;
    }
    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE) {
        return topology->current.dock_postcondition_observed;
    }
    return true;
}

static bool managed_space_sip_fallback_ax_create(struct managed_space_sip_fallback *topology, AXUIElementRef mission_control)
{
    AXUIElementRef spaces = managed_space_sip_fallback_copy_ax_spaces_group(mission_control, topology->current.target_did);
    if (!spaces) return false;

    AXUIElementRef add = managed_space_sip_fallback_copy_ax_child(spaces, CFSTR("mc.spaces.add"));
    CFRelease(spaces);
    int space_count = topology->current.ax_target_count_before;
    if (!add) {
        if (space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            managed_space_sip_fallback_record_space_limit(topology,
                                                      topology->current.target_did,
                                                      space_count);
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "space-limit-reached");
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
            managed_space_sip_fallback_record_space_limit(topology,
                                                      topology->current.target_did,
                                                      space_count);
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "space-limit-reached");
        }
        return false;
    }

    topology->current.mutation_started = true;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT;
    return true;
}

static bool managed_space_sip_fallback_ax_destroy(struct managed_space_sip_fallback *topology, AXUIElementRef mission_control)
{
    uint32_t did = space_display_id(topology->current.sid);
    int count = 0;
    uint64_t *space_list = display_space_list(did, &count);
    int index = managed_space_sip_fallback_find_sid(space_list, count, topology->current.sid);
    if (index < 0) return false;

    AXUIElementRef spaces = managed_space_sip_fallback_copy_ax_spaces_group(mission_control, did);
    if (!spaces) return false;

    AXUIElementRef list = managed_space_sip_fallback_copy_ax_child(spaces, CFSTR("mc.spaces.list"));
    CFRelease(spaces);
    if (!list) return false;

    AXUIElementRef child = managed_space_sip_fallback_copy_ax_list_child(list, index);
    CFRelease(list);
    if (!child) return false;

    AXError result = AXUIElementPerformAction(child, CFSTR("AXRemoveDesktop"));
    CFRelease(child);
    if (result != kAXErrorSuccess) return false;

    topology->current.mutation_started = true;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT;
    return true;
}

static bool managed_space_sip_fallback_ax_reorder(struct managed_space_sip_fallback *topology, AXUIElementRef mission_control)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
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
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, 0);
        return true;
    }

    int source_index = managed_space_sip_fallback_find_sid(space_list, space_count, request->desired_order[mismatch_index]);
    if (source_index < 0 || source_index == target_index) return false;
    if (++request->phase > request->desired_order_count + 1) return false;

    AXUIElementRef spaces = managed_space_sip_fallback_copy_ax_spaces_group(mission_control, did);
    if (!spaces) return false;
    CGRect spaces_frame;
    bool have_spaces_frame = managed_space_sip_fallback_ax_frame(spaces, &spaces_frame);
    AXUIElementRef list = managed_space_sip_fallback_copy_ax_child(spaces, CFSTR("mc.spaces.list"));
    CFRelease(spaces);
    if (!list) return false;

    AXUIElementRef source = managed_space_sip_fallback_copy_ax_list_child(list, source_index);
    AXUIElementRef target = managed_space_sip_fallback_copy_ax_list_child(list, target_index);
    CFRelease(list);
    if (!source || !target) {
        if (source) CFRelease(source);
        if (target) CFRelease(target);
        return false;
    }

    CGRect source_frame;
    CGRect target_frame;
    bool have_frames = managed_space_sip_fallback_ax_frame(source, &source_frame) &&
                       managed_space_sip_fallback_ax_frame(target, &target_frame);
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

        CGRect visible_spaces;
        if (!have_spaces_frame ||
            !managed_space_sip_fallback_visible_intersection(spaces_frame,
                                                         display_frame,
                                                         &visible_spaces)) {
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-spaces-group-unavailable");
            return false;
        }

        CGPoint hover_point = {
            CGRectGetMidX(visible_spaces),
            CGRectGetMinY(visible_spaces) + CGRectGetHeight(visible_spaces) * 0.05
        };
        request->ax_spaces_bar_hovered = true;
        managed_space_sip_fallback_post_mouse_event(kCGEventMouseMoved, hover_point);
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology,
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

    debug("managed_space_sip_fallback_ax_reorder: dragging space %llu from child %d "
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

    managed_space_sip_fallback_drag(source_point, target_point);
    request->mutation_started = true;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
    managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    managed_space_sip_fallback_schedule_watchdog(topology);
    return true;
}

static bool managed_space_sip_fallback_ax_move_display(struct managed_space_sip_fallback *topology, AXUIElementRef mission_control)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
    if (space_display_id(request->sid) == request->target_did) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, 0);
        return true;
    }

    uint32_t source_did = space_display_id(request->sid);
    int source_count = 0;
    uint64_t *source_space_list = display_space_list(source_did, &source_count);
    int source_index = managed_space_sip_fallback_find_sid(source_space_list, source_count, request->sid);
    if (source_index < 0) return false;

    AXUIElementRef source_spaces = managed_space_sip_fallback_copy_ax_spaces_group(mission_control, source_did);
    AXUIElementRef target_spaces = managed_space_sip_fallback_copy_ax_spaces_group(mission_control, request->target_did);
    if (!source_spaces || !target_spaces) {
        if (source_spaces) CFRelease(source_spaces);
        if (target_spaces) CFRelease(target_spaces);
        return false;
    }

    CGRect source_spaces_frame;
    CGRect target_spaces_frame;
    bool have_spaces_frames =
        managed_space_sip_fallback_ax_frame(source_spaces, &source_spaces_frame) &&
        managed_space_sip_fallback_ax_frame(target_spaces, &target_spaces_frame);
    AXUIElementRef source_list = managed_space_sip_fallback_copy_ax_child(source_spaces, CFSTR("mc.spaces.list"));
    AXUIElementRef target_list = managed_space_sip_fallback_copy_ax_child(target_spaces, CFSTR("mc.spaces.list"));
    CFRelease(source_spaces);
    CFRelease(target_spaces);
    if (!source_list || !target_list) {
        if (source_list) CFRelease(source_list);
        if (target_list) CFRelease(target_list);
        return false;
    }

    AXUIElementRef source = managed_space_sip_fallback_copy_ax_list_child(source_list, source_index);
    CFRelease(source_list);
    if (!source) {
        CFRelease(target_list);
        return false;
    }

    int target_count = 0;
    uint64_t *target_space_list = display_space_list(request->target_did, &target_count);
    int target_index = -1;
    for (int i = target_count - 1; i >= 0; --i) {
        if (!space_is_user(target_space_list[i])) continue;
        target_index = i;
        break;
    }
    AXUIElementRef target = target_index >= 0
        ? managed_space_sip_fallback_copy_ax_list_child(target_list, target_index)
        : NULL;
    CFRelease(target_list);
    if (!target) {
        CFRelease(source);
        return false;
    }

    CGRect source_frame;
    CGRect target_frame;
    bool have_frames = managed_space_sip_fallback_ax_frame(source, &source_frame) &&
                       managed_space_sip_fallback_ax_frame(target, &target_frame);
    CFRelease(source);
    if (!have_frames) {
        CFRelease(target);
        return false;
    }

    CGRect source_display_frame = CGDisplayBounds(source_did);
    if (!managed_space_sip_fallback_visible_intersection(source_frame,
                                                     source_display_frame,
                                                     NULL)) {
        if (request->ax_spaces_bar_hovered) {
            debug("managed_space_sip_fallback_ax_move_display: source space %llu frame "
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
            CFRelease(target);
            return false;
        }

        CGRect visible_source_spaces;
        if (!have_spaces_frames ||
            !managed_space_sip_fallback_visible_intersection(source_spaces_frame,
                                                         source_display_frame,
                                                         &visible_source_spaces)) {
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-source-spaces-group-unavailable");
            CFRelease(target);
            return false;
        }

        CGPoint hover_point = {
            CGRectGetMidX(visible_source_spaces),
            CGRectGetMinY(visible_source_spaces) + CGRectGetHeight(visible_source_spaces) * 0.05
        };
        request->ax_spaces_bar_hovered = true;
        managed_space_sip_fallback_post_mouse_event(kCGEventMouseMoved, hover_point);
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_SPACES_BAR_DELAY_SECONDS);
        CFRelease(target);
        return true;
    }

    if (request->mutation_started) {
        CFRelease(target);
        return false;
    }

    CGRect target_display_frame = CGDisplayBounds(request->target_did);
    bool target_frame_visible = managed_space_sip_fallback_visible_intersection(target_frame,
                                                                            target_display_frame,
                                                                            NULL);
    CGPoint source_point = { CGRectGetMidX(source_frame), CGRectGetMidY(source_frame) };
    CGPoint target_point = { CGRectGetMidX(target_frame), CGRectGetMidY(target_frame) };
    debug("managed_space_sip_fallback_ax_move_display: dragging space %llu from display %u "
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

    bool dragged = target_frame_visible;
    if (target_frame_visible) {
        managed_space_sip_fallback_drag(source_point, target_point);
    } else {
        CGRect visible_target_spaces;
        if (!have_spaces_frames ||
            !managed_space_sip_fallback_visible_intersection(target_spaces_frame,
                                                         target_display_frame,
                                                         &visible_target_spaces)) {
            snprintf(topology->operation_error,
                     sizeof(topology->operation_error),
                     "%s",
                     "accessibility-target-spaces-group-unavailable");
        } else {
            CGPoint target_hover = {
                fmin(fmax(CGRectGetMidX(target_frame), CGRectGetMinX(visible_target_spaces)),
                     CGRectGetMaxX(visible_target_spaces)),
                CGRectGetMinY(visible_target_spaces) +
                    CGRectGetHeight(visible_target_spaces) * 0.05
            };
            CGRect refreshed_target_frame;
            dragged = managed_space_sip_fallback_drag_to_ax_target(source_point,
                                                                target_hover,
                                                                target,
                                                                target_display_frame,
                                                                &refreshed_target_frame);
            if (dragged) {
                debug("managed_space_sip_fallback_ax_move_display: destination expanded "
                      "to (%.1f, %.1f, %.1f, %.1f)\n",
                      refreshed_target_frame.origin.x,
                      refreshed_target_frame.origin.y,
                      refreshed_target_frame.size.width,
                      refreshed_target_frame.size.height);
            } else {
                snprintf(topology->operation_error,
                         sizeof(topology->operation_error),
                         "%s",
                         "accessibility-target-spaces-bar-unavailable");
            }
        }
    }
    CFRelease(target);
    if (!dragged) return false;

    request->mutation_started = true;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
    managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    managed_space_sip_fallback_schedule_watchdog(topology);
    return true;
}

static enum managed_space_sip_fallback_ax_result
managed_space_sip_fallback_execute_accessibility(struct managed_space_sip_fallback *topology)
{
    if (!topology->current.mutation_started &&
        managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
        if (managed_space_sip_fallback_observe_persisted_postcondition(topology)) {
            return MANAGED_SPACE_TOPOLOGY_AX_STARTED;
        }
        if (!topology->current.readiness_retry_scheduled) {
            topology->current.readiness_retry_scheduled = true;
            managed_space_sip_fallback_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
        }
        return MANAGED_SPACE_TOPOLOGY_AX_WAITING;
    }

    if (!topology->current.mutation_started &&
        topology->current.precondition_hash != managed_space_sip_fallback_snapshot_hash()) {
        snprintf(topology->operation_error,
                 sizeof(topology->operation_error),
                 "%s",
                 "stale-topology");
        return MANAGED_SPACE_TOPOLOGY_AX_FAILED;
    }

    pid_t dock_pid = 0;
    AXUIElementRef mission_control = managed_space_sip_fallback_copy_mission_control(&dock_pid);
    if (!mission_control) {
        if (!topology->current.readiness_retry_scheduled) {
            topology->current.readiness_retry_scheduled = true;
            managed_space_sip_fallback_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
        }
        return MANAGED_SPACE_TOPOLOGY_AX_WAITING;
    }
    managed_space_sip_fallback_observe_mission_control(topology, dock_pid, mission_control);

    enum managed_space_sip_fallback_ax_result precondition_result =
        managed_space_sip_fallback_capture_ax_precondition(topology, mission_control);
    if (precondition_result != MANAGED_SPACE_TOPOLOGY_AX_STARTED) {
        CFRelease(mission_control);
        if (precondition_result == MANAGED_SPACE_TOPOLOGY_AX_WAITING &&
            !topology->current.readiness_retry_scheduled) {
            topology->current.readiness_retry_scheduled = true;
            managed_space_sip_fallback_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
        }
        return precondition_result;
    }

    if (managed_space_sip_fallback_observe_ax_postcondition(topology, mission_control)) {
        CFRelease(mission_control);
        return MANAGED_SPACE_TOPOLOGY_AX_STARTED;
    }

    if (topology->current.mutation_started &&
        topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER &&
        topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP) {
        CFRelease(mission_control);
        return MANAGED_SPACE_TOPOLOGY_AX_WAITING;
    }

    bool result = false;
    switch (topology->current.operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:
        result = managed_space_sip_fallback_ax_create(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:
        result = managed_space_sip_fallback_ax_destroy(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:
        result = managed_space_sip_fallback_ax_reorder(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY:
        result = managed_space_sip_fallback_ax_move_display(topology, mission_control);
        break;
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:
        break;
    }

    CFRelease(mission_control);
    if (result) return MANAGED_SPACE_TOPOLOGY_AX_STARTED;
    if (topology->operation_error[0]) return MANAGED_SPACE_TOPOLOGY_AX_FAILED;

    if (!topology->current.readiness_retry_scheduled) {
        topology->current.readiness_retry_scheduled = true;
        managed_space_sip_fallback_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    }
    return MANAGED_SPACE_TOPOLOGY_AX_WAITING;
}

static uint64_t managed_space_sip_fallback_other_user_space(uint32_t did, uint64_t sid)
{
    int count = 0;
    uint64_t *space_list = display_space_list(did, &count);

    for (int i = 0; i < count; ++i) {
        uint64_t candidate_sid = space_list[i];
        if (candidate_sid != sid && space_is_user(candidate_sid)) return candidate_sid;
    }

    return 0;
}

static bool managed_space_sip_fallback_ax_activate_space(uint64_t sid)
{
    uint32_t did = space_display_id(sid);
    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    int index = managed_space_sip_fallback_find_sid(space_list, space_count, sid);
    if (!did || index < 0) return false;

    pid_t dock_pid = 0;
    AXUIElementRef mission_control = managed_space_sip_fallback_copy_mission_control(&dock_pid);
    if (!mission_control) return false;

    AXUIElementRef list = managed_space_sip_fallback_copy_ax_spaces_list(mission_control, did);
    CFRelease(mission_control);
    if (!list) return false;

    int ax_count = 0;
    bool count_matches = managed_space_sip_fallback_ax_list_count(list, &ax_count) &&
                         ax_count == space_count;
    AXUIElementRef child = count_matches
        ? managed_space_sip_fallback_copy_ax_list_child(list, index)
        : NULL;
    CFRelease(list);
    if (!child) return false;

    AXError result = AXUIElementPerformAction(child, kAXPressAction);
    CFRelease(child);
    debug("managed_space_sip_fallback_ax_activate_space: activating space %llu on "
          "display %u through AXPress returned %d\n",
          sid,
          did,
          result);
    return result == kAXErrorSuccess;
}

static void managed_space_sip_fallback_start_accessibility(struct managed_space_sip_fallback *topology)
{
    if (!topology->current.mutation_started &&
        managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, 0);
        managed_space_sip_fallback_schedule_watchdog(topology);
        return;
    }

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY &&
        topology->current.phase == 0 &&
        display_space_id(topology->current.target_did) == topology->current.sid) {
        uint64_t active_sid = space_manager_active_space();
        if (active_sid != topology->current.sid) {
            topology->current.restore_focus_sid = active_sid;
        }

        if (topology->owns_mission_control &&
            (mission_control_is_active() || managed_space_sip_fallback_mission_control_ui_exists())) {
            managed_space_sip_fallback_schedule_owned_mission_control_deactivation(topology);
            return;
        }

        uint64_t focus_sid = managed_space_sip_fallback_other_user_space(topology->current.target_did,
                                                                     topology->current.sid);
        enum space_op_error result = focus_sid
            ? space_manager_focus_space(focus_sid)
            : SPACE_OP_ERROR_MISSING_DST;
        debug("managed_space_sip_fallback_start_accessibility: focusing %llu before "
              "destroying active space %llu returned %d\n",
              focus_sid,
              topology->current.sid,
              result);
        if ((result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING ||
             result == SPACE_OP_ERROR_IN_MISSION_CONTROL) &&
            !topology->current.readiness_retry_scheduled) {
            topology->current.readiness_retry_scheduled = true;
            topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
            managed_space_sip_fallback_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
            managed_space_sip_fallback_schedule_watchdog(topology);
            return;
        }
        if (result != SPACE_OP_ERROR_SUCCESS && result != SPACE_OP_ERROR_SAME_SPACE) {
            if (managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
                topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
                managed_space_sip_fallback_schedule_step(topology, 0);
                managed_space_sip_fallback_schedule_watchdog(topology);
                return;
            }
            managed_space_sip_fallback_fail_current(topology,
                                                "could-not-deactivate-destroy-target");
            return;
        }

        topology->current.phase = 1;
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY;
        managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
        managed_space_sip_fallback_schedule_watchdog(topology);
        return;
    }

    bool mission_control_active = mission_control_is_active() ||
                                  managed_space_sip_fallback_mission_control_ui_exists();
    if (mission_control_active) {
        topology->state = managed_space_sip_fallback_accessibility_session_state(true,
                                                                              topology->owns_mission_control);
        if (!topology->owns_mission_control) {
            return;
        }

        managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
        managed_space_sip_fallback_schedule_watchdog(topology);
        return;
    }

    if (!managed_space_sip_fallback_start_input_event_tap(topology)) {
        managed_space_sip_fallback_fail_current(topology, "input-event-tap-unavailable");
        return;
    }

    topology->owns_mission_control = true;
    topology->state = managed_space_sip_fallback_accessibility_session_state(false, true);
    CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
    managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
    managed_space_sip_fallback_schedule_watchdog(topology);
}

static void managed_space_sip_fallback_begin_current(struct managed_space_sip_fallback *topology)
{
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        topology->current.placeholder_required &&
        space_manager_is_space_last_user_space(topology->current.sid)) {
        managed_space_sip_fallback_fail_current(topology, "placeholder-create-failed");
        return;
    }

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY &&
        topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY) {
        uint32_t source_did = space_display_id(topology->current.sid);
        bool source_is_active = display_space_id(source_did) == topology->current.sid;
        debug("managed_space_sip_fallback_begin_current: move-display generation=%llu "
              "phase=%d sid=%llu source=%u current=%llu global=%llu "
              "focus=%d placeholder=%d\n",
              topology->current.generation,
              topology->current.phase,
              topology->current.sid,
              source_did,
              display_space_id(source_did),
              space_manager_active_space(),
              topology->current.focus_space,
              topology->current.placeholder_required);

        if (topology->current.phase == 0 && source_is_active) {
            if (topology->owns_mission_control &&
                (mission_control_is_active() || managed_space_sip_fallback_mission_control_ui_exists())) {
                topology->current.restore_focus_sid = space_manager_active_space();
                managed_space_sip_fallback_schedule_owned_mission_control_deactivation(topology);
                return;
            }

            uint64_t focus_sid = managed_space_sip_fallback_other_user_space(source_did,
                                                                         topology->current.sid);
            if (!focus_sid) {
                managed_space_sip_fallback_fail_current(topology, "could-not-deactivate-move-source");
                return;
            }

            topology->current.restore_focus_sid = space_manager_active_space();
            enum space_op_error result = space_manager_focus_space(focus_sid);
            debug("managed_space_sip_fallback_begin_current: deactivating move source "
                  "%llu through %llu returned %d\n",
                  topology->current.sid,
                  focus_sid,
                  result);
            if (result != SPACE_OP_ERROR_SUCCESS && result != SPACE_OP_ERROR_SAME_SPACE) {
                managed_space_sip_fallback_fail_current(topology, "could-not-deactivate-move-source");
                return;
            }

            topology->current.phase = 1;
            topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
            managed_space_sip_fallback_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
            managed_space_sip_fallback_schedule_watchdog(topology);
            return;
        }

        if (topology->current.phase == 1) {
            if (source_is_active) {
                managed_space_sip_fallback_fail_current(topology, "could-not-deactivate-move-source");
                return;
            }

            uint64_t restore_sid = topology->current.restore_focus_sid;
            if (!topology->current.focus_space &&
                restore_sid &&
                restore_sid != space_manager_active_space()) {
                enum space_op_error result = space_manager_focus_space(restore_sid);
                debug("managed_space_sip_fallback_begin_current: restoring focus to %llu "
                      "before move returned %d\n",
                      restore_sid,
                      result);
                if (result != SPACE_OP_ERROR_SUCCESS && result != SPACE_OP_ERROR_SAME_SPACE) {
                    managed_space_sip_fallback_fail_current(topology, "could-not-restore-focus-before-move");
                    return;
                }
                topology->current.restore_focus_sid = 0;
            }

            topology->current.phase = 2;
            topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
            managed_space_sip_fallback_schedule_step(topology,
                                                 MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
            managed_space_sip_fallback_schedule_watchdog(topology);
            return;
        }

        if (topology->current.phase == 2 && source_is_active) {
            managed_space_sip_fallback_fail_current(topology, "move-source-reactivated");
            return;
        }
    }

    if (managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology, 0);
        managed_space_sip_fallback_schedule_watchdog(topology);
        return;
    }

    if (topology->current.precondition_hash != managed_space_sip_fallback_snapshot_hash()) {
        managed_space_sip_fallback_fail_current(topology, "stale-topology");
        return;
    }

    if ((mission_control_is_active() || managed_space_sip_fallback_mission_control_ui_exists()) &&
        !topology->owns_mission_control) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_USER_MISSION_CONTROL;
        managed_space_sip_fallback_cancel_watchdog(topology);
        return;
    }

    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE) {
        if (!managed_space_sip_fallback_execute_bridge(topology)) {
            if (topology->policy == MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO &&
                !topology->current.mutation_started) {
                topology->current.backend = MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY;
                topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
                managed_space_sip_fallback_begin_current(topology);
            } else {
                managed_space_sip_fallback_fail_current(topology, "bridge-operation-failed");
            }
        }
    } else if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY) {
        if (!AXIsProcessTrusted()) {
            managed_space_sip_fallback_fail_current(topology, "accessibility-permission-missing");
        } else {
            managed_space_sip_fallback_start_accessibility(topology);
        }
    } else {
        managed_space_sip_fallback_fail_current(topology, "backend-unavailable");
    }
}

static void managed_space_sip_fallback_start_next(struct managed_space_sip_fallback *topology)
{
    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;
    if (buf_len(topology->queue) == 0) return;

    topology->current = topology->queue[0];
    if (buf_len(topology->queue) > 1) {
        memmove(topology->queue,
                topology->queue + 1,
                sizeof(struct managed_space_sip_fallback_request) * (buf_len(topology->queue) - 1));
    }
    --buf__hdr(topology->queue)->len;

    topology->current.precondition_hash = managed_space_sip_fallback_snapshot_hash();
    managed_space_sip_fallback_copy_space_uuid(topology->current.sid, topology->current.sid_uuid);
    managed_space_sip_fallback_copy_space_uuid(topology->current.target_sid, topology->current.target_uuid);
    managed_space_sip_fallback_capture_request_snapshot(&topology->current);
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY) {
        topology->current.focus_space = topology->current.sid == space_manager_active_space();
    }
    topology->operation_error[0] = '\0';
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
    managed_space_sip_fallback_begin_current(topology);
}

static bool managed_space_sip_fallback_event_matches(struct managed_space_sip_fallback_request *request,
                                                 enum managed_space_topology_operation operation,
                                                 uint64_t sid)
{
    if (request->operation != operation) return false;
    if (!request->mutation_started) return false;
    if (operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE) {
        if (managed_space_sip_fallback_snapshot_contains(request->pre_target_order,
                                                     request->pre_target_count,
                                                     sid)) {
            return false;
        }
        return !request->created_sid || request->created_sid == sid;
    }

    return request->sid == sid;
}

static bool managed_space_sip_fallback_created_space_matches_request(
    struct managed_space_sip_fallback_request *request,
    uint64_t sid,
    uint32_t did,
    bool is_user)
{
    return is_user &&
           did == request->target_did &&
           managed_space_sip_fallback_event_matches(request,
                                                MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
                                                sid);
}

void managed_space_sip_fallback_handle_space_created(struct managed_space_sip_fallback *topology, uint64_t sid)
{
    if (!topology->enabled) return;
    if (topology->space_limit_reached) {
        int space_count = display_space_count(topology->space_limit_did);
        if (space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            topology->space_limit_count = space_count;
        } else {
            managed_space_sip_fallback_note_configuration_changed(topology);
        }
    }

    if (!managed_space_sip_fallback_created_space_matches_request(&topology->current,
                                                              sid,
                                                              space_display_id(sid),
                                                              space_is_user(sid))) {
        if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
            !topology->space_limit_reached) {
            managed_space_sip_fallback_note_configuration_changed(topology);
        }
        return;
    }
    topology->current.created_sid = sid;
    topology->current.topology_event_observed = true;
    managed_space_sip_fallback_copy_space_uuid(sid, topology->current.sid_uuid);
    if (!managed_space_sip_fallback_request_is_satisfied(&topology->current)) return;

    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY ||
        topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    } else {
        managed_space_sip_fallback_complete_current(topology);
    }
}

void managed_space_sip_fallback_handle_space_destroyed(struct managed_space_sip_fallback *topology, uint64_t sid)
{
    if (!topology->enabled) return;
    if (topology->space_limit_reached) {
        int space_count = display_space_count(topology->space_limit_did);
        if (space_count >= MANAGED_SPACE_TOPOLOGY_UI_SPACE_LIMIT) {
            topology->space_limit_count = space_count;
        } else {
            managed_space_sip_fallback_note_configuration_changed(topology);
        }
    }

    if (!managed_space_sip_fallback_event_matches(&topology->current,
                                              MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
                                              sid)) {
        if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
            !topology->space_limit_reached) {
            managed_space_sip_fallback_note_configuration_changed(topology);
        }
        return;
    }

    topology->current.topology_event_observed = true;
    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY ||
        topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE;
        managed_space_sip_fallback_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
    } else {
        managed_space_sip_fallback_complete_current(topology);
    }
}

void managed_space_sip_fallback_handle_mission_control_enter(struct managed_space_sip_fallback *topology)
{
    if (!topology->enabled) return;
    if (topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL) return;
    if (!topology->owns_mission_control) return;

    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY;
    managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
}

void managed_space_sip_fallback_handle_mission_control_exit(struct managed_space_sip_fallback *topology)
{
    if (!topology->enabled) return;
    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY &&
        !topology->current.ax_postcondition_observed) {
        managed_space_sip_fallback_observe_persisted_postcondition(topology);
    }

    bool space_limit_failure =
        topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE &&
        string_equals(topology->operation_error, "space-limit-reached");
    uint32_t space_limit_did = topology->current.target_did;
    int space_limit_count = topology->space_limit_count;

    managed_space_sip_fallback_stop_ax_observer(topology);
    bool finish_batch = topology->finish_batch_requested;
    topology->finish_batch_requested = false;
    managed_space_sip_fallback_release_mission_control_ownership(topology);
    managed_space_sip_fallback_restore_pending_focus(topology);

    if ((topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY ||
         topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY) &&
        topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT &&
        (topology->current.phase == MANAGED_SPACE_TOPOLOGY_PHASE_CLOSE_MISSION_CONTROL ||
         topology->current.phase == MANAGED_SPACE_TOPOLOGY_PHASE_DEACTIVATE_IN_MISSION_CONTROL ||
         topology->current.phase == 1)) {
        if (topology->current.phase != 1) {
            topology->current.phase = 0;
        }
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
        managed_space_sip_fallback_schedule_step(topology,
                                             MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
        return;
    }

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_USER_MISSION_CONTROL) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
        managed_space_sip_fallback_schedule_step(topology, MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
        return;
    }

    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY &&
        managed_space_sip_fallback_request_postcondition_satisfied(topology)) {
        managed_space_sip_fallback_complete_current(topology);
        return;
    }

    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT) {
        managed_space_sip_fallback_fail_current(topology, "topology-postcondition-failed");
        return;
    }

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_FAILED || finish_batch) {
        managed_space_sip_fallback_discard_request(&topology->current);
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;
        if (space_limit_failure) {
            managed_space_sip_fallback_record_space_limit(topology,
                                                      space_limit_did,
                                                      space_limit_count);
        }
        managed_space_sip_fallback_start_next(topology);
        managed_space_request_reconcile(&g_managed_space);
        return;
    }

    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE &&
        topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY) {
        managed_space_sip_fallback_fail_current(topology, "mission-control-exited");
    }
}

void managed_space_sip_fallback_handle_dock_restart(struct managed_space_sip_fallback *topology)
{
    if (!topology->enabled) return;
    managed_space_sip_fallback_stop_ax_observer(topology);
    managed_space_sip_fallback_note_configuration_changed(topology);
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) {
        managed_space_sip_fallback_release_mission_control_ownership(topology);
        topology->finish_batch_requested = false;
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;
        managed_space_request_reconcile(&g_managed_space);
        return;
    }
    managed_space_sip_fallback_fail_current(topology, "dock-restarted");
}

void managed_space_sip_fallback_note_input_event(struct managed_space_sip_fallback *topology, CGEventRef event)
{
    if (!topology->enabled) return;
    if (!topology->owns_mission_control) return;
    if (!event || topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == MANAGED_SPACE_TOPOLOGY_MOUSE_EVENT_TAG) return;

    event_loop_post(&g_event_loop,
                    MANAGED_SPACE_TOPOLOGY_USER_INPUT,
                    (void *)(uintptr_t) topology->current.generation,
                    0);
}

void managed_space_sip_fallback_handle_user_interruption(struct managed_space_sip_fallback *topology, uint64_t generation)
{
    if (!topology->enabled) return;
    if (!topology->owns_mission_control) return;
    if (topology->current.generation != generation) return;

    managed_space_sip_fallback_release_mission_control_ownership(topology);
    topology->finish_batch_requested = false;
    managed_space_sip_fallback_stop_ax_observer(topology);
    managed_space_sip_fallback_fail_current(topology, "user-interrupted");
}

void managed_space_sip_fallback_step(struct managed_space_sip_fallback *topology, uint64_t token)
{
    if (!topology->enabled) return;
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;
    if (token != topology->step_token) return;
    if (topology->current.generation != topology->step_generation) return;

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT &&
        topology->current.phase == MANAGED_SPACE_TOPOLOGY_PHASE_DEACTIVATE_IN_MISSION_CONTROL) {
        uint32_t source_did = space_display_id(topology->current.sid);
        uint64_t focus_sid = managed_space_sip_fallback_other_user_space(source_did,
                                                                     topology->current.sid);
        if (!focus_sid) {
            managed_space_sip_fallback_fail_current(topology,
                                                "could-not-deactivate-topology-target");
            return;
        }

        if (managed_space_sip_fallback_ax_activate_space(focus_sid)) {
            topology->current.phase = 1;
            managed_space_sip_fallback_schedule_step(
                topology,
                MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
            managed_space_sip_fallback_schedule_watchdog(topology);
            return;
        }

        managed_space_sip_fallback_schedule_owned_mission_control_exit(topology);
        return;
    }

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT &&
        topology->current.phase == 1) {
        uint32_t source_did = space_display_id(topology->current.sid);
        if (display_space_id(source_did) == topology->current.sid) {
            managed_space_sip_fallback_schedule_owned_mission_control_exit(topology);
            return;
        }

        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
        managed_space_sip_fallback_begin_current(topology);
        return;
    }

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT &&
        topology->current.phase == MANAGED_SPACE_TOPOLOGY_PHASE_CLOSE_MISSION_CONTROL) {
        if (!mission_control_is_active() &&
            !managed_space_sip_fallback_mission_control_ui_exists()) {
            managed_space_sip_fallback_release_mission_control_ownership(topology);
            topology->current.phase = 0;
            topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED;
            managed_space_sip_fallback_schedule_step(
                topology,
                MANAGED_SPACE_TOPOLOGY_MISSION_CONTROL_DELAY_SECONDS);
            return;
        }

        managed_space_sip_fallback_close_owned_mission_control(topology);
        return;
    }

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_QUEUED) {
        managed_space_sip_fallback_begin_current(topology);
        return;
    }

    if (topology->state == MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL) {
        if (!topology->owns_mission_control) return;
        if (!mission_control_is_active() && !managed_space_sip_fallback_mission_control_ui_exists()) return;
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY;
    }

    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE) {
        if (topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE) return;
        if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE &&
            managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
            managed_space_sip_fallback_observe_persisted_postcondition(topology);
        }
        if (managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
            if (managed_space_sip_fallback_request_postcondition_satisfied(topology)) {
                managed_space_sip_fallback_complete_current(topology);
            } else if (!topology->current.readiness_retry_scheduled) {
                topology->current.readiness_retry_scheduled = true;
                managed_space_sip_fallback_schedule_step(
                    topology,
                    MANAGED_SPACE_TOPOLOGY_SETTLE_DELAY_SECONDS);
            }
        }
        return;
    }

    if (topology->current.backend != MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY) return;

    if (topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY &&
        topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT &&
        topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_SETTLE) return;

    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY &&
        topology->current.phase == 1 &&
        !mission_control_is_active()) {
        if (display_space_id(topology->current.target_did) == topology->current.sid) {
            managed_space_sip_fallback_fail_current(topology,
                                                "could-not-deactivate-destroy-target");
            return;
        }
        managed_space_sip_fallback_start_accessibility(topology);
        return;
    }

    if (!topology->current.mutation_started) {
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY;
    }
    enum managed_space_sip_fallback_ax_result result =
        managed_space_sip_fallback_execute_accessibility(topology);
    if (managed_space_sip_fallback_request_postcondition_satisfied(topology)) {
        managed_space_sip_fallback_complete_current(topology);
    } else if (result == MANAGED_SPACE_TOPOLOGY_AX_FAILED) {
        char *error = topology->operation_error[0]
            ? topology->operation_error
            : "accessibility-operation-failed";
        managed_space_sip_fallback_fail_current(topology, error);
    }
}

void managed_space_sip_fallback_watchdog(struct managed_space_sip_fallback *topology, uint64_t token)
{
    if (!topology->enabled) return;
    if (token != topology->watchdog_token) return;
    if (topology->current.operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) {
        if (topology->state != MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT) return;

        snprintf(topology->last_error, sizeof(topology->last_error), "%s", "mission-control-exit-timed-out");
        topology->last_failed_operation = MANAGED_SPACE_TOPOLOGY_OPERATION_NONE;
        topology->last_failed_backend = MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY;
        event_signal_push(SIGNAL_MANAGED_SPACE_TOPOLOGY_FAILED, topology);
        managed_space_sip_fallback_close_owned_mission_control(topology);
        managed_space_sip_fallback_release_mission_control_ownership(topology);
        topology->finish_batch_requested = false;
        topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_IDLE;
        managed_space_sip_fallback_start_next(topology);
        managed_space_request_reconcile(&g_managed_space);
        return;
    }
    if (topology->current.generation != topology->watchdog_generation) return;

    if (topology->current.backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE &&
        managed_space_sip_fallback_request_is_satisfied(&topology->current)) {
        managed_space_sip_fallback_observe_persisted_postcondition(topology);
    }

    if (managed_space_sip_fallback_request_postcondition_satisfied(topology)) {
        managed_space_sip_fallback_complete_current(topology);
    } else {
        managed_space_sip_fallback_fail_current(topology, "operation-timed-out");
    }
}

bool managed_space_sip_fallback_operation_pending(struct managed_space_sip_fallback *topology)
{
    return topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE ||
           buf_len(topology->queue) > 0;
}

bool managed_space_sip_fallback_reconciliation_blocked(struct managed_space_sip_fallback *topology)
{
    return topology->reconciliation_blocked;
}

bool managed_space_sip_fallback_owns_mission_control(struct managed_space_sip_fallback *topology)
{
    return topology->owns_mission_control;
}

bool managed_space_sip_fallback_defers_destroy_membership(struct managed_space_sip_fallback *topology, uint64_t sid)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
    return request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY &&
           request->origin == MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND &&
           request->mutation_started &&
           request->sid == sid;
}

void managed_space_sip_fallback_finish_batch(struct managed_space_sip_fallback *topology)
{
    if (!topology->owns_mission_control) return;
    if (topology->current.operation != MANAGED_SPACE_TOPOLOGY_OPERATION_NONE) return;

    topology->finish_batch_requested = true;
    topology->state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT;
    managed_space_sip_fallback_close_owned_mission_control(topology);
    managed_space_sip_fallback_schedule_watchdog(topology);
}

void managed_space_sip_fallback_write_query(FILE *rsp, struct managed_space_sip_fallback *topology)
{
    struct managed_space_sip_fallback_request *request = &topology->current;
    char source_display_uuid[64] = {0};
    char target_display_uuid[64] = {0};
    if (request->source_did) {
        CFStringRef uuid = display_uuid(request->source_did);
        if (uuid) {
            CFStringGetCString(uuid,
                               source_display_uuid,
                               sizeof(source_display_uuid),
                               kCFStringEncodingUTF8);
            CFRelease(uuid);
        }
    }
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
    uint32_t known_bridge_operations = managed_space_sip_fallback_known_bridge_operations(topology->os_build);
    enum managed_space_topology_operation operations[] = {
        MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE,
        MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY,
        MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER,
        MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY
    };
    bool accessibility_trusted = topology->enabled && AXIsProcessTrusted();

    fprintf(rsp,
            "\t\"topology-os-build\":\"%s\",\n"
            "\t\"topology-accessibility-trusted\":%s,\n"
            "\t\"topology-authority-observed\":%s,\n"
            "\t\"topology-authority-consistent\":%s,\n"
            "\t\"topology-authority-display\":%d,\n"
            "\t\"topology-authority-sls-count\":%d,\n"
            "\t\"topology-authority-ax-count\":%d,\n"
            "\t\"topology-capabilities\":{",
            topology->os_build,
            json_bool(accessibility_trusted),
            json_bool(topology->authority_observed),
            json_bool(topology->authority_consistent),
            topology->authority_did
                ? display_manager_display_id_arrangement(topology->authority_did)
                : 0,
            topology->authority_sls_count,
            topology->authority_ax_count);

    for (int i = 0; i < array_count(operations); ++i) {
        enum managed_space_topology_operation operation = operations[i];
        enum managed_space_sip_fallback_backend preferred_backend = topology->enabled
            ? managed_space_sip_fallback_select_backend(topology, operation)
            : MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE;
        bool bridge_available = topology->enabled &&
                                managed_space_sip_fallback_bridge_symbol_available(operation);
        bool bridge_validated = (known_bridge_operations & managed_space_sip_fallback_operation_bridge_bit(operation)) != 0;
        const char *preferred_backend_name =
            managed_space_sip_fallback_backend_name(preferred_backend);
        const char *fallback_backend_name = "none";

        if (topology->enabled &&
            topology->policy == MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO &&
            preferred_backend == MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE) {
            fallback_backend_name = "accessibility";
        }

        fprintf(rsp,
                "%s\"%s\":{\"preferred-backend\":\"%s\",\"fallback-backend\":\"%s\",\"bridge-available\":%s,\"bridge-validated\":%s,\"accessibility\":%s}",
                i ? "," : "",
                managed_space_topology_operation_name(operation),
                preferred_backend_name,
                fallback_backend_name,
                json_bool(bridge_available),
                json_bool(bridge_validated),
                json_bool(accessibility_trusted));
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
            "\t\"topology-operation-source-display\":%d,\n"
            "\t\"topology-operation-source-display-uuid\":\"%s\",\n"
            "\t\"topology-operation-target-display\":%d,\n"
            "\t\"topology-operation-target-display-uuid\":\"%s\",\n"
            "\t\"topology-operation-pre-source-count\":%d,\n"
            "\t\"topology-operation-pre-target-count\":%d,\n"
            "\t\"topology-operation-ax-source-count\":%d,\n"
            "\t\"topology-operation-ax-target-count\":%d,\n"
            "\t\"topology-operation-phase\":%d,\n"
            "\t\"topology-operation-mutation-started\":%s,\n"
            "\t\"topology-operation-event-observed\":%s,\n"
            "\t\"topology-operation-ax-precondition-observed\":%s,\n"
            "\t\"topology-operation-ax-postcondition-observed\":%s,\n"
            "\t\"topology-operation-dock-postcondition-observed\":%s,\n"
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
            managed_space_sip_fallback_state_name(topology->state),
            managed_space_topology_operation_name(request->operation),
            request->operation == MANAGED_SPACE_TOPOLOGY_OPERATION_NONE
                ? "none"
                : managed_space_topology_origin_name(request->origin),
            managed_space_sip_fallback_backend_name(request->backend),
            request->generation,
            request->precondition_hash,
            request->sid,
            request->sid_uuid,
            request->target_sid,
            request->target_uuid,
            request->created_sid,
            request->source_did ? display_manager_display_id_arrangement(request->source_did) : 0,
            source_display_uuid,
            request->target_did ? display_manager_display_id_arrangement(request->target_did) : 0,
            target_display_uuid,
            request->pre_source_count,
            request->pre_target_count,
            request->ax_source_count_before,
            request->ax_target_count_before,
            request->phase,
            json_bool(request->mutation_started),
            json_bool(request->topology_event_observed),
            json_bool(request->ax_precondition_observed),
            json_bool(request->ax_postcondition_observed),
            json_bool(request->dock_postcondition_observed),
            buf_len(topology->queue),
            json_bool(topology->owns_mission_control),
            json_bool(topology->reconciliation_blocked),
            json_bool(topology->space_limit_reached),
            topology->space_limit_did ? display_manager_display_id_arrangement(topology->space_limit_did) : 0,
            topology->space_limit_count,
            topology->last_failed_generation,
            managed_space_topology_operation_name(topology->last_failed_operation),
            managed_space_sip_fallback_backend_name(topology->last_failed_backend),
            topology->last_error);
}
