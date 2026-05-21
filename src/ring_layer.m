#include "ring_layer.h"
#include "animation.h"
#include "misc/helpers.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>

@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(uint32_t)connection options:(NSDictionary*)options;
@property (nonatomic, retain) CALayer* layer;
@property (nonatomic, readonly) uint32_t contextId;
- (void)invalidate;
@end

struct layer_host {
  CAContext* context;
  CALayer* root;
  uint32_t surface_id;
  CGSize size;
};

struct ring_layer_tree {
  CAShapeLayer* track;
  CAShapeLayer* progress;
  CAShapeLayer* marker_background;
  CALayer* marker_clip;
  CATextLayer* marker;
  CAShapeLayer* marker_badge_background;
  CATextLayer* marker_badge;
  CAShapeLayer* badge_background;
  CATextLayer* badge;
};

static const CGFloat layer_scale = 2.0;

static bool background_requires_cg_fallback(struct background* background) {
  return background->image.enabled || background->shadow.enabled;
}

// The CA renderer handles the ring arc, marker text, and badge without a
// CGContext redraw. Background features that require image or shadow rasterization
// deliberately fall back to the legacy renderer until those are layer-backed too.
static bool ring_layer_can_render(struct ring* ring) {
  if (ring->marker.shadow.enabled) return false;
  if (background_requires_cg_fallback(&ring->marker.background)) return false;
  if (background_requires_cg_fallback(&ring->marker.badge.background)) return false;
  if (background_requires_cg_fallback(&ring->badge.background)) return false;
  return true;
}

static void layer_host_flush(struct window* window) {
  if (!window || !window->layer_host) return;
  SLSFlushSurface(g_connection,
                  window->id,
                  window->layer_host->surface_id,
                  0);
}

static bool layer_host_uses_screen_origin(void) {
  if (__builtin_available(macOS 26.0, *)) return true;
  return false;
}

static void layer_host_bind_origin(struct window* window, int* x, int* y) {
  *x = 0;
  *y = 0;

  if (!layer_host_uses_screen_origin()) return;
  *x = (int)window->origin.x;
  *y = (int)window->origin.y;
}

static CGError layer_host_bind_surface(struct window* window,
                                      struct layer_host* host) {
  int x = 0;
  int y = 0;
  layer_host_bind_origin(window, &x, &y);

  return SLSBindSurface(g_connection,
                        window->id,
                        host->surface_id,
                        x,
                        y,
                        host->context.contextId);
}

static bool layer_host_rebind_surface_for_origin(struct window* window) {
  if (!window || !window->layer_host) return false;
  if (!layer_host_uses_screen_origin()) return true;
  return layer_host_bind_surface(window, window->layer_host) == kCGErrorSuccess;
}

static bool ring_layer_arc_drawable(struct ring* ring) {
  return ring->enabled && ring->width > 0 && ring->line_width > 0.f;
}

static CGColorRef color_create(struct color* color) {
  CGFloat components[4] = { color->r, color->g, color->b, color->a };
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  CGColorRef cg_color = CGColorCreate(color_space, components);
  CGColorSpaceRelease(color_space);
  return cg_color;
}

static NSString* line_cap_for_ring(char cap) {
  switch (cap) {
    case 'b': return kCALineCapButt;
    case 's': return kCALineCapSquare;
    case 'r':
    default: return kCALineCapRound;
  }
}

static NSString* alignment_mode_for_char(char align) {
  switch (align) {
    case POSITION_RIGHT: return kCAAlignmentRight;
    case POSITION_CENTER: return kCAAlignmentCenter;
    case POSITION_LEFT:
    default: return kCAAlignmentLeft;
  }
}

// SketchyBar's historical interpolators are scalar C functions evaluated per
// frame. CoreAnimation owns ring-layer animation timing now, so map each curve to
// the closest compositor-native timing function and keep exact keyframes as a
// future compatibility fallback if users report visible curve mismatches.
static CAMediaTimingFunction* timing_function_for_interp(char interp_function) {
  switch (interp_function) {
    case INTERP_FUNCTION_LINEAR:
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    case INTERP_FUNCTION_SIN:
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    case INTERP_FUNCTION_QUADRATIC:
    case INTERP_FUNCTION_EXP:
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    case INTERP_FUNCTION_TANH:
    case INTERP_FUNCTION_CIRC:
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    case INTERP_FUNCTION_OVERSHOOT:
      return [CAMediaTimingFunction functionWithControlPoints:0.175f :0.885f :0.320f :1.275f];
    case INTERP_FUNCTION_BOUNCE:
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    default:
      return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
  }
}

static CFTimeInterval duration_seconds(uint32_t duration) {
  return (CFTimeInterval)duration / 60.0;
}

static void add_basic_animation(CALayer* layer,
                                NSString* key_path,
                                id to_value,
                                uint32_t duration,
                                char interp_function) {
  if (duration == 0 || !layer || !key_path || !to_value) return;

  CALayer* presentation = [layer presentationLayer];
  id from_value = presentation ? [presentation valueForKeyPath:key_path]
                               : [layer valueForKeyPath:key_path];

  CABasicAnimation* animation = [CABasicAnimation animationWithKeyPath:key_path];
  animation.fromValue = from_value;
  animation.toValue = to_value;
  animation.duration = duration_seconds(duration);
  animation.timingFunction = timing_function_for_interp(interp_function);
  animation.removedOnCompletion = YES;

  [layer addAnimation:animation forKey:key_path];
}

static void cancel_layer_animation(CALayer* layer, NSString* key) {
  if (!layer || !key) return;
  [layer removeAnimationForKey:key];
}

static CGPathRef ring_path_create(struct ring* ring) {
  CGMutablePathRef path = CGPathCreateMutable();

  CGFloat line_width = ring->line_width > 0.f
                       ? min(ring->line_width, (float)ring->width)
                       : 0.f;
  CGFloat radius = ((CGFloat)ring->width - line_width) / 2.f;
  if (radius <= 0.f) return path;

  CGPoint center = CGPointMake(ring->bounds.origin.x + ring->bounds.size.width / 2.f,
                               ring->bounds.origin.y + ring->bounds.size.height / 2.f);
  CGFloat start = -(CGFloat)ring->start_angle * (CGFloat)deg_to_rad;
  CGFloat end = start + (ring->clockwise ? -2.0 * M_PI : 2.0 * M_PI);
  CGPathAddArc(path, NULL, center.x, center.y, radius, start, end, ring->clockwise);

  return path;
}

static CGPathRef rounded_rect_path_create(CGRect region, CGFloat radius, CGFloat line_width) {
  CGFloat inset = line_width > 0.f ? line_width / 2.f : 0.f;
  CGRect rect = CGRectInset(region, inset, inset);
  CGFloat max_radius = min(rect.size.width, rect.size.height) / 2.f;
  if (radius > max_radius) radius = max_radius;
  if (radius < 0.f) radius = 0.f;

  CGMutablePathRef path = CGPathCreateMutable();
  CGPathAddRoundedRect(path, NULL, rect, radius, radius);
  return path;
}

static void configure_background_layer(CAShapeLayer* layer, struct background* background) {
  if (!background->enabled
      || ((background->color.a == 0.f)
          && (background->border_color.a == 0.f || background->border_width == 0))) {
    layer.hidden = YES;
    return;
  }

  CGRect bounds = background->bounds;
  bounds.origin.x += background->x_offset;
  bounds.origin.y += background->y_offset;

  layer.hidden = NO;
  layer.contentsScale = layer_scale;
  CGPathRef path = rounded_rect_path_create(bounds,
                                            background->corner_radius,
                                            background->border_width);
  layer.path = path;
  CGPathRelease(path);

  CGColorRef fill = color_create(&background->color);
  layer.fillColor = fill;
  CGColorRelease(fill);

  if (background->border_width > 0 && background->border_color.a > 0.f) {
    CGColorRef stroke = color_create(&background->border_color);
    layer.strokeColor = stroke;
    CGColorRelease(stroke);
    layer.lineWidth = background->border_width;
  } else {
    layer.strokeColor = nil;
    layer.lineWidth = 0.f;
  }
}

static CGPoint configure_marker_clip_layer(CALayer* layer,
                                           struct text* text,
                                           CGRect layer_frame) {
  if (!text->drawing) {
    layer.hidden = YES;
    layer.masksToBounds = NO;
    layer.frame = layer_frame;
    return CGPointZero;
  }

  layer.hidden = NO;
  layer.contentsScale = layer_scale;
  if (text->max_chars > 0) {
    CGRect clip = layer_frame;
    clip.origin.x = text->bounds.origin.x + text->padding_left;
    clip.size.width = text->width;
    layer.frame = clip;
    layer.masksToBounds = YES;
    return clip.origin;
  }

  layer.frame = layer_frame;
  layer.masksToBounds = NO;
  return CGPointZero;
}

static void configure_text_layer(CATextLayer* layer,
                                 struct text* text,
                                 CGPoint container_origin) {
  if (!text->drawing || !text->string || !text->line.line) {
    layer.hidden = YES;
    return;
  }

  layer.hidden = NO;
  layer.contentsScale = layer_scale;
  layer.alignmentMode = alignment_mode_for_char(text->align);
  layer.truncationMode = kCATruncationNone;
  layer.wrapped = NO;
  layer.font = text->font.ct_font;
  layer.fontSize = text->font.size;

  NSString* string = [[NSString alloc] initWithUTF8String:text->string];
  layer.string = string ? string : @"";
  [string release];

  struct color color = text->highlight ? text->highlight_color : text->color;
  CGColorRef text_color = color_create(&color);
  layer.foregroundColor = text_color;
  CGColorRelease(text_color);

  CGFloat width = text_get_length(text, true);
  CGFloat height = text->line.ascent + text->line.descent;
  if (height < text->bounds.size.height) height = text->bounds.size.height;

  layer.frame = CGRectMake(text->bounds.origin.x
                           + text->padding_left
                           - text->scroll
                           - container_origin.x,
                           text->bounds.origin.y
                           + text->y_offset
                           - text->line.descent
                           - container_origin.y,
                           width,
                           height);
}

static CGFloat badge_text_width(struct badge* badge) {
  return badge->advance_centering ? badge->advance : badge->width;
}

static void configure_badge_text_layer(CATextLayer* layer, struct badge* badge) {
  if (!badge->drawing || !badge->string || !badge->line.line) {
    layer.hidden = YES;
    return;
  }

  layer.hidden = NO;
  layer.contentsScale = layer_scale;
  layer.alignmentMode = alignment_mode_for_char(badge->align);
  layer.truncationMode = kCATruncationNone;
  layer.wrapped = NO;
  layer.font = badge->font.ct_font;
  layer.fontSize = badge->font.size;

  NSString* string = [[NSString alloc] initWithUTF8String:badge->string];
  layer.string = string ? string : @"";
  [string release];

  CGColorRef text_color = color_create(&badge->color);
  layer.foregroundColor = text_color;
  CGColorRelease(text_color);

  CGFloat width = badge_text_width(badge);
  CGFloat height = badge->line.ascent + badge->line.descent;
  if (height < badge->bounds.size.height) height = badge->bounds.size.height;

  layer.frame = CGRectMake(badge->bounds.origin.x,
                           badge->bounds.origin.y - badge->line.descent,
                           width,
                           height);
}

static struct layer_host* layer_host_create(struct window* window) {
  if (![CAContext respondsToSelector:@selector(contextWithCGSConnection:options:)])
    return NULL;

  struct layer_host* host = malloc(sizeof(struct layer_host));
  if (!host) return NULL;
  memset(host, 0, sizeof(struct layer_host));

  host->size = window->frame.size;
  host->context = [[CAContext contextWithCGSConnection:g_connection options:nil] retain];
  if (!host->context) {
    free(host);
    return NULL;
  }

  host->root = [[CALayer layer] retain];
  host->root.anchorPoint = CGPointZero;
  host->root.position = CGPointZero;
  host->root.bounds = CGRectMake(0, 0, host->size.width, host->size.height);
  host->root.contentsScale = layer_scale;
  host->root.geometryFlipped = NO;
  host->root.masksToBounds = NO;
  host->context.layer = host->root;

  if (SLSAddSurface(g_connection, window->id, &host->surface_id) != kCGErrorSuccess
      || host->surface_id == 0) {
    [host->context invalidate];
    [host->root release];
    [host->context release];
    free(host);
    return NULL;
  }

  CGRect bounds = CGRectMake(0, 0, host->size.width, host->size.height);
  // macOS 26 binds the CA context using screen-space coordinates. Older
  // releases use the historical window-relative zero origin, matching the
  // SLSSetWindowShape split in window_apply_frame().
  CGError error = layer_host_bind_surface(window, host);
  if (error != kCGErrorSuccess
      || SLSSetSurfaceBounds(g_connection,
                             window->id,
                             host->surface_id,
                             bounds) != kCGErrorSuccess) {
    SLSRemoveSurface(g_connection, window->id, host->surface_id);
    host->context.layer = nil;
    [host->context invalidate];
    [host->root release];
    [host->context release];
    free(host);
    return NULL;
  }
  SLSSetSurfaceResolution(g_connection, window->id, host->surface_id, layer_scale);
  SLSSetSurfaceOpacity(g_connection, window->id, host->surface_id, false);
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  SLSSetSurfaceColorSpace(g_connection, window->id, host->surface_id, color_space);
  CGColorSpaceRelease(color_space);
  SLSOrderSurface(g_connection, window->id, host->surface_id, W_ABOVE, 0);
  SLSFlushSurface(g_connection, window->id, host->surface_id, 0);

  return host;
}

static void layer_host_destroy(struct window* window) {
  struct layer_host* host = window->layer_host;
  if (!host) return;

  if (host->surface_id)
    SLSRemoveSurface(g_connection, window->id, host->surface_id);

  host->context.layer = nil;
  [host->context invalidate];
  [host->root release];
  [host->context release];
  free(host);

  window->layer_host = NULL;
}

static void layer_host_resize(struct window* window) {
  struct layer_host* host = window->layer_host;
  if (!host) return;

  host->size = window->frame.size;
  CGRect bounds = CGRectMake(0, 0, host->size.width, host->size.height);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  host->root.bounds = bounds;
  host->root.position = CGPointZero;
  [CATransaction commit];

  SLSSetSurfaceBounds(g_connection, window->id, host->surface_id, bounds);
  layer_host_rebind_surface_for_origin(window);
  SLSFlushSurface(g_connection, window->id, host->surface_id, 0);
}

static CAShapeLayer* shape_layer_create(CALayer* root) {
  CAShapeLayer* layer = [[CAShapeLayer layer] retain];
  layer.contentsScale = layer_scale;
  layer.fillColor = nil;
  [root addSublayer:layer];
  return layer;
}

static CALayer* container_layer_create(CALayer* root) {
  CALayer* layer = [[CALayer layer] retain];
  layer.contentsScale = layer_scale;
  layer.masksToBounds = NO;
  [root addSublayer:layer];
  return layer;
}

static CATextLayer* text_layer_create(CALayer* root) {
  CATextLayer* layer = [[CATextLayer layer] retain];
  layer.contentsScale = layer_scale;
  layer.needsDisplayOnBoundsChange = YES;
  [root addSublayer:layer];
  return layer;
}

static struct ring_layer_tree* ring_layer_tree_create(struct window* window) {
  if (!ring_layer_window_attach(window)) return NULL;

  struct ring_layer_tree* tree = malloc(sizeof(struct ring_layer_tree));
  if (!tree) return NULL;
  memset(tree, 0, sizeof(struct ring_layer_tree));

  CALayer* root = window->layer_host->root;
  tree->track = shape_layer_create(root);
  tree->progress = shape_layer_create(root);
  tree->marker_background = shape_layer_create(root);
  tree->marker_clip = container_layer_create(root);
  tree->marker = text_layer_create(tree->marker_clip);
  tree->marker_badge_background = shape_layer_create(root);
  tree->marker_badge = text_layer_create(root);
  tree->badge_background = shape_layer_create(root);
  tree->badge = text_layer_create(root);

  return tree;
}

static void ring_layer_tree_destroy(struct ring_layer_tree* tree) {
  if (!tree) return;

  [tree->track removeFromSuperlayer];
  [tree->progress removeFromSuperlayer];
  [tree->marker_background removeFromSuperlayer];
  [tree->marker removeFromSuperlayer];
  [tree->marker_clip removeFromSuperlayer];
  [tree->marker_badge_background removeFromSuperlayer];
  [tree->marker_badge removeFromSuperlayer];
  [tree->badge_background removeFromSuperlayer];
  [tree->badge removeFromSuperlayer];

  [tree->track release];
  [tree->progress release];
  [tree->marker_background release];
  [tree->marker release];
  [tree->marker_clip release];
  [tree->marker_badge_background release];
  [tree->marker_badge release];
  [tree->badge_background release];
  [tree->badge release];

  free(tree);
}

bool ring_layer_window_attach(struct window* window) {
  if (!window || !window->id) return false;
  if (window->layer_host) return true;

  window->layer_host = layer_host_create(window);
  return window->layer_host != NULL;
}

void ring_layer_window_resize(struct window* window) {
  if (!window || !window->layer_host) return;
  layer_host_resize(window);
}

void ring_layer_window_move(struct window* window) {
  if (!window || !window->layer_host) return;
  if (!layer_host_uses_screen_origin()) return;
  if (layer_host_rebind_surface_for_origin(window))
    layer_host_flush(window);
}

void ring_layer_window_destroy_tree(struct window* window) {
  if (!window || !window->ring_layer) return;
  ring_layer_tree_destroy(window->ring_layer);
  window->ring_layer = NULL;
}

void ring_layer_window_destroy(struct window* window) {
  if (!window) return;
  ring_layer_window_destroy_tree(window);
  layer_host_destroy(window);
}

bool ring_layer_window_has_tree(struct window* window) {
  return window && window->layer_host && window->ring_layer;
}

static bool ensure_ring_layer_tree(struct ring* ring, struct window* window) {
  if (!ring_layer_can_render(ring)) {
    ring_layer_window_destroy_tree(window);
    return false;
  }

  if (!window->ring_layer)
    window->ring_layer = ring_layer_tree_create(window);

  return window->ring_layer != NULL;
}

static void ring_layer_configure_arcs(struct ring* ring, struct ring_layer_tree* tree) {
  CGFloat line_width = ring->line_width > 0.f
                       ? min(ring->line_width, (float)ring->width)
                       : 0.f;
  bool draws_track = ring->enabled && ring->width > 0 && line_width > 0.f
                     && ring->track_color.a > 0.f;
  bool draws_progress = ring->enabled && ring->width > 0 && line_width > 0.f
                        && ring->color.a > 0.f;

  CGPathRef path = ring_path_create(ring);

  tree->track.hidden = !draws_track;
  tree->track.path = path;
  tree->track.lineWidth = line_width;
  tree->track.lineCap = line_cap_for_ring(ring->cap);
  tree->track.strokeStart = 0.f;
  tree->track.strokeEnd = 1.f;
  if (draws_track) {
    CGColorRef track_color = color_create(&ring->track_color);
    tree->track.strokeColor = track_color;
    CGColorRelease(track_color);
  }

  tree->progress.hidden = !draws_progress;
  tree->progress.path = path;
  tree->progress.lineWidth = line_width;
  tree->progress.lineCap = line_cap_for_ring(ring->cap);
  tree->progress.strokeStart = 0.f;
  tree->progress.strokeEnd = ring->value;
  if (draws_progress) {
    CGColorRef progress_color = color_create(&ring->color);
    tree->progress.strokeColor = progress_color;
    CGColorRelease(progress_color);
  }

  CGPathRelease(path);
}

bool ring_layer_update(struct ring* ring, struct window* window, bool disable_actions) {
  if (!ring || !window) return false;
  if (!ensure_ring_layer_tree(ring, window)) return false;

  struct ring_layer_tree* tree = window->ring_layer;
  CGRect layer_frame = CGRectMake(0, 0,
                                  window->frame.size.width,
                                  window->frame.size.height);
  tree->track.frame = layer_frame;
  tree->progress.frame = layer_frame;
  tree->marker_background.frame = layer_frame;
  tree->marker_clip.frame = layer_frame;
  tree->marker_badge_background.frame = layer_frame;
  tree->badge_background.frame = layer_frame;

  [CATransaction begin];
  [CATransaction setDisableActions:disable_actions ? YES : NO];

  ring_layer_configure_arcs(ring, tree);

  configure_background_layer(tree->marker_background, &ring->marker.background);
  CGPoint marker_origin = configure_marker_clip_layer(tree->marker_clip,
                                                     &ring->marker,
                                                     layer_frame);
  configure_text_layer(tree->marker, &ring->marker, marker_origin);
  configure_background_layer(tree->marker_badge_background,
                             &ring->marker.badge.background);
  configure_badge_text_layer(tree->marker_badge, &ring->marker.badge);
  configure_background_layer(tree->badge_background, &ring->badge.background);
  configure_badge_text_layer(tree->badge, &ring->badge);

  [CATransaction commit];
  [CATransaction flush];

  layer_host_flush(window);

  return true;
}

bool ring_layer_set_value(struct ring* ring, struct window* window, float value) {
  if (!ring || !window || !ring_layer_window_has_tree(window)) return false;
  struct ring_layer_tree* tree = window->ring_layer;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  cancel_layer_animation(tree->progress, @"strokeEnd");
  tree->progress.strokeEnd = value;
  [CATransaction commit];
  [CATransaction flush];
  layer_host_flush(window);
  return true;
}

bool ring_layer_animate_value(struct ring* ring,
                              struct window* window,
                              float value,
                              uint32_t duration,
                              char interp_function) {
  if (!ring || !window || !ring_layer_window_has_tree(window)) return false;
  struct ring_layer_tree* tree = window->ring_layer;

  NSNumber* target = [NSNumber numberWithFloat:value];

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  add_basic_animation(tree->progress,
                      @"strokeEnd",
                      target,
                      duration,
                      interp_function);
  tree->progress.strokeEnd = value;
  [CATransaction commit];
  [CATransaction flush];
  layer_host_flush(window);
  return true;
}

bool ring_layer_set_color(struct ring* ring, struct window* window, bool track) {
  if (!ring || !window || !ring_layer_window_has_tree(window)) return false;
  struct ring_layer_tree* tree = window->ring_layer;
  CAShapeLayer* layer = track ? tree->track : tree->progress;
  struct color* color = track ? &ring->track_color : &ring->color;

  CGColorRef cg_color = color_create(color);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  cancel_layer_animation(layer, @"strokeColor");
  layer.strokeColor = cg_color;
  layer.hidden = !ring_layer_arc_drawable(ring) || color->a <= 0.f;
  [CATransaction commit];
  CGColorRelease(cg_color);
  [CATransaction flush];
  layer_host_flush(window);
  return true;
}

bool ring_layer_sync_color(struct ring* ring, struct window* window, bool track) {
  if (!ring || !window || !ring_layer_window_has_tree(window)) return false;
  struct ring_layer_tree* tree = window->ring_layer;
  CAShapeLayer* layer = track ? tree->track : tree->progress;
  struct color* color = track ? &ring->track_color : &ring->color;

  CGColorRef cg_color = color_create(color);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.strokeColor = cg_color;
  if (![layer animationForKey:@"strokeColor"])
    layer.hidden = !ring_layer_arc_drawable(ring) || color->a <= 0.f;
  [CATransaction commit];
  CGColorRelease(cg_color);
  [CATransaction flush];
  layer_host_flush(window);
  return true;
}

bool ring_layer_animate_color(struct ring* ring,
                              struct window* window,
                              bool track,
                              uint32_t duration,
                              char interp_function) {
  if (!ring || !window || !ring_layer_window_has_tree(window)) return false;
  struct ring_layer_tree* tree = window->ring_layer;
  CAShapeLayer* layer = track ? tree->track : tree->progress;
  struct color* color = track ? &ring->track_color : &ring->color;

  CGColorRef cg_color = color_create(color);
  bool drawable = ring_layer_arc_drawable(ring);

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (drawable) {
    // Keep drawable arcs visible for the duration of the animation so a fade
    // to alpha zero is actually visible.
    layer.hidden = NO;
    add_basic_animation(layer,
                        @"strokeColor",
                        (id)cg_color,
                        duration,
                        interp_function);
  } else {
    cancel_layer_animation(layer, @"strokeColor");
    layer.hidden = YES;
  }
  layer.strokeColor = cg_color;
  [CATransaction commit];
  CGColorRelease(cg_color);
  [CATransaction flush];
  layer_host_flush(window);
  return true;
}

bool ring_layer_set_line_width(struct ring* ring, struct window* window) {
  if (!ring || !window || !ring_layer_window_has_tree(window)) return false;
  return ring_layer_update(ring, window, true);
}
