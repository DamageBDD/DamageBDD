/* Window-scoped shortcuts for the voice-note app. Consume Space once per
 * physical press, including when a button has focus; preserve text editing. */
static gboolean gn4_notes_key(GtkEventControllerKey *controller, guint key,
                             guint code, GdkModifierType modifiers, gpointer data) {
  Gn4Widget *entry = data;
  GtkWidget *focus;
  ei_x_buff event;
  const char *name;
  (void)code;
  if (entry->destroying || entry->suppress_events ||
      !gtk_widget_has_css_class(entry->widget, "erm_voice_notes_window"))
    return FALSE;
  if (modifiers & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK))
    return FALSE;
  if (key == GDK_KEY_Escape) name = "escape";
  else if (key == GDK_KEY_space) {
    focus = gtk_window_get_focus(GTK_WINDOW(entry->widget));
    if (focus && (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus))) return FALSE;
    if (g_object_get_data(G_OBJECT(controller), "erm_space_down")) return TRUE;
    g_object_set_data(G_OBJECT(controller), "erm_space_down", GINT_TO_POINTER(1));
    name = "space";
  } else return FALSE;
  gn4_event_begin(entry, &event, "keypress", 1);
  ei_x_encode_atom(&event, "key");
  ei_x_encode_atom(&event, name);
  gn4_event_send(entry, &event);
  return TRUE;
}
static void gn4_notes_key_up(GtkEventControllerKey *controller, guint key,
                            guint code, GdkModifierType modifiers, gpointer data) {
  (void)code; (void)modifiers; (void)data;
  if (key == GDK_KEY_space)
    g_object_set_data(G_OBJECT(controller), "erm_space_down", NULL);
}
static void gn4_voice_notes_keys(Gn4Widget *entry) {
  GtkEventController *key;
  if (!GTK_IS_WINDOW(entry->widget)) return;
  key = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(key, GTK_PHASE_CAPTURE);
  g_signal_connect(key, "key-pressed", G_CALLBACK(gn4_notes_key), entry);
  g_signal_connect(key, "key-released", G_CALLBACK(gn4_notes_key_up), entry);
  gtk_widget_add_controller(entry->widget, key);
}
