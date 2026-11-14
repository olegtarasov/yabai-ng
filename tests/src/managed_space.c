TEST_FUNC(managed_space_display_policy_defaults_to_follow_main,
{
    struct managed_space ms;
    managed_space_init(&ms);

    TEST_CHECK(managed_space_display_policy(&ms), MANAGED_SPACE_DISPLAY_FOLLOW_MAIN);

    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_display_policy_can_be_set_while_disabled,
{
    struct managed_space ms;
    managed_space_init(&ms);

    managed_space_set_display_policy(&ms, MANAGED_SPACE_DISPLAY_FIXED);
    TEST_CHECK(managed_space_display_policy(&ms), MANAGED_SPACE_DISPLAY_FIXED);

    managed_space_set_display_policy(&ms, MANAGED_SPACE_DISPLAY_FOLLOW_MAIN);
    TEST_CHECK(managed_space_display_policy(&ms), MANAGED_SPACE_DISPLAY_FOLLOW_MAIN);

    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_display_affinity_names_are_stable,
{
    TEST_CHECK(strcmp(managed_space_display_affinity_name(MANAGED_SPACE_DISPLAY_FOLLOW_MAIN), "follow-main"), 0);
    TEST_CHECK(strcmp(managed_space_display_affinity_name(MANAGED_SPACE_DISPLAY_FIXED), "fixed"), 0);
});


TEST_FUNC(managed_space_pending_create_counts_only_managed_spaces,
{
    struct managed_space ms;
    managed_space_init(&ms);
    ms.enabled = true;

    managed_space_prepare_user_space_create(&ms, 0, MANAGED_SPACE_DISPLAY_FOLLOW_MAIN);
    managed_space_add_pending_create(&ms, 0, MANAGED_SPACE_DISPLAY_FIXED, false);
    TEST_CHECK(ms.pending_user_creates, 1);
    TEST_CHECK(buf_len(ms.pending_creates), 2);

    managed_space_cancel_user_space_create(&ms);
    TEST_CHECK(ms.pending_user_creates, 0);
    TEST_CHECK(buf_len(ms.pending_creates), 1);

    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_secondary_workspace_reservation_survives_reorder_and_is_display_scoped,
{
    struct managed_space ms;
    managed_space_init(&ms);
    CFStringRef candidates[2];
    candidates[0] = CFSTR("secondary-workspace");
    candidates[1] = CFSTR("extra");
    CFStringRef selected = managed_space_select_secondary_workspace(&ms, CFSTR("display-a"), candidates, 2);
    TEST_CHECK(CFEqual(selected, CFSTR("secondary-workspace")), true);

    candidates[0] = CFSTR("extra");
    candidates[1] = CFSTR("secondary-workspace");
    selected = managed_space_select_secondary_workspace(&ms, CFSTR("display-a"), candidates, 2);
    TEST_CHECK(CFEqual(selected, CFSTR("secondary-workspace")), true);
    selected = managed_space_select_secondary_workspace(&ms, CFSTR("display-b"), candidates, 2);
    TEST_CHECK(CFEqual(selected, CFSTR("extra")), true);
    TEST_CHECK(buf_len(ms.secondary_workspaces), 2);

    // A vanished UUID may be replaced, while an empty transient observation does not erase it.
    selected = managed_space_select_secondary_workspace(&ms, CFSTR("display-a"), candidates, 0);
    TEST_CHECK(selected == NULL, true);
    TEST_CHECK(CFEqual(ms.secondary_workspaces[0].space_uuid, CFSTR("secondary-workspace")), true);
    selected = managed_space_select_secondary_workspace(&ms, CFSTR("display-a"), candidates, 1);
    TEST_CHECK(CFEqual(selected, CFSTR("extra")), true);
    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_drag_defers_only_affected_window_repairs_and_cancellation_resumes_them,
{
    struct managed_space ms;
    managed_space_init(&ms);
    ms.enabled = true;
    ms.event_posted = true;
    struct managed_space_entry home = ((struct managed_space_entry) {0});
    home.uuid = CFRetain(CFSTR("home"));
    home.sid = 11;
    buf_push(ms.spaces, home);
    managed_space_set_window_namespace(&ms, NULL, 1, CFSTR("home"));
    managed_space_set_window_namespace(&ms, NULL, 2, CFSTR("home"));
    struct window source = ((struct window) {0});
    source.id = 1;
    struct window peer = ((struct window) {0});
    peer.id = 3;
    managed_space_begin_window_drag(&ms, &source);
    managed_space_track_window_drag(&ms, &peer);
    managed_space_track_window_drag(&ms, &source);
    TEST_CHECK(buf_len(ms.drag_windows), 2);
    TEST_CHECK(managed_space_drag_contains_window(&ms, ms.windows[0].wid), true);
    TEST_CHECK(managed_space_drag_contains_window(&ms, ms.windows[1].wid), false);

    managed_space_cancel_window_drag(&ms, 9);
    TEST_CHECK(buf_len(ms.drag_windows), 2);
    managed_space_cancel_window_drag(&ms, 1);
    TEST_CHECK(buf_len(ms.drag_windows), 0);
    TEST_CHECK(managed_space_drag_contains_window(&ms, ms.windows[0].wid), false);
    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_intent_commits_preserve_unrelated_windows_and_secondary_without_home,
{
    struct managed_space ms;
    managed_space_init(&ms);
    managed_space_set_window_namespace(&ms, NULL, 1, CFSTR("first-home"));
    managed_space_set_window_namespace(&ms, NULL, 2, CFSTR("other-home"));
    managed_space_set_secondary_residence(&ms, 1, CFSTR("secondary"));
    managed_space_set_secondary_residence(&ms, 3, CFSTR("secondary"));
    TEST_CHECK(ms.windows[2].space_uuid == NULL, true);

    managed_space_set_window_namespace(&ms, &ms.windows[0], 1, CFSTR("new-home"));
    TEST_CHECK(ms.windows[0].secondary_space_uuid == NULL, true);
    TEST_CHECK(CFEqual(ms.windows[0].space_uuid, CFSTR("new-home")), true);
    TEST_CHECK(CFEqual(ms.windows[1].space_uuid, CFSTR("other-home")), true);
    TEST_CHECK(ms.windows[1].secondary_space_uuid == NULL, true);
    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_native_tab_handoff_moves_home_residence_and_active_drag,
{
    struct managed_space ms;
    managed_space_init(&ms);
    ms.enabled = true;
    ms.event_posted = true;
    managed_space_set_window_namespace(&ms, NULL, 1, CFSTR("group-home"));
    managed_space_set_secondary_residence(&ms, 1, CFSTR("secondary"));
    managed_space_set_window_namespace(&ms, NULL, 2, CFSTR("stale-member-home"));
    managed_space_set_window_namespace(&ms, NULL, 3, CFSTR("unrelated"));
    buf_push(ms.drag_windows, 1);
    buf_push(ms.drag_windows, 2);

    managed_space_replace_window(&ms, 1, 2);
    TEST_CHECK(buf_len(ms.windows), 2);
    TEST_CHECK(managed_space_find_window_entry(&ms, 1) == NULL, true);
    struct managed_window_entry *selected = managed_space_find_window_entry(&ms, 2);
    TEST_CHECK(selected != NULL, true);
    TEST_CHECK(CFEqual(selected->space_uuid, CFSTR("group-home")), true);
    TEST_CHECK(CFEqual(selected->secondary_space_uuid, CFSTR("secondary")), true);
    TEST_CHECK(CFEqual(managed_space_find_window_entry(&ms, 3)->space_uuid, CFSTR("unrelated")), true);
    TEST_CHECK(buf_len(ms.drag_windows), 1);
    TEST_CHECK(managed_space_drag_contains_window(&ms, 2), true);

    // An unremembered secondary representative must not inherit a stale member home.
    managed_space_replace_window(&ms, 4, 2);
    TEST_CHECK(managed_space_find_window_entry(&ms, 2) == NULL, true);
    TEST_CHECK(buf_len(ms.windows), 1);
    managed_space_destroy(&ms);
});


TEST_FUNC(managed_space_destroy_preserves_remaining_slot_order,
{
    struct managed_space ms; managed_space_init(&ms);
    struct managed_space_entry first = ((struct managed_space_entry) { .uuid = CFRetain(CFSTR("first")), .sid = 11 });
    struct managed_space_entry second = ((struct managed_space_entry) { .uuid = CFRetain(CFSTR("second")), .sid = 22 });
    struct managed_space_entry third = ((struct managed_space_entry) { .uuid = CFRetain(CFSTR("third")), .sid = 33 });
    buf_push(ms.spaces, first); buf_push(ms.spaces, second); buf_push(ms.spaces, third);
    TEST_CHECK(managed_space_remove_entry_ordered(&ms, 11), true);
    TEST_CHECK(buf_len(ms.spaces), 2);
    TEST_CHECK(CFEqual(ms.spaces[0].uuid, CFSTR("second")), true);
    TEST_CHECK(CFEqual(ms.spaces[1].uuid, CFSTR("third")), true);
    TEST_CHECK(ms.spaces[0].order, 1);
    TEST_CHECK(ms.spaces[1].order, 2);
    managed_space_destroy(&ms);
});

static void managed_space_test_fixture(struct managed_space *ms, struct managed_space_observation *o)
{
    managed_space_init(ms); ms->enabled = ms->scripting_addition_ready = ms->event_posted = true;
    memset(o, 0, sizeof(*o)); o->valid = true; o->hash = 123;
    struct managed_space_observed_display display = ((struct managed_space_observed_display) { .did = 1, .uuid = CFRetain(CFSTR("main")), .main = true, .active_sid = 11 });
    struct managed_space_observed_space home = ((struct managed_space_observed_space) { .sid = 11, .uuid = CFRetain(CFSTR("home")), .did = 1, .index = 1, .normal = true });
    struct managed_space_observed_space other = ((struct managed_space_observed_space) { .sid = 22, .uuid = CFRetain(CFSTR("other")), .did = 1, .index = 2, .normal = true });
    struct managed_space_entry entry = ((struct managed_space_entry) { .uuid = CFRetain(CFSTR("home")), .sid = 11, .order = 1 });
    buf_push(o->displays, display); buf_push(o->spaces, home); buf_push(o->spaces, other); buf_push(ms->spaces, entry);
    struct managed_space_entry other_entry = ((struct managed_space_entry) { .uuid = CFRetain(CFSTR("other")), .sid = 22, .order = 2 });
    buf_push(ms->spaces, other_entry);
    managed_space_set_window_namespace(ms, NULL, 10, CFSTR("home"));
    struct managed_space_observed_window window = ((struct managed_space_observed_window) { .wid = 10, .sid = 22, .actionable = true });
    buf_push(o->windows, window);
}

TEST_FUNC(managed_space_planner_never_repairs_actual_fullscreen_membership,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    struct managed_space_observed_space fullscreen = ((struct managed_space_observed_space) { .sid = 33, .uuid = CFRetain(CFSTR("fullscreen")), .did = 1, .index = 3, .fullscreen = true });
    buf_push(o.spaces, fullscreen);
    o.windows[0].sid = 33; o.windows[0].fullscreen = false;
    // Deliberately leave cached/actionable=true to model the historical AX race.
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    TEST_CHECK((int) ms.window_repair_attempt_count, 0);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_planner_defers_unknown_or_interrupted_observation,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_REPAIR_WINDOW);
    o.valid = false; action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    o.valid = true; o.blocked = true; action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    o.blocked = false; ms.scripting_addition_ready = false;
    action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    TEST_CHECK(CFEqual(ms.windows[0].space_uuid, CFSTR("home")), true);
    // Missing fixed slots are recreated on an available display without losing affinity.
    ms.scripting_addition_ready = true;
    ms.spaces[0].display_affinity = MANAGED_SPACE_DISPLAY_FIXED;
    ms.spaces[0].preferred_display_uuid = CFRetain(CFSTR("disconnected"));
    CFRelease(o.spaces[0].uuid); o.spaces[0] = o.spaces[1]; --buf__hdr(o.spaces)->len;
    o.displays[0].active_sid = 22;
    action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_CREATE);
    TEST_CHECK((int) action.did, 1);
    TEST_CHECK(CFEqual(ms.spaces[0].preferred_display_uuid, CFSTR("disconnected")), true);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_unknown_window_membership_defers_only_that_window,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    o.windows[0].sid = 0;
    // Even a stale actionable bit must not turn unknown membership into the
    // display's currently active normal Space.
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);

    managed_space_set_window_namespace(&ms, NULL, 20, CFSTR("home"));
    struct managed_space_observed_window known = ((struct managed_space_observed_window) {
        .wid = 20, .sid = 22, .actionable = true,
    });
    buf_push(o.windows, known);
    action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_REPAIR_WINDOW);
    TEST_CHECK(action.wid, 20);
    TEST_CHECK(CFEqual(ms.windows[0].space_uuid, CFSTR("home")), true);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_accepted_placement_waits_for_event_and_explicit_refresh_retries,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    managed_space_set_pending_placement(&ms.windows[0], 22, CFSTR("home"));
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    managed_space_test_probe_override_enabled = true;
    managed_space_test_probe_override = (struct scripting_addition_probe_result) { .status = SCRIPTING_ADDITION_PROBE_COMPATIBLE };
    TEST_CHECK(managed_space_set_enabled(&ms, true), true);
    TEST_CHECK(buf_len(ms.spaces), 2);
    TEST_CHECK(ms.windows[0].pending_space_uuid == NULL, true);
    action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_REPAIR_WINDOW);
    managed_space_set_pending_placement(&ms.windows[0], 22, CFSTR("home"));
    o.windows[0].sid = 11;
    managed_space_refresh_observed_intent(&ms, &o);
    TEST_CHECK(ms.windows[0].pending_space_uuid == NULL, true);
    action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    managed_space_test_probe_override_enabled = false;
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_readiness_failure_preserves_registry_and_home,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    managed_space_test_probe_override_enabled = true;
    managed_space_test_probe_override = (struct scripting_addition_probe_result) { .status = SCRIPTING_ADDITION_PROBE_VERSION_MISMATCH };
    TEST_CHECK(managed_space_set_enabled(&ms, true), false);
    TEST_CHECK(ms.enabled, true);
    TEST_CHECK(ms.scripting_addition_ready, false);
    TEST_CHECK(buf_len(ms.spaces), 2);
    TEST_CHECK(CFEqual(ms.windows[0].space_uuid, CFSTR("home")), true);
    managed_space_handle_dock_restart(&ms);
    TEST_CHECK(ms.enabled, true);
    TEST_CHECK(ms.scripting_addition.status, SCRIPTING_ADDITION_PROBE_UNAVAILABLE);
    managed_space_test_probe_override = (struct scripting_addition_probe_result) { .status = SCRIPTING_ADDITION_PROBE_COMPATIBLE };
    TEST_CHECK(managed_space_refresh_scripting_addition(&ms), true);
    TEST_CHECK(buf_len(ms.spaces), 2);
    managed_space_note_topology_result(&ms, SPACE_OP_ERROR_SCRIPTING_ADDITION);
    TEST_CHECK(ms.scripting_addition_ready, false);
    TEST_CHECK(ms.last_error, SPACE_OP_ERROR_SCRIPTING_ADDITION);
    managed_space_test_probe_override_enabled = false;
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_initial_enable_requires_compatible_addition,
{
    struct managed_space ms; managed_space_init(&ms);
    managed_space_test_probe_override_enabled = true;
    managed_space_test_probe_override = (struct scripting_addition_probe_result) { .status = SCRIPTING_ADDITION_PROBE_CAPABILITIES_MISSING };
    TEST_CHECK(managed_space_set_enabled(&ms, true), false);
    TEST_CHECK(ms.enabled, false);
    TEST_CHECK(buf_len(ms.spaces), 0);
    managed_space_test_probe_override_enabled = false;
    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_create_tickets_protect_display_and_cancel_exact_latest_user,
{
    struct managed_space ms; managed_space_init(&ms); ms.enabled = true;
    struct managed_space_create_request user = ((struct managed_space_create_request) { .display_uuid = CFRetain(CFSTR("a")), .sequence = 1, .managed = true });
    struct managed_space_create_request replacement = ((struct managed_space_create_request) { .display_uuid = CFRetain(CFSTR("a")), .replacement_uuid = CFRetain(CFSTR("lost")), .sequence = 2, .managed = true });
    struct managed_space_create_request placeholder = ((struct managed_space_create_request) { .display_uuid = CFRetain(CFSTR("b")), .sequence = 3 });
    struct managed_space_create_request latest = ((struct managed_space_create_request) { .display_uuid = CFRetain(CFSTR("a")), .sequence = 4, .managed = true });
    buf_push(ms.pending_creates, user); buf_push(ms.pending_creates, replacement); buf_push(ms.pending_creates, placeholder); buf_push(ms.pending_creates, latest);
    TEST_CHECK(managed_space_pending_user_create_count(&ms), 2);
    TEST_CHECK(managed_space_display_has_pending_create(&ms, CFSTR("a")), true);
    TEST_CHECK(managed_space_display_has_pending_create(&ms, CFSTR("c")), false);
    managed_space_cancel_user_space_create(&ms);
    TEST_CHECK(buf_len(ms.pending_creates), 3);
    TEST_CHECK(managed_space_pending_user_create_count(&ms), 1);
    TEST_CHECK(managed_space_pending_replacement(&ms, CFSTR("lost")), true);
    int index = managed_space_find_pending_placeholder_create_for_uuid(&ms, CFSTR("b"));
    TEST_CHECK(index >= 0, true);
    managed_space_remove_pending_create_at_index(&ms, index);
    TEST_CHECK(managed_space_display_has_pending_create(&ms, CFSTR("b")), false);
    TEST_CHECK(managed_space_pending_replacement(&ms, CFSTR("lost")), true);
    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_late_creation_receipt_does_not_consume_next_ticket,
{
    struct managed_space ms; managed_space_init(&ms);
    struct managed_space_create_request request = ((struct managed_space_create_request) { .display_uuid = CFRetain(CFSTR("a")), .sequence = 3, .managed = true });
    buf_push(request.known_space_uuids, CFRetain(CFSTR("old")));
    buf_push(ms.pending_creates, request);
    buf_push(ms.replacement_receipts, CFRetain(CFSTR("admitted")));
    TEST_CHECK(managed_space_consume_replacement_receipt(&ms, CFSTR("other")), false);
    TEST_CHECK(managed_space_consume_replacement_receipt(&ms, CFSTR("admitted")), true);
    TEST_CHECK(buf_len(ms.pending_creates), 1);
    TEST_CHECK(managed_space_create_knows_uuid(&ms.pending_creates[0], CFSTR("old")), true);
    TEST_CHECK(managed_space_create_knows_uuid(&ms.pending_creates[0], CFSTR("new")), false);
    TEST_CHECK(managed_space_consume_replacement_receipt(&ms, CFSTR("admitted")), false);
    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_secondary_disappearance_is_transition_and_no_replug_return,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    managed_space_set_secondary_residence(&ms, 10, CFSTR("secondary"));
    struct managed_secondary_workspace workspace = ((struct managed_secondary_workspace) { .display_uuid = CFRetain(CFSTR("display-b")), .space_uuid = CFRetain(CFSTR("secondary")) });
    buf_push(ms.secondary_workspaces, workspace);
    o.valid = false; managed_space_refresh_observed_intent(&ms, &o);
    TEST_CHECK(ms.windows[0].secondary_space_uuid != NULL, true);
    o.valid = true; managed_space_refresh_observed_intent(&ms, &o);
    TEST_CHECK(ms.windows[0].secondary_space_uuid == NULL, true);
    TEST_CHECK(CFEqual(ms.windows[0].space_uuid, CFSTR("home")), true);
    struct managed_space_observed_display second = ((struct managed_space_observed_display) { .did = 2, .uuid = CFRetain(CFSTR("display-b")), .active_sid = 33 });
    struct managed_space_observed_space secondary = ((struct managed_space_observed_space) { .sid = 33, .uuid = CFRetain(CFSTR("secondary")), .did = 2, .index = 3, .normal = true });
    buf_push(o.displays, second); buf_push(o.spaces, secondary);
    managed_space_refresh_observed_intent(&ms, &o);
    TEST_CHECK(ms.windows[0].secondary_space_uuid == NULL, true);
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_REPAIR_WINDOW);
    TEST_CHECK((int) action.target_sid, 11);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_planner_respects_drag_and_creation_admission,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    o.windows[0].dragged = true;
    struct managed_space_action action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    struct managed_space_observed_space extra = ((struct managed_space_observed_space) { .sid = 33, .uuid = CFRetain(CFSTR("new-space")), .did = 1, .index = 3, .normal = true });
    buf_push(o.spaces, extra);
    struct managed_space_create_request request = ((struct managed_space_create_request) { .display_uuid = CFRetain(CFSTR("main")), .sequence = 1, .managed = true });
    buf_push(ms.pending_creates, request);
    action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    managed_space_remove_pending_create_at_index(&ms, 0);
    action = managed_space_plan(&ms, &o); TEST_CHECK(action.type, MANAGED_SPACE_ACTION_DESTROY);
    TEST_CHECK((int) action.sid, 33);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_explicit_destroy_does_not_replenish_configured_names,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    buf_push(ms.names, string_copy("1")); buf_push(ms.names, string_copy("2"));
    // A successful explicit destroy already removed the second physical space.
    ms.spaces[1].sid = 0;
    managed_space_remove_entry_ordered_at_index(&ms, 1);
    CFRelease(o.spaces[1].uuid); --buf__hdr(o.spaces)->len;
    o.windows[0].sid = 11;
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    TEST_CHECK(buf_len(ms.spaces), 1);
    TEST_CHECK(buf_len(ms.names), 2);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_unchanged_observation_does_not_repeat_failed_action,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(managed_space_should_execute_action(&ms, &o, action), true);
    ms.last_action_key = managed_space_action_key(action); ms.last_action_observation = o.hash;
    // Re-entering reconciliation on another notification is not evidence of progress.
    TEST_CHECK(managed_space_should_execute_action(&ms, &o, action), false);
    ++o.hash;
    TEST_CHECK(managed_space_should_execute_action(&ms, &o, action), true);
    ms.last_action_observation = o.hash;
    managed_space_note_reconcile_result(&ms, SPACE_OP_ERROR_INVALID_SRC);
    TEST_CHECK(managed_space_should_execute_action(&ms, &o, action), false);
    managed_space_note_reconcile_result(&ms, SPACE_OP_ERROR_DISPLAY_IS_ANIMATING);
    TEST_CHECK(managed_space_should_execute_action(&ms, &o, action), true);
    ms.last_action_key = managed_space_action_key(action); ms.last_action_observation = o.hash;
    managed_space_note_reconcile_result(&ms, SPACE_OP_ERROR_IN_MISSION_CONTROL);
    TEST_CHECK(managed_space_should_execute_action(&ms, &o, action), true);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_planner_orders_slots_with_interleaved_display_affinity,
{
    struct managed_space ms; struct managed_space_observation o; managed_space_test_fixture(&ms, &o);
    struct managed_space_observed_display display = ((struct managed_space_observed_display) {
        .did = 2, .uuid = CFRetain(CFSTR("secondary")), .active_sid = 33 });
    struct managed_space_observed_space space = ((struct managed_space_observed_space) {
        .sid = 33, .uuid = CFRetain(CFSTR("pinned")), .did = 2, .index = 3, .normal = true });
    struct managed_space_entry pinned = ((struct managed_space_entry) {
        .uuid = CFRetain(CFSTR("pinned")), .sid = 33, .order = 2,
        .display_affinity = MANAGED_SPACE_DISPLAY_FIXED, .preferred_display_uuid = CFRetain(CFSTR("secondary")) });
    buf_push(o.displays, display); buf_push(o.spaces, space); buf_push(ms.spaces, pinned);
    struct managed_space_entry last = ms.spaces[1]; ms.spaces[1] = ms.spaces[2]; ms.spaces[2] = last;
    ms.spaces[2].order = 3;
    // Desired main-A, secondary-B, main-C; observed main-C, main-A.
    o.spaces[0].index = 2; o.spaces[1].index = 1;
    struct managed_space_action action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_REORDER);
    TEST_CHECK((int) action.sid, 11);
    TEST_CHECK((int) action.target_sid, 22);
    o.spaces[0].index = 1; o.spaces[1].index = 2; o.windows[0].sid = 11;
    action = managed_space_plan(&ms, &o);
    TEST_CHECK(action.type, MANAGED_SPACE_ACTION_NONE);
    managed_space_destroy_observation(&o); managed_space_destroy(&ms);
});
