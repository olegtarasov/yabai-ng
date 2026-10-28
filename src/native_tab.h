#ifndef NATIVE_TAB_H
#define NATIVE_TAB_H

bool native_tab_handle_window_created(struct window_manager *wm, struct window *window);
bool native_tab_handle_window_moved(struct space_manager *sm, struct window_manager *wm, struct window *window);
bool native_tab_handle_window_resized(struct space_manager *sm, struct window_manager *wm, struct window *window);
bool native_tab_repair_window(struct window_manager *wm, struct window *window);
void native_tab_handle_window_destroyed(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t destroyed_sid);
struct window *native_tab_focused_window(struct window_manager *wm, struct window *window);
bool native_tab_windows_share_group(struct window *a, struct window *b);
bool native_tab_set_group_opacity(struct window_manager *wm, struct window *window, float opacity);
bool native_tab_should_preserve_parent(struct window_manager *wm, struct window *window);
struct window *native_tab_managed_window(struct window_manager *wm, struct window *window);
void native_tab_sync_group_float(struct window_manager *wm, struct window *window);
void native_tab_forget_window(struct window_manager *wm, struct window *window);
bool native_tab_is_presentation_window(struct window_manager *wm, struct window *window);

#endif
