unsigned char __src_osax_payload[1];
unsigned int __src_osax_payload_len;
unsigned char __src_osax_loader[1];
unsigned int __src_osax_loader_len;

#include "../../src/manifest.m"

#define TEST_SIG(name) bool test_##name(void)
typedef TEST_SIG(function);

#define TEST_FUNC(name, code) static TEST_SIG(name) { char *test_name = #name; bool result = true; {code} return result; }
#define TEST_CHECK(r, e) if ((r) != (e)) { printf("                   \e[1;33m%s\e[m\e[1;31m#%d %s == %s\e[m \e[1;31m(%d == %d)\e[m\n", test_name, __LINE__, #r, #e, r, e); result = false; }

#include "area.c"
#include "mouse.c"
#include "stack_focus.c"
#include "managed_space.c"
#include "managed_space_topology.c"
#include "managed_space_sip_fallback.c"

#define TEST_ENTRY(name) { #name, test_##name },
#define TEST_LIST                                              \
    TEST_ENTRY(display_area_is_in_direction)                   \
    TEST_ENTRY(closest_display_in_direction)                   \
    TEST_ENTRY(mouse_drop_action_modifier_inherits_default)     \
    TEST_ENTRY(mouse_drop_action_modifier_overrides_center_drop)\
    TEST_ENTRY(mouse_drop_action_modifier_uses_exact_modifier_match)\
    TEST_ENTRY(mouse_drop_action_modifier_does_not_affect_warp_zones)\
    TEST_ENTRY(stack_focus_inside_east_returns_next_logical_window)\
    TEST_ENTRY(stack_focus_inside_west_returns_prev_logical_window)\
    TEST_ENTRY(stack_focus_inside_boundary_falls_through)       \
    TEST_ENTRY(stack_focus_inside_disabled_falls_through)       \
    TEST_ENTRY(stack_focus_inside_vertical_falls_through)       \
    TEST_ENTRY(stack_focus_inside_single_window_falls_through)  \
    TEST_ENTRY(stack_insert_source_after_right_side_target_edge)\
    TEST_ENTRY(stack_insert_source_before_left_side_target_edge)\
    TEST_ENTRY(stack_remove_non_active_source_preserves_logical_order_and_active)\
    TEST_ENTRY(stack_window_rejects_same_stack)                 \
    TEST_ENTRY(managed_space_display_policy_defaults_to_follow_main)\
    TEST_ENTRY(managed_space_display_policy_can_be_set_while_disabled)\
    TEST_ENTRY(managed_space_display_affinity_names_are_stable) \
    TEST_ENTRY(managed_space_pending_create_counts_only_managed_spaces) \
    TEST_ENTRY(managed_space_sip_fallback_destroy_preserves_remaining_uuid_order_after_sid_refresh) \
    TEST_ENTRY(managed_space_scripting_addition_destroy_preserves_primary_swap_delete_semantics) \
    TEST_ENTRY(managed_space_topology_backend_policy_values_are_stable) \
    TEST_ENTRY(managed_space_topology_auto_selects_only_compatible_scripting_addition) \
    TEST_ENTRY(managed_space_topology_forced_provider_never_cross_falls_back) \
    TEST_ENTRY(managed_space_topology_primary_dispatch_is_synchronous_and_fallback_resources_stay_dormant) \
    TEST_ENTRY(managed_space_topology_selection_is_sticky_until_explicit_refresh) \
    TEST_ENTRY(managed_space_topology_result_keeps_provider_errors_out_of_space_manager) \
    TEST_ENTRY(managed_space_sip_fallback_backend_selection_is_operation_scoped) \
    TEST_ENTRY(managed_space_sip_fallback_validated_bridge_matrix_is_os_scoped) \
    TEST_ENTRY(managed_space_sip_fallback_backend_change_preserves_last_failure) \
    TEST_ENTRY(managed_space_sip_fallback_failed_reconcile_waits_for_new_state) \
    TEST_ENTRY(managed_space_sip_fallback_queue_serializes_and_records_origin) \
    TEST_ENTRY(managed_space_sip_fallback_stale_watchdogs_are_rejected) \
    TEST_ENTRY(managed_space_sip_fallback_events_match_only_the_active_request) \
    TEST_ENTRY(managed_space_sip_fallback_create_events_must_be_new_to_the_request) \
    TEST_ENTRY(managed_space_sip_fallback_mutation_backends_require_authoritative_postconditions) \
    TEST_ENTRY(managed_space_sip_fallback_persisted_postconditions_are_transactional) \
    TEST_ENTRY(managed_space_sip_fallback_explicit_destroy_defers_membership_commit) \
    TEST_ENTRY(managed_space_sip_fallback_failed_reorder_keeps_previous_desired_order) \
    TEST_ENTRY(managed_space_sip_fallback_swap_expected_order_is_transactional) \
    TEST_ENTRY(managed_space_sip_fallback_mission_control_ownership_is_explicit) \
    TEST_ENTRY(managed_space_sip_fallback_owned_deactivation_is_generation_checked) \
    TEST_ENTRY(managed_space_sip_fallback_drag_targets_use_visible_ax_frames) \
    TEST_ENTRY(managed_space_sip_fallback_ax_display_mapping_accepts_numeric_ids) \
    TEST_ENTRY(managed_space_sip_fallback_space_limit_is_display_scoped) \
    TEST_ENTRY(managed_space_sip_fallback_normal_order_excludes_fullscreen_entries)

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
