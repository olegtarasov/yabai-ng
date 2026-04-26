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
