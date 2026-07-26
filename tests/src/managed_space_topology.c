static int64_t managed_space_topology_test_async_bridge(void *operation)
{
    (void) operation;
    return 0;
}

static bool managed_space_topology_test_keep_normal_space(uint64_t sid)
{
    return sid != 20;
}

TEST_FUNC(managed_space_topology_backend_selection_is_operation_scoped,
{
    struct managed_space_topology topology = {
        .policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO
    };
    snprintf(topology.os_build, sizeof(topology.os_build), "%s", "25E253");

    int64_t (*previous_bridge)(void *) = SLSPerformAsynchronousBridgedWindowManagementOperation;
    SLSPerformAsynchronousBridgedWindowManagementOperation = managed_space_topology_test_async_bridge;

    TEST_CHECK(managed_space_topology_select_initial_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION);
    TEST_CHECK(managed_space_topology_select_fallback_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE);
    TEST_CHECK(managed_space_topology_select_fallback_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE);
    TEST_CHECK(managed_space_topology_select_fallback_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY);

    topology.policy = MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE;
    TEST_CHECK(managed_space_topology_select_initial_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_BRIDGE);

    SLSPerformAsynchronousBridgedWindowManagementOperation = NULL;
    TEST_CHECK(managed_space_topology_select_initial_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_NONE);

    topology.policy = MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY;
    TEST_CHECK(managed_space_topology_select_initial_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY);

    topology.policy = MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION;
    TEST_CHECK(managed_space_topology_select_initial_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_SCRIPTING_ADDITION);
    TEST_CHECK(managed_space_topology_select_fallback_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_TOPOLOGY_BACKEND_NONE);

    SLSPerformAsynchronousBridgedWindowManagementOperation = previous_bridge;
});

TEST_FUNC(managed_space_topology_backend_policy_values_are_stable,
{
    enum managed_space_topology_backend_policy policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO;

    TEST_CHECK(managed_space_topology_backend_policy_from_string("auto", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("scripting-addition", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("bridge", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("accessibility", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("invalid", &policy), false);
});

TEST_FUNC(managed_space_topology_validated_bridge_matrix_is_build_scoped,
{
    uint32_t operations = managed_space_topology_known_bridge_operations("25E253");
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_CREATE) != 0, true);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_DESTROY) != 0, true);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY) != 0, true);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_REORDER) != 0, false);
    TEST_CHECK((int) managed_space_topology_known_bridge_operations("unknown"), 0);
});

TEST_FUNC(managed_space_topology_backend_change_preserves_last_failure,
{
    struct managed_space_topology topology = {
        .policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO
    };
    snprintf(topology.operation_error,
             sizeof(topology.operation_error),
             "%s",
             "current-operation-error");
    snprintf(topology.last_error, sizeof(topology.last_error), "%s", "persistent-error");

    managed_space_topology_set_backend_policy(&topology,
                                              MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY);
    TEST_CHECK(topology.policy, MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY);
    TEST_CHECK(topology.operation_error[0] == '\0', true);
    TEST_CHECK(string_equals(topology.last_error, "persistent-error"), true);
});

TEST_FUNC(managed_space_topology_failed_reconcile_waits_for_new_state,
{
    struct managed_space_topology topology = {0};
    struct managed_space_topology_request reconcile_request = {0};
    reconcile_request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER;
    reconcile_request.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE;
    reconcile_request.generation = 9;

    managed_space_topology_record_immediate_failure(&topology,
                                                    &reconcile_request,
                                                    "unchanged-state");
    TEST_CHECK(managed_space_topology_reconciliation_blocked(&topology), true);
    TEST_CHECK(string_equals(topology.last_error, "unchanged-state"), true);

    managed_space_topology_note_configuration_changed(&topology);
    TEST_CHECK(managed_space_topology_reconciliation_blocked(&topology), false);

    reconcile_request.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND;
    managed_space_topology_record_immediate_failure(&topology,
                                                    &reconcile_request,
                                                    "command-failed");
    TEST_CHECK(managed_space_topology_reconciliation_blocked(&topology), false);
});

TEST_FUNC(managed_space_topology_queue_serializes_and_records_origin,
{
    struct managed_space_topology topology = {0};
    topology.enabled = true;
    topology.policy = MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY;
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE;

    managed_space_topology_test_snapshot_override_enabled = true;
    managed_space_topology_test_snapshot_override = 0x1234;

    struct managed_space_topology_request reconcile_request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY
    };
    TEST_CHECK(managed_space_topology_submit_request(&topology, reconcile_request), SPACE_OP_ERROR_QUEUED);
    TEST_CHECK(buf_len(topology.queue), 1);
    TEST_CHECK(topology.queue[0].origin, MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE);
    TEST_CHECK(topology.queue[0].backend, MANAGED_SPACE_TOPOLOGY_BACKEND_ACTIVE_ACCESSIBILITY);
    TEST_CHECK((int) topology.queue[0].generation, 1);
    TEST_CHECK((int) topology.queue[0].precondition_hash, 0x1234);

    managed_space_topology_begin_command(&topology);
    struct managed_space_topology_request command_request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY
    };
    TEST_CHECK(managed_space_topology_submit_request(&topology, command_request), SPACE_OP_ERROR_QUEUED);
    managed_space_topology_end_command(&topology);

    TEST_CHECK(buf_len(topology.queue), 2);
    TEST_CHECK(topology.queue[1].origin, MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND);
    TEST_CHECK((int) topology.queue[1].generation, 2);

    managed_space_topology_test_snapshot_override_enabled = false;
    managed_space_topology_destroy(&topology);
});

TEST_FUNC(managed_space_topology_stale_watchdogs_are_rejected,
{
    struct managed_space_topology topology = {0};
    topology.state = MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT;
    topology.watchdog_token = 9;
    topology.watchdog_generation = 7;
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY;
    topology.current.generation = 8;
    topology.current.sid = 42;

    managed_space_topology_watchdog(&topology, 8);
    TEST_CHECK(topology.state, MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT);
    TEST_CHECK(topology.current.operation, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY);

    managed_space_topology_watchdog(&topology, 9);
    TEST_CHECK(topology.state, MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_EVENT);
    TEST_CHECK(topology.current.operation, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY);
});

TEST_FUNC(managed_space_topology_events_match_only_the_active_request,
{
    struct managed_space_topology_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE
    };

    TEST_CHECK(managed_space_topology_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 11), true);
    request.created_sid = 12;
    TEST_CHECK(managed_space_topology_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 11), false);
    TEST_CHECK(managed_space_topology_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 12), true);

    memset(&request, 0, sizeof(request));
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY;
    request.sid = 21;
    TEST_CHECK(managed_space_topology_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY, 20), false);
    TEST_CHECK(managed_space_topology_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY, 21), true);
});

TEST_FUNC(managed_space_topology_failed_reorder_keeps_previous_desired_order,
{
    uint64_t managed_order[4];
    managed_order[0] = 10;
    managed_order[1] = 20;
    managed_order[2] = 30;
    managed_order[3] = 40;
    uint64_t requested_order[4];
    memcpy(requested_order, managed_order, sizeof(managed_order));
    bool place_after = false;
    int final_index = -1;

    TEST_CHECK(managed_space_topology_move_order_in_place(requested_order, 4, 10, 30, &place_after, &final_index), true);
    TEST_CHECK(place_after, true);
    TEST_CHECK(final_index, 2);
    TEST_CHECK((int) requested_order[0], 20);
    TEST_CHECK((int) requested_order[1], 30);
    TEST_CHECK((int) requested_order[2], 10);
    TEST_CHECK((int) requested_order[3], 40);

    TEST_CHECK((int) managed_order[0], 10);
    TEST_CHECK((int) managed_order[1], 20);
    TEST_CHECK((int) managed_order[2], 30);
    TEST_CHECK((int) managed_order[3], 40);
});

TEST_FUNC(managed_space_topology_swap_expected_order_is_transactional,
{
    uint64_t order[4];
    order[0] = 10;
    order[1] = 20;
    order[2] = 30;
    order[3] = 40;
    int target_index = -1;

    TEST_CHECK(managed_space_topology_swap_order_in_place(order, 4, 20, 40, &target_index), true);
    TEST_CHECK(target_index, 3);
    TEST_CHECK((int) order[0], 10);
    TEST_CHECK((int) order[1], 40);
    TEST_CHECK((int) order[2], 30);
    TEST_CHECK((int) order[3], 20);
});

TEST_FUNC(managed_space_topology_mission_control_ownership_is_explicit,
{
    TEST_CHECK(managed_space_topology_accessibility_session_state(false, false),
               MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_MISSION_CONTROL);
    TEST_CHECK(managed_space_topology_accessibility_session_state(true, false),
               MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_USER_MISSION_CONTROL);
    TEST_CHECK(managed_space_topology_accessibility_session_state(true, true),
               MANAGED_SPACE_TOPOLOGY_STATE_WAITING_FOR_ACCESSIBILITY);
});

TEST_FUNC(managed_space_topology_ax_display_mapping_accepts_numeric_ids,
{
    int64_t did = 1234;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt64Type, &did);
    TEST_CHECK(managed_space_topology_ax_display_value_matches(value, 1234), true);
    TEST_CHECK(managed_space_topology_ax_display_value_matches(value, 4321), false);
    CFRelease(value);
});

TEST_FUNC(managed_space_topology_space_limit_is_display_scoped,
{
    struct managed_space_topology topology = {0};
    topology.space_limit_reached = true;
    topology.space_limit_did = 12;
    topology.space_limit_count = 16;

    TEST_CHECK(managed_space_topology_create_is_blocked(&topology, 12), true);
    TEST_CHECK(managed_space_topology_create_is_blocked(&topology, 13), false);
    managed_space_topology_note_configuration_changed(&topology);
    TEST_CHECK(managed_space_topology_create_is_blocked(&topology, 12), false);
});

TEST_FUNC(managed_space_topology_normal_order_excludes_fullscreen_entries,
{
    uint64_t source[4];
    source[0] = 10;
    source[1] = 20;
    source[2] = 30;
    source[3] = 40;
    uint64_t destination[4] = {0};
    int count = managed_space_topology_copy_matching_spaces(source,
                                                            4,
                                                            destination,
                                                            managed_space_topology_test_keep_normal_space);

    TEST_CHECK(count, 3);
    TEST_CHECK((int) destination[0], 10);
    TEST_CHECK((int) destination[1], 30);
    TEST_CHECK((int) destination[2], 40);
});
