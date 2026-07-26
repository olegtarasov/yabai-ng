#ifndef MANAGED_SPACE_LEGACY_H
#define MANAGED_SPACE_LEGACY_H

enum space_op_error managed_space_legacy_create(uint64_t acting_sid);
enum space_op_error managed_space_legacy_destroy(uint64_t sid);
enum space_op_error managed_space_legacy_move(uint64_t sid, uint64_t target_sid);
enum space_op_error managed_space_legacy_swap(uint64_t sid, uint64_t target_sid);
enum space_op_error managed_space_legacy_move_to_display(uint64_t sid, uint32_t did);

#endif
