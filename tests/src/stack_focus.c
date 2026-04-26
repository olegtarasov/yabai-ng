static inline struct window_node test_stack_focus_node(uint32_t *window_list, int window_count)
{
    struct window_node node = {0};
    node.window_count = window_count;

    for (int i = 0; i < window_count; ++i) {
        node.window_list[i] = window_list[i];
    }

    return node;
}

TEST_FUNC(stack_focus_inside_east_returns_next_logical_window,
{
    uint32_t windows[3];
    windows[0] = 101;
    windows[1] = 102;
    windows[2] = 103;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));

    uint32_t next = window_node_find_stack_window_in_direction(&node, 102, DIR_EAST, true);
    TEST_CHECK(next, 103);
});

TEST_FUNC(stack_focus_inside_west_returns_prev_logical_window,
{
    uint32_t windows[3];
    windows[0] = 101;
    windows[1] = 102;
    windows[2] = 103;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));

    uint32_t prev = window_node_find_stack_window_in_direction(&node, 102, DIR_WEST, true);
    TEST_CHECK(prev, 101);
});

TEST_FUNC(stack_focus_inside_boundary_falls_through,
{
    uint32_t windows[3];
    windows[0] = 101;
    windows[1] = 102;
    windows[2] = 103;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));

    uint32_t past_last = window_node_find_stack_window_in_direction(&node, 103, DIR_EAST, true);
    TEST_CHECK(past_last, 0);

    uint32_t past_first = window_node_find_stack_window_in_direction(&node, 101, DIR_WEST, true);
    TEST_CHECK(past_first, 0);
});

TEST_FUNC(stack_focus_inside_disabled_falls_through,
{
    uint32_t windows[3];
    windows[0] = 101;
    windows[1] = 102;
    windows[2] = 103;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));

    uint32_t next = window_node_find_stack_window_in_direction(&node, 102, DIR_EAST, false);
    TEST_CHECK(next, 0);

    uint32_t prev = window_node_find_stack_window_in_direction(&node, 102, DIR_WEST, false);
    TEST_CHECK(prev, 0);
});

TEST_FUNC(stack_focus_inside_vertical_falls_through,
{
    uint32_t windows[3];
    windows[0] = 101;
    windows[1] = 102;
    windows[2] = 103;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));

    uint32_t north = window_node_find_stack_window_in_direction(&node, 102, DIR_NORTH, true);
    TEST_CHECK(north, 0);

    uint32_t south = window_node_find_stack_window_in_direction(&node, 102, DIR_SOUTH, true);
    TEST_CHECK(south, 0);
});

TEST_FUNC(stack_focus_inside_single_window_falls_through,
{
    uint32_t windows[1];
    windows[0] = 101;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));

    uint32_t next = window_node_find_stack_window_in_direction(&node, 101, DIR_EAST, true);
    TEST_CHECK(next, 0);
});
