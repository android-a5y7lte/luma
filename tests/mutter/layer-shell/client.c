/* SPDX-License-Identifier: Apache-2.0 */
/* A zwlr_layer_shell_v1 client for the layer-shell test (run.sh). It places
 * one solid-coloured layer surface and logs, one line each on stdout:
 *
 *   bound VERSION            the global was there
 *   no-global                it was not
 *   configure W H            each configure (acknowledged and drawn at once)
 *   closed                   the compositor closed the surface
 *   keyboard-enter|leave     keyboard focus
 *   key KEY                  a key press
 *   popup-configure X Y W H  / popup-done
 *
 *   layer-test-client [--layer background|bottom|top|overlay]
 *     [--anchor tblr] [--size WxH] [--zone N] [--edge t|b|l|r]
 *     [--margin T,R,B,L] [--keyboard none|exclusive|on_demand]
 *     [--namespace NAME] [--colour RRGGBB] [--popup]
 *     [--set-layer-after-ms LAYER:MS] [--empty-input]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm_base;
static struct zwlr_layer_shell_v1 *layer_shell;
static struct wl_surface *surface;
static struct zwlr_layer_surface_v1 *layer_surface;
static struct wl_surface *popup_surface;
static struct xdg_surface *popup_xdg_surface;
static uint32_t colour = 0xcc3366ff;
static int closed;
static int want_popup;
static int popup_made;

static void
say (const char *fmt, ...)
{
  va_list args;

  va_start (args, fmt);
  vprintf (fmt, args);
  va_end (args);
  putchar ('\n');
  fflush (stdout);
}

static struct wl_buffer *
make_buffer (int width, int height, uint32_t argb)
{
  int stride = width * 4;
  int size = stride * height;
  int fd = memfd_create ("layer-test", MFD_CLOEXEC);
  struct wl_shm_pool *pool;
  struct wl_buffer *buffer;
  uint32_t *data;
  int i;

  if (fd < 0 || ftruncate (fd, size) < 0)
    exit (2);
  data = mmap (NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  for (i = 0; i < width * height; i++)
    data[i] = argb;
  munmap (data, size);
  pool = wl_shm_create_pool (shm, fd, size);
  buffer = wl_shm_pool_create_buffer (pool, 0, width, height, stride,
                                      WL_SHM_FORMAT_ARGB8888);
  wl_shm_pool_destroy (pool);
  close (fd);
  return buffer;
}

/* Popup */

static void
popup_configure (void *data, struct xdg_popup *popup,
                 int32_t x, int32_t y, int32_t width, int32_t height)
{
  say ("popup-configure %d %d %d %d", x, y, width, height);
}

static void
popup_done (void *data, struct xdg_popup *popup)
{
  say ("popup-done");
}

static void
popup_repositioned (void *data, struct xdg_popup *popup, uint32_t token)
{
}

static const struct xdg_popup_listener popup_listener = {
  popup_configure, popup_done, popup_repositioned,
};

static void
popup_surface_configure (void *data, struct xdg_surface *xdg_surface,
                         uint32_t serial)
{
  xdg_surface_ack_configure (xdg_surface, serial);
  wl_surface_attach (popup_surface, make_buffer (120, 80, 0xff22aa44), 0, 0);
  wl_surface_damage_buffer (popup_surface, 0, 0, 120, 80);
  wl_surface_commit (popup_surface);
}

static const struct xdg_surface_listener popup_surface_listener = {
  popup_surface_configure,
};

static void
make_popup (void)
{
  struct xdg_positioner *positioner = xdg_wm_base_create_positioner (wm_base);
  struct xdg_popup *popup;

  xdg_positioner_set_size (positioner, 120, 80);
  xdg_positioner_set_anchor_rect (positioner, 0, 0, 10, 10);
  xdg_positioner_set_anchor (positioner, XDG_POSITIONER_ANCHOR_BOTTOM_LEFT);
  xdg_positioner_set_gravity (positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);

  popup_surface = wl_compositor_create_surface (compositor);
  popup_xdg_surface = xdg_wm_base_get_xdg_surface (wm_base, popup_surface);
  xdg_surface_add_listener (popup_xdg_surface, &popup_surface_listener, NULL);
  popup = xdg_surface_get_popup (popup_xdg_surface, NULL, positioner);
  xdg_popup_add_listener (popup, &popup_listener, NULL);
  zwlr_layer_surface_v1_get_popup (layer_surface, popup);
  wl_surface_commit (popup_surface);
  xdg_positioner_destroy (positioner);
}

/* Layer surface */

static void
layer_configure (void *data, struct zwlr_layer_surface_v1 *ls,
                 uint32_t serial, uint32_t width, uint32_t height)
{
  say ("configure %u %u", width, height);
  zwlr_layer_surface_v1_ack_configure (ls, serial);
  wl_surface_attach (surface, make_buffer (width ? width : 1, height ? height : 1,
                                           colour), 0, 0);
  wl_surface_damage_buffer (surface, 0, 0, width, height);
  wl_surface_commit (surface);

  if (want_popup && !popup_made)
    {
      popup_made = 1;
      make_popup ();
    }
}

static void
layer_closed (void *data, struct zwlr_layer_surface_v1 *ls)
{
  say ("closed");
  closed = 1;
}

static const struct zwlr_layer_surface_v1_listener layer_listener = {
  layer_configure, layer_closed,
};

/* Keyboard */

static void kb_keymap (void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t s) { close (fd); }
static void kb_enter (void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys) { say ("keyboard-enter"); }
static void kb_leave (void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf) { say ("keyboard-leave"); }
static void kb_key (void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t state) { if (state) say ("key %u", key); }
static void kb_modifiers (void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) {}
static void kb_repeat (void *d, struct wl_keyboard *k, int32_t r, int32_t de) {}

static const struct wl_keyboard_listener keyboard_listener = {
  kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat,
};

static void
wm_base_ping (void *data, struct xdg_wm_base *base, uint32_t serial)
{
  xdg_wm_base_pong (base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { wm_base_ping };

static void
registry_global (void *data, struct wl_registry *registry, uint32_t name,
                 const char *interface, uint32_t version)
{
  if (strcmp (interface, wl_compositor_interface.name) == 0)
    compositor = wl_registry_bind (registry, name, &wl_compositor_interface, 4);
  else if (strcmp (interface, wl_shm_interface.name) == 0)
    shm = wl_registry_bind (registry, name, &wl_shm_interface, 1);
  else if (strcmp (interface, wl_seat_interface.name) == 0)
    seat = wl_registry_bind (registry, name, &wl_seat_interface, 5);
  else if (strcmp (interface, xdg_wm_base_interface.name) == 0)
    {
      wm_base = wl_registry_bind (registry, name, &xdg_wm_base_interface, 2);
      xdg_wm_base_add_listener (wm_base, &wm_base_listener, NULL);
    }
  else if (strcmp (interface, zwlr_layer_shell_v1_interface.name) == 0)
    {
      layer_shell = wl_registry_bind (registry, name,
                                      &zwlr_layer_shell_v1_interface,
                                      version < 5 ? version : 5);
      say ("bound %u", version);
    }
}

static void
registry_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
}

static const struct wl_registry_listener registry_listener = {
  registry_global, registry_global_remove,
};

static uint32_t
parse_layer (const char *name)
{
  if (strcmp (name, "background") == 0) return ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND;
  if (strcmp (name, "bottom") == 0) return ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM;
  if (strcmp (name, "overlay") == 0) return ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY;
  return ZWLR_LAYER_SHELL_V1_LAYER_TOP;
}

static uint32_t
parse_edges (const char *s)
{
  uint32_t edges = 0;

  for (; *s; s++)
    edges |= *s == 't' ? ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP :
             *s == 'b' ? ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM :
             *s == 'l' ? ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT :
             *s == 'r' ? ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT : 0;
  return edges;
}

static int64_t
now_ms (void)
{
  struct timespec ts;

  clock_gettime (CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int
main (int argc, char **argv)
{
  uint32_t layer = ZWLR_LAYER_SHELL_V1_LAYER_TOP;
  uint32_t anchor = 0, edge = 0, keyboard = 0;
  uint32_t width = 200, height = 100;
  int32_t zone = 0, margin[4] = { 0 };
  const char *namespace = "layer-test";
  uint32_t later_layer = 0;
  int64_t later_at = -1;
  int empty_input = 0;
  struct wl_display *display;
  struct wl_registry *registry;
  int i;

  for (i = 1; i < argc; i++)
    {
      const char *arg = argv[i];
      const char *value = i + 1 < argc ? argv[i + 1] : "";

      if (strcmp (arg, "--layer") == 0) { layer = parse_layer (value); i++; }
      else if (strcmp (arg, "--anchor") == 0) { anchor = parse_edges (value); i++; }
      else if (strcmp (arg, "--edge") == 0) { edge = parse_edges (value); i++; }
      else if (strcmp (arg, "--size") == 0) { sscanf (value, "%ux%u", &width, &height); i++; }
      else if (strcmp (arg, "--zone") == 0) { zone = atoi (value); i++; }
      else if (strcmp (arg, "--margin") == 0) { sscanf (value, "%d,%d,%d,%d", &margin[0], &margin[1], &margin[2], &margin[3]); i++; }
      else if (strcmp (arg, "--keyboard") == 0)
        {
          keyboard = strcmp (value, "exclusive") == 0 ? 1 :
                     strcmp (value, "on_demand") == 0 ? 2 : 0;
          i++;
        }
      else if (strcmp (arg, "--namespace") == 0) { namespace = value; i++; }
      else if (strcmp (arg, "--colour") == 0) { colour = 0xff000000 | strtoul (value, NULL, 16); i++; }
      else if (strcmp (arg, "--popup") == 0) want_popup = 1;
      else if (strcmp (arg, "--empty-input") == 0) empty_input = 1;
      else if (strcmp (arg, "--set-layer-after-ms") == 0)
        {
          char name[32] = "";
          int ms = 0;

          sscanf (value, "%31[a-z]:%d", name, &ms);
          later_layer = parse_layer (name);
          later_at = now_ms () + ms;
          i++;
        }
    }

  display = wl_display_connect (NULL);
  if (!display)
    return 3;

  registry = wl_display_get_registry (display);
  wl_registry_add_listener (registry, &registry_listener, NULL);
  wl_display_roundtrip (display);

  if (!layer_shell)
    {
      say ("no-global");
      return 4;
    }

  if (seat)
    wl_keyboard_add_listener (wl_seat_get_keyboard (seat), &keyboard_listener, NULL);

  surface = wl_compositor_create_surface (compositor);
  layer_surface = zwlr_layer_shell_v1_get_layer_surface (layer_shell, surface,
                                                         NULL, layer, namespace);
  zwlr_layer_surface_v1_add_listener (layer_surface, &layer_listener, NULL);
  zwlr_layer_surface_v1_set_size (layer_surface, width, height);
  zwlr_layer_surface_v1_set_anchor (layer_surface, anchor);
  zwlr_layer_surface_v1_set_exclusive_zone (layer_surface, zone);
  zwlr_layer_surface_v1_set_margin (layer_surface, margin[0], margin[1],
                                    margin[2], margin[3]);
  zwlr_layer_surface_v1_set_keyboard_interactivity (layer_surface, keyboard);
  if (edge)
    zwlr_layer_surface_v1_set_exclusive_edge (layer_surface, edge);
  if (empty_input)
    {
      struct wl_region *region = wl_compositor_create_region (compositor);

      wl_surface_set_input_region (surface, region);
      wl_region_destroy (region);
    }
  wl_surface_commit (surface);

  while (!closed)
    {
      struct pollfd pfd = { wl_display_get_fd (display), POLLIN, 0 };
      int timeout = -1;

      wl_display_flush (display);
      if (later_at >= 0)
        timeout = (int) (later_at - now_ms () > 0 ? later_at - now_ms () : 0);

      if (poll (&pfd, 1, timeout) > 0)
        {
          if (wl_display_dispatch (display) < 0)
            {
              say ("error %d", wl_display_get_error (display));
              return 5;
            }
        }

      if (later_at >= 0 && now_ms () >= later_at)
        {
          later_at = -1;
          zwlr_layer_surface_v1_set_layer (layer_surface, later_layer);
          wl_surface_commit (surface);
          say ("set-layer %u", later_layer);
        }
    }

  wl_display_roundtrip (display);
  return 0;
}
