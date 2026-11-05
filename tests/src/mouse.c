static inline struct window test_mouse_window(float x, float y, float w, float h)
{
    struct window window = {0};
    window.frame = (CGRect) {{ x, y }, { w, h }};
    return window;
}

static inline struct window_node test_mouse_node(int window_count)
{
    struct window_node node = {0};
    node.window_count = window_count;
    return node;
}

TEST_FUNC(mouse_drop_action_modifier_inherits_default,
{
    struct mouse_state ms = {0};
    mouse_state_init(&ms);
    ms.modifier = MOUSE_MOD_ALT;
    ms.drop_action = MOUSE_MODE_STACK;

    struct window_node src_node = test_mouse_node(1);
    struct window dst_window = test_mouse_window(0, 0, 400, 400);
    CGPoint center;
    center.x = 200;
    center.y = 200;

    enum mouse_drop_action normal = mouse_determine_drop_action(&ms, &src_node, &dst_window, center, MOUSE_MOD_NONE);
    TEST_CHECK(normal, MOUSE_DROP_ACTION_STACK);

    enum mouse_drop_action modified = mouse_determine_drop_action(&ms, &src_node, &dst_window, center, MOUSE_MOD_ALT);
    TEST_CHECK(modified, MOUSE_DROP_ACTION_STACK);
});

TEST_FUNC(mouse_drop_action_modifier_overrides_center_drop,
{
    struct mouse_state ms = {0};
    mouse_state_init(&ms);
    ms.modifier = MOUSE_MOD_ALT;
    ms.drop_action = MOUSE_MODE_SWAP;
    ms.drop_action_modifier = MOUSE_MODE_STACK;
    ms.drop_action_modifier_configured = true;

    struct window_node src_node = test_mouse_node(1);
    struct window dst_window = test_mouse_window(0, 0, 400, 400);
    CGPoint center;
    center.x = 200;
    center.y = 200;

    enum mouse_drop_action normal = mouse_determine_drop_action(&ms, &src_node, &dst_window, center, MOUSE_MOD_NONE);
    TEST_CHECK(normal, MOUSE_DROP_ACTION_SWAP);

    enum mouse_drop_action modified = mouse_determine_drop_action(&ms, &src_node, &dst_window, center, MOUSE_MOD_ALT);
    TEST_CHECK(modified, MOUSE_DROP_ACTION_STACK);
});

TEST_FUNC(mouse_drop_action_modifier_uses_exact_modifier_match,
{
    struct mouse_state ms = {0};
    mouse_state_init(&ms);
    ms.modifier = MOUSE_MOD_ALT;
    ms.drop_action = MOUSE_MODE_SWAP;
    ms.drop_action_modifier = MOUSE_MODE_STACK;
    ms.drop_action_modifier_configured = true;

    struct window_node src_node = test_mouse_node(1);
    struct window dst_window = test_mouse_window(0, 0, 400, 400);
    CGPoint center;
    center.x = 200;
    center.y = 200;

    enum mouse_drop_action modified = mouse_determine_drop_action(&ms, &src_node, &dst_window, center, MOUSE_MOD_ALT | MOUSE_MOD_SHIFT);
    TEST_CHECK(modified, MOUSE_DROP_ACTION_SWAP);
});

TEST_FUNC(mouse_drop_action_modifier_does_not_affect_warp_zones,
{
    struct mouse_state ms = {0};
    mouse_state_init(&ms);
    ms.modifier = MOUSE_MOD_ALT;
    ms.drop_action = MOUSE_MODE_SWAP;
    ms.drop_action_modifier = MOUSE_MODE_STACK;
    ms.drop_action_modifier_configured = true;

    struct window_node src_node = test_mouse_node(1);
    struct window dst_window = test_mouse_window(0, 0, 400, 400);
    CGPoint bottom;
    bottom.x = 200;
    bottom.y = 350;

    enum mouse_drop_action normal = mouse_determine_drop_action(&ms, &src_node, &dst_window, bottom, MOUSE_MOD_NONE);
    TEST_CHECK(normal, MOUSE_DROP_ACTION_WARP_BOTTOM);

    enum mouse_drop_action modified = mouse_determine_drop_action(&ms, &src_node, &dst_window, bottom, MOUSE_MOD_ALT);
    TEST_CHECK(modified, MOUSE_DROP_ACTION_WARP_BOTTOM);
});

TEST_FUNC(mouse_empty_drop_feedback_uses_destination_tiling_area,
{
    struct view src_view = ((struct view) { .sid = 1, .layout = VIEW_BSP });
    struct window_node root = ((struct window_node) { .area = { -1712, 51, 1696, 1034 } });
    struct view dst_view = ((struct view) { .sid = 2, .layout = VIEW_BSP, .root = &root });
    struct area area = {0};

    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), true);
    TEST_CHECK((int) area.x, -1712);
    TEST_CHECK((int) area.y, 51);
    TEST_CHECK((int) area.w, 1696);
    TEST_CHECK((int) area.h, 1034);

    dst_view.layout = VIEW_STACK;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), true);
});

TEST_FUNC(mouse_empty_drop_feedback_rejects_invalid_destinations,
{
    struct view src_view = ((struct view) { .sid = 1, .layout = VIEW_BSP });
    struct window_node root = ((struct window_node) { .area = { 0, 0, 1000, 800 } });
    struct window_node child = {0};
    struct view dst_view = ((struct view) { .sid = 2, .layout = VIEW_BSP, .root = &root });
    struct area area = {0};

    dst_view.sid = src_view.sid;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), false);
    dst_view.sid = 2;
    dst_view.layout = VIEW_FLOAT;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), false);
    dst_view.layout = VIEW_BSP;
    root.window_count = 1;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), false);
    root.window_count = 0;
    root.left = &child;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), false);
    root.left = NULL;
    root.area.w = 0;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), false);
    dst_view.root = NULL;
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, &dst_view, &area), false);
    TEST_CHECK(mouse_empty_drop_feedback_area(&src_view, NULL, &area), false);
});

TEST_FUNC(mouse_drop_feedback_cleanup_ignores_retired_nodes,
{
    struct table saved_feedback = g_window_manager.insert_feedback;
    table_init(&g_window_manager.insert_feedback, 8, hash_wm, compare_wm);

    struct window_node retired_node = { .insert_dir = DIR_NORTH };
    struct mouse_state ms = ((struct mouse_state) {
        .feedback_node = &retired_node,
        .feedback_window_id = 123,
        .empty_feedback_sid = 99,
    });
    mouse_clear_drop_feedback(&ms);
    TEST_CHECK(ms.feedback_node == NULL, true);
    TEST_CHECK(ms.feedback_window_id, 0);
    TEST_CHECK((int) ms.empty_feedback_sid, 0);

    struct window_node live_node = ((struct window_node) { .window_count = 1, .window_order = { 42 }, .insert_dir = DIR_EAST });
    table_add(&g_window_manager.insert_feedback, &live_node.window_order[0], &live_node);
    ms.feedback_node = &live_node;
    mouse_clear_drop_feedback(&ms);
    TEST_CHECK(live_node.insert_dir, DIR_EAST);
    mouse_clear_drop_feedback(&ms);
    TEST_CHECK(ms.feedback_node == NULL, true);

    table_free(&g_window_manager.insert_feedback);
    g_window_manager.insert_feedback = saved_feedback;
});

TEST_FUNC(mouse_drop_feedback_identity_requires_live_window,
{
    struct window_node original = ((struct window_node) { .feedback_window = { .id = 100 } });
    struct window_node replacement = original;
    struct mouse_state ms = ((struct mouse_state) { .feedback_node = &original, .feedback_window_id = 100 });

    TEST_CHECK(mouse_owns_drop_feedback(&ms, &original), true);
    TEST_CHECK(mouse_owns_drop_feedback(&ms, &replacement), false);
    original.feedback_window.id = 101;
    TEST_CHECK(mouse_owns_drop_feedback(&ms, &original), false);
    original.feedback_window.id = 0;
    ms.feedback_window_id = 0;
    TEST_CHECK(mouse_owns_drop_feedback(&ms, &original), false);
});

TEST_FUNC(mouse_handler_teardown_cancels_drag_without_live_tap,
{
    struct managed_space saved_managed_space = g_managed_space;
    g_managed_space = ((struct managed_space) { .enabled = true, .is_reconciling = true });
    buf_push(g_managed_space.drag_windows, 42);

    struct window window = { .id = 42 };
    struct mouse_state ms = ((struct mouse_state) { .window = &window, .current_action = MOUSE_MODE_MOVE });
    mouse_handler_end(&ms);
    TEST_CHECK(ms.window == NULL, true);
    TEST_CHECK(ms.current_action, MOUSE_MODE_NONE);
    TEST_CHECK(buf_len(g_managed_space.drag_windows), 0);
    TEST_CHECK(g_managed_space.pending_reconcile, true);

    buf_free(g_managed_space.drag_windows);
    g_managed_space = saved_managed_space;
});

TEST_FUNC(mouse_drop_feedback_transfer_preserves_ownership,
{
    struct table saved_feedback = g_window_manager.insert_feedback;
    struct mouse_state saved_mouse_state = g_mouse_state;
    table_init(&g_window_manager.insert_feedback, 8, hash_wm, compare_wm);

    struct window_node child = ((struct window_node) {
        .window_count = 1, .window_order = { 42 }, .insert_dir = DIR_EAST, .feedback_window = { .id = 100 },
    });
    struct window_node parent = child;
    g_mouse_state = ((struct mouse_state) { .feedback_node = &child, .feedback_window_id = 100 });
    table_add(&g_window_manager.insert_feedback, &child.window_order[0], &child);
    insert_feedback_rebind_node(&child, &parent);
    TEST_CHECK(table_find(&g_window_manager.insert_feedback, &parent.window_order[0]) == &parent, true);
    TEST_CHECK(mouse_owns_drop_feedback(&g_mouse_state, &parent), true);

    struct window_node unrelated = ((struct window_node) { .insert_dir = DIR_NORTH, .feedback_window = { .id = 200 } });
    TEST_CHECK(insert_feedback_cancel_mouse_owner(&unrelated), false);
    TEST_CHECK(unrelated.insert_dir, DIR_NORTH);
    TEST_CHECK(insert_feedback_cancel_mouse_owner(&parent), true);
    TEST_CHECK(parent.insert_dir, 0);
    TEST_CHECK(g_mouse_state.feedback_node == NULL, true);
    TEST_CHECK(g_mouse_state.feedback_window_id, 0);

    table_free(&g_window_manager.insert_feedback);
    g_window_manager.insert_feedback = saved_feedback;
    g_mouse_state = saved_mouse_state;
});

TEST_FUNC(mouse_drag_cancel_after_native_tab_handoff_clears_batch,
{
    struct managed_space saved_managed_space = g_managed_space;
    struct mouse_state saved_mouse_state = g_mouse_state;
    struct table saved_windows = g_window_manager.window;
    g_managed_space = ((struct managed_space) { .enabled = true, .is_reconciling = true });
    table_init(&g_window_manager.window, 8, hash_wm, compare_wm);

    struct application application = {0};
    struct window old_child = ((struct window) {
        .id = 10, .flags = WINDOW_TAB, .tab_parent_id = 20, .application = &application,
    });
    struct window new_parent = ((struct window) {
        .id = 20, .flags = WINDOW_TAB_PARENT, .application = &application,
    });
    old_child.id_ptr = &old_child.id;
    new_parent.id_ptr = &new_parent.id;
    table_add(&g_window_manager.window, &old_child.id, &old_child);
    table_add(&g_window_manager.window, &new_parent.id, &new_parent);
    buf_push(g_managed_space.drag_windows, new_parent.id);
    g_mouse_state = ((struct mouse_state) { .window = &old_child, .current_action = MOUSE_MODE_MOVE });

    cancel_mouse_drag(old_child.id);
    TEST_CHECK(g_mouse_state.window == NULL, true);
    TEST_CHECK(g_mouse_state.current_action, MOUSE_MODE_NONE);
    TEST_CHECK(buf_len(g_managed_space.drag_windows), 0);
    TEST_CHECK(g_managed_space.pending_reconcile, true);

    buf_free(g_managed_space.drag_windows);
    table_free(&g_window_manager.window);
    g_window_manager.window = saved_windows;
    g_mouse_state = saved_mouse_state;
    g_managed_space = saved_managed_space;
});
