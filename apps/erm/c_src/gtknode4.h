#ifndef GTKNODE4_H
#define GTKNODE4_H

#include <gtk/gtk.h>
#include <ei.h>
#include <stdint.h>

/*
 * Basic runtime state for the GTK4 C-node.
 */
typedef struct {
  /* Erlang node configuration */
  char  *node_name;
  char  *cookie;
  char  *peer_node;
  char  *peer_regname;

  /* Erlang connection */
  int       dist_fd;
  int       creation;
  ei_cnode  ec;

  /* GTK / UI state */
  GtkApplication *app;
  GtkBuilder     *builder;   /* keep the builder here */

  gboolean  running;
} Gn4State;



/* ---- Lifecycle -------------------------------------------------------- */

/* Parse CLI arguments & initialise Gn4State. Does not connect or init GTK. */
gboolean gn4_parse_args(Gn4State *st, int argc, char **argv);

/* Initialise Erlang C-node connection using ei. */
gboolean gn4_init_erlang(Gn4State *st);

/* Initialise GTK4 / GtkApplication. */
gboolean gn4_init_gtk(Gn4State *st, int *argc, char ***argv);

/* Main event loop: interleave Erlang I/O and GTK main context. */
void gn4_main_loop(Gn4State *st);

/* Clean up resources. */
void gn4_cleanup(Gn4State *st);

/* ---- Erlang protocol -------------------------------------------------- */

/* Handle one incoming Erlang message; non-blocking wrapper. */
gboolean gn4_poll_erlang(Gn4State *st);

/* Send a simple tuple back to the Erlang controller, e.g. {gtknode4, ok}. */
gboolean gn4_send_hello(Gn4State *st);

/* ---- GTK / UI helpers ------------------------------------------------- */

/* Load a UI file via GtkBuilder and cache widgets by name. */
gboolean gn4_load_ui(Gn4State *st, const char *filename);

/* Lookup widget by name (from Erlang). */
GtkWidget *gn4_get_widget(Gn4State *st, const char *name);

/* Example: set a label on a GtkButton/GtkLabel from a UTF-8 string. */
gboolean gn4_set_widget_label(Gn4State *st,
                              const char *widget_name,
                              const char *text);

/* Hook up signals of interest to a generic handler that calls back to Erlang. */
void gn4_connect_signals(Gn4State *st, GtkBuilder *builder);

/* Generic signal callback used from GTK. */
void gn4_signal_handler(GtkWidget *widget,
                        const char *signal_name,
                        gpointer user_data);

#endif /* GTKNODE4_H */
