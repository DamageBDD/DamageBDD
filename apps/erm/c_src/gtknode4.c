#include "gtknode4.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/* ----------------------------------------------------------------------
 * Utility
 * ---------------------------------------------------------------------- */

static char *
gn4_strdup(const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s) + 1;
  char *p = malloc(n);
  if (p) memcpy(p, s, n);
  return p;
}

/* ----------------------------------------------------------------------
 * Argument parsing
 *
 * Example CLI (adjust as needed):
 *   gtknode4 <this-node> <cookie> <peer-node> <peer-regname>
 *
 * In practice you can mirror the existing gtknode CLI.
 * ---------------------------------------------------------------------- */
gboolean
gn4_parse_args(Gn4State *st, int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr,
            "Usage: %s <this-node> <cookie> <peer-node> <peer-regname>\n",
            argv[0]);
    return FALSE;
  }

  memset(st, 0, sizeof(*st));


  return TRUE;
}
/* Decode a binary or string term into a malloc'ed C string (NUL-terminated).
 * Caller must free() the returned value.
 */
static char *
gn4_decode_string(ei_x_buff *x, int *idx) {
  int type, size;
  long len;
  char *buf;

  if (ei_get_type(x->buff, idx, &type, &size) < 0)
    return NULL;

  buf = (char *)malloc((size_t)size + 1);
  if (!buf)
    return NULL;

  if (type == ERL_BINARY_EXT) {
    if (ei_decode_binary(x->buff, idx, buf, &len) < 0) {
      free(buf);
      return NULL;
    }
    buf[len] = '\0';
  } else if (type == ERL_STRING_EXT) {
    if (ei_decode_string(x->buff, idx, buf) < 0) {
      free(buf);
      return NULL;
    }
  } else if (type == ERL_ATOM_EXT || type == ERL_SMALL_ATOM_EXT) {
    if (ei_decode_atom(x->buff, idx, buf) < 0) {
      free(buf);
      return NULL;
    }
  } else {
    free(buf);
    return NULL;
  }

  return buf;
}

/* Helper to send {gtknode4, reply, Ref, Result} where Result is:
 *   - ok          -> encode atom ok
 *   - error(Atom) -> encode {error, Atom}
 *   - ok_bin(Str) -> encode {ok, <<Str>>}
 */
static void
gn4_send_reply_ok(Gn4State *st, const erlang_ref *ref) {
  ei_x_buff r;
  ei_x_new_with_version(&r);

  ei_x_encode_tuple_header(&r, 4);
  ei_x_encode_atom(&r, "gtknode4");
  ei_x_encode_atom(&r, "reply");
  ei_x_encode_ref(&r, (erlang_ref *)ref);
  ei_x_encode_atom(&r, "ok");

  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, r.buff, r.index);
  ei_x_free(&r);
}


static void
gn4_send_reply_error(Gn4State *st, const erlang_ref *ref, const char *reason) {
  ei_x_buff r;
  ei_x_new_with_version(&r);

  ei_x_encode_tuple_header(&r, 4);
  ei_x_encode_atom(&r, "gtknode4");
  ei_x_encode_atom(&r, "reply");
  ei_x_encode_ref(&r, (erlang_ref *)ref);

  ei_x_encode_tuple_header(&r, 2);
  ei_x_encode_atom(&r, "error");
  ei_x_encode_atom(&r, reason ? reason : "unknown");

  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, r.buff, r.index);
  ei_x_free(&r);
}


static void
gn4_send_reply_ok_binary(Gn4State *st, const erlang_ref *ref, const char *bin) {
  ei_x_buff r;
  size_t len = bin ? strlen(bin) : 0;

  ei_x_new_with_version(&r);

  ei_x_encode_tuple_header(&r, 4);
  ei_x_encode_atom(&r, "gtknode4");
  ei_x_encode_atom(&r, "reply");
  ei_x_encode_ref(&r, (erlang_ref *)ref);

  ei_x_encode_tuple_header(&r, 2);
  ei_x_encode_atom(&r, "ok");
  ei_x_encode_binary(&r, bin, (long)len);

  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, r.buff, r.index);
  ei_x_free(&r);
}



/* ----------------------------------------------------------------------
 * Erlang C-node init (ei)
 * ---------------------------------------------------------------------- */

#define CREATION 1

gboolean
gn4_init_erlang(Gn4State *st) {
  int r;

  /* Initialise ei cnode with our node name + cookie */
  r = ei_connect_init(&st->ec, st->node_name, st->cookie, CREATION);
  if (r < 0) {
    fprintf(stderr, "ei_connect_init failed: %d\n", r);
    return FALSE;
  }

  /* Connect to remote Erlang node */
  st->dist_fd = ei_connect(&st->ec, st->peer_node);
  if (st->dist_fd < 0) {
    fprintf(stderr, "ei_connect to %s failed: %d\n",
            st->peer_node, st->dist_fd);
    return FALSE;
  }

  fprintf(stderr, "gtknode4: connected to %s as %s (fd=%d)\n",
          st->peer_node, st->node_name, st->dist_fd);

  return TRUE;
}


/* ----------------------------------------------------------------------
 * GTK4 init
 * ---------------------------------------------------------------------- */

static void
gn4_app_activate(GApplication *app, gpointer user_data) {
  /* You can create a default window here if desired. */
  (void) user_data;

  GtkApplication *gtk_app = GTK_APPLICATION(app);
  GtkWidget *win = gtk_application_window_new(gtk_app);
  gtk_window_set_title(GTK_WINDOW(win), "gtknode4");
  gtk_window_set_default_size(GTK_WINDOW(win), 400, 200);
  gtk_window_present(GTK_WINDOW(win));

}

gboolean
gn4_init_gtk(Gn4State *st, int *argc, char ***argv) {
  (void)argc;   /* silence unused parameter warnings */
  (void)argv;

  st->app = gtk_application_new("org.damagebdd.gtknode4",
                                G_APPLICATION_DEFAULT_FLAGS);
  if (!st->app) {
    fprintf(stderr, "Failed to create GtkApplication\n");
    return FALSE;
  }

  g_signal_connect(st->app, "activate",
                   G_CALLBACK(gn4_app_activate), st);

  /* We don’t call g_application_run here; gn4_main_loop drives GMainContext */
  return TRUE;
}

/* ----------------------------------------------------------------------
 * Erlang message polling (skeleton)
 * ---------------------------------------------------------------------- */

gboolean
gn4_poll_erlang(Gn4State *st) {
  if (st->dist_fd < 0)
    return FALSE;

  ei_x_buff x;
  erlang_msg msg;
  int r;

  ei_x_new(&x);
  r = ei_xreceive_msg(st->dist_fd, &msg, &x);

    if (r == ERL_TICK) {
        ei_x_free(&x);
        return TRUE;
    }
    if (r == ERL_ERROR) {
        fprintf(stderr, "gtknode4: ei_xreceive_msg error\n");
        st->running = FALSE;
        ei_x_free(&x);
        return FALSE;
    }

    if (msg.msgtype != ERL_REG_SEND && msg.msgtype != ERL_SEND) {
        ei_x_free(&x);
        return TRUE;
	}

	int idx = 0;
	int version;
	int arity;
	char atom[256];

	if (ei_decode_version(x.buff, &idx, &version) < 0)
		goto decode_error;

	/* Expect {gtknode4, call, Ref, Command} */
	if (ei_decode_tuple_header(x.buff, &idx, &arity) < 0 || arity != 4)
		goto decode_error;

	if (ei_decode_atom(x.buff, &idx, atom) < 0)
		goto decode_error;
	if (strcmp(atom, "gtknode4") != 0)
		goto decode_error;

	if (ei_decode_atom(x.buff, &idx, atom) < 0)
		goto decode_error;
	if (strcmp(atom, "call") != 0)
		goto decode_error;

	erlang_ref ref;
	if (ei_decode_ref(x.buff, &idx, &ref) < 0)
		goto decode_error;

	/* Command tuple: {load_ui, Filename} | {set_label, Name, Text} | {get_label, Name} */
	int cmd_arity;
	if (ei_decode_tuple_header(x.buff, &idx, &cmd_arity) < 0 || cmd_arity < 1)
		goto decode_error;

	if (ei_decode_atom(x.buff, &idx, atom) < 0)
		goto decode_error;

	if (strcmp(atom, "load_ui") == 0 && cmd_arity == 2) {
		char *filename = gn4_decode_string(&x, &idx);
		if (!filename) {
			gn4_send_reply_error(st, &ref, "badarg");
		} else {
			gboolean ok = gn4_load_ui(st, filename);
			if (ok)
				gn4_send_reply_ok(st, &ref);
			else
				gn4_send_reply_error(st, &ref, "load_ui_failed");
			free(filename);
		}

	} else if (strcmp(atom, "set_label") == 0 && cmd_arity == 3) {
		char *widget_name = gn4_decode_string(&x, &idx);
		char *text        = gn4_decode_string(&x, &idx);
		if (!widget_name || !text) {
			gn4_send_reply_error(st, &ref, "badarg");
		} else {
			gboolean ok = gn4_set_widget_label(st, widget_name, text);
			if (ok)
				gn4_send_reply_ok(st, &ref);
			else
				gn4_send_reply_error(st, &ref, "set_label_failed");
		}
		free(widget_name);
		free(text);

	} else if (strcmp(atom, "get_label") == 0 && cmd_arity == 2) {
		char *widget_name = gn4_decode_string(&x, &idx);
		if (!widget_name) {
			gn4_send_reply_error(st, &ref, "badarg");
		} else {
			GtkWidget *w = gn4_get_widget(st, widget_name);
			if (!w) {
				gn4_send_reply_error(st, &ref, "widget_not_found");
			} else {
				const char *label = NULL;
				if (GTK_IS_BUTTON(w)) {
					label = gtk_button_get_label(GTK_BUTTON(w));
				} else if (GTK_IS_LABEL(w)) {
					label = gtk_label_get_text(GTK_LABEL(w));
				}
				if (label) {
					gn4_send_reply_ok_binary(st, &ref, label);
				} else {
					gn4_send_reply_error(st, &ref, "no_label");
				}
			}
		}
		free(widget_name);

	} else {
		/* Unknown command */
		fprintf(stderr, "gtknode4: unknown command atom '%s'\n", atom);
		gn4_send_reply_error(st, &ref, "unknown_command");
	}

	ei_x_free(&x);
	return TRUE;

decode_error:
	fprintf(stderr, "gtknode4: decode error in gn4_poll_erlang\n");
	ei_x_free(&x);
	return TRUE;
}


/* ----------------------------------------------------------------------
 * Example: send hello tuple {gtknode4, ok}
 * ---------------------------------------------------------------------- */

gboolean
gn4_send_hello(Gn4State *st) {
  if (st->dist_fd < 0)
    return FALSE;

  ei_x_buff x;
  ei_x_new_with_version(&x);

  ei_x_encode_tuple_header(&x, 2);
  ei_x_encode_atom(&x, "gtknode4");
  ei_x_encode_atom(&x, "ok");

  if (ei_reg_send(&st->ec,
                  st->dist_fd,
                  st->peer_regname,
                  x.buff,
                  x.index) < 0) {
    fprintf(stderr, "gtknode4: ei_reg_send (hello) failed\n");
    ei_x_free(&x);
    return FALSE;
  }

  ei_x_free(&x);
  return TRUE;
}


/* ----------------------------------------------------------------------
 * GTK / UI helpers (skeleton)
 * ---------------------------------------------------------------------- */

gboolean
gn4_load_ui(Gn4State *st, const char *filename) {
  GError *err = NULL;
  GtkBuilder *builder = gtk_builder_new();

  if (!gtk_builder_add_from_file(builder, filename, &err)) {
    fprintf(stderr, "Error loading UI file '%s': %s\n",
            filename, err ? err->message : "unknown");
    if (err) g_error_free(err);
    g_object_unref(builder);
    return FALSE;
  }

  /* Optionally connect signals later – currently a no-op */
  gn4_connect_signals(st, builder);

  /* Drop any previous builder and keep this one */
  if (st->builder)
    g_object_unref(st->builder);
  st->builder = builder;

  return TRUE;
}


GtkWidget *
gn4_get_widget(Gn4State *st, const char *name) {
  if (!st->builder || !name)
    return NULL;

  GObject *obj = gtk_builder_get_object(st->builder, name);
  if (!obj || !GTK_IS_WIDGET(obj))
    return NULL;

  return GTK_WIDGET(obj);
}


gboolean
gn4_set_widget_label(Gn4State *st,
                     const char *widget_name,
                     const char *text) {
  GtkWidget *w = gn4_get_widget(st, widget_name);
  if (!w)
    return FALSE;

  if (GTK_IS_BUTTON(w)) {
    gtk_button_set_label(GTK_BUTTON(w), text);
    return TRUE;
  } else if (GTK_IS_LABEL(w)) {
    gtk_label_set_text(GTK_LABEL(w), text);
    return TRUE;
  }

  return FALSE;
}

void
gn4_connect_signals(Gn4State *st, GtkBuilder *builder) {
  (void)st;
  (void)builder;
  /* TODO: use g_signal_connect() here when you decide which signals to expose */
}



/* Generic signal handler pattern. You can create small wrappers
 * like on_button_clicked() that call this with the signal name.
 */
void
gn4_signal_handler(GtkWidget *widget,
                   const char *signal_name,
                   gpointer user_data) {
  Gn4State *st = (Gn4State *)user_data;
  (void)widget;
  (void)st;

  const char *wname = "unknown";

  fprintf(stderr, "gtknode4: signal %s on widget %s\n",
          signal_name ? signal_name : "(unknown)",
          wname);

  /* TODO: build and send {gtknode4, signal, WidgetName, SignalName, Payload}
   * with a real widget name once you wire manual signal handlers.
   */
}


/* ----------------------------------------------------------------------
 * Main loop
 * ---------------------------------------------------------------------- */

void
gn4_main_loop(Gn4State *st) {
  GMainContext *ctx = g_main_context_default();

  while (st->running) {
    /* 1. Poll Erlang; non-blocking */
    gn4_poll_erlang(st);

    /* 2. Process GTK events */
    while (g_main_context_pending(ctx)) {
      g_main_context_iteration(ctx, FALSE);
    }

    /* Avoid busy loop */
    g_usleep(1000); /* 1 ms; tune as needed */
  }
}

/* ----------------------------------------------------------------------
 * Cleanup
 * ---------------------------------------------------------------------- */

void
gn4_cleanup(Gn4State *st) {
  if (!st)
    return;

  if (st->dist_fd >= 0) {
    close(st->dist_fd);
    st->dist_fd = -1;
  }


  if (st->app) {
    g_object_unref(st->app);
    st->app = NULL;
  }

  free(st->node_name);
  free(st->cookie);
  free(st->peer_node);
  free(st->peer_regname);
}

/* ----------------------------------------------------------------------
 * Entry point
 * ---------------------------------------------------------------------- */

int
main(int argc, char **argv) {
  Gn4State st;

  if (!gn4_parse_args(&st, argc, argv))
    return 1;

  if (!gn4_init_erlang(&st)) {
    gn4_cleanup(&st);
    return 1;
  }

  if (!gn4_init_gtk(&st, &argc, &argv)) {
    gn4_cleanup(&st);
    return 1;
  }

  /* Optional handshake to Erlang controller */
  gn4_send_hello(&st);

  gn4_main_loop(&st);
  gn4_cleanup(&st);

  return 0;
}
