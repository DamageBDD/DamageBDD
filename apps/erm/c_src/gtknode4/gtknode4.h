#ifndef GTKNODE4_H
#define GTKNODE4_H

#include <gtk/gtk.h>
#include <ei.h>
#include <stdint.h>

/* Runtime state for the GTK4 C-node. */
typedef struct {
  char *node_name;
  char *alive_name;
  char *cookie;
  char *peer_node;
  char *peer_regname;
  char *register_name;

  int dist_fd;
  unsigned int creation;
  ei_cnode ec;

  GtkApplication *app;
  GtkBuilder *builder;
  GHashTable *widgets;
  GHashTable *stylesheets;
  uint64_t event_seq;
  gboolean test_mode;
  gboolean running;
} Gn4State;

gboolean gn4_parse_args(Gn4State *st, int argc, char **argv);
gboolean gn4_init_erlang(Gn4State *st);
gboolean gn4_init_gtk(Gn4State *st, int *argc, char ***argv);
void gn4_main_loop(Gn4State *st);
void gn4_cleanup(Gn4State *st);

gboolean gn4_poll_erlang(Gn4State *st);
gboolean gn4_send_hello(Gn4State *st);

/* Compatibility helpers for the original GtkBuilder protocol. */
gboolean gn4_load_ui(Gn4State *st, const char *filename);
GtkWidget *gn4_get_widget(Gn4State *st, const char *name);
gboolean gn4_set_widget_label(Gn4State *st,
                              const char *widget_name,
                              const char *text);
void gn4_connect_signals(Gn4State *st, GtkBuilder *builder);
void gn4_signal_handler(GtkWidget *widget,
                        const char *signal_name,
                        gpointer user_data);

#endif /* GTKNODE4_H */
