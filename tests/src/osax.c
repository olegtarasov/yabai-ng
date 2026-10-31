TEST_FUNC(osax_platform_capabilities_require_space_movement,
{
    TEST_CHECK(osax_required_attrib(27, 2, 1), 0x5d);
    TEST_CHECK(osax_required_attrib(27, 0, 1), OSAX_ATTRIB_ALL);
    TEST_CHECK(osax_required_attrib(26, 6, 1), OSAX_ATTRIB_ALL);
    TEST_CHECK(osax_required_attrib(27, 2, 0), OSAX_ATTRIB_ALL);
    unsigned required = osax_required_attrib(27, 2, 1);
    TEST_CHECK((required & OSAX_ATTRIB_MOV_SPACE) != 0, true);
    TEST_CHECK((required & OSAX_ATTRIB_DOCK_SPACES) != 0, true);
    TEST_CHECK((required & OSAX_ATTRIB_ADD_SPACE) != 0, true);
    TEST_CHECK((required & OSAX_ATTRIB_REM_SPACE) != 0, true);
    TEST_CHECK((required & OSAX_ATTRIB_ANIM_TIME) != 0, true);
})
