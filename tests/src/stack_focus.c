static inline struct window_node test_stack_focus_node(uint32_t *window_list, int window_count)
{
    struct window_node node = {0};
    node.window_count = window_count;

    for (int i = 0; i < window_count; ++i) {
        node.window_list[i] = window_list[i];
        node.window_order[i] = window_list[i];
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

TEST_FUNC(stack_insert_source_after_right_side_target_edge,
{
    uint32_t windows[2];
    windows[0] = 101;
    windows[1] = 103;
    struct window_node target = test_stack_focus_node(windows, array_count(windows));
    target.area.x = 0;
    target.area.y = 0;
    target.area.w = 100;
    target.area.h = 100;

    struct window_node source_node = {0};
    source_node.area.x = 200;
    source_node.area.y = 0;
    source_node.area.w = 100;
    source_node.area.h = 100;

    struct window source = { .id = 102 };
    bool insert_after = window_manager_stack_source_after_target(&source_node, &target, &source);
    view_stack_window_node_at_index(&target, &source, insert_after ? target.window_count : 0);

    TEST_CHECK(insert_after, true);
    TEST_CHECK(target.window_count, 3);
    TEST_CHECK(target.window_list[0], 101);
    TEST_CHECK(target.window_list[1], 103);
    TEST_CHECK(target.window_list[2], 102);
    TEST_CHECK(target.window_order[0], 102);
    TEST_CHECK(target.window_order[1], 101);
    TEST_CHECK(target.window_order[2], 103);
});

TEST_FUNC(stack_insert_source_before_left_side_target_edge,
{
    uint32_t windows[2];
    windows[0] = 102;
    windows[1] = 103;
    struct window_node target = test_stack_focus_node(windows, array_count(windows));
    target.area.x = 200;
    target.area.y = 0;
    target.area.w = 100;
    target.area.h = 100;

    struct window_node source_node = {0};
    source_node.area.x = 0;
    source_node.area.y = 0;
    source_node.area.w = 100;
    source_node.area.h = 100;

    struct window source = { .id = 101 };
    bool insert_after = window_manager_stack_source_after_target(&source_node, &target, &source);
    view_stack_window_node_at_index(&target, &source, insert_after ? target.window_count : 0);

    TEST_CHECK(insert_after, false);
    TEST_CHECK(target.window_count, 3);
    TEST_CHECK(target.window_list[0], 101);
    TEST_CHECK(target.window_list[1], 102);
    TEST_CHECK(target.window_list[2], 103);
    TEST_CHECK(target.window_order[0], 101);
    TEST_CHECK(target.window_order[1], 102);
    TEST_CHECK(target.window_order[2], 103);
});

TEST_FUNC(stack_remove_non_active_source_preserves_logical_order_and_active,
{
    uint32_t windows[3];
    windows[0] = 101;
    windows[1] = 102;
    windows[2] = 103;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));
    node.window_order[0] = 102;
    node.window_order[1] = 101;
    node.window_order[2] = 103;
    node.recent_window_id = 101;

    struct view view = { .root = &node };
    struct window source = { .id = 103 };
    view_remove_window_node(&view, &source);

    TEST_CHECK(node.window_count, 2);
    TEST_CHECK(node.window_list[0], 101);
    TEST_CHECK(node.window_list[1], 102);
    TEST_CHECK(node.window_order[0], 102);
    TEST_CHECK(node.window_order[1], 101);
    TEST_CHECK(node.recent_window_id, 101);
});

TEST_FUNC(stack_window_rejects_same_stack,
{
    uint32_t windows[2];
    windows[0] = 101;
    windows[1] = 102;
    struct window_node node = test_stack_focus_node(windows, array_count(windows));
    struct view view = {0};
    view.root = &node;
    view.layout = VIEW_BSP;

    struct window source = { .id = 101 };
    struct window target = { .id = 102 };
    struct window_manager wm = {0};
    table_init(&wm.managed_window, 8, hash_wm, compare_wm);
    table_add(&wm.managed_window, &source.id, &view);
    table_add(&wm.managed_window, &target.id, &view);

    enum window_op_error result = window_manager_stack_window(&g_space_manager, &wm, &source, &target);
    TEST_CHECK(result, WINDOW_OP_ERROR_SAME_STACK);
});
