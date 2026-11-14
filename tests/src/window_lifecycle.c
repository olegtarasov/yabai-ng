TEST_FUNC(window_space_id_decode_normalizes_numeric_width,
{
    int32_t small = 9;
    int64_t large = ((int64_t)1 << 40) + 9;
    CFNumberRef narrow = CFNumberCreate(NULL, kCFNumberSInt32Type, &small);
    CFNumberRef wide = CFNumberCreate(NULL, kCFNumberSInt64Type, &large);
    uint64_t sid = UINT64_C(0xdeadbeef00000000);
    TEST_CHECK(window_space_decode_id(narrow, &sid), true);
    TEST_CHECK(sid == (uint64_t)small, true);
    TEST_CHECK(window_space_decode_id(wide, &sid), true);
    TEST_CHECK(sid == (uint64_t)large, true);
    TEST_CHECK(window_space_decode_id(NULL, &sid), false);
    TEST_CHECK(sid == 0, true);
    CFRelease(narrow); CFRelease(wide);
});

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
