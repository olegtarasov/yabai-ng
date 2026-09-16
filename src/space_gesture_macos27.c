// macOS 27 validates synthetic Dock swipes against a serialized IOHID queue.
// Event layout and phase fields adapted from joshuarli/iss (0BSD).
#pragma pack(push, 1)
struct space_gesture_hid_base {
    uint32_t size, type, options;
    uint8_t depth, reserved[3];
};
struct space_gesture_fluid {
    struct space_gesture_hid_base base;
    int32_t x, y, z;
    uint32_t mask;
    uint16_t motion, flavor;
    int32_t progress;
};
struct space_gesture_velocity {
    struct space_gesture_hid_base base;
    int32_t x, y, z;
};
struct space_gesture_queue {
    uint64_t timestamp, sender;
    uint32_t options, attribute_length, count;
};
#pragma pack(pop)

_Static_assert(sizeof(struct space_gesture_fluid) == 40, "IOHID fluid layout");
_Static_assert(sizeof(struct space_gesture_velocity) == 28, "IOHID velocity layout");
_Static_assert(sizeof(struct space_gesture_queue) == 28, "IOHID queue layout");

static CGEventRef space_gesture_augment(CGEventRef event, int phase, double direction)
{
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;
    CFIndex length = CFDataGetLength(data);
    const uint8_t *bytes = CFDataGetBytePtr(data);
    if (length < 4 || bytes[0] || bytes[1] || bytes[2] || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    struct {
        struct space_gesture_queue queue;
        struct space_gesture_fluid fluid;
        struct space_gesture_velocity velocity;
    } payload = {0};
    bool with_velocity = phase == 4;
    size_t payload_length = sizeof(payload.queue) + sizeof(payload.fluid) +
                            (with_velocity ? sizeof(payload.velocity) : 0);
    payload.queue.timestamp = CGEventGetTimestamp(event);
    if (!payload.queue.timestamp) payload.queue.timestamp = mach_absolute_time();
    payload.queue.count = with_velocity ? 2 : 1;
    payload.fluid.base.size = sizeof(payload.fluid);
    payload.fluid.base.type = 23;
    payload.fluid.base.options = (phase & 0xff) << 24;
    payload.fluid.motion = 1;
    payload.fluid.flavor = 3;
    payload.fluid.progress = direction * 65536.0;
    if (with_velocity) {
        payload.velocity.base.size = sizeof(payload.velocity);
        payload.velocity.base.type = 9;
        payload.velocity.base.depth = 1;
        payload.velocity.x = direction * 9999.0 * 65536.0;
    }

    size_t new_length = (size_t)length + 4 + payload_length;
    uint8_t *buffer = malloc(new_length);
    if (!buffer) { CFRelease(data); return NULL; }
    memcpy(buffer, bytes, length);
    buffer[length] = payload_length >> 8;
    buffer[length + 1] = payload_length;
    buffer[length + 2] = 4205 >> 8;
    buffer[length + 3] = 4205 & 0xff;
    memcpy(buffer + length + 4, &payload, payload_length);
    CFRelease(data);
    CFDataRef augmented = CFDataCreate(kCFAllocatorDefault, buffer, new_length);
    free(buffer);
    if (!augmented) return NULL;
    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, augmented);
    CFRelease(augmented);
    return result;
}

static bool space_gesture_macos27_post_phase(int phase, double direction)
{
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    CGEventSetIntegerValueField(event, (CGEventField)55, 30);
    CGEventSetIntegerValueField(event, (CGEventField)110, 23);
    CGEventSetIntegerValueField(event, (CGEventField)132, phase);
    CGEventSetDoubleValueField(event, (CGEventField)124, direction);
    CGEventSetIntegerValueField(event, (CGEventField)123, 1);
    CGEventSetIntegerValueField(event, (CGEventField)134, phase);
    CGEventSetDoubleValueField(event, (CGEventField)138, 3.0);
    CGEventSetDoubleValueField(event, (CGEventField)169, mach_absolute_time());
    CGEventSetDoubleValueField(event, (CGEventField)125, 0.1);
    if (phase == 4) CGEventSetDoubleValueField(event, (CGEventField)129, direction * 9999.0);
    CGEventRef dock = space_gesture_augment(event, phase, direction);
    CFRelease(event);
    if (!dock) return false;
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) { CFRelease(dock); return false; }
    CGEventSetIntegerValueField(companion, (CGEventField)55, 29);
    CGEventPost(kCGSessionEventTap, dock);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(dock);
    CFRelease(companion);
    return true;
}

static bool space_gesture_macos27_switch(int direction, int count)
{
    // macOS 27 reverses the progress encoding for a rightward space switch.
    double progress = direction > 0 ? -1.0 : 1.0;
    for (int i = 0; i < count; ++i) {
        if (!space_gesture_macos27_post_phase(1, progress) ||
            !space_gesture_macos27_post_phase(2, progress) ||
            !space_gesture_macos27_post_phase(4, progress)) return false;
    }
    return true;
}
