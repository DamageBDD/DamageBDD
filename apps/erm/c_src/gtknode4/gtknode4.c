#include "gtknode4.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GN4_PROTOCOL_VERSION 1

typedef struct {
  long id;
  long parent_id;
  char *type;
  GtkWidget *widget;
  GtkWidget *signal_widget;
  Gn4State *state;
  gboolean suppress_events;
  gboolean destroying;
} Gn4Widget;

typedef struct {
  char *label;
  char *text;
  char *title;
  char *tooltip;
  char *placeholder;
  char *orientation;
  char *css_class;
  char *align;
  char *selection;
  char *add;
  char **items;
  int item_count;
  gboolean has_items;
  gboolean has_enabled;
  gboolean enabled;
  gboolean has_shown;
  gboolean shown;
  gboolean has_focus;
  gboolean focus;
  gboolean has_expand;
  gboolean expand;
  gboolean has_homogeneous;
  gboolean homogeneous;
  gboolean has_wrap;
  gboolean wrap;
  gboolean has_draw_value;
  gboolean draw_value;
  gboolean has_value;
  double value;
  gboolean has_min;
  double min;
  gboolean has_max;
  double max;
  gboolean has_step;
  double step;
  gboolean has_width;
  int width;
  gboolean has_height;
  int height;
  gboolean has_min_width;
  int min_width;
  gboolean has_min_height;
  int min_height;
  gboolean has_spacing;
  int spacing;
  gboolean has_margin;
  int margin;
  gboolean has_width_chars;
  int width_chars;
} Gn4Options;

typedef struct {
  char *message;
} Gn4CssParseError;

static char *gn4_strdup(const char *value) {
  return value ? g_strdup(value) : NULL;
}

static void gn4_disconnect_widget_signals(Gn4Widget *entry) {
  if (!entry)
    return;

  /* Signal callbacks use entry as user_data. Disconnect them before entry is
   * released, otherwise a queued GTK signal can dereference freed memory. */
  if (entry->signal_widget)
    g_signal_handlers_disconnect_by_data(entry->signal_widget, entry);
  if (entry->widget && entry->widget != entry->signal_widget)
    g_signal_handlers_disconnect_by_data(entry->widget, entry);
}

static void gn4_widget_free(gpointer data) {
  Gn4Widget *entry = data;
  if (!entry)
    return;

  gn4_disconnect_widget_signals(entry);

  /* Every registry entry owns one strong reference. Parent containers own a
   * separate reference while the widget is attached. */
  g_clear_object(&entry->widget);
  entry->signal_widget = NULL;
  g_clear_pointer(&entry->type, g_free);
  g_free(entry);
}

static Gn4Widget *gn4_widget_lookup(Gn4State *st, long id) {
  return st && st->widgets
             ? g_hash_table_lookup(st->widgets, GINT_TO_POINTER((gint)id))
             : NULL;
}

static void gn4_options_init(Gn4Options *opts) {
  memset(opts, 0, sizeof(*opts));
  opts->min = 0.0;
  opts->max = 100.0;
  opts->step = 1.0;
}

static void gn4_options_clear(Gn4Options *opts) {
  int i;
  g_free(opts->label);
  g_free(opts->text);
  g_free(opts->title);
  g_free(opts->tooltip);
  g_free(opts->placeholder);
  g_free(opts->orientation);
  g_free(opts->css_class);
  g_free(opts->align);
  g_free(opts->selection);
  g_free(opts->add);
  for (i = 0; i < opts->item_count; i++)
    g_free(opts->items[i]);
  g_free(opts->items);
}

static char *gn4_decode_string(const char *buf, int *idx) {
  int type = 0;
  int size = 0;
  long length = 0;
  char *value;

  if (ei_get_type(buf, idx, &type, &size) < 0)
    return NULL;

  value = g_malloc0((gsize)size + 1);
  if (!value)
    return NULL;

  if (type == ERL_BINARY_EXT) {
    if (ei_decode_binary(buf, idx, value, &length) < 0) {
      g_free(value);
      return NULL;
    }
    value[length] = '\0';
  } else if (type == ERL_STRING_EXT || type == ERL_LIST_EXT ||
             type == ERL_NIL_EXT) {
    if (ei_decode_string(buf, idx, value) < 0) {
      g_free(value);
      return NULL;
    }
  } else if (type == ERL_ATOM_EXT || type == ERL_SMALL_ATOM_EXT ||
             type == ERL_ATOM_UTF8_EXT || type == ERL_SMALL_ATOM_UTF8_EXT) {
    if (ei_decode_atom(buf, idx, value) < 0) {
      g_free(value);
      return NULL;
    }
  } else {
    g_free(value);
    return NULL;
  }
  return value;
}

static gboolean gn4_decode_bool(const char *buf, int *idx, gboolean *value) {
  char atom[1024];
  if (ei_decode_atom(buf, idx, atom) < 0)
    return FALSE;
  if (strcmp(atom, "true") == 0) {
    *value = TRUE;
    return TRUE;
  }
  if (strcmp(atom, "false") == 0) {
    *value = FALSE;
    return TRUE;
  }
  return FALSE;
}

static gboolean gn4_decode_number(const char *buf, int *idx, double *value) {
  int type = 0;
  int size = 0;
  long integer = 0;
  double real = 0.0;
  if (ei_get_type(buf, idx, &type, &size) < 0)
    return FALSE;
  if (type == ERL_FLOAT_EXT || type == NEW_FLOAT_EXT) {
    if (ei_decode_double(buf, idx, &real) < 0)
      return FALSE;
    *value = real;
    return TRUE;
  }
  if (ei_decode_long(buf, idx, &integer) < 0)
    return FALSE;
  *value = (double)integer;
  return TRUE;
}

static gboolean gn4_decode_items(const char *buf, int *idx,
                                 Gn4Options *opts) {
  int arity = 0;
  int i;
  if (ei_decode_list_header(buf, idx, &arity) < 0)
    return FALSE;
  opts->has_items = TRUE;
  if (arity == 0)
    return TRUE;
  opts->items = g_new0(char *, arity);
  opts->item_count = arity;
  for (i = 0; i < arity; i++) {
    opts->items[i] = gn4_decode_string(buf, idx);
    if (!opts->items[i])
      return FALSE;
  }
  if (ei_decode_list_header(buf, idx, &arity) < 0 || arity != 0)
    return FALSE;
  return TRUE;
}

static gboolean gn4_decode_options(const char *buf, int *idx,
                                   Gn4Options *opts) {
  int arity = 0;
  int i;
  if (ei_decode_map_header(buf, idx, &arity) < 0)
    return FALSE;

  for (i = 0; i < arity; i++) {
    char *key = gn4_decode_string(buf, idx);
    if (!key)
      return FALSE;

#define GN4_STRING_OPTION(Name, Field)                                         \
    if (strcmp(key, Name) == 0) {                                             \
      opts->Field = gn4_decode_string(buf, idx);                              \
      g_free(key);                                                            \
      if (!opts->Field)                                                       \
        return FALSE;                                                         \
      continue;                                                               \
    }

    GN4_STRING_OPTION("label", label)
    GN4_STRING_OPTION("text", text)
    GN4_STRING_OPTION("title", title)
    GN4_STRING_OPTION("tooltip", tooltip)
    GN4_STRING_OPTION("placeholder", placeholder)
    GN4_STRING_OPTION("orientation", orientation)
    GN4_STRING_OPTION("class", css_class)
    GN4_STRING_OPTION("align", align)
    GN4_STRING_OPTION("selection", selection)
    GN4_STRING_OPTION("add", add)

#undef GN4_STRING_OPTION

    if (strcmp(key, "items") == 0) {
      gboolean ok = gn4_decode_items(buf, idx, opts);
      g_free(key);
      if (!ok)
        return FALSE;
      continue;
    }

#define GN4_BOOL_OPTION(Name, HasField, Field)                                \
    if (strcmp(key, Name) == 0) {                                             \
      opts->HasField = TRUE;                                                  \
      if (!gn4_decode_bool(buf, idx, &opts->Field)) {                         \
        g_free(key);                                                          \
        return FALSE;                                                         \
      }                                                                       \
      g_free(key);                                                            \
      continue;                                                               \
    }

    GN4_BOOL_OPTION("enabled", has_enabled, enabled)
    GN4_BOOL_OPTION("shown", has_shown, shown)
    GN4_BOOL_OPTION("focus", has_focus, focus)
    GN4_BOOL_OPTION("expand", has_expand, expand)
    GN4_BOOL_OPTION("homogeneous", has_homogeneous, homogeneous)
    GN4_BOOL_OPTION("wrap", has_wrap, wrap)
    GN4_BOOL_OPTION("draw_value", has_draw_value, draw_value)

#undef GN4_BOOL_OPTION

#define GN4_NUMBER_OPTION(Name, HasField, Field)                              \
    if (strcmp(key, Name) == 0) {                                             \
      double number = 0.0;                                                    \
      opts->HasField = TRUE;                                                  \
      if (!gn4_decode_number(buf, idx, &number)) {                            \
        g_free(key);                                                          \
        return FALSE;                                                         \
      }                                                                       \
      opts->Field = number;                                                   \
      g_free(key);                                                            \
      continue;                                                               \
    }

    GN4_NUMBER_OPTION("value", has_value, value)
    GN4_NUMBER_OPTION("min", has_min, min)
    GN4_NUMBER_OPTION("max", has_max, max)
    GN4_NUMBER_OPTION("step", has_step, step)
    GN4_NUMBER_OPTION("width", has_width, width)
    GN4_NUMBER_OPTION("height", has_height, height)
    GN4_NUMBER_OPTION("min_width", has_min_width, min_width)
    GN4_NUMBER_OPTION("min_height", has_min_height, min_height)
    GN4_NUMBER_OPTION("spacing", has_spacing, spacing)
    GN4_NUMBER_OPTION("margin", has_margin, margin)
    GN4_NUMBER_OPTION("width_chars", has_width_chars, width_chars)

#undef GN4_NUMBER_OPTION

    g_free(key);
    if (ei_skip_term(buf, idx) < 0)
      return FALSE;
  }
  return TRUE;
}

static void gn4_send_reply_ok(Gn4State *st, const erlang_ref *ref) {
  ei_x_buff reply;
  ei_x_new_with_version(&reply);
  ei_x_encode_tuple_header(&reply, 4);
  ei_x_encode_atom(&reply, "gtknode4");
  ei_x_encode_atom(&reply, "reply");
  ei_x_encode_ref(&reply, (erlang_ref *)ref);
  ei_x_encode_atom(&reply, "ok");
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, reply.buff,
              reply.index);
  ei_x_free(&reply);
}

static void gn4_send_reply_error(Gn4State *st, const erlang_ref *ref,
                                 const char *reason) {
  ei_x_buff reply;
  ei_x_new_with_version(&reply);
  ei_x_encode_tuple_header(&reply, 4);
  ei_x_encode_atom(&reply, "gtknode4");
  ei_x_encode_atom(&reply, "reply");
  ei_x_encode_ref(&reply, (erlang_ref *)ref);
  ei_x_encode_tuple_header(&reply, 2);
  ei_x_encode_atom(&reply, "error");
  ei_x_encode_atom(&reply, reason ? reason : "unknown");
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, reply.buff,
              reply.index);
  ei_x_free(&reply);
}

static void gn4_send_reply_error_detail(Gn4State *st, const erlang_ref *ref,
                                        const char *reason,
                                        const char *detail) {
  ei_x_buff reply;
  const char *safe_reason = reason ? reason : "unknown";
  const char *safe_detail = detail ? detail : "";
  ei_x_new_with_version(&reply);
  ei_x_encode_tuple_header(&reply, 4);
  ei_x_encode_atom(&reply, "gtknode4");
  ei_x_encode_atom(&reply, "reply");
  ei_x_encode_ref(&reply, (erlang_ref *)ref);
  ei_x_encode_tuple_header(&reply, 2);
  ei_x_encode_atom(&reply, "error");
  ei_x_encode_tuple_header(&reply, 2);
  ei_x_encode_atom(&reply, safe_reason);
  ei_x_encode_binary(&reply, safe_detail, (long)strlen(safe_detail));
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, reply.buff,
              reply.index);
  ei_x_free(&reply);
}

static void gn4_send_reply_ok_binary(Gn4State *st, const erlang_ref *ref,
                                     const char *value) {
  ei_x_buff reply;
  size_t length = value ? strlen(value) : 0;
  ei_x_new_with_version(&reply);
  ei_x_encode_tuple_header(&reply, 4);
  ei_x_encode_atom(&reply, "gtknode4");
  ei_x_encode_atom(&reply, "reply");
  ei_x_encode_ref(&reply, (erlang_ref *)ref);
  ei_x_encode_tuple_header(&reply, 2);
  ei_x_encode_atom(&reply, "ok");
  ei_x_encode_binary(&reply, value ? value : "", (long)length);
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, reply.buff,
              reply.index);
  ei_x_free(&reply);
}

static void gn4_send_reply_ok_double(Gn4State *st, const erlang_ref *ref,
                                     double value) {
  ei_x_buff reply;
  ei_x_new_with_version(&reply);
  ei_x_encode_tuple_header(&reply, 4);
  ei_x_encode_atom(&reply, "gtknode4");
  ei_x_encode_atom(&reply, "reply");
  ei_x_encode_ref(&reply, (erlang_ref *)ref);
  ei_x_encode_tuple_header(&reply, 2);
  ei_x_encode_atom(&reply, "ok");
  ei_x_encode_double(&reply, value);
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, reply.buff,
              reply.index);
  ei_x_free(&reply);
}

static void gn4_send_reply_ok_bool(Gn4State *st, const erlang_ref *ref,
                                   gboolean value) {
  ei_x_buff reply;
  ei_x_new_with_version(&reply);
  ei_x_encode_tuple_header(&reply, 4);
  ei_x_encode_atom(&reply, "gtknode4");
  ei_x_encode_atom(&reply, "reply");
  ei_x_encode_ref(&reply, (erlang_ref *)ref);
  ei_x_encode_tuple_header(&reply, 2);
  ei_x_encode_atom(&reply, "ok");
  ei_x_encode_atom(&reply, value ? "true" : "false");
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, reply.buff,
              reply.index);
  ei_x_free(&reply);
}

static void gn4_event_begin(Gn4Widget *entry, ei_x_buff *event,
                            const char *event_name, int payload_size) {
  Gn4State *st = entry->state;
  ei_x_new_with_version(event);
  ei_x_encode_tuple_header(event, 6);
  ei_x_encode_atom(event, "gtknode4");
  ei_x_encode_atom(event, "event");
  ei_x_encode_ulonglong(event, ++st->event_seq);
  ei_x_encode_long(event, entry->id);
  ei_x_encode_atom(event, event_name);
  ei_x_encode_map_header(event, payload_size);
}

static void gn4_event_send(Gn4Widget *entry, ei_x_buff *event) {
  Gn4State *st = entry->state;
  ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, event->buff,
              event->index);
  ei_x_free(event);
}

static void gn4_send_empty_event(Gn4Widget *entry, const char *name) {
  ei_x_buff event;
  gn4_event_begin(entry, &event, name, 0);
  gn4_event_send(entry, &event);
}

static void gn4_on_button_clicked(GtkButton *button, gpointer user_data) {
  Gn4Widget *entry = user_data;
  (void)button;
  if (!entry->suppress_events)
    gn4_send_empty_event(entry, "clicked");
}

static void gn4_on_entry_activate(GtkEntry *widget, gpointer user_data) {
  Gn4Widget *entry = user_data;
  const char *text;
  ei_x_buff event;
  if (entry->suppress_events)
    return;
  text = gtk_editable_get_text(GTK_EDITABLE(widget));
  gn4_event_begin(entry, &event, "activate", 2);
  ei_x_encode_atom(&event, "key");
  ei_x_encode_atom(&event, "return");
  ei_x_encode_atom(&event, "text");
  ei_x_encode_binary(&event, text, (long)strlen(text));
  gn4_event_send(entry, &event);
}

static void gn4_on_scale_changed(GtkRange *range, gpointer user_data) {
  Gn4Widget *entry = user_data;
  ei_x_buff event;
  if (entry->suppress_events)
    return;
  gn4_event_begin(entry, &event, "value_changed", 1);
  ei_x_encode_atom(&event, "value");
  ei_x_encode_double(&event, gtk_range_get_value(range));
  gn4_event_send(entry, &event);
}

static void gn4_on_list_selected(GtkListBox *box, GtkListBoxRow *row,
                                 gpointer user_data) {
  Gn4Widget *entry = user_data;
  GtkWidget *child;
  const char *text = "";
  ei_x_buff event;
  (void)box;
  if (entry->suppress_events || !row)
    return;
  child = gtk_list_box_row_get_child(row);
  if (GTK_IS_LABEL(child))
    text = gtk_label_get_text(GTK_LABEL(child));
  gn4_event_begin(entry, &event, "selection_changed", 3);
  ei_x_encode_atom(&event, "index");
  ei_x_encode_long(&event, gtk_list_box_row_get_index(row));
  ei_x_encode_atom(&event, "text");
  ei_x_encode_binary(&event, text, (long)strlen(text));
  ei_x_encode_atom(&event, "selected");
  ei_x_encode_atom(&event, "true");
  gn4_event_send(entry, &event);
}

static gboolean gn4_on_window_close(GtkWindow *window, gpointer user_data) {
  Gn4Widget *entry = user_data;
  gtk_widget_set_visible(GTK_WIDGET(window), FALSE);
  if (!entry->suppress_events)
    gn4_send_empty_event(entry, "hidden");
  return TRUE;
}

static GtkOrientation gn4_orientation(const char *value) {
  return value && strcmp(value, "horizontal") == 0 ? GTK_ORIENTATION_HORIZONTAL
                                                    : GTK_ORIENTATION_VERTICAL;
}

static GtkAlign gn4_align(const char *value) {
  if (!value || strcmp(value, "fill") == 0)
    return GTK_ALIGN_FILL;
  if (strcmp(value, "start") == 0)
    return GTK_ALIGN_START;
  if (strcmp(value, "end") == 0)
    return GTK_ALIGN_END;
  if (strcmp(value, "center") == 0)
    return GTK_ALIGN_CENTER;
  return GTK_ALIGN_FILL;
}

static void gn4_list_clear(GtkListBox *list) {
  GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(list));
  while (child) {
    GtkWidget *next = gtk_widget_get_next_sibling(child);
    gtk_list_box_remove(list, child);
    child = next;
  }
}

static void gn4_list_append(GtkListBox *list, const char *text) {
  GtkWidget *label = gtk_label_new(text ? text : "");
  gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
  gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_MIDDLE);
  gtk_widget_set_margin_start(label, 12);
  gtk_widget_set_margin_end(label, 12);
  gtk_widget_set_margin_top(label, 10);
  gtk_widget_set_margin_bottom(label, 10);
  gtk_list_box_append(list, label);
}

static void gn4_css_parse_error(GtkCssProvider *provider,
                                GtkCssSection *section,
                                const GError *error,
                                gpointer user_data) {
  Gn4CssParseError *parse_error = user_data;
  (void)provider;
  (void)section;
  if (parse_error && parse_error->message == NULL && error && error->message)
    parse_error->message = g_strdup(error->message);
}

static void gn4_remove_provider_for_display(gpointer key, gpointer value,
                                            gpointer user_data) {
  GdkDisplay *display = user_data;
  (void)key;
  if (display && value)
    gtk_style_context_remove_provider_for_display(
        display, GTK_STYLE_PROVIDER(value));
}

static gboolean gn4_remove_stylesheet(Gn4State *st, const char *name) {
  GtkCssProvider *provider;
  GdkDisplay *display;

  if (!st || !st->stylesheets || !name || name[0] == '\0')
    return FALSE;

  provider = g_hash_table_lookup(st->stylesheets, name);
  if (!provider)
    return TRUE;

  display = gdk_display_get_default();
  if (display)
    gtk_style_context_remove_provider_for_display(
        display, GTK_STYLE_PROVIDER(provider));

  g_hash_table_remove(st->stylesheets, name);
  return TRUE;
}

static gboolean gn4_set_stylesheet(Gn4State *st, const char *name,
                                   const char *css, char **error_message) {
  GtkCssProvider *provider;
  GdkDisplay *display;
  Gn4CssParseError parse_error = {NULL};
  gulong parse_handler;

  if (error_message)
    *error_message = NULL;

  if (!st || !st->stylesheets || !name || name[0] == '\0' || !css) {
    if (error_message)
      *error_message = g_strdup("badarg");
    return FALSE;
  }

  display = gdk_display_get_default();
  if (!display) {
    if (error_message)
      *error_message = g_strdup("no_display");
    return FALSE;
  }

  provider = gtk_css_provider_new();
  if (!provider) {
    if (error_message)
      *error_message = g_strdup("css_provider_alloc_failed");
    return FALSE;
  }

  parse_handler = g_signal_connect(provider, "parsing-error",
                                   G_CALLBACK(gn4_css_parse_error),
                                   &parse_error);
  gtk_css_provider_load_from_data(provider, css, -1);
  g_signal_handler_disconnect(provider, parse_handler);

  if (parse_error.message != NULL) {
    if (error_message)
      *error_message = parse_error.message;
    else
      g_free(parse_error.message);
    g_object_unref(provider);
    return FALSE;
  }

  gn4_remove_stylesheet(st, name);
  gtk_style_context_add_provider_for_display(
      display, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_hash_table_insert(st->stylesheets, g_strdup(name), provider);
  return TRUE;
}

static void gn4_apply_options(Gn4Widget *entry, Gn4Options *opts) {
  GtkWidget *widget = entry->widget;
  GtkWidget *target = entry->signal_widget ? entry->signal_widget : widget;
  int width = -1;
  int height = -1;
  int i;

  entry->suppress_events = TRUE;

  if (opts->label) {
    if (GTK_IS_BUTTON(target))
      gtk_button_set_label(GTK_BUTTON(target), opts->label);
    else if (GTK_IS_LABEL(target))
      gtk_label_set_text(GTK_LABEL(target), opts->label);
  }
  if (opts->text) {
    if (GTK_IS_LABEL(target))
      gtk_label_set_text(GTK_LABEL(target), opts->text);
    else if (GTK_IS_EDITABLE(target))
      gtk_editable_set_text(GTK_EDITABLE(target), opts->text);
    else if (GTK_IS_TEXT_VIEW(target))
      gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(target)),
                               opts->text, -1);
    else if (GTK_IS_PICTURE(target))
      gtk_picture_set_filename(GTK_PICTURE(target),
                               opts->text[0] ? opts->text : NULL);
  }
  if (opts->title && GTK_IS_WINDOW(widget))
    gtk_window_set_title(GTK_WINDOW(widget), opts->title);
  if (opts->tooltip)
    gtk_widget_set_tooltip_text(widget, opts->tooltip);
  if (opts->placeholder && GTK_IS_ENTRY(target))
    gtk_entry_set_placeholder_text(GTK_ENTRY(target), opts->placeholder);
  if (opts->css_class)
    gtk_widget_add_css_class(widget, opts->css_class);
  if (opts->align) {
    gtk_widget_set_halign(widget, gn4_align(opts->align));
    if (GTK_IS_LABEL(target))
      gtk_label_set_xalign(GTK_LABEL(target),
                           gn4_align(opts->align) == GTK_ALIGN_END
                               ? 1.0f
                               : (gn4_align(opts->align) == GTK_ALIGN_CENTER
                                      ? 0.5f
                                      : 0.0f));
  }
  if (opts->orientation && GTK_IS_ORIENTABLE(target))
    gtk_orientable_set_orientation(GTK_ORIENTABLE(target),
                                   gn4_orientation(opts->orientation));
  if (opts->has_spacing && GTK_IS_BOX(target))
    gtk_box_set_spacing(GTK_BOX(target), opts->spacing);
  if (opts->has_homogeneous && GTK_IS_BOX(target))
    gtk_box_set_homogeneous(GTK_BOX(target), opts->homogeneous);
  if (opts->has_wrap && GTK_IS_LABEL(target))
    gtk_label_set_wrap(GTK_LABEL(target), opts->wrap);
  if (opts->has_width_chars) {
    if (GTK_IS_LABEL(target))
      gtk_label_set_width_chars(GTK_LABEL(target), opts->width_chars);
    else if (GTK_IS_ENTRY(target))
      gtk_editable_set_width_chars(GTK_EDITABLE(target), opts->width_chars);
  }
  if (opts->has_expand) {
    gtk_widget_set_hexpand(widget, opts->expand);
    gtk_widget_set_vexpand(widget, opts->expand);
  }
  if (opts->has_margin) {
    gtk_widget_set_margin_start(widget, opts->margin);
    gtk_widget_set_margin_end(widget, opts->margin);
    gtk_widget_set_margin_top(widget, opts->margin);
    gtk_widget_set_margin_bottom(widget, opts->margin);
  }
  if (opts->has_min_width)
    width = opts->min_width;
  else if (opts->has_width)
    width = opts->width;
  if (opts->has_min_height)
    height = opts->min_height;
  else if (opts->has_height)
    height = opts->height;
  if (width >= 0 || height >= 0)
    gtk_widget_set_size_request(widget, width, height);
  if (GTK_IS_WINDOW(widget) && (opts->has_width || opts->has_height))
    gtk_window_set_default_size(GTK_WINDOW(widget),
                                opts->has_width ? opts->width : -1,
                                opts->has_height ? opts->height : -1);

  if (GTK_IS_RANGE(target)) {
    GtkAdjustment *adjustment = gtk_range_get_adjustment(GTK_RANGE(target));
    double lower = opts->has_min ? opts->min : gtk_adjustment_get_lower(adjustment);
    double upper = opts->has_max ? opts->max : gtk_adjustment_get_upper(adjustment);
    double step = opts->has_step ? opts->step : gtk_adjustment_get_step_increment(adjustment);
    gtk_range_set_range(GTK_RANGE(target), lower, upper);
    gtk_range_set_increments(GTK_RANGE(target), step, step * 10.0);
    if (opts->has_value)
      gtk_range_set_value(GTK_RANGE(target), opts->value);
    if (opts->has_draw_value && GTK_IS_SCALE(target))
      gtk_scale_set_draw_value(GTK_SCALE(target), opts->draw_value);
  }

  if (GTK_IS_LIST_BOX(target)) {
    if (opts->has_items) {
      gn4_list_clear(GTK_LIST_BOX(target));
      for (i = 0; i < opts->item_count; i++)
        gn4_list_append(GTK_LIST_BOX(target), opts->items[i]);
    }
    if (opts->add)
      gn4_list_append(GTK_LIST_BOX(target), opts->add);
    if (opts->selection) {
      GtkSelectionMode mode = GTK_SELECTION_SINGLE;
      if (strcmp(opts->selection, "none") == 0)
        mode = GTK_SELECTION_NONE;
      else if (strcmp(opts->selection, "multiple") == 0)
        mode = GTK_SELECTION_MULTIPLE;
      gtk_list_box_set_selection_mode(GTK_LIST_BOX(target), mode);
    }
  }

  if (opts->has_enabled)
    gtk_widget_set_sensitive(widget, opts->enabled);
  if (opts->has_shown) {
    gtk_widget_set_visible(widget, opts->shown);
    if (opts->shown && GTK_IS_WINDOW(widget))
      gtk_window_present(GTK_WINDOW(widget));
  }
  if (opts->has_focus && opts->focus)
    gtk_widget_grab_focus(target);

  entry->suppress_events = FALSE;
}

static gboolean gn4_attach_widget(Gn4State *st, Gn4Widget *entry) {
  Gn4Widget *parent;
  if (entry->parent_id == 0)
    return GTK_IS_WINDOW(entry->widget);
  parent = gn4_widget_lookup(st, entry->parent_id);
  if (!parent)
    return FALSE;
  if (GTK_IS_WINDOW(parent->widget)) {
    if (gtk_window_get_child(GTK_WINDOW(parent->widget)) != NULL)
      return FALSE;
    gtk_window_set_child(GTK_WINDOW(parent->widget), entry->widget);
    return TRUE;
  }
  if (GTK_IS_BOX(parent->signal_widget)) {
    gtk_box_append(GTK_BOX(parent->signal_widget), entry->widget);
    return TRUE;
  }
  return FALSE;
}

static Gn4Widget *gn4_create_widget(Gn4State *st, long id, const char *type,
                                    long parent_id, Gn4Options *opts) {
  Gn4Widget *entry;
  GtkWidget *widget = NULL;
  GtkWidget *signal_widget = NULL;

  if (gn4_widget_lookup(st, id))
    return NULL;

  if (strcmp(type, "window") == 0) {
    widget = gtk_application_window_new(st->app);
    signal_widget = widget;
  } else if (strcmp(type, "box") == 0) {
    widget = gtk_box_new(gn4_orientation(opts->orientation),
                         opts->has_spacing ? opts->spacing : 0);
    signal_widget = widget;
  } else if (strcmp(type, "button") == 0) {
    widget = gtk_button_new_with_label(opts->label ? opts->label : "");
    signal_widget = widget;
  } else if (strcmp(type, "label") == 0) {
    widget = gtk_label_new(opts->text ? opts->text :
                                       (opts->label ? opts->label : ""));
    signal_widget = widget;
  } else if (strcmp(type, "entry") == 0) {
    widget = gtk_entry_new();
    signal_widget = widget;
  } else if (strcmp(type, "text_view") == 0) {
    widget = gtk_text_view_new();
    signal_widget = widget;
  } else if (strcmp(type, "list_view") == 0) {
    GtkWidget *list = gtk_list_box_new();
    widget = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(widget),
                                   GTK_POLICY_AUTOMATIC,
                                   GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(widget), list);
    signal_widget = list;
  } else if (strcmp(type, "scrolled_box") == 0) {
    GtkWidget *box = gtk_box_new(gn4_orientation(opts->orientation),
                                 opts->has_spacing ? opts->spacing : 0);
    widget = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(widget),
                                   GTK_POLICY_NEVER,
                                   GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(widget), box);
    /* Children attach to the inner box while sizing/margins apply to the
       outer scrolled window. */
    signal_widget = box;
  } else if (strcmp(type, "picture") == 0) {
    widget = gtk_picture_new();
    gtk_picture_set_can_shrink(GTK_PICTURE(widget), TRUE);
    signal_widget = widget;
  } else if (strcmp(type, "scale") == 0) {
    widget = gtk_scale_new_with_range(gn4_orientation(opts->orientation),
                                      opts->has_min ? opts->min : 0.0,
                                      opts->has_max ? opts->max : 100.0,
                                      opts->has_step ? opts->step : 1.0);
    signal_widget = widget;
  } else {
    return NULL;
  }

  /* Keep every widget alive independently of its parent. GTK containers own
   * their children, so without this registry reference removing or destroying
   * a parent can leave entry->widget as a dangling pointer. */
  g_object_ref_sink(widget);

  entry = g_new0(Gn4Widget, 1);
  entry->id = id;
  entry->parent_id = parent_id;
  entry->type = g_strdup(type);
  entry->widget = widget;
  entry->signal_widget = signal_widget;
  entry->state = st;
  entry->suppress_events = TRUE;
  entry->destroying = FALSE;

  g_hash_table_insert(st->widgets, GINT_TO_POINTER((gint)id), entry);
  if (!gn4_attach_widget(st, entry)) {
    /* Removing the entry releases the registry-owned reference. */
    g_hash_table_remove(st->widgets, GINT_TO_POINTER((gint)id));
    return NULL;
  }

  if (GTK_IS_BUTTON(signal_widget))
    g_signal_connect(signal_widget, "clicked", G_CALLBACK(gn4_on_button_clicked),
                     entry);
  else if (GTK_IS_ENTRY(signal_widget))
    g_signal_connect(signal_widget, "activate", G_CALLBACK(gn4_on_entry_activate),
                     entry);
  else if (GTK_IS_RANGE(signal_widget))
    g_signal_connect(signal_widget, "value-changed",
                     G_CALLBACK(gn4_on_scale_changed), entry);
  else if (GTK_IS_LIST_BOX(signal_widget))
    g_signal_connect(signal_widget, "row-selected",
                     G_CALLBACK(gn4_on_list_selected), entry);
  if (GTK_IS_WINDOW(widget))
    g_signal_connect(widget, "close-request", G_CALLBACK(gn4_on_window_close),
                     entry);

  gn4_apply_options(entry, opts);
  return entry;
}

static gboolean gn4_detach_widget(Gn4State *st, Gn4Widget *entry) {
  GtkWidget *widget;
  GtkWidget *parent_widget;
  Gn4Widget *logical_parent;

  if (!st || !entry || !entry->widget)
    return FALSE;

  widget = entry->widget;
  parent_widget = gtk_widget_get_parent(widget);
  if (!parent_widget)
    return TRUE;

  logical_parent = gn4_widget_lookup(st, entry->parent_id);
  if (logical_parent) {
    GtkWidget *expected_parent = logical_parent->signal_widget
                                     ? logical_parent->signal_widget
                                     : logical_parent->widget;
    if (expected_parent != parent_widget) {
      fprintf(stderr,
              "gtknode4: widget %ld parent mismatch: logical=%ld native=%s\n",
              entry->id, entry->parent_id,
              G_OBJECT_TYPE_NAME(parent_widget));
    }
  }

  /* GTK4 requires applications to use the owning container's public removal
   * API. gtk_widget_unparent() is reserved for GtkWidget implementations and
   * bypasses container bookkeeping. */
  if (GTK_IS_WINDOW(parent_widget)) {
    GtkWidget *child = gtk_window_get_child(GTK_WINDOW(parent_widget));
    if (child == widget) {
      gtk_window_set_child(GTK_WINDOW(parent_widget), NULL);
      return TRUE;
    }
  } else if (GTK_IS_BOX(parent_widget)) {
    gtk_box_remove(GTK_BOX(parent_widget), widget);
    return TRUE;
  } else if (GTK_IS_SCROLLED_WINDOW(parent_widget)) {
    GtkWidget *child =
        gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(parent_widget));
    if (child == widget) {
      gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(parent_widget), NULL);
      return TRUE;
    }
  } else if (GTK_IS_LIST_BOX(parent_widget)) {
    gtk_list_box_remove(GTK_LIST_BOX(parent_widget), widget);
    return TRUE;
  } else if (GTK_IS_GRID(parent_widget)) {
    gtk_grid_remove(GTK_GRID(parent_widget), widget);
    return TRUE;
  } else if (GTK_IS_STACK(parent_widget)) {
    gtk_stack_remove(GTK_STACK(parent_widget), widget);
    return TRUE;
  }

  fprintf(stderr,
          "gtknode4: cannot safely detach widget %ld (%s) from parent %s; "
          "leaving removal to the parent lifecycle\n",
          entry->id, entry->type ? entry->type : "unknown",
          G_OBJECT_TYPE_NAME(parent_widget));
  return FALSE;
}

static void gn4_destroy_widget(Gn4State *st, long id) {
  Gn4Widget *entry = gn4_widget_lookup(st, id);
  GHashTableIter iter;
  gpointer key;
  gpointer value;
  GArray *children;
  guint i;

  if (!entry || entry->destroying)
    return;

  entry->destroying = TRUE;
  entry->suppress_events = TRUE;

  /* Destroy the logical subtree from the leaves upward. Keeping one registry
   * reference per widget makes every pointer valid throughout this walk. */
  children = g_array_new(FALSE, FALSE, sizeof(long));
  g_hash_table_iter_init(&iter, st->widgets);
  while (g_hash_table_iter_next(&iter, &key, &value)) {
    Gn4Widget *candidate = value;
    if (candidate->parent_id == id)
      g_array_append_val(children, candidate->id);
  }
  for (i = 0; i < children->len; i++)
    gn4_destroy_widget(st, g_array_index(children, long, i));
  g_array_free(children, TRUE);

  entry = gn4_widget_lookup(st, id);
  if (!entry)
    return;

  gn4_disconnect_widget_signals(entry);

  if (GTK_IS_WINDOW(entry->widget)) {
    if (!gtk_widget_in_destruction(entry->widget))
      gtk_window_destroy(GTK_WINDOW(entry->widget));
  } else if (!gtk_widget_in_destruction(entry->widget)) {
    (void)gn4_detach_widget(st, entry);
  }

  /* The hash-table value destructor drops the registry-owned reference. */
  g_hash_table_remove(st->widgets, GINT_TO_POINTER((gint)id));
}

static gboolean gn4_decode_parent(const char *buf, int *idx, long *parent_id) {
  int type = 0;
  int size = 0;
  char atom[1024];
  if (ei_get_type(buf, idx, &type, &size) < 0)
    return FALSE;
  if (type == ERL_ATOM_EXT || type == ERL_SMALL_ATOM_EXT ||
      type == ERL_ATOM_UTF8_EXT || type == ERL_SMALL_ATOM_UTF8_EXT) {
    if (ei_decode_atom(buf, idx, atom) < 0 || strcmp(atom, "root") != 0)
      return FALSE;
    *parent_id = 0;
    return TRUE;
  }
  return ei_decode_long(buf, idx, parent_id) == 0;
}

static void gn4_handle_read(Gn4State *st, const erlang_ref *ref,
                            Gn4Widget *entry, const char *key) {
  GtkWidget *widget = entry->widget;
  GtkWidget *target = entry->signal_widget ? entry->signal_widget : widget;
  if (strcmp(key, "text") == 0) {
    if (GTK_IS_EDITABLE(target))
      gn4_send_reply_ok_binary(st, ref,
                               gtk_editable_get_text(GTK_EDITABLE(target)));
    else if (GTK_IS_LABEL(target))
      gn4_send_reply_ok_binary(st, ref,
                               gtk_label_get_text(GTK_LABEL(target)));
    else
      gn4_send_reply_error(st, ref, "unsupported_property");
  } else if (strcmp(key, "label") == 0) {
    if (GTK_IS_BUTTON(target))
      gn4_send_reply_ok_binary(st, ref,
                               gtk_button_get_label(GTK_BUTTON(target)));
    else if (GTK_IS_LABEL(target))
      gn4_send_reply_ok_binary(st, ref,
                               gtk_label_get_text(GTK_LABEL(target)));
    else
      gn4_send_reply_error(st, ref, "unsupported_property");
  } else if (strcmp(key, "value") == 0 && GTK_IS_RANGE(target)) {
    gn4_send_reply_ok_double(st, ref, gtk_range_get_value(GTK_RANGE(target)));
  } else if (strcmp(key, "shown") == 0) {
    gn4_send_reply_ok_bool(st, ref, gtk_widget_get_visible(widget));
  } else if (strcmp(key, "enabled") == 0) {
    gn4_send_reply_ok_bool(st, ref, gtk_widget_get_sensitive(widget));
  } else if (strcmp(key, "title") == 0 && GTK_IS_WINDOW(widget)) {
    gn4_send_reply_ok_binary(st, ref,
                             gtk_window_get_title(GTK_WINDOW(widget)));
  } else {
    gn4_send_reply_error(st, ref, "unsupported_property");
  }
}

static void gn4_handle_tuple_command(Gn4State *st, const char *buf, int *idx,
                                     int arity, const char *command,
                                     const erlang_ref *ref, gboolean reply) {
  long id = 0;
  long parent_id = 0;
  Gn4Widget *entry;
  Gn4Options opts;
  char *type = NULL;
  char *key = NULL;

  if (strcmp(command, "create") == 0 && arity == 5) {
    gn4_options_init(&opts);
    if (ei_decode_long(buf, idx, &id) < 0 ||
        !(type = gn4_decode_string(buf, idx)) ||
        !gn4_decode_parent(buf, idx, &parent_id) ||
        !gn4_decode_options(buf, idx, &opts)) {
      if (reply)
        gn4_send_reply_error(st, ref, "badarg");
    } else if (gn4_create_widget(st, id, type, parent_id, &opts)) {
      if (reply)
        gn4_send_reply_ok(st, ref);
    } else if (reply) {
      fprintf(stderr,
              "gtknode4: widget create failed id=%ld type=%s parent=%ld\n",
              id, type ? type : "<null>", parent_id);
      gn4_send_reply_error(st, ref, "create_failed");
    }
    g_free(type);
    gn4_options_clear(&opts);
    return;
  }

  if (strcmp(command, "config") == 0 && arity == 3) {
    gn4_options_init(&opts);
    if (ei_decode_long(buf, idx, &id) < 0 ||
        !gn4_decode_options(buf, idx, &opts)) {
      if (reply)
        gn4_send_reply_error(st, ref, "badarg");
    } else if (!(entry = gn4_widget_lookup(st, id))) {
      if (reply)
        gn4_send_reply_error(st, ref, "widget_not_found");
    } else {
      gn4_apply_options(entry, &opts);
      if (reply)
        gn4_send_reply_ok(st, ref);
    }
    gn4_options_clear(&opts);
    return;
  }

  if (strcmp(command, "read") == 0 && arity == 3) {
    if (ei_decode_long(buf, idx, &id) < 0 ||
        !(key = gn4_decode_string(buf, idx))) {
      if (reply)
        gn4_send_reply_error(st, ref, "badarg");
    } else if (!(entry = gn4_widget_lookup(st, id))) {
      if (reply)
        gn4_send_reply_error(st, ref, "widget_not_found");
    } else if (reply) {
      gn4_handle_read(st, ref, entry, key);
    }
    g_free(key);
    return;
  }

  if (strcmp(command, "destroy") == 0 && arity == 2) {
    if (ei_decode_long(buf, idx, &id) < 0) {
      if (reply)
        gn4_send_reply_error(st, ref, "badarg");
    } else if (!gn4_widget_lookup(st, id)) {
      if (reply)
        gn4_send_reply_error(st, ref, "widget_not_found");
    } else {
      gn4_destroy_widget(st, id);
      if (reply)
        gn4_send_reply_ok(st, ref);
    }
    return;
  }

  if (strcmp(command, "load_ui") == 0 && arity == 2) {
    char *filename = gn4_decode_string(buf, idx);
    gboolean ok = filename && gn4_load_ui(st, filename);
    if (reply) {
      if (ok)
        gn4_send_reply_ok(st, ref);
      else
        gn4_send_reply_error(st, ref, "load_ui_failed");
    }
    g_free(filename);
    return;
  }

  if (strcmp(command, "set_label") == 0 && arity == 3) {
    char *name = gn4_decode_string(buf, idx);
    char *text = gn4_decode_string(buf, idx);
    gboolean ok = name && text && gn4_set_widget_label(st, name, text);
    if (reply) {
      if (ok)
        gn4_send_reply_ok(st, ref);
      else
        gn4_send_reply_error(st, ref, "set_label_failed");
    }
    g_free(name);
    g_free(text);
    return;
  }

  if (strcmp(command, "get_label") == 0 && arity == 2) {
    char *name = gn4_decode_string(buf, idx);
    GtkWidget *widget = name ? gn4_get_widget(st, name) : NULL;
    const char *text = NULL;
    if (GTK_IS_BUTTON(widget))
      text = gtk_button_get_label(GTK_BUTTON(widget));
    else if (GTK_IS_LABEL(widget))
      text = gtk_label_get_text(GTK_LABEL(widget));
    if (reply) {
      if (text)
        gn4_send_reply_ok_binary(st, ref, text);
      else
        gn4_send_reply_error(st, ref, "widget_not_found");
    }
    g_free(name);
    return;
  }

  if (strcmp(command, "set_stylesheet") == 0 && arity == 3) {
    char *name = gn4_decode_string(buf, idx);
    char *css = gn4_decode_string(buf, idx);
    char *error_message = NULL;
    gboolean ok = name && css && gn4_set_stylesheet(st, name, css,
                                                    &error_message);
    if (reply) {
      if (ok)
        gn4_send_reply_ok(st, ref);
      else if (error_message)
        gn4_send_reply_error_detail(st, ref, "stylesheet_failed",
                                    error_message);
      else
        gn4_send_reply_error(st, ref, "stylesheet_failed");
    }
    g_free(error_message);
    g_free(name);
    g_free(css);
    return;
  }

  if (strcmp(command, "remove_stylesheet") == 0 && arity == 2) {
    char *name = gn4_decode_string(buf, idx);
    gboolean ok = name && gn4_remove_stylesheet(st, name);
    if (reply) {
      if (ok)
        gn4_send_reply_ok(st, ref);
      else
        gn4_send_reply_error(st, ref, "stylesheet_remove_failed");
    }
    g_free(name);
    return;
  }

  if (reply)
    gn4_send_reply_error(st, ref, "unsupported_command");
}

static void gn4_handle_command(Gn4State *st, const char *buf, int *idx,
                               const erlang_ref *ref, gboolean reply) {
  int type = 0;
  int size = 0;
  int arity = 0;
  char *command;
  if (ei_get_type(buf, idx, &type, &size) < 0) {
    if (reply)
      gn4_send_reply_error(st, ref, "badarg");
    return;
  }

  if (type == ERL_ATOM_EXT || type == ERL_SMALL_ATOM_EXT ||
      type == ERL_ATOM_UTF8_EXT || type == ERL_SMALL_ATOM_UTF8_EXT) {
    command = gn4_decode_string(buf, idx);
    if (!command) {
      if (reply)
        gn4_send_reply_error(st, ref, "badarg");
      return;
    }
    if (strcmp(command, "sync") == 0) {
      while (g_main_context_pending(NULL))
        g_main_context_iteration(NULL, FALSE);
      if (reply)
        gn4_send_reply_ok(st, ref);
    } else if (strcmp(command, "shutdown") == 0) {
      st->running = FALSE;
      if (reply)
        gn4_send_reply_ok(st, ref);
    } else if (reply) {
      gn4_send_reply_error(st, ref, "unsupported_command");
    }
    g_free(command);
    return;
  }

  if (ei_decode_tuple_header(buf, idx, &arity) < 0 || arity < 1 ||
      !(command = gn4_decode_string(buf, idx))) {
    if (reply)
      gn4_send_reply_error(st, ref, "badarg");
    return;
  }
  gn4_handle_tuple_command(st, buf, idx, arity, command, ref, reply);
  g_free(command);
}

gboolean gn4_parse_args(Gn4State *st, int argc, char **argv) {
  int i;
  const char *cookie_env = "GTKNODE4_COOKIE";
  memset(st, 0, sizeof(*st));
  st->dist_fd = -1;
  /* Distinguish rapid native restarts from stale distributed-node state. */
  st->creation = (unsigned int)getpid();
  if (st->creation == 0)
    st->creation = 1;
  st->peer_regname = gn4_strdup("gtknode4");
  st->register_name = gn4_strdup("gtknode4");

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--test-mode") == 0) {
      st->test_mode = TRUE;
      continue;
    }
    if (i + 1 >= argc) {
      fprintf(stderr, "gtknode4: missing value for %s\n", argv[i]);
      return FALSE;
    }
    if (strcmp(argv[i], "--name") == 0)
      st->node_name = gn4_strdup(argv[++i]);
    else if (strcmp(argv[i], "--peer") == 0)
      st->peer_node = gn4_strdup(argv[++i]);
    else if (strcmp(argv[i], "--register") == 0) {
      g_free(st->register_name);
      st->register_name = gn4_strdup(argv[++i]);
    } else if (strcmp(argv[i], "--controller") == 0) {
      g_free(st->peer_regname);
      st->peer_regname = gn4_strdup(argv[++i]);
    } else if (strcmp(argv[i], "--cookie-env") == 0)
      cookie_env = argv[++i];
    else if (strcmp(argv[i], "--protocol") == 0)
      i++;
    else {
      fprintf(stderr, "gtknode4: unknown option %s\n", argv[i]);
      return FALSE;
    }
  }

  if (!st->node_name || !st->peer_node) {
    fprintf(stderr, "gtknode4: --name and --peer are required\n");
    return FALSE;
  }
  st->cookie = gn4_strdup(getenv(cookie_env));
  if (!st->cookie || st->cookie[0] == '\0') {
    fprintf(stderr, "gtknode4: cookie environment %s is missing\n", cookie_env);
    return FALSE;
  }
  {
    const char *at = strchr(st->node_name, '@');
    st->alive_name = at ? g_strndup(st->node_name, (gsize)(at - st->node_name))
                        : gn4_strdup(st->node_name);
  }
  st->running = TRUE;
  return TRUE;
}

gboolean gn4_init_erlang(Gn4State *st) {
  if (ei_init() < 0) {
    fprintf(stderr, "gtknode4: ei_init failed: erl_errno=%d (%s)\n",
            erl_errno, strerror(erl_errno));
    return FALSE;
  }
  if (ei_connect_init(&st->ec, st->alive_name, st->cookie, st->creation) < 0) {
    fprintf(stderr,
            "gtknode4: ei_connect_init for %s failed: erl_errno=%d (%s)\n",
            st->alive_name, erl_errno, strerror(erl_errno));
    return FALSE;
  }
  st->dist_fd = ei_connect(&st->ec, st->peer_node);
  if (st->dist_fd < 0) {
    fprintf(stderr,
            "gtknode4: ei_connect to %s failed: result=%d erl_errno=%d (%s)\n",
            st->peer_node, st->dist_fd, erl_errno, strerror(erl_errno));
    return FALSE;
  }
  fprintf(stderr, "gtknode4: connected to %s as %s\n", st->peer_node,
          st->node_name);
  return TRUE;
}

static void gn4_app_activate(GApplication *app, gpointer user_data) {
  (void)app;
  (void)user_data;
  /* Windows are created explicitly by gtkgs. */
}

gboolean gn4_init_gtk(Gn4State *st, int *argc, char ***argv) {
  GError *error = NULL;
  (void)argc;
  (void)argv;
  gtk_init();
  st->app = gtk_application_new("org.damagebdd.gtknode4",
                                G_APPLICATION_NON_UNIQUE);
  if (!st->app)
    return FALSE;
  g_signal_connect(st->app, "activate", G_CALLBACK(gn4_app_activate), st);
  if (!g_application_register(G_APPLICATION(st->app), NULL, &error)) {
    fprintf(stderr, "gtknode4: GTK application registration failed: %s\n",
            error ? error->message : "unknown");
    g_clear_error(&error);
    return FALSE;
  }
  st->widgets = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL,
                                      gn4_widget_free);
  st->stylesheets = g_hash_table_new_full(g_str_hash, g_str_equal, g_free,
                                         g_object_unref);
  if (!st->widgets || !st->stylesheets)
    return FALSE;
  return TRUE;
}

gboolean gn4_poll_erlang(Gn4State *st) {
  struct pollfd descriptor;
  ei_x_buff message_buffer;
  erlang_msg message;
  int result;
  int idx = 0;
  int version = 0;
  int envelope_arity = 0;
  char *tag = NULL;
  char *kind = NULL;
  erlang_ref ref;

  if (st->dist_fd < 0)
    return FALSE;
  descriptor.fd = st->dist_fd;
  descriptor.events = POLLIN;
  descriptor.revents = 0;
  result = poll(&descriptor, 1, 0);
  if (result == 0)
    return TRUE;
  if (result < 0) {
    if (errno == EINTR)
      return TRUE;
    return FALSE;
  }

  ei_x_new(&message_buffer);
  result = ei_xreceive_msg(st->dist_fd, &message, &message_buffer);
  if (result == ERL_TICK) {
    ei_x_free(&message_buffer);
    return TRUE;
  }
  if (result == ERL_ERROR) {
    ei_x_free(&message_buffer);
    st->running = FALSE;
    return FALSE;
  }
  if (message.msgtype != ERL_REG_SEND && message.msgtype != ERL_SEND) {
    ei_x_free(&message_buffer);
    return TRUE;
  }

  if (ei_decode_version(message_buffer.buff, &idx, &version) < 0 ||
      ei_decode_tuple_header(message_buffer.buff, &idx, &envelope_arity) < 0 ||
      !(tag = gn4_decode_string(message_buffer.buff, &idx)) ||
      strcmp(tag, "gtknode4") != 0 ||
      !(kind = gn4_decode_string(message_buffer.buff, &idx))) {
    fprintf(stderr, "gtknode4: malformed protocol envelope\n");
    goto done;
  }

  if (strcmp(kind, "call") == 0 && envelope_arity == 4) {
    if (ei_decode_ref(message_buffer.buff, &idx, &ref) < 0) {
      fprintf(stderr, "gtknode4: malformed call reference\n");
      goto done;
    }
    gn4_handle_command(st, message_buffer.buff, &idx, &ref, TRUE);
  } else if (strcmp(kind, "cast") == 0 && envelope_arity == 3) {
    gn4_handle_command(st, message_buffer.buff, &idx, NULL, FALSE);
  } else {
    fprintf(stderr, "gtknode4: unsupported protocol envelope\n");
  }

done:
  g_free(tag);
  g_free(kind);
  ei_x_free(&message_buffer);
  return TRUE;
}

gboolean gn4_send_hello(Gn4State *st) {
  ei_x_buff hello;
  const char *widgets[] = {"window", "box", "button", "label",
                           "entry", "text_view", "list_view", "scale",
                           "picture", "scrolled_box"};
  const int widget_count = (int)(sizeof(widgets) / sizeof(widgets[0]));
  int i;
  ei_x_new_with_version(&hello);
  ei_x_encode_tuple_header(&hello, 5);
  ei_x_encode_atom(&hello, "gtknode4");
  ei_x_encode_atom(&hello, "hello");
  ei_x_encode_long(&hello, GN4_PROTOCOL_VERSION);
  ei_x_encode_tuple_header(&hello, 2);
  ei_x_encode_atom(&hello, st->register_name);
  ei_x_encode_atom(&hello, st->node_name);
  ei_x_encode_map_header(&hello, 5);
  ei_x_encode_atom(&hello, "protocol");
  ei_x_encode_long(&hello, GN4_PROTOCOL_VERSION);
  ei_x_encode_atom(&hello, "widgets");
  ei_x_encode_list_header(&hello, widget_count);
  for (i = 0; i < widget_count; i++)
    ei_x_encode_atom(&hello, widgets[i]);
  ei_x_encode_empty_list(&hello);
  ei_x_encode_atom(&hello, "test_mode");
  ei_x_encode_atom(&hello, st->test_mode ? "true" : "false");
  ei_x_encode_atom(&hello, "css");
  ei_x_encode_atom(&hello, "true");
  ei_x_encode_atom(&hello, "style_commands");
  ei_x_encode_list_header(&hello, 2);
  ei_x_encode_atom(&hello, "set_stylesheet");
  ei_x_encode_atom(&hello, "remove_stylesheet");
  ei_x_encode_empty_list(&hello);
  if (ei_reg_send(&st->ec, st->dist_fd, st->peer_regname, hello.buff,
                  hello.index) < 0) {
    ei_x_free(&hello);
    return FALSE;
  }
  ei_x_free(&hello);
  return TRUE;
}

gboolean gn4_load_ui(Gn4State *st, const char *filename) {
  GError *error = NULL;
  GtkBuilder *builder = gtk_builder_new();
  if (!gtk_builder_add_from_file(builder, filename, &error)) {
    fprintf(stderr, "gtknode4: loading UI %s failed: %s\n", filename,
            error ? error->message : "unknown");
    g_clear_error(&error);
    g_object_unref(builder);
    return FALSE;
  }
  gn4_connect_signals(st, builder);
  g_clear_object(&st->builder);
  st->builder = builder;
  return TRUE;
}

GtkWidget *gn4_get_widget(Gn4State *st, const char *name) {
  GObject *object;
  if (!st->builder || !name)
    return NULL;
  object = gtk_builder_get_object(st->builder, name);
  return object && GTK_IS_WIDGET(object) ? GTK_WIDGET(object) : NULL;
}

gboolean gn4_set_widget_label(Gn4State *st, const char *widget_name,
                              const char *text) {
  GtkWidget *widget = gn4_get_widget(st, widget_name);
  if (GTK_IS_BUTTON(widget)) {
    gtk_button_set_label(GTK_BUTTON(widget), text);
    return TRUE;
  }
  if (GTK_IS_LABEL(widget)) {
    gtk_label_set_text(GTK_LABEL(widget), text);
    return TRUE;
  }
  return FALSE;
}

void gn4_connect_signals(Gn4State *st, GtkBuilder *builder) {
  (void)st;
  (void)builder;
}

void gn4_signal_handler(GtkWidget *widget, const char *signal_name,
                        gpointer user_data) {
  (void)widget;
  (void)signal_name;
  (void)user_data;
}

void gn4_main_loop(Gn4State *st) {
  GMainContext *context = g_main_context_default();
  while (st->running) {
    while (g_main_context_pending(context))
      g_main_context_iteration(context, FALSE);
    if (!gn4_poll_erlang(st))
      break;
    g_usleep(5000);
  }
}

void gn4_cleanup(Gn4State *st) {
  if (!st)
    return;
  if (st->stylesheets) {
    GdkDisplay *display = gdk_display_get_default();
    if (display)
      g_hash_table_foreach(st->stylesheets, gn4_remove_provider_for_display,
                           display);
    g_hash_table_destroy(st->stylesheets);
    st->stylesheets = NULL;
  }
  if (st->widgets) {
    /* Use the same leaf-first, container-aware destruction path during normal
     * shutdown. Never destroy a window while registry entries still contain
     * unowned pointers to its descendants. */
    while (g_hash_table_size(st->widgets) > 0) {
      GHashTableIter iter;
      gpointer key = NULL;
      gpointer value = NULL;
      long destroy_id = 0;

      g_hash_table_iter_init(&iter, st->widgets);
      while (g_hash_table_iter_next(&iter, &key, &value)) {
        Gn4Widget *entry = value;
        if (destroy_id == 0)
          destroy_id = entry->id;
        if (entry->parent_id == 0 ||
            !gn4_widget_lookup(st, entry->parent_id)) {
          destroy_id = entry->id;
          break;
        }
      }

      if (destroy_id == 0)
        break;
      gn4_destroy_widget(st, destroy_id);
    }
    g_hash_table_destroy(st->widgets);
    st->widgets = NULL;
  }
  g_clear_object(&st->builder);
  g_clear_object(&st->app);
  if (st->dist_fd >= 0)
    close(st->dist_fd);
  g_free(st->node_name);
  g_free(st->alive_name);
  g_free(st->cookie);
  g_free(st->peer_node);
  g_free(st->peer_regname);
  g_free(st->register_name);
}

int main(int argc, char **argv) {
  Gn4State state;
  if (!gn4_parse_args(&state, argc, argv)) {
    gn4_cleanup(&state);
    return 1;
  }
  if (!gn4_init_erlang(&state) || !gn4_init_gtk(&state, &argc, &argv) ||
      !gn4_send_hello(&state)) {
    gn4_cleanup(&state);
    return 1;
  }
  gn4_main_loop(&state);
  gn4_cleanup(&state);
  return 0;
}
