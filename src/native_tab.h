#ifndef NATIVE_TAB_H
#define NATIVE_TAB_H

bool native_tab_handle_window_created(struct window_manager *wm, struct window *window);
bool native_tab_handle_window_moved(struct space_manager *sm, struct window_manager *wm, struct window *window);
bool native_tab_handle_window_resized(struct space_manager *sm, struct window_manager *wm, struct window *window);
void native_tab_handle_window_destroyed(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t destroyed_sid);
bool native_tab_should_preserve_parent(struct window_manager *wm, struct window *window);

#endif
