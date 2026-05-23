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
