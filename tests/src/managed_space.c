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

TEST_FUNC(managed_space_sip_safe_destroy_preserves_remaining_uuid_order_after_sid_refresh,
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

TEST_FUNC(managed_space_legacy_destroy_keeps_pre_sip_safe_swap_delete_semantics,
{
    struct managed_space ms;
    managed_space_init(&ms);

    struct managed_space_entry first = { .sid = 11 };
    struct managed_space_entry second = { .sid = 22 };
    struct managed_space_entry third = { .sid = 33 };
    buf_push(ms.spaces, first);
    buf_push(ms.spaces, second);
    buf_push(ms.spaces, third);

    TEST_CHECK(managed_space_remove_entry_legacy(&ms, 11), true);
    TEST_CHECK(buf_len(ms.spaces), 2);
    TEST_CHECK((int) ms.spaces[0].sid, 33);
    TEST_CHECK((int) ms.spaces[1].sid, 22);

    managed_space_destroy(&ms);
});
