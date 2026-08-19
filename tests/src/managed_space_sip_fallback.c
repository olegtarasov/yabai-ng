static int64_t managed_space_sip_fallback_test_async_bridge(void *operation)
{
    (void) operation;
    return 0;
}

static bool managed_space_sip_fallback_test_keep_normal_space(uint64_t sid)
{
    return sid != 20;
}

TEST_FUNC(managed_space_sip_fallback_backend_selection_is_operation_scoped,
{
    struct managed_space_sip_fallback topology = {
        .policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO
    };
    snprintf(topology.os_build, sizeof(topology.os_build), "%s", "25E253");

    int64_t (*previous_bridge)(void *) = SLSPerformAsynchronousBridgedWindowManagementOperation;
    SLSPerformAsynchronousBridgedWindowManagementOperation = managed_space_sip_fallback_test_async_bridge;

    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY);
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY);
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY);

    snprintf(topology.os_build, sizeof(topology.os_build), "%s", "26A5416b");
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY);
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE);
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE);

    snprintf(topology.os_build, sizeof(topology.os_build), "%s", "26B1234");
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE);
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE);

    topology.policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_BRIDGE;
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE);

    SLSPerformAsynchronousBridgedWindowManagementOperation = NULL;
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_NONE);

    topology.policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY;
    TEST_CHECK(managed_space_sip_fallback_select_backend(&topology, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY),
               MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY);

    SLSPerformAsynchronousBridgedWindowManagementOperation = previous_bridge;
});

TEST_FUNC(managed_space_sip_fallback_validated_bridge_matrix_is_os_scoped,
{
    uint32_t operations = managed_space_sip_fallback_known_bridge_operations("25E253");
    TEST_CHECK((int) operations, 0);
    operations = managed_space_sip_fallback_known_bridge_operations("26A5416b");
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_REORDER) != 0, true);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY) != 0, true);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_CREATE) != 0, false);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_DESTROY) != 0, false);
    operations = managed_space_sip_fallback_known_bridge_operations("26Z9999");
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_REORDER) != 0, true);
    TEST_CHECK((operations & MANAGED_SPACE_TOPOLOGY_BRIDGE_MOVE_DISPLAY) != 0, true);
    TEST_CHECK((int) managed_space_sip_fallback_known_bridge_operations("unknown"), 0);
    TEST_CHECK((int) managed_space_sip_fallback_known_bridge_operations(NULL), 0);
});

TEST_FUNC(managed_space_sip_fallback_backend_change_preserves_last_failure,
{
    struct managed_space_sip_fallback topology = {
        .policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO
    };
    snprintf(topology.operation_error,
             sizeof(topology.operation_error),
             "%s",
             "current-operation-error");
    snprintf(topology.last_error, sizeof(topology.last_error), "%s", "persistent-error");

    managed_space_sip_fallback_set_backend_policy(&topology,
                                              MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY);
    TEST_CHECK(topology.policy, MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY);
    TEST_CHECK(topology.operation_error[0] == '\0', true);
    TEST_CHECK(string_equals(topology.last_error, "persistent-error"), true);
});

TEST_FUNC(managed_space_sip_fallback_failed_reconcile_waits_for_new_state,
{
    struct managed_space_sip_fallback topology = {0};
    struct managed_space_sip_fallback_request reconcile_request = {0};
    reconcile_request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER;
    reconcile_request.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE;
    reconcile_request.generation = 9;

    managed_space_sip_fallback_record_immediate_failure(&topology,
                                                    &reconcile_request,
                                                    "unchanged-state");
    TEST_CHECK(managed_space_sip_fallback_reconciliation_blocked(&topology), true);
    TEST_CHECK(string_equals(topology.last_error, "unchanged-state"), true);

    managed_space_sip_fallback_note_configuration_changed(&topology);
    TEST_CHECK(managed_space_sip_fallback_reconciliation_blocked(&topology), false);

    reconcile_request.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND;
    managed_space_sip_fallback_record_immediate_failure(&topology,
                                                    &reconcile_request,
                                                    "command-failed");
    TEST_CHECK(managed_space_sip_fallback_reconciliation_blocked(&topology), false);
});

TEST_FUNC(managed_space_sip_fallback_queue_serializes_and_records_origin,
{
    struct managed_space_sip_fallback topology = {0};
    topology.enabled = true;
    topology.policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY;
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE;

    managed_space_sip_fallback_test_snapshot_override_enabled = true;
    managed_space_sip_fallback_test_snapshot_override = 0x1234;

    struct managed_space_sip_fallback_request reconcile_request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY
    };
    struct managed_space_topology_result reconcile_result =
        managed_space_sip_fallback_submit_request(&topology,
                                              reconcile_request,
                                              MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE);
    TEST_CHECK(reconcile_result.queued, true);
    TEST_CHECK(buf_len(topology.queue), 1);
    TEST_CHECK(topology.queue[0].origin, MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE);
    TEST_CHECK(topology.queue[0].backend, MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY);
    TEST_CHECK((int) topology.queue[0].generation, 1);
    TEST_CHECK((int) topology.queue[0].precondition_hash, 0x1234);

    struct managed_space_sip_fallback_request command_request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY
    };
    struct managed_space_topology_result command_result =
        managed_space_sip_fallback_submit_request(&topology,
                                              command_request,
                                              MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND);
    TEST_CHECK(command_result.queued, true);

    TEST_CHECK(buf_len(topology.queue), 2);
    TEST_CHECK(topology.queue[1].origin, MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND);
    TEST_CHECK((int) topology.queue[1].generation, 2);

    managed_space_sip_fallback_test_snapshot_override_enabled = false;
    managed_space_sip_fallback_destroy(&topology);
});

TEST_FUNC(managed_space_sip_fallback_stale_watchdogs_are_rejected,
{
    struct managed_space_sip_fallback topology = {0};
    topology.state = MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT;
    topology.watchdog_token = 9;
    topology.watchdog_generation = 7;
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY;
    topology.current.generation = 8;
    topology.current.sid = 42;

    managed_space_sip_fallback_watchdog(&topology, 8);
    TEST_CHECK(topology.state, MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT);
    TEST_CHECK(topology.current.operation, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY);

    managed_space_sip_fallback_watchdog(&topology, 9);
    TEST_CHECK(topology.state, MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_EVENT);
    TEST_CHECK(topology.current.operation, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY);
});

TEST_FUNC(managed_space_sip_fallback_events_match_only_the_active_request,
{
    struct managed_space_sip_fallback_request request = {
        .operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE
    };

    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 11), false);
    request.mutation_started = true;
    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 11), true);
    request.created_sid = 12;
    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 11), false);
    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE, 12), true);

    memset(&request, 0, sizeof(request));
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY;
    request.sid = 21;
    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY, 20), false);
    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY, 21), false);
    request.mutation_started = true;
    TEST_CHECK(managed_space_sip_fallback_event_matches(&request, MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY, 21), true);
});

TEST_FUNC(managed_space_sip_fallback_create_events_must_be_new_to_the_request,
{
    uint64_t pre_target_order[3];
    pre_target_order[0] = 10;
    pre_target_order[1] = 20;
    pre_target_order[2] = 30;
    struct managed_space_sip_fallback_request request = {0};
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE;
    request.mutation_started = true;
    request.target_did = 7;
    request.pre_target_order = pre_target_order;
    request.pre_target_count = 3;

    TEST_CHECK(managed_space_sip_fallback_created_space_matches_request(&request,
                                                                    20,
                                                                    7,
                                                                    true),
               false);
    TEST_CHECK(managed_space_sip_fallback_created_space_matches_request(&request,
                                                                    40,
                                                                    8,
                                                                    true),
               false);
    TEST_CHECK(managed_space_sip_fallback_created_space_matches_request(&request,
                                                                    40,
                                                                    7,
                                                                    false),
               false);
    TEST_CHECK(managed_space_sip_fallback_created_space_matches_request(&request,
                                                                    40,
                                                                    7,
                                                                    true),
               true);
});

TEST_FUNC(managed_space_sip_fallback_mutation_backends_require_authoritative_postconditions,
{
    struct managed_space_sip_fallback topology = {0};
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_NONE;
    topology.current.backend = MANAGED_SPACE_SIP_FALLBACK_BACKEND_ACCESSIBILITY;

    TEST_CHECK(managed_space_sip_fallback_request_postcondition_satisfied(&topology), false);
    topology.current.dock_postcondition_observed = true;
    TEST_CHECK(managed_space_sip_fallback_request_postcondition_satisfied(&topology), true);
    topology.current.dock_postcondition_observed = false;
    topology.current.ax_postcondition_observed = true;
    TEST_CHECK(managed_space_sip_fallback_request_postcondition_satisfied(&topology), true);

    topology.current.backend = MANAGED_SPACE_SIP_FALLBACK_BACKEND_BRIDGE;
    topology.current.ax_postcondition_observed = false;
    topology.current.dock_postcondition_observed = false;
    TEST_CHECK(managed_space_sip_fallback_request_postcondition_satisfied(&topology), false);
    topology.current.dock_postcondition_observed = true;
    TEST_CHECK(managed_space_sip_fallback_request_postcondition_satisfied(&topology), true);
});

TEST_FUNC(managed_space_sip_fallback_persisted_postconditions_are_transactional,
{
    uint64_t before[3];
    before[0] = 10;
    before[1] = 20;
    before[2] = 30;
    uint64_t after[4];
    after[0] = 10;
    after[1] = 20;
    after[2] = 30;
    after[3] = 40;

    struct managed_space_sip_fallback_request request = {0};
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE;
    request.created_sid = 40;
    request.pre_target_order = before;
    request.pre_target_count = 3;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       after,
                                                                       4,
                                                                       after,
                                                                       4),
               true);
    after[0] = 20;
    after[1] = 10;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       after,
                                                                       4,
                                                                       after,
                                                                       4),
               false);
    after[0] = 10;
    after[1] = 50;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       after,
                                                                       4,
                                                                       after,
                                                                       4),
               false);

    after[1] = 20;
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY;
    request.sid = 20;
    uint64_t destroyed[2];
    destroyed[0] = 10;
    destroyed[1] = 30;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       destroyed,
                                                                       2,
                                                                       destroyed,
                                                                       2),
               true);
    destroyed[1] = 99;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       destroyed,
                                                                       2,
                                                                       destroyed,
                                                                       2),
               false);

    uint64_t desired[3];
    desired[0] = 30;
    desired[1] = 10;
    desired[2] = 20;
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER;
    request.desired_order = desired;
    request.desired_order_count = 3;
    uint64_t reordered[3];
    memcpy(reordered, desired, sizeof(reordered));
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       reordered,
                                                                       3,
                                                                       reordered,
                                                                       3),
               true);
    reordered[0] = 10;
    reordered[1] = 30;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       reordered,
                                                                       3,
                                                                       reordered,
                                                                       3),
               false);

    uint64_t source_before[3];
    source_before[0] = 10;
    source_before[1] = 20;
    source_before[2] = 30;
    uint64_t target_before[2];
    target_before[0] = 40;
    target_before[1] = 50;
    uint64_t source_after[2];
    source_after[0] = 10;
    source_after[1] = 30;
    uint64_t target_after[3];
    target_after[0] = 40;
    target_after[1] = 50;
    target_after[2] = 20;
    request.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY;
    request.sid = 20;
    request.source_did = 1;
    request.target_did = 2;
    request.pre_source_order = source_before;
    request.pre_source_count = 3;
    request.pre_target_order = target_before;
    request.pre_target_count = 2;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       target_after,
                                                                       3,
                                                                       source_after,
                                                                       2),
               true);
    source_after[1] = 99;
    TEST_CHECK(managed_space_sip_fallback_persisted_orders_satisfy_request(&request,
                                                                       target_after,
                                                                       3,
                                                                       source_after,
                                                                       2),
               false);
});

TEST_FUNC(managed_space_sip_fallback_explicit_destroy_defers_membership_commit,
{
    struct managed_space_sip_fallback topology = {0};
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY;
    topology.current.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND;
    topology.current.sid = 42;

    TEST_CHECK(managed_space_sip_fallback_defers_destroy_membership(&topology, 42), false);
    topology.current.mutation_started = true;
    TEST_CHECK(managed_space_sip_fallback_defers_destroy_membership(&topology, 42), true);
    TEST_CHECK(managed_space_sip_fallback_defers_destroy_membership(&topology, 41), false);

    topology.current.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE;
    TEST_CHECK(managed_space_sip_fallback_defers_destroy_membership(&topology, 42), false);
});

TEST_FUNC(managed_space_sip_fallback_failed_reorder_keeps_previous_desired_order,
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

    TEST_CHECK(managed_space_sip_fallback_move_order_in_place(requested_order, 4, 10, 30, &place_after, &final_index), true);
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

TEST_FUNC(managed_space_sip_fallback_swap_expected_order_is_transactional,
{
    uint64_t order[4];
    order[0] = 10;
    order[1] = 20;
    order[2] = 30;
    order[3] = 40;
    int target_index = -1;

    TEST_CHECK(managed_space_sip_fallback_swap_order_in_place(order, 4, 20, 40, &target_index), true);
    TEST_CHECK(target_index, 3);
    TEST_CHECK((int) order[0], 10);
    TEST_CHECK((int) order[1], 40);
    TEST_CHECK((int) order[2], 30);
    TEST_CHECK((int) order[3], 20);
});

TEST_FUNC(managed_space_sip_fallback_mission_control_ownership_is_explicit,
{
    TEST_CHECK(managed_space_sip_fallback_accessibility_session_state(false, false),
               MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL);
    TEST_CHECK(managed_space_sip_fallback_accessibility_session_state(true, false),
               MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_USER_MISSION_CONTROL);
    TEST_CHECK(managed_space_sip_fallback_accessibility_session_state(true, true),
               MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_ACCESSIBILITY);
});

TEST_FUNC(managed_space_sip_fallback_owned_deactivation_is_generation_checked,
{
    struct managed_space_sip_fallback topology = {0};
    topology.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY;
    topology.current.generation = 17;

    managed_space_sip_fallback_schedule_owned_mission_control_deactivation(&topology);
    TEST_CHECK(topology.state,
               MANAGED_SPACE_SIP_FALLBACK_STATE_WAITING_FOR_MISSION_CONTROL_EXIT);
    TEST_CHECK(topology.current.phase,
               MANAGED_SPACE_TOPOLOGY_PHASE_DEACTIVATE_IN_MISSION_CONTROL);
    TEST_CHECK((int) topology.step_generation, 17);
    TEST_CHECK((int) topology.watchdog_generation, 17);

    managed_space_sip_fallback_schedule_owned_mission_control_exit(&topology);
    TEST_CHECK(topology.current.phase,
               MANAGED_SPACE_TOPOLOGY_PHASE_CLOSE_MISSION_CONTROL);
    TEST_CHECK((int) topology.step_generation, 17);
    TEST_CHECK((int) topology.watchdog_generation, 17);

    managed_space_sip_fallback_cancel_step(&topology);
    managed_space_sip_fallback_cancel_watchdog(&topology);
});

TEST_FUNC(managed_space_sip_fallback_drag_targets_use_visible_ax_frames,
{
    CGRect visible = CGRectZero;
    CGRect display = CGRectMake(0, 0, 100, 100);
    CGRect partly_visible = CGRectMake(75, -25, 50, 50);
    TEST_CHECK(managed_space_sip_fallback_visible_intersection(partly_visible,
                                                           display,
                                                           &visible),
               true);
    TEST_CHECK((int) visible.origin.x, 75);
    TEST_CHECK((int) visible.origin.y, 0);
    TEST_CHECK((int) visible.size.width, 25);
    TEST_CHECK((int) visible.size.height, 25);

    CGRect hidden = CGRectMake(150, 150, 20, 20);
    TEST_CHECK(managed_space_sip_fallback_visible_intersection(hidden,
                                                           display,
                                                           &visible),
               false);
});

TEST_FUNC(managed_space_sip_fallback_ax_display_mapping_accepts_numeric_ids,
{
    int64_t did = 1234;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt64Type, &did);
    TEST_CHECK(managed_space_sip_fallback_ax_display_value_matches(value, 1234), true);
    TEST_CHECK(managed_space_sip_fallback_ax_display_value_matches(value, 4321), false);
    CFRelease(value);
});

TEST_FUNC(managed_space_sip_fallback_space_limit_is_display_scoped,
{
    struct managed_space_sip_fallback topology = {0};
    topology.space_limit_reached = true;
    topology.space_limit_did = 12;
    topology.space_limit_count = 16;

    TEST_CHECK(managed_space_sip_fallback_create_is_blocked(&topology, 12), true);
    TEST_CHECK(managed_space_sip_fallback_create_is_blocked(&topology, 13), false);
    managed_space_sip_fallback_note_configuration_changed(&topology);
    TEST_CHECK(managed_space_sip_fallback_create_is_blocked(&topology, 12), false);
});

TEST_FUNC(managed_space_sip_fallback_normal_order_excludes_fullscreen_entries,
{
    uint64_t source[4];
    source[0] = 10;
    source[1] = 20;
    source[2] = 30;
    source[3] = 40;
    uint64_t destination[4] = {0};
    int count = managed_space_sip_fallback_copy_matching_spaces(source,
                                                            4,
                                                            destination,
                                                            managed_space_sip_fallback_test_keep_normal_space);

    TEST_CHECK(count, 3);
    TEST_CHECK((int) destination[0], 10);
    TEST_CHECK((int) destination[1], 30);
    TEST_CHECK((int) destination[2], 40);
});
