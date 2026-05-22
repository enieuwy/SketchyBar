#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "ring.h"
#include "window.h"

bool ring_layer_window_attach(struct window* window);
void ring_layer_window_resize(struct window* window);
void ring_layer_window_move(struct window* window);
void ring_layer_window_destroy(struct window* window);

bool ring_layer_window_has_tree(struct window* window);
void ring_layer_window_destroy_tree(struct window* window);

bool ring_layer_update(struct ring* ring, struct window* window, bool disable_actions);
bool ring_layer_set_value(struct ring* ring, struct window* window, float value);
bool ring_layer_animate_value(struct ring* ring,
                              struct window* window,
                              float value,
                              uint32_t duration,
                              char interp_function);
bool ring_layer_set_color(struct ring* ring, struct window* window, bool track);
bool ring_layer_sync_color(struct ring* ring, struct window* window, bool track);
bool ring_layer_animate_color(struct ring* ring,
                              struct window* window,
                              bool track,
                              uint32_t duration,
                              char interp_function);
bool ring_layer_set_line_width(struct ring* ring, struct window* window);
