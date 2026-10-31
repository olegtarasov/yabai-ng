#import <Foundation/Foundation.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>
#include "../../src/osax/arm64_payload.m"

// Static acceptance for a local macOS 27 Dock, including the arm64e.x1 slice.
// Each lookup must be unique inside the real payload's scan window.
int main(int argc, char **argv)
{
    @autoreleasepool {
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        if (os.majorVersion != 27) return 77;
        NSData *data = [NSData dataWithContentsOfFile:argc > 1 ? @(argv[1]) : @"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"];
        if (!data || data.length < sizeof(struct fat_header)) return 1;
        const uint8_t *bytes = data.bytes;
        const struct fat_header *fat = (const void *) bytes;
        if (OSSwapBigToHostInt32(fat->magic) != FAT_MAGIC) return 1;
        uint32_t slices = OSSwapBigToHostInt32(fat->nfat_arch);
        if (sizeof(*fat) + slices * sizeof(struct fat_arch) > data.length) return 1;
        const struct fat_arch *arch = (const void *)(fat + 1);
        const char *names[] = {"dock.spaces", "dppm", "add", "remove", "move", "front", "animation"};
        const char *patterns[] = {get_dock_spaces_pattern(os), get_dppm_pattern(os), get_add_space_pattern(os), get_remove_space_pattern(os), get_move_space_pattern(os), get_set_front_window_pattern(os), get_fix_animation_pattern(os)};
        uint64_t starts[] = {get_dock_spaces_offset(os), get_dppm_offset(os), get_add_space_offset(os), get_remove_space_offset(os), get_move_space_offset(os), get_set_front_window_offset(os), get_fix_animation_offset(os)};
        int failures = 0;
        for (uint32_t a = 0; a < slices; ++a) {
            uint64_t offset = OSSwapBigToHostInt32(arch[a].offset), size = OSSwapBigToHostInt32(arch[a].size);
            if (offset + size > data.length) return 1;
            const uint8_t *slice = bytes + offset;
            const struct mach_header_64 *header = (const void *)slice;
            if (size < sizeof(*header) || header->magic != MH_MAGIC_64) return 1;
            uint64_t text_end = 0;
            const struct load_command *command = (const void *)(header + 1);
            for (uint32_t c = 0; c < header->ncmds; ++c) {
                if ((const uint8_t *)command + command->cmdsize > slice + size) return 1;
                if (command->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segment = (const void *)command;
                    if (strcmp(segment->segname, "__TEXT") == 0) text_end = segment->fileoff + segment->filesize;
                }
                command = (const void *)((const uint8_t *)command + command->cmdsize);
            }
            if (!text_end || text_end > size) return 1;
            for (int p = 0; p < 7; ++p) {
                if (!patterns[p]) continue;
                unsigned values[256], wildcard[256], length = 0;
                for (const char *token = patterns[p]; *token; token += 3) {
                    if (length == 256) return 1;
                    wildcard[length] = token[0] == '?';
                    values[length++] = strtoul(token, NULL, 16);
                    if (!token[2]) break;
                }
                unsigned count = 0; uint64_t hit = 0;
                for (uint64_t i = starts[p]; i < starts[p] + 0x1286a0 && i + length <= text_end; ++i) {
                    unsigned j = 0;
                    for (; j < length; ++j) if (!wildcard[j] && slice[i+j] != values[j]) break;
                    if (j == length) { ++count; hit = i; }
                }
                printf("slice %u %s: %u hit(s), 0x%llx\n", a, names[p], count, hit);
                if (count != 1) ++failures;
            }
        }
        return failures ? 1 : 0;
    }
}
