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
    struct view view = ((struct view) {.root = &node, .insertion_point = 10});
    TEST_CHECK(view_replace_window_id(&view, 10, 20), true);
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

TEST_FUNC(native_tab_slot_handoff_preserves_recent_history_and_rejects_duplicate_identity,
{
    struct window_node node = ((struct window_node) {
        .window_count = 3, .window_list = {7, 10, 9}, .window_order = {7, 10, 9}, .recent_window_id = 10,
    });
    struct view view = ((struct view) { .root = &node, .insertion_point = 10 });

    // A background representative retirement must retain the recent logical
    // slot without relying on a later focus event to repair its history.
    TEST_CHECK(view_replace_window_id(&view, 10, 20), true);
    TEST_CHECK(node.window_list[1], 20);
    TEST_CHECK(node.window_order[0], 7);
    TEST_CHECK(node.recent_window_id, 20);
    TEST_CHECK(window_node_contains_window(&node, node.recent_window_id), true);
    TEST_CHECK(view.insertion_point, 20);

    TEST_CHECK(view_replace_window_id(&view, 20, 9), false);
    TEST_CHECK(view_replace_window_id(&view, 20, 0), false);
    TEST_CHECK(view_replace_window_id(&view, 30, 40), false);
    TEST_CHECK(node.window_count, 3);
    TEST_CHECK(node.window_list[1], 20);
    TEST_CHECK(node.recent_window_id, 20);
    TEST_CHECK(view.insertion_point, 20);

    TEST_CHECK(window_node_activate_window(&node, 20), true);
    TEST_CHECK(node.window_order[0], 20);
    TEST_CHECK(node.recent_window_id, 7);
    TEST_CHECK(node.window_list[0], 7);
    TEST_CHECK(node.window_list[1], 20);
});

TEST_FUNC(native_tab_focus_history_tracks_logical_slots_without_fabricating_focus,
{
    struct window_manager wm = {0};
    struct application application = {0};
    struct window parent = ((struct window) { .id = 10, .application = &application, .flags = WINDOW_TAB_PARENT, .rule_flags = WINDOW_RULE_TAB });
    struct window selected = ((struct window) { .id = 20, .application = &application, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB });
    struct window other = ((struct window) { .id = 30, .application = &application });
    parent.id_ptr = &parent.id;
    selected.id_ptr = &selected.id;
    other.id_ptr = &other.id;
    table_init(&wm.window, 8, hash_wm, compare_wm);
    table_add(&wm.window, &parent.id, &parent);
    table_add(&wm.window, &selected.id, &selected);
    table_add(&wm.window, &other.id, &other);
    wm.focused_window_id = parent.id;
    wm.last_window_id = other.id;

    native_tab_reparent_members(&wm, &parent, &selected, false);
    TEST_CHECK(wm.focused_window_id, parent.id);
    window_manager_record_window_focus(&wm, &selected);
    TEST_CHECK(wm.focused_window_id, selected.id);
    TEST_CHECK(wm.last_window_id, other.id);

    window_manager_record_window_focus(&wm, &other);
    TEST_CHECK(wm.focused_window_id, other.id);
    TEST_CHECK(wm.last_window_id, selected.id);

    // Retiring a background representative transfers recent-slot identity but
    // leaves observed frontmost focus untouched until an actual focus event.
    native_tab_reparent_members(&wm, &selected, &parent, true);
    TEST_CHECK(wm.focused_window_id, other.id);
    TEST_CHECK(wm.last_window_id, parent.id);
    table_free(&wm.window);
});

TEST_FUNC(native_tab_group_move_includes_only_live_recorded_members,
{
    struct window_manager wm = {0};
    struct application application = {0};
    struct application other_application = {0};
    struct window parent = ((struct window) { .id = 10, .application = &application, .flags = WINDOW_TAB_PARENT, .rule_flags = WINDOW_RULE_TAB });
    struct window selected = ((struct window) { .id = 20, .application = &application, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB });
    struct window inactive = ((struct window) { .id = 30, .application = &application, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB });
    struct window retired = ((struct window) { .id = 40, .application = &application, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB });
    struct window unrelated = ((struct window) { .id = 50, .application = &other_application, .flags = WINDOW_TAB, .tab_parent_id = 10, .rule_flags = WINDOW_RULE_TAB });
    struct window detached = ((struct window) { .id = 60, .application = &application, .rule_flags = WINDOW_RULE_TAB });
    parent.id_ptr = &parent.id;
    selected.id_ptr = &selected.id;
    inactive.id_ptr = &inactive.id;
    unrelated.id_ptr = &unrelated.id;
    detached.id_ptr = &detached.id;
    table_init(&wm.window, 8, hash_wm, compare_wm);
    table_add(&wm.window, &parent.id, &parent);
    table_add(&wm.window, &selected.id, &selected);
    table_add(&wm.window, &inactive.id, &inactive);
    table_add(&wm.window, &retired.id, &retired);
    table_add(&wm.window, &unrelated.id, &unrelated);
    table_add(&wm.window, &detached.id, &detached);

    uint32_t *window_list = native_tab_collect_move_windows(&wm, &selected);
    TEST_CHECK(buf_len(window_list), 3);
    TEST_CHECK(window_list[0], selected.id);
    bool found_parent = false;
    bool found_inactive = false;
    for (int i = 0; i < buf_len(window_list); ++i) {
        if (window_list[i] == parent.id) found_parent = true;
        if (window_list[i] == inactive.id) found_inactive = true;
    }
    TEST_CHECK(found_parent, true);
    TEST_CHECK(found_inactive, true);
    buf_free(window_list);

    window_list = native_tab_collect_move_windows(&wm, &detached);
    TEST_CHECK(buf_len(window_list), 1);
    TEST_CHECK(window_list[0], detached.id);
    buf_free(window_list);
    TEST_CHECK(native_tab_collect_move_windows(&wm, &retired) == NULL, true);
    table_free(&wm.window);
});
