unsigned char __src_osax_payload[1];
unsigned int __src_osax_payload_len;
unsigned char __src_osax_loader[1];
unsigned int __src_osax_loader_len;

#include "../../src/manifest.m"

#define TEST_SIG(name) bool test_##name(void)
typedef TEST_SIG(function);

#define TEST_FUNC(name, code) static TEST_SIG(name) { char *test_name = #name; bool result = true; {code} return result; }
#define TEST_CHECK(r, e) if ((r) != (e)) { printf("                   \e[1;33m%s\e[m\e[1;31m#%d %s == %s\e[m \e[1;31m(%d == %d)\e[m\n", test_name, __LINE__, #r, #e, r, e); result = false; }

#include "osax.c"
#include "area.c"
#include "mouse.c"
#include "stack_focus.c"
#include "native_tab.c"
#include "window_lifecycle.c"
#include "managed_space.c"

#define TEST_ENTRY(name) { #name, test_##name },
#define TEST_LIST \
    TEST_ENTRY(window_space_id_decode_normalizes_numeric_width) \
    TEST_ENTRY(managed_space_unknown_window_membership_defers_only_that_window) \
    TEST_ENTRY(window_fullscreen_space_membership_overrides_lagging_ax_and_preserves_unknown) \
    TEST_ENTRY(osax_platform_capabilities_require_space_movement) \
    TEST_ENTRY(native_tab_reparent_preserves_all_members_and_group_float) \
    TEST_ENTRY(native_tab_parent_retirement_reparents_survivors_without_frame_matching) \
    TEST_ENTRY(native_tab_slot_transfer_preserves_stack_order_zoom_and_insertion) \
    TEST_ENTRY(native_tab_slot_handoff_preserves_recent_history_and_rejects_duplicate_identity) \
    TEST_ENTRY(native_tab_focus_history_tracks_logical_slots_without_fabricating_focus) \
    TEST_ENTRY(native_tab_rule_removal_dissolves_membership_and_group_float_is_shared) \
    TEST_ENTRY(native_tab_group_move_includes_only_live_recorded_members) \
    TEST_ENTRY(display_area_is_in_direction) \
    TEST_ENTRY(closest_display_in_direction) \
    TEST_ENTRY(mouse_drop_action_modifier_inherits_default) \
    TEST_ENTRY(mouse_drop_action_modifier_overrides_center_drop) \
    TEST_ENTRY(mouse_drop_action_modifier_uses_exact_modifier_match) \
    TEST_ENTRY(mouse_drop_action_modifier_does_not_affect_warp_zones) \
    TEST_ENTRY(mouse_empty_drop_feedback_uses_destination_tiling_area) \
    TEST_ENTRY(mouse_empty_drop_feedback_rejects_invalid_destinations) \
    TEST_ENTRY(mouse_drop_feedback_cleanup_ignores_retired_nodes) \
    TEST_ENTRY(mouse_drop_feedback_identity_requires_live_window) \
    TEST_ENTRY(mouse_handler_teardown_cancels_drag_without_live_tap) \
    TEST_ENTRY(mouse_drop_feedback_transfer_preserves_ownership) \
    TEST_ENTRY(mouse_drag_cancel_after_native_tab_handoff_clears_batch) \
    TEST_ENTRY(mouse_drag_session_replacement_and_scoped_cancellation) \
    TEST_ENTRY(stack_focus_inside_east_returns_next_logical_window) \
    TEST_ENTRY(stack_focus_inside_west_returns_prev_logical_window) \
    TEST_ENTRY(stack_focus_inside_boundary_falls_through) \
    TEST_ENTRY(stack_focus_inside_disabled_falls_through) \
    TEST_ENTRY(stack_focus_inside_vertical_falls_through) \
    TEST_ENTRY(stack_focus_inside_single_window_falls_through) \
    TEST_ENTRY(stack_insert_source_after_right_side_target_edge) \
    TEST_ENTRY(stack_insert_source_before_left_side_target_edge) \
    TEST_ENTRY(stack_remove_non_active_source_preserves_logical_order_and_active) \
    TEST_ENTRY(stack_window_rejects_same_stack) \
    TEST_ENTRY(managed_space_display_policy_defaults_to_follow_main)\
    TEST_ENTRY(managed_space_display_policy_can_be_set_while_disabled)\
    TEST_ENTRY(managed_space_display_affinity_names_are_stable)\
    TEST_ENTRY(managed_space_pending_create_counts_only_managed_spaces)\
    TEST_ENTRY(managed_space_secondary_workspace_reservation_survives_reorder_and_is_display_scoped)\
    TEST_ENTRY(managed_space_drag_defers_only_affected_window_repairs_and_cancellation_resumes_them)\
    TEST_ENTRY(managed_space_intent_commits_preserve_unrelated_windows_and_secondary_without_home)\
    TEST_ENTRY(managed_space_native_tab_handoff_moves_home_residence_and_active_drag)\
    TEST_ENTRY(managed_space_destroy_preserves_remaining_slot_order)\
    TEST_ENTRY(managed_space_planner_never_repairs_actual_fullscreen_membership)\
    TEST_ENTRY(managed_space_planner_defers_unknown_or_interrupted_observation)\
    TEST_ENTRY(managed_space_accepted_placement_waits_for_event_and_explicit_refresh_retries)\
    TEST_ENTRY(managed_space_readiness_failure_preserves_registry_and_home)\
    TEST_ENTRY(managed_space_initial_enable_requires_compatible_addition)\
    TEST_ENTRY(managed_space_create_tickets_protect_display_and_cancel_exact_latest_user)\
    TEST_ENTRY(managed_space_late_creation_receipt_does_not_consume_next_ticket)\
    TEST_ENTRY(managed_space_secondary_disappearance_is_transition_and_no_replug_return)\
    TEST_ENTRY(managed_space_planner_respects_drag_and_creation_admission)\
    TEST_ENTRY(managed_space_explicit_destroy_does_not_replenish_configured_names)\
    TEST_ENTRY(managed_space_unchanged_observation_does_not_repeat_failed_action)\
    TEST_ENTRY(managed_space_planner_orders_slots_with_interleaved_display_affinity)

static struct {
    char *name;
    test_function *func;
} tests[] = {
    TEST_LIST
};

int main(int argc, char **argv)
{
    int succeeded = 0;
    int failed = 0;
    int total = array_count(tests);
    printf("\e[1;34m -- Running %d tests\e[m\n\n", total);

    uint64_t cpu_freq  = read_cpu_freq();
    uint64_t begin_tsc = read_cpu_timer();

    for (int i = 0; i < total; ++i) {
        uint64_t tsc = read_cpu_timer();
        bool result = tests[i].func();
        double ms_elapsed = 1000.0 * (double)(read_cpu_timer() - tsc) / (double)cpu_freq;

        printf("(%0.4fms) %s \e[1;33m%s\e[m\n", ms_elapsed, result ? "\e[1;32msuccess\e[m" : " \e[1;31mfailed\e[m", tests[i].name);
        if (result) ++succeeded; else ++failed;
    }

    double ms_elapsed = 1000.0 * (double)(read_cpu_timer() - begin_tsc) / (double)cpu_freq;
    printf("\n\e[1;34m -- Completed (%0.4fms)\e[m\n", ms_elapsed);
    printf("\t%d \e[1;32msucceeded\e[m\n", succeeded);
    printf("\t%d \e[1;31mfailed\e[m\n", failed);
    printf("\t%d \e[1;33mtotal\e[m\n", total);

    return total == succeeded ? EXIT_SUCCESS : EXIT_FAILURE;
}
