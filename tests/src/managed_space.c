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

TEST_FUNC(managed_space_sip_fallback_destroy_preserves_remaining_uuid_order_after_sid_refresh,
{
    struct managed_space ms;
    managed_space_init(&ms);

    struct managed_space_entry first = {0};
    first.uuid = CFStringCreateCopy(NULL, CFSTR("first"));
    first.name = string_copy("1");
    struct managed_space_entry second = {0};
    second.uuid = CFStringCreateCopy(NULL, CFSTR("second"));
    second.sid = 22;
    second.name = string_copy("2");
    struct managed_space_entry third = {0};
    third.uuid = CFStringCreateCopy(NULL, CFSTR("third"));
    third.sid = 33;
    third.name = string_copy("3");
    buf_push(ms.spaces, first);
    buf_push(ms.spaces, second);
    buf_push(ms.spaces, third);

    TEST_CHECK(managed_space_remove_entry_ordered_by_uuid_string(&ms, "first"), true);
    TEST_CHECK(buf_len(ms.spaces), 2);
    TEST_CHECK((int) ms.spaces[0].sid, 22);
    TEST_CHECK(CFEqual(ms.spaces[0].uuid, CFSTR("second")), true);
    TEST_CHECK((int) ms.spaces[1].sid, 33);
    TEST_CHECK(CFEqual(ms.spaces[1].uuid, CFSTR("third")), true);

    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_scripting_addition_destroy_preserves_primary_swap_delete_semantics,
{
    struct managed_space ms;
    managed_space_init(&ms);

    struct managed_space_entry first = { .sid = 11 };
    struct managed_space_entry second = { .sid = 22 };
    struct managed_space_entry third = { .sid = 33 };
    buf_push(ms.spaces, first);
    buf_push(ms.spaces, second);
    buf_push(ms.spaces, third);

    TEST_CHECK(managed_space_remove_entry_scripting_addition(&ms, 11), true);
    TEST_CHECK(buf_len(ms.spaces), 2);
    TEST_CHECK((int) ms.spaces[0].sid, 33);
    TEST_CHECK((int) ms.spaces[1].sid, 22);

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
    struct managed_space_entry home = {0};
    home.uuid = CFRetain(CFSTR("home"));
    home.sid = 11;
    buf_push(ms.spaces, home);
    managed_space_set_window_namespace(&ms, NULL, 1, CFSTR("home"));
    managed_space_set_window_namespace(&ms, NULL, 2, CFSTR("home"));
    struct window source = {0};
    source.id = 1;
    struct window peer = {0};
    peer.id = 3;
    managed_space_begin_window_drag(&ms, &source);
    managed_space_track_window_drag(&ms, &peer);
    managed_space_track_window_drag(&ms, &source);
    TEST_CHECK(buf_len(ms.drag_windows), 2);
    TEST_CHECK(managed_space_window_needs_repair(&ms, &ms.windows[0], 22, 0), false);
    TEST_CHECK(managed_space_window_needs_repair(&ms, &ms.windows[1], 22, 0), true);

    managed_space_cancel_window_drag(&ms, 9);
    TEST_CHECK(buf_len(ms.drag_windows), 2);
    managed_space_cancel_window_drag(&ms, 1);
    TEST_CHECK(buf_len(ms.drag_windows), 0);
    TEST_CHECK(managed_space_window_needs_repair(&ms, &ms.windows[0], 22, 0), true);
    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_secondary_residence_repairs_delayed_transfer_and_recovers_home_when_absent,
{
    struct managed_space ms;
    managed_space_init(&ms);
    struct managed_space_entry home = {0};
    home.uuid = CFRetain(CFSTR("home"));
    home.sid = 11;
    buf_push(ms.spaces, home);
    managed_space_set_window_namespace(&ms, NULL, 1, CFSTR("home"));
    managed_space_set_secondary_residence(&ms, 1, CFSTR("secondary"));
    struct managed_window_entry *window = &ms.windows[0];
    TEST_CHECK(CFEqual(window->space_uuid, CFSTR("home")), true);
    TEST_CHECK((int) managed_space_window_repair_target(&ms, window, 22), 22);
    TEST_CHECK(managed_space_window_needs_repair(&ms, window, 11, 22), true);
    TEST_CHECK(managed_space_window_needs_repair(&ms, window, 22, 22), false);
    TEST_CHECK((int) managed_space_window_repair_target(&ms, window, 0), 11);
    TEST_CHECK(managed_space_window_needs_repair(&ms, window, 22, 0), true);

    // Invalidating the vanished secondary destination prevents automatic replug return.
    managed_space_clear_secondary_residence(window);
    TEST_CHECK((int) managed_space_window_repair_target(&ms, window, 22), 11);
    managed_space_set_secondary_residence(&ms, 1, CFSTR("secondary"));

    // Returning home clears residence even when the managed UUID itself did not change.
    managed_space_set_window_namespace(&ms, window, 1, CFSTR("home"));
    TEST_CHECK(window->secondary_space_uuid == NULL, true);
    TEST_CHECK((int) managed_space_window_repair_target(&ms, window, 22), 11);
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
    TEST_CHECK((int) managed_space_window_repair_target(&ms, &ms.windows[2], 22), 22);
    TEST_CHECK((int) managed_space_window_repair_target(&ms, &ms.windows[2], 0), 0);

    managed_space_set_window_namespace(&ms, &ms.windows[0], 1, CFSTR("new-home"));
    TEST_CHECK(ms.windows[0].secondary_space_uuid == NULL, true);
    TEST_CHECK(CFEqual(ms.windows[0].space_uuid, CFSTR("new-home")), true);
    TEST_CHECK(CFEqual(ms.windows[1].space_uuid, CFSTR("other-home")), true);
    TEST_CHECK(ms.windows[1].secondary_space_uuid == NULL, true);
    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_pending_placeholder_matching_is_display_scoped_and_preserves_replacement,
{
    struct managed_space ms;
    managed_space_init(&ms);
    ms.pending_replacement_order = 7;
    struct managed_space_create_request user = {0};
    user.display_uuid = CFRetain(CFSTR("display-a"));
    user.managed = true;
    struct managed_space_create_request placeholder = {0};
    placeholder.display_uuid = CFRetain(CFSTR("display-b"));
    buf_push(ms.pending_creates, user);
    buf_push(ms.pending_creates, placeholder);
    ms.pending_user_creates = 1;

    TEST_CHECK(managed_space_find_pending_placeholder_create_for_uuid(&ms, CFSTR("display-a")), -1);
    int index = managed_space_find_pending_placeholder_create_for_uuid(&ms, CFSTR("display-b"));
    TEST_CHECK(index, 1);
    managed_space_remove_pending_create_at_index(&ms, index);
    TEST_CHECK(ms.pending_replacement_order, 7);
    TEST_CHECK(ms.pending_user_creates, 1);
    TEST_CHECK(buf_len(ms.pending_creates), 1);
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

TEST_FUNC(managed_space_create_ownership_preserves_same_display_fifo_with_replacement,
{
    for (int placeholder_first = 0; placeholder_first < 2; ++placeholder_first) {
        struct managed_space ms;
        managed_space_init(&ms);
        struct managed_space_create_request user = {0};
        user.display_uuid = CFRetain(CFSTR("display"));
        user.managed = true;
        user.sequence = placeholder_first ? 3 : 1;
        struct managed_space_create_request placeholder = {0};
        placeholder.display_uuid = CFRetain(CFSTR("display"));
        placeholder.sequence = placeholder_first ? 1 : 3;
        buf_push(ms.pending_creates, user);
        buf_push(ms.pending_creates, placeholder);
        ms.pending_user_creates = 1;
        ms.pending_replacement_order = 7;
        ms.pending_replacement_sequence = 2;
        ms.pending_replacement_display_uuid = CFRetain(CFSTR("display"));

        TEST_CHECK(managed_space_created_space_owner(&ms, CFSTR("other-display")), MANAGED_SPACE_CREATE_OWNER_NONE);
        int owner = managed_space_created_space_owner(&ms, CFSTR("display"));
        TEST_CHECK(owner, placeholder_first ? 1 : 0);
        TEST_CHECK(ms.pending_creates[owner].managed, !placeholder_first);
        managed_space_remove_pending_create_at_index(&ms, owner);
        TEST_CHECK(managed_space_created_space_owner(&ms, CFSTR("display")), MANAGED_SPACE_CREATE_OWNER_REPLACEMENT);
        TEST_CHECK(ms.pending_replacement_order, 7);
        managed_space_clear_replacement_ticket(&ms);
        owner = managed_space_created_space_owner(&ms, CFSTR("display"));
        TEST_CHECK(owner, 0);
        TEST_CHECK(ms.pending_creates[owner].managed, placeholder_first);
        managed_space_remove_pending_create_at_index(&ms, owner);
        TEST_CHECK(managed_space_created_space_owner(&ms, CFSTR("display")), MANAGED_SPACE_CREATE_OWNER_NONE);
        managed_space_destroy(&ms);
    }
});

TEST_FUNC(managed_space_create_cancellation_and_delayed_receipts_preserve_newer_ownership,
{
    struct managed_space ms;
    managed_space_init(&ms);
    struct managed_space_create_request first = {0};
    first.display_uuid = CFRetain(CFSTR("display"));
    first.sequence = 1;
    first.managed = true;
    struct managed_space_create_request placeholder = {0};
    placeholder.display_uuid = CFRetain(CFSTR("display"));
    placeholder.sequence = 2;
    struct managed_space_create_request last = {0};
    last.display_uuid = CFRetain(CFSTR("display"));
    last.sequence = 3;
    last.managed = true;
    buf_push(ms.pending_creates, placeholder);
    buf_push(ms.pending_creates, last);
    buf_push(ms.pending_creates, first);
    managed_space_remove_last_pending_user_create(&ms);
    TEST_CHECK(buf_len(ms.pending_creates), 2);
    int owner = managed_space_created_space_owner(&ms, CFSTR("display"));
    TEST_CHECK((int) ms.pending_creates[owner].sequence, 1);

    buf_push(ms.replacement_receipts, CFRetain(CFSTR("rebound-space")));
    TEST_CHECK(managed_space_consume_replacement_receipt(&ms, CFSTR("unrelated-space")), false);
    TEST_CHECK(managed_space_consume_replacement_receipt(&ms, CFSTR("rebound-space")), true);
    TEST_CHECK(buf_len(ms.replacement_receipts), 0);
    TEST_CHECK(managed_space_created_space_owner(&ms, CFSTR("display")), owner);
    TEST_CHECK(managed_space_consume_replacement_receipt(&ms, CFSTR("rebound-space")), false);
    managed_space_destroy(&ms);
});

TEST_FUNC(managed_space_sip_fallback_create_failure_after_event_preserves_next_pending_owner,
{
    struct managed_space ms;
    managed_space_init(&ms);
    ms.enabled = true;
    ms.event_posted = true;
    struct managed_space_create_request first = {0};
    first.display_uuid = CFRetain(CFSTR("display"));
    first.sequence = 1;
    first.managed = true;
    struct managed_space_create_request next = {0};
    next.display_uuid = CFRetain(CFSTR("display"));
    next.sequence = 2;
    next.managed = true;
    buf_push(ms.pending_creates, first);
    buf_push(ms.pending_creates, next);
    managed_space_remove_pending_create_at_index(&ms, 0);
    TEST_CHECK(managed_space_failed_create_owner(&ms, CFSTR("display"), false), 0);
    TEST_CHECK(managed_space_failed_create_owner(&ms, CFSTR("display"), true), MANAGED_SPACE_CREATE_OWNER_NONE);

    struct managed_space_sip_fallback_request failed = {0};
    failed.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE;
    failed.origin = MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND;
    failed.topology_event_observed = true;
    managed_space_handle_sip_fallback_operation_failed(&ms, &failed);
    TEST_CHECK(buf_len(ms.pending_creates), 1);
    TEST_CHECK(ms.pending_user_creates, 1);
    TEST_CHECK((int) ms.pending_creates[0].sequence, 2);
    TEST_CHECK(managed_space_created_space_owner(&ms, CFSTR("display")), 0);
    managed_space_destroy(&ms);
});
