TEST_FUNC(native_tab_reparent_preserves_all_members_and_group_float,
{
    struct window_manager wm = {0};
    struct application app = {0}; struct application other_app = {0};
    struct window parent = ((struct window) {.id = 10, .application = &app, .flags = WINDOW_TAB_PARENT | WINDOW_FLOAT, .rule_flags = WINDOW_RULE_TAB});
    struct window selected = ((struct window) {.id = 20, .application = &app, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB});
    struct window child = ((struct window) {.id = 30, .application = &app, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB});
    struct window unrelated = ((struct window) {.id = 40, .application = &other_app, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB});
    parent.id_ptr = &parent.id; selected.id_ptr = &selected.id; child.id_ptr = &child.id; unrelated.id_ptr = &unrelated.id;
    table_init(&wm.window, 8, hash_wm, compare_wm);
    table_add(&wm.window, &parent.id, &parent); table_add(&wm.window, &selected.id, &selected);
    table_add(&wm.window, &child.id, &child); table_add(&wm.window, &unrelated.id, &unrelated);
    native_tab_reparent_members(&wm, &parent, &selected, false);
    TEST_CHECK(parent.tab_parent_id, selected.id);
    TEST_CHECK(child.tab_parent_id, selected.id);
    TEST_CHECK(unrelated.tab_parent_id, 10);
    TEST_CHECK(window_check_flag(&selected, WINDOW_TAB), false);
    TEST_CHECK(window_check_flag(&selected, WINDOW_TAB_PARENT), true);
    TEST_CHECK(window_check_flag(&selected, WINDOW_FLOAT), true);
    TEST_CHECK(window_check_flag(&child, WINDOW_FLOAT), true);
    TEST_CHECK(native_tab_windows_share_group(&selected, &child), true);
    TEST_CHECK(native_tab_windows_share_group(&selected, &unrelated), false);
    table_free(&wm.window);
});

TEST_FUNC(native_tab_parent_retirement_reparents_survivors_without_frame_matching,
{
    struct window_manager wm = {0};
    struct application app = {0};
    struct window parent = ((struct window) {.id = 10, .application = &app, .flags = WINDOW_TAB_PARENT, .rule_flags = WINDOW_RULE_TAB});
    struct window selected = ((struct window) {.id = 20, .application = &app, .flags = WINDOW_TAB | WINDOW_FLOAT, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB});
    struct window child = ((struct window) {.id = 30, .application = &app, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB});
    selected.id_ptr = &selected.id; child.id_ptr = &child.id;
    child.frame = CGRectMake(50, 50, 800, 600);
    table_init(&wm.window, 8, hash_wm, compare_wm);
    table_add(&wm.window, &parent.id, &parent); table_add(&wm.window, &selected.id, &selected); table_add(&wm.window, &child.id, &child);
    native_tab_reparent_members(&wm, &parent, &selected, true);
    TEST_CHECK(window_check_flag(&parent, WINDOW_TAB), false);
    TEST_CHECK(window_check_flag(&selected, WINDOW_FLOAT), false);
    TEST_CHECK(child.tab_parent_id, selected.id);
    TEST_CHECK(native_tab_parent_has_children(&wm, &selected, 0), true);
    table_free(&wm.window);
});

TEST_FUNC(native_tab_slot_transfer_preserves_stack_order_zoom_and_insertion,
{
    struct window_node node = ((struct window_node) {.window_count = 3, .window_list = {7, 10, 9}, .window_order = {10, 9, 7}, .area = {1, 2, 300, 400}});
    struct window_node zoom = ((struct window_node) {0});
    node.zoom = &zoom;
    struct view view = ((struct view) {.insertion_point = 10});
    native_tab_replace_node_window(&view, &node, 10, 20);
    TEST_CHECK(node.window_list[0], 7); TEST_CHECK(node.window_list[1], 20); TEST_CHECK(node.window_list[2], 9);
    TEST_CHECK(node.window_order[0], 20); TEST_CHECK(node.window_order[1], 9); TEST_CHECK(node.window_order[2], 7);
    TEST_CHECK(view.insertion_point, 20); TEST_CHECK(node.zoom == &zoom, true);
    TEST_CHECK((int)node.area.w, 300);
});

TEST_FUNC(native_tab_rule_removal_dissolves_membership_and_group_float_is_shared,
{
    struct window_manager wm = {0};
    struct application app = {0};
    struct window parent = ((struct window) {.id = 10, .application = &app, .flags = WINDOW_TAB_PARENT, .rule_flags = WINDOW_RULE_TAB});
    struct window child = ((struct window) {.id = 20, .application = &app, .flags = WINDOW_TAB | WINDOW_FLOAT, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB});
    parent.id_ptr = &parent.id; child.id_ptr = &child.id;
    table_init(&wm.window, 8, hash_wm, compare_wm);
    table_add(&wm.window, &parent.id, &parent); table_add(&wm.window, &child.id, &child);
    TEST_CHECK(native_tab_managed_window(&wm, &child) == &parent, true);
    native_tab_sync_group_float(&wm, &parent);
    TEST_CHECK(window_check_flag(&child, WINDOW_FLOAT), false);
    window_set_flag(&parent, WINDOW_FLOAT); native_tab_sync_group_float(&wm, &parent);
    TEST_CHECK(window_check_flag(&child, WINDOW_FLOAT), true);
    native_tab_forget_window(&wm, &parent);
    TEST_CHECK(window_check_flag(&parent, WINDOW_TAB_PARENT), false);
    TEST_CHECK(window_check_flag(&child, WINDOW_TAB), false);
    TEST_CHECK(child.tab_parent_id, 0);
    table_free(&wm.window);
});
