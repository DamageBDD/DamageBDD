/* Real native GTK controller lifecycle, keyboard routing and repeat handling. */
#include <assert.h>
#define ei_reg_send notes_test_send
#define main gtknode4_program_main
#include "../../c_src/gtknode4/gtknode4.c"
#undef main
#undef ei_reg_send
static int events;
static char last_key[32];
int notes_test_send(ei_cnode *ec,int fd,char *name,char *buf,int len) {
  int i=0,v,n;char atom[64];long id;unsigned long long seq;
  (void)ec;(void)fd;(void)name;(void)len;
  assert(!ei_decode_version(buf,&i,&v));assert(!ei_decode_tuple_header(buf,&i,&n));assert(n==6);
  assert(!ei_decode_atom(buf,&i,atom));assert(!ei_decode_atom(buf,&i,atom));
  assert(!ei_decode_ulonglong(buf,&i,&seq));assert(!ei_decode_long(buf,&i,&id));
  assert(!ei_decode_atom(buf,&i,atom));assert(!strcmp(atom,"keypress"));
  assert(!ei_decode_map_header(buf,&i,&n)&&n==1);
  assert(!ei_decode_atom(buf,&i,atom)&&!strcmp(atom,"key"));
  assert(!ei_decode_atom(buf,&i,last_key));events++;return 0;
}
int main(void) {
  gtk_init();Gn4State st={0};
  st.app=gtk_application_new("org.erm.VoiceNotesKeysTest",G_APPLICATION_NON_UNIQUE);
  assert(g_application_register(G_APPLICATION(st.app),NULL,NULL));
  st.widgets=g_hash_table_new_full(g_direct_hash,g_direct_equal,NULL,gn4_widget_free);
  Gn4Options o;gn4_options_init(&o);
  Gn4Widget *w=gn4_create_widget(&st,1,"window",0,&o);assert(w);gtk_widget_add_css_class(w->widget,"erm_voice_notes_window");gn4_options_clear(&o);
  gn4_options_init(&o);Gn4Widget *box=gn4_create_widget(&st,2,"box",1,&o);assert(box);
  Gn4Widget *button=gn4_create_widget(&st,3,"button",2,&o);assert(button);
  Gn4Widget *entry=gn4_create_widget(&st,4,"entry",2,&o);assert(entry);
  gtk_window_present(GTK_WINDOW(w->widget));
  for(int n=0;n<64 && g_main_context_pending(NULL);n++)g_main_context_iteration(NULL,FALSE);
  GListModel *controllers=gtk_widget_observe_controllers(w->widget);
  GtkEventController *key=NULL;
  for(guint i=0;i<g_list_model_get_n_items(controllers);i++) {
    GObject *c=g_list_model_get_item(controllers,i);
    if(GTK_IS_EVENT_CONTROLLER_KEY(c) && g_signal_handler_find(c,G_SIGNAL_MATCH_FUNC,0,0,NULL,G_CALLBACK(gn4_notes_key),NULL))key=GTK_EVENT_CONTROLLER(c);else g_object_unref(c);
  }
  assert(key);g_object_unref(controllers);gboolean handled=FALSE;
  gtk_window_set_focus(GTK_WINDOW(w->widget),button->widget);
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_space,65,0,&handled);
  assert(handled&&events==1&&!strcmp(last_key,"space"));
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_space,65,0,&handled);assert(events==1);
  g_signal_emit_by_name(key,"key-released",GDK_KEY_space,65,0);
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_space,65,0,&handled);assert(events==2);
  g_signal_emit_by_name(key,"key-released",GDK_KEY_space,65,0);
  gtk_window_set_focus(GTK_WINDOW(w->widget),entry->widget);
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_space,65,0,&handled);assert(!handled&&events==2);
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_Escape,9,0,&handled);
  assert(handled&&events==3&&!strcmp(last_key,"escape"));
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_space,65,GDK_CONTROL_MASK,&handled);
  assert(!handled&&events==3);
  gn4_destroy_widget(&st,1);
  g_signal_emit_by_name(key,"key-pressed",GDK_KEY_Escape,9,0,&handled);assert(events==3);
  g_object_unref(key);g_hash_table_unref(st.widgets);g_object_unref(st.app);
  puts("GTK shortcuts: Space, repeat suppression, editable focus, Escape, modifiers and destruction passed");
  return 0;
}
