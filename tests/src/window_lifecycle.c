TEST_FUNC(window_fullscreen_space_membership_overrides_lagging_ax_and_preserves_unknown,
{
    bool fullscreen = false;
    int types[2];
    types[0] = 4;
    TEST_CHECK(window_manager_fullscreen_from_space_types(types, 1, &fullscreen), true);
    TEST_CHECK(fullscreen, true);

    // An exit must clear stale cached/AX fullscreen state even if no final AX
    // resize notification accompanies the authoritative Space change.
    types[0] = 0;
    TEST_CHECK(window_manager_fullscreen_from_space_types(types, 1, &fullscreen), true);
    TEST_CHECK(fullscreen, false);

    // A transition can temporarily list both the origin and native Space.
    types[1] = 4;
    TEST_CHECK(window_manager_fullscreen_from_space_types(types, 2, &fullscreen), true);
    TEST_CHECK(fullscreen, true);

    // Unknown, absent and system-only membership cannot manufacture an exit.
    TEST_CHECK(window_manager_fullscreen_from_space_types(NULL, 0, &fullscreen), false);
    TEST_CHECK(fullscreen, true);
    types[0] = -1;
    TEST_CHECK(window_manager_fullscreen_from_space_types(types, 1, &fullscreen), false);
    TEST_CHECK(fullscreen, true);
    types[0] = 2;
    TEST_CHECK(window_manager_fullscreen_from_space_types(types, 1, &fullscreen), false);
    TEST_CHECK(fullscreen, true);
    types[0] = 0;
    types[1] = -1;
    TEST_CHECK(window_manager_fullscreen_from_space_types(types, 2, &fullscreen), false);
    TEST_CHECK(fullscreen, true);
});
