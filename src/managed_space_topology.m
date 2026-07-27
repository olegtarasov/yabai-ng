extern struct managed_space g_managed_space;
extern struct managed_space_sip_fallback g_managed_space_sip_fallback;

#ifdef TESTS
static bool managed_space_topology_test_probe_override_enabled;
static struct scripting_addition_probe_result managed_space_topology_test_probe_override;
#endif

static void managed_space_topology_refresh_probe(struct managed_space_topology *topology)
{
    struct scripting_addition_probe_result probe = {0};
#ifdef TESTS
    if (managed_space_topology_test_probe_override_enabled) {
        probe = managed_space_topology_test_probe_override;
    } else {
        scripting_addition_probe(&probe);
    }
#else
    scripting_addition_probe(&probe);
#endif

    topology->scripting_addition_status = probe.status;
    topology->scripting_addition_capabilities = probe.capabilities;
    snprintf(topology->scripting_addition_version,
             sizeof(topology->scripting_addition_version),
             "%s",
             probe.version);
}

static void managed_space_topology_resolve_provider(struct managed_space_topology *topology)
{
    managed_space_topology_refresh_probe(topology);

    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION) {
        topology->provider = MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION;
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_FORCED_POLICY;
        return;
    }

    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_SIP_FALLBACK ||
        topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE ||
        topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY) {
        topology->provider = MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_FALLBACK;
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_FORCED_POLICY;
        return;
    }

    if (topology->scripting_addition_status == SCRIPTING_ADDITION_PROBE_COMPATIBLE) {
        topology->provider = MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION;
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_COMPATIBLE_HANDSHAKE;
        return;
    }

    topology->provider = MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_FALLBACK;
    switch (topology->scripting_addition_status) {
    case SCRIPTING_ADDITION_PROBE_UNAVAILABLE:
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_HANDSHAKE_UNAVAILABLE;
        break;
    case SCRIPTING_ADDITION_PROBE_VERSION_MISMATCH:
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_VERSION_MISMATCH;
        break;
    case SCRIPTING_ADDITION_PROBE_CAPABILITIES_MISSING:
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_CAPABILITIES_MISSING;
        break;
    case SCRIPTING_ADDITION_PROBE_COMPATIBLE:
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_COMPATIBLE_HANDSHAKE;
        break;
    }
}

static void managed_space_topology_activate_resolved_provider(struct managed_space_topology *topology)
{
    managed_space_sip_fallback_set_enabled(&g_managed_space_sip_fallback, false);
    if (topology->provider != MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_FALLBACK) return;

    enum managed_space_sip_fallback_policy fallback_policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_AUTO;
    if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE) {
        fallback_policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_BRIDGE;
    } else if (topology->policy == MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY) {
        fallback_policy = MANAGED_SPACE_SIP_FALLBACK_POLICY_ACCESSIBILITY;
    }
    managed_space_sip_fallback_set_backend_policy(&g_managed_space_sip_fallback, fallback_policy);
    managed_space_sip_fallback_set_enabled(&g_managed_space_sip_fallback, true);
}

void managed_space_topology_init(struct managed_space_topology *topology)
{
    memset(topology, 0, sizeof(struct managed_space_topology));
    topology->policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO;
    topology->provider = MANAGED_SPACE_TOPOLOGY_PROVIDER_DISABLED;
    topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_DISABLED;
    managed_space_sip_fallback_init(&g_managed_space_sip_fallback);
}

void managed_space_topology_destroy(struct managed_space_topology *topology)
{
    managed_space_sip_fallback_destroy(&g_managed_space_sip_fallback);
    memset(topology, 0, sizeof(struct managed_space_topology));
}

void managed_space_topology_set_enabled(struct managed_space_topology *topology, bool enabled)
{
    if (!enabled) {
        managed_space_sip_fallback_set_enabled(&g_managed_space_sip_fallback, false);
        topology->enabled = false;
        topology->provider = MANAGED_SPACE_TOPOLOGY_PROVIDER_DISABLED;
        topology->selection_reason = MANAGED_SPACE_TOPOLOGY_SELECTION_DISABLED;
        return;
    }

    topology->enabled = true;
    managed_space_topology_resolve_provider(topology);
    managed_space_topology_activate_resolved_provider(topology);
}

bool managed_space_topology_is_enabled(struct managed_space_topology *topology)
{
    return topology->enabled;
}

bool managed_space_topology_uses_scripting_addition(struct managed_space_topology *topology)
{
    return topology->enabled &&
           topology->provider == MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION;
}

bool managed_space_topology_uses_sip_fallback(struct managed_space_topology *topology)
{
    return topology->enabled &&
           topology->provider == MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_FALLBACK;
}

void managed_space_topology_note_configuration_changed(struct managed_space_topology *topology)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_note_configuration_changed(&g_managed_space_sip_fallback);
}

const char *managed_space_topology_backend_policy_name(enum managed_space_topology_backend_policy policy)
{
    switch (policy) {
    case MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO:               return "auto";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION: return "scripting-addition";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_SIP_FALLBACK:       return "sip-fallback";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE:             return "bridge";
    case MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY:      return "accessibility";
    }

    return "unknown";
}

bool managed_space_topology_backend_policy_from_string(char *value,
                                                       enum managed_space_topology_backend_policy *policy)
{
    if (string_equals(value, "auto")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO;
    } else if (string_equals(value, "scripting-addition")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION;
    } else if (string_equals(value, "sip-fallback")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_SIP_FALLBACK;
    } else if (string_equals(value, "bridge")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE;
    } else if (string_equals(value, "accessibility")) {
        *policy = MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY;
    } else {
        return false;
    }

    return true;
}

bool managed_space_topology_set_backend_policy(struct managed_space_topology *topology,
                                               enum managed_space_topology_backend_policy policy)
{
    if (managed_space_topology_uses_sip_fallback(topology) &&
        managed_space_sip_fallback_operation_pending(&g_managed_space_sip_fallback)) {
        return false;
    }

    topology->policy = policy;
    if (!topology->enabled) return true;

    managed_space_topology_resolve_provider(topology);
    managed_space_topology_activate_resolved_provider(topology);
    managed_space_request_reconcile(&g_managed_space);
    return true;
}

enum managed_space_topology_backend_policy
managed_space_topology_backend_policy(struct managed_space_topology *topology)
{
    return topology->policy;
}

const char *managed_space_topology_provider_name(enum managed_space_topology_provider provider)
{
    switch (provider) {
    case MANAGED_SPACE_TOPOLOGY_PROVIDER_DISABLED:           return "disabled";
    case MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION: return "scripting-addition";
    case MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_FALLBACK:       return "sip-fallback";
    }

    return "unknown";
}

const char *managed_space_topology_selection_reason_name(enum managed_space_topology_selection_reason reason)
{
    switch (reason) {
    case MANAGED_SPACE_TOPOLOGY_SELECTION_DISABLED:             return "disabled";
    case MANAGED_SPACE_TOPOLOGY_SELECTION_COMPATIBLE_HANDSHAKE: return "compatible-handshake";
    case MANAGED_SPACE_TOPOLOGY_SELECTION_HANDSHAKE_UNAVAILABLE:return "handshake-unavailable";
    case MANAGED_SPACE_TOPOLOGY_SELECTION_VERSION_MISMATCH:     return "version-mismatch";
    case MANAGED_SPACE_TOPOLOGY_SELECTION_CAPABILITIES_MISSING: return "capabilities-missing";
    case MANAGED_SPACE_TOPOLOGY_SELECTION_FORCED_POLICY:        return "forced-policy";
    }

    return "unknown";
}

const char *managed_space_topology_operation_name(enum managed_space_topology_operation operation)
{
    switch (operation) {
    case MANAGED_SPACE_TOPOLOGY_OPERATION_NONE:         return "none";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE:       return "create";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_DESTROY:      return "destroy";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_REORDER:      return "reorder";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_SWAP:         return "swap";
    case MANAGED_SPACE_TOPOLOGY_OPERATION_MOVE_DISPLAY: return "move-display";
    }

    return "unknown";
}

const char *managed_space_topology_origin_name(enum managed_space_topology_origin origin)
{
    switch (origin) {
    case MANAGED_SPACE_TOPOLOGY_ORIGIN_RECONCILE: return "reconcile";
    case MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND:   return "command";
    }

    return "unknown";
}

static struct managed_space_topology_result
managed_space_topology_wrap_scripting_addition_result(enum space_op_error result)
{
    return managed_space_topology_result_space_error(result);
}

struct managed_space_topology_result
managed_space_topology_create(struct managed_space_topology *topology,
                              enum managed_space_topology_origin origin,
                              uint64_t acting_sid)
{
    if (managed_space_topology_uses_scripting_addition(topology)) {
        return managed_space_topology_wrap_scripting_addition_result(
            managed_space_scripting_addition_create(acting_sid));
    }
    if (!managed_space_topology_uses_sip_fallback(topology)) {
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    if (!acting_sid) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_MISSING_SRC);
    }
    uint32_t did = space_display_id(acting_sid);
    if (display_manager_display_is_animating(did)) {
        return managed_space_topology_result_space_error(
            SPACE_OP_ERROR_DISPLAY_IS_ANIMATING);
    }
    return managed_space_sip_fallback_create(&g_managed_space_sip_fallback, origin, acting_sid);
}

struct managed_space_topology_result
managed_space_topology_destroy_space(struct managed_space_topology *topology,
                                     enum managed_space_topology_origin origin,
                                     uint64_t sid)
{
    if (managed_space_topology_uses_scripting_addition(topology)) {
        return managed_space_topology_wrap_scripting_addition_result(
            managed_space_scripting_addition_destroy(sid));
    }
    if (!managed_space_topology_uses_sip_fallback(topology)) {
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    if (!sid) return managed_space_topology_result_space_error(SPACE_OP_ERROR_MISSING_SRC);
    if (!space_is_user(sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }
    if (space_manager_is_space_last_user_space(sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_SRC);
    }
    if (display_manager_display_is_animating(space_display_id(sid))) {
        return managed_space_topology_result_space_error(
            SPACE_OP_ERROR_DISPLAY_IS_ANIMATING);
    }
    return managed_space_sip_fallback_destroy_space(&g_managed_space_sip_fallback, origin, sid);
}

struct managed_space_topology_result
managed_space_topology_move_space(struct managed_space_topology *topology,
                                  enum managed_space_topology_origin origin,
                                  uint64_t sid,
                                  uint64_t target_sid)
{
    if (managed_space_topology_uses_scripting_addition(topology)) {
        return managed_space_topology_wrap_scripting_addition_result(
            managed_space_scripting_addition_move(sid, target_sid));
    }
    if (!managed_space_topology_uses_sip_fallback(topology)) {
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    if (sid == target_sid) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_SAME_SPACE);
    }
    if (!space_is_user(sid) || !space_is_user(target_sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }
    uint32_t did = space_display_id(sid);
    if (did != space_display_id(target_sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_SAME_DISPLAY);
    }
    if (display_manager_display_is_animating(did)) {
        return managed_space_topology_result_space_error(
            SPACE_OP_ERROR_DISPLAY_IS_ANIMATING);
    }
    return managed_space_sip_fallback_move_space(&g_managed_space_sip_fallback,
                                                 origin,
                                                 sid,
                                                 target_sid);
}

struct managed_space_topology_result
managed_space_topology_swap_spaces(struct managed_space_topology *topology,
                                   enum managed_space_topology_origin origin,
                                   uint64_t sid,
                                   uint64_t target_sid)
{
    if (managed_space_topology_uses_scripting_addition(topology)) {
        return managed_space_topology_wrap_scripting_addition_result(
            managed_space_scripting_addition_swap(sid, target_sid));
    }
    if (!managed_space_topology_uses_sip_fallback(topology)) {
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    if (sid == target_sid) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_SAME_SPACE);
    }
    if (!space_is_user(sid) || !space_is_user(target_sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }
    uint32_t did = space_display_id(sid);
    if (did != space_display_id(target_sid)) {
        uint32_t target_did = space_display_id(target_sid);
        return managed_space_topology_result_space_error(
            space_manager_swap_space_with_space_on_display(did,
                                                           sid,
                                                           target_did,
                                                           target_sid));
    }
    if (display_manager_display_is_animating(did)) {
        return managed_space_topology_result_space_error(
            SPACE_OP_ERROR_DISPLAY_IS_ANIMATING);
    }
    return managed_space_sip_fallback_swap_spaces(&g_managed_space_sip_fallback,
                                                  origin,
                                                  sid,
                                                  target_sid);
}

struct managed_space_topology_result
managed_space_topology_move_space_to_display(struct managed_space_topology *topology,
                                             enum managed_space_topology_origin origin,
                                             uint64_t sid,
                                             uint32_t did,
                                             bool placeholder_required)
{
    if (managed_space_topology_uses_scripting_addition(topology)) {
        return managed_space_topology_wrap_scripting_addition_result(
            managed_space_scripting_addition_move_to_display(sid, did));
    }
    if (!managed_space_topology_uses_sip_fallback(topology)) {
        return managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_BACKEND);
    }

    if (!sid) return managed_space_topology_result_space_error(SPACE_OP_ERROR_MISSING_SRC);
    if (!space_is_user(sid)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_TYPE);
    }
    uint32_t source_did = space_display_id(sid);
    if (source_did == did) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_DST);
    }
    if (display_manager_display_is_animating(source_did) ||
        display_manager_display_is_animating(did)) {
        return managed_space_topology_result_space_error(
            SPACE_OP_ERROR_DISPLAY_IS_ANIMATING);
    }
    if (!display_space_id(did)) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_MISSING_DST);
    }
    if (space_manager_is_space_last_user_space(sid) && !placeholder_required) {
        return managed_space_topology_result_space_error(SPACE_OP_ERROR_INVALID_SRC);
    }
    return managed_space_sip_fallback_move_space_to_display(&g_managed_space_sip_fallback,
                                                            origin,
                                                            sid,
                                                            did,
                                                            placeholder_required);
}

bool managed_space_topology_space_limit_reached_for_display(struct managed_space_topology *topology,
                                                            uint32_t did)
{
    return managed_space_topology_uses_sip_fallback(topology) &&
           managed_space_sip_fallback_space_limit_reached_for_display(
               &g_managed_space_sip_fallback,
               did);
}

void managed_space_topology_handle_space_created(struct managed_space_topology *topology, uint64_t sid)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_space_created(&g_managed_space_sip_fallback, sid);
}

void managed_space_topology_handle_space_destroyed(struct managed_space_topology *topology, uint64_t sid)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_space_destroyed(&g_managed_space_sip_fallback, sid);
}

void managed_space_topology_handle_focus_changed(struct managed_space_topology *topology)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_focus_changed(&g_managed_space_sip_fallback);
}

void managed_space_topology_handle_mission_control_enter(struct managed_space_topology *topology)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_mission_control_enter(&g_managed_space_sip_fallback);
}

void managed_space_topology_handle_mission_control_exit(struct managed_space_topology *topology)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_mission_control_exit(&g_managed_space_sip_fallback);
}

void managed_space_topology_handle_dock_restart(struct managed_space_topology *topology)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_dock_restart(&g_managed_space_sip_fallback);
}

void managed_space_topology_handle_user_interruption(struct managed_space_topology *topology,
                                                     uint64_t generation)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_handle_user_interruption(&g_managed_space_sip_fallback, generation);
}

void managed_space_topology_step(struct managed_space_topology *topology, uint64_t token)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_step(&g_managed_space_sip_fallback, token);
}

void managed_space_topology_watchdog(struct managed_space_topology *topology, uint64_t token)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_watchdog(&g_managed_space_sip_fallback, token);
}

bool managed_space_topology_operation_pending(struct managed_space_topology *topology)
{
    return managed_space_topology_uses_sip_fallback(topology) &&
           managed_space_sip_fallback_operation_pending(&g_managed_space_sip_fallback);
}

bool managed_space_topology_reconciliation_blocked(struct managed_space_topology *topology)
{
    return managed_space_topology_uses_sip_fallback(topology) &&
           managed_space_sip_fallback_reconciliation_blocked(&g_managed_space_sip_fallback);
}

bool managed_space_topology_owns_mission_control(struct managed_space_topology *topology)
{
    return managed_space_topology_uses_sip_fallback(topology) &&
           managed_space_sip_fallback_owns_mission_control(&g_managed_space_sip_fallback);
}

bool managed_space_topology_defers_destroy_membership(struct managed_space_topology *topology,
                                                      uint64_t sid)
{
    return managed_space_topology_uses_sip_fallback(topology) &&
           managed_space_sip_fallback_defers_destroy_membership(&g_managed_space_sip_fallback, sid);
}

void managed_space_topology_finish_batch(struct managed_space_topology *topology)
{
    if (!managed_space_topology_uses_sip_fallback(topology)) return;
    managed_space_sip_fallback_finish_batch(&g_managed_space_sip_fallback);
}

void managed_space_topology_write_query(FILE *rsp, struct managed_space_topology *topology)
{
    fprintf(rsp,
            "\t\"topology-backend-policy\":\"%s\",\n"
            "\t\"topology-resolved-provider\":\"%s\",\n"
            "\t\"topology-provider-selection-reason\":\"%s\",\n"
            "\t\"topology-scripting-addition-compatible\":%s,\n"
            "\t\"topology-scripting-addition-version\":\"%s\",\n"
            "\t\"topology-scripting-addition-capabilities\":\"0x%08x\",\n",
            managed_space_topology_backend_policy_name(topology->policy),
            managed_space_topology_provider_name(topology->provider),
            managed_space_topology_selection_reason_name(topology->selection_reason),
            json_bool(topology->scripting_addition_status == SCRIPTING_ADDITION_PROBE_COMPATIBLE),
            topology->scripting_addition_version,
            topology->scripting_addition_capabilities);

    managed_space_sip_fallback_write_query(rsp, &g_managed_space_sip_fallback);
}
