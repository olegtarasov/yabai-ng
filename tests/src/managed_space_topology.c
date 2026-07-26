static void managed_space_topology_test_set_probe(enum scripting_addition_probe_status status,
                                                  char *version,
                                                  uint32_t capabilities)
{
    managed_space_topology_test_probe_override_enabled = true;
    memset(&managed_space_topology_test_probe_override,
           0,
           sizeof(managed_space_topology_test_probe_override));
    managed_space_topology_test_probe_override.status = status;
    managed_space_topology_test_probe_override.capabilities = capabilities;
    if (version) {
        snprintf(managed_space_topology_test_probe_override.version,
                 sizeof(managed_space_topology_test_probe_override.version),
                 "%s",
                 version);
    }
}

TEST_FUNC(managed_space_topology_backend_policy_values_are_stable,
{
    enum managed_space_topology_backend_policy policy = MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO;

    TEST_CHECK(managed_space_topology_backend_policy_from_string("auto", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("scripting-addition", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("bridge", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_BRIDGE);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("accessibility", &policy), true);
    TEST_CHECK(policy, MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY);
    TEST_CHECK(managed_space_topology_backend_policy_from_string("invalid", &policy), false);
});

TEST_FUNC(managed_space_topology_auto_selects_only_compatible_scripting_addition,
{
    struct managed_space_topology topology;
    managed_space_topology_init(&topology);

    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_COMPATIBLE,
                                          OSAX_VERSION,
                                          OSAX_ATTRIB_ALL);
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION);
    TEST_CHECK(topology.selection_reason, MANAGED_SPACE_TOPOLOGY_SELECTION_COMPATIBLE_HANDSHAKE);
    TEST_CHECK(g_managed_space_sip_safe.enabled, false);

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_UNAVAILABLE, "", 0);
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE);
    TEST_CHECK(topology.selection_reason, MANAGED_SPACE_TOPOLOGY_SELECTION_HANDSHAKE_UNAVAILABLE);
    TEST_CHECK(g_managed_space_sip_safe.enabled, true);

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_VERSION_MISMATCH,
                                          "0.0.0",
                                          OSAX_ATTRIB_ALL);
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE);
    TEST_CHECK(topology.selection_reason, MANAGED_SPACE_TOPOLOGY_SELECTION_VERSION_MISMATCH);

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_CAPABILITIES_MISSING,
                                          OSAX_VERSION,
                                          OSAX_ATTRIB_DOCK_SPACES);
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE);
    TEST_CHECK(topology.selection_reason, MANAGED_SPACE_TOPOLOGY_SELECTION_CAPABILITIES_MISSING);

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_destroy(&topology);
});

TEST_FUNC(managed_space_topology_forced_provider_never_cross_falls_back,
{
    struct managed_space_topology topology;
    managed_space_topology_init(&topology);
    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_UNAVAILABLE, "", 0);

    topology.policy = MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION;
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION);
    TEST_CHECK(g_managed_space_sip_safe.enabled, false);

    managed_space_topology_set_enabled(&topology, false);
    topology.policy = MANAGED_SPACE_TOPOLOGY_BACKEND_ACCESSIBILITY;
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE);
    TEST_CHECK(g_managed_space_sip_safe.policy, MANAGED_SPACE_SIP_SAFE_POLICY_ACCESSIBILITY);

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_destroy(&topology);
});

TEST_FUNC(managed_space_topology_legacy_dispatch_is_synchronous_and_safe_resources_stay_dormant,
{
    struct managed_space_topology topology;
    managed_space_topology_init(&topology);
    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_COMPATIBLE,
                                          OSAX_VERSION,
                                          OSAX_ATTRIB_ALL);
    managed_space_topology_set_enabled(&topology, true);

    struct managed_space_topology_result topology_result =
        managed_space_topology_create(&topology,
                                      MANAGED_SPACE_TOPOLOGY_ORIGIN_COMMAND,
                                      0);
    TEST_CHECK(topology_result.space_error, SPACE_OP_ERROR_MISSING_SRC);
    TEST_CHECK(topology_result.provider_error, MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_NONE);
    TEST_CHECK(topology_result.queued, false);
    TEST_CHECK(g_managed_space_sip_safe.enabled, false);
    TEST_CHECK(g_managed_space_sip_safe.state, MANAGED_SPACE_SIP_SAFE_STATE_IDLE);
    TEST_CHECK(g_managed_space_sip_safe.ax_observer == NULL, true);
    TEST_CHECK(g_managed_space_sip_safe.input_event_tap == NULL, true);
    TEST_CHECK(g_managed_space_sip_safe.input_event_source == NULL, true);
    TEST_CHECK(managed_space_sip_safe_bridge_symbols_resolved, false);

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_destroy(&topology);
});

TEST_FUNC(managed_space_topology_selection_is_sticky_until_explicit_refresh,
{
    struct managed_space_topology topology;
    managed_space_topology_init(&topology);
    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_COMPATIBLE,
                                          OSAX_VERSION,
                                          OSAX_ATTRIB_ALL);
    managed_space_topology_set_enabled(&topology, true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION);

    managed_space_topology_test_set_probe(SCRIPTING_ADDITION_PROBE_UNAVAILABLE, "", 0);
    managed_space_topology_handle_dock_restart(&topology);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SCRIPTING_ADDITION);

    TEST_CHECK(managed_space_topology_set_backend_policy(&topology,
                                                        MANAGED_SPACE_TOPOLOGY_BACKEND_AUTO),
               true);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE);

    g_managed_space_sip_safe.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_CREATE;
    TEST_CHECK(managed_space_topology_set_backend_policy(&topology,
                                                        MANAGED_SPACE_TOPOLOGY_BACKEND_SCRIPTING_ADDITION),
               false);
    TEST_CHECK(topology.provider, MANAGED_SPACE_TOPOLOGY_PROVIDER_SIP_SAFE);
    g_managed_space_sip_safe.current.operation = MANAGED_SPACE_TOPOLOGY_OPERATION_NONE;

    managed_space_topology_set_enabled(&topology, false);
    managed_space_topology_destroy(&topology);
});

TEST_FUNC(managed_space_topology_result_keeps_provider_errors_out_of_space_manager,
{
    struct managed_space_topology_result queued = managed_space_topology_result_queued();
    TEST_CHECK(queued.space_error, SPACE_OP_ERROR_SUCCESS);
    TEST_CHECK(queued.queued, true);
    TEST_CHECK(managed_space_topology_result_error_code(queued), 0);

    struct managed_space_topology_result accessibility =
        managed_space_topology_result_provider_error(
            MANAGED_SPACE_TOPOLOGY_PROVIDER_ERROR_ACCESSIBILITY);
    TEST_CHECK(accessibility.space_error, SPACE_OP_ERROR_SUCCESS);
    TEST_CHECK(managed_space_topology_result_error_code(accessibility), 13);
});
