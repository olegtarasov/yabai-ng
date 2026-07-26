//
// The scripting-addition provider is intentionally a transparent adapter.
// Validation, call ordering, return values, and timing belong to the original
// synchronous space_manager implementation.
//

enum space_op_error managed_space_legacy_create(uint64_t acting_sid)
{
    return space_manager_add_space(acting_sid);
}

enum space_op_error managed_space_legacy_destroy(uint64_t sid)
{
    return space_manager_destroy_space(sid);
}

enum space_op_error managed_space_legacy_move(uint64_t sid, uint64_t target_sid)
{
    return space_manager_move_space_to_space(sid, target_sid);
}

enum space_op_error managed_space_legacy_swap(uint64_t sid, uint64_t target_sid)
{
    return space_manager_swap_space_with_space(sid, target_sid);
}

enum space_op_error managed_space_legacy_move_to_display(uint64_t sid, uint32_t did)
{
    return space_manager_move_space_to_display(&g_space_manager, sid, did);
}
