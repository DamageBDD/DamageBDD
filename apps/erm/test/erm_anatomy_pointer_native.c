/* Real GTK widget/controller lifecycle test; intercept only Erlang transport. */
#include <assert.h>
#define ei_reg_send test_reg_send
#define main gtknode4_program_main
#include "../c_src/gtknode4/gtknode4.c"
#undef main
#undef ei_reg_send
static char last_event[128];
static int events;
static int hellos;
static double last_dx;
int test_reg_send(ei_cnode *ec, int fd, char *name, char *buf, int len) {
  int i=0, version, arity, fields; char atom[128]; long id; unsigned long long seq;
  (void)ec; (void)fd; (void)name; (void)len;
  assert(ei_decode_version(buf,&i,&version)==0);
  assert(ei_decode_tuple_header(buf,&i,&arity)==0);
  if (arity==5) {
    gboolean pointer=FALSE, maps=FALSE, widget_map=FALSE;
    assert(ei_decode_atom(buf,&i,atom)==0 && strcmp(atom,"gtknode4")==0);
    assert(ei_decode_atom(buf,&i,atom)==0 && strcmp(atom,"hello")==0);
    assert(ei_decode_long(buf,&i,&id)==0 && id==GN4_PROTOCOL_VERSION);
    assert(ei_skip_term(buf,&i)==0);
    assert(ei_decode_map_header(buf,&i,&fields)==0);
    for (int n=0;n<fields;n++) {
      assert(ei_decode_atom(buf,&i,atom)==0);
      if (strcmp(atom,"pointer_events")==0) {
        assert(ei_decode_atom(buf,&i,atom)==0 && strcmp(atom,"true")==0);
        pointer=TRUE;
      } else if (strcmp(atom,"libshumate")==0) {
        assert(ei_decode_atom(buf,&i,atom)==0);
#ifdef HAVE_LIBSHUMATE
        assert(strcmp(atom,"true")==0);
#else
        assert(strcmp(atom,"false")==0);
#endif
        maps=TRUE;
      } else if (strcmp(atom,"widgets")==0) {
        int count, tail;
        assert(ei_decode_list_header(buf,&i,&count)==0);
        for (int w=0;w<count;w++) {
          assert(ei_decode_atom(buf,&i,atom)==0);
          if (strcmp(atom,"map")==0) widget_map=TRUE;
        }
        assert(ei_decode_list_header(buf,&i,&tail)==0 && tail==0);
      } else assert(ei_skip_term(buf,&i)==0);
    }
    assert(pointer && maps && i==len);
#ifdef HAVE_LIBSHUMATE
    assert(widget_map);
#else
    assert(!widget_map);
#endif
    hellos++;
    return 0;
  }
  assert(arity==6);
  assert(ei_decode_atom(buf,&i,atom)==0);
  assert(ei_decode_atom(buf,&i,atom)==0);
  assert(ei_decode_ulonglong(buf,&i,&seq)==0);
  assert(ei_decode_long(buf,&i,&id)==0);
  assert(ei_decode_atom(buf,&i,last_event)==0);
  assert(ei_decode_map_header(buf,&i,&fields)==0 && fields==5);
  for(int n=0;n<fields;n++) {
    assert(ei_decode_atom(buf,&i,atom)==0);
    if(strcmp(atom,"dx")==0) assert(ei_decode_double(buf,&i,&last_dx)==0);
    else assert(ei_skip_term(buf,&i)==0);
  }
  events++;
  return 0;
}
int main(int argc, char **argv) {
  Gn4State st={0};
  st.register_name="gtknode4";
  st.node_name="test@localhost";
  assert(gn4_send_hello(&st) && hellos==1);
  puts("Native hello capability encoding: passed");
  if (argc==2 && strcmp(argv[1],"--hello-only")==0) return 0;
  gtk_init();
  st.app=gtk_application_new("org.erm.AnatomySmoke",G_APPLICATION_NON_UNIQUE);
  assert(g_application_register(G_APPLICATION(st.app),NULL,NULL));
  st.widgets=g_hash_table_new_full(g_direct_hash,g_direct_equal,NULL,gn4_widget_free);
  Gn4Options opts;gn4_options_init(&opts);
  Gn4Widget *window=gn4_create_widget(&st,1,"window",0,&opts);assert(window);
  Gn4Widget *box=gn4_create_widget(&st,2,"box",1,&opts);assert(box);
  opts.has_pointer_events=TRUE;opts.pointer_events=TRUE;
  Gn4Widget *view=gn4_create_widget(&st,3,"picture",2,&opts);assert(view);
  assert(view->pointer_drag && view->pointer_scroll && view->pointer_click);
  g_signal_emit_by_name(view->pointer_drag,"drag-begin",100.0,90.0);
  assert(strcmp(last_event,"pointer_drag_begin")==0);
  g_signal_emit_by_name(view->pointer_drag,"drag-update",12.0,3.0);
  assert(strcmp(last_event,"pointer_drag_update")==0 && last_dx==12.0);
  g_signal_emit_by_name(view->pointer_drag,"drag-end",15.0,5.0);
  assert(strcmp(last_event,"pointer_drag_end")==0 && last_dx==15.0);
  gboolean handled=FALSE;
  g_signal_emit_by_name(view->pointer_scroll,"scroll",0.0,-1.0,&handled);
  assert(handled && strcmp(last_event,"pointer_scroll")==0);
  g_signal_emit_by_name(view->pointer_click,"pressed",2,100.0,90.0);
  assert(strcmp(last_event,"pointer_doubleclick")==0);
  g_signal_emit_by_name(view->pointer_drag,"cancel",NULL);
  assert(strcmp(last_event,"pointer_cancel")==0);
  int count=events;gn4_pointer_events(view,FALSE);
  g_signal_emit_by_name(view->pointer_scroll,"scroll",0.0,1.0,&handled);
  assert(!handled && events==count);
  gn4_pointer_events(view,TRUE);
  GtkEventController *retained=g_object_ref(view->pointer_drag);
  gn4_destroy_widget(&st,1);
  assert(g_hash_table_size(st.widgets)==0);
  g_signal_emit_by_name(retained,"drag-update",2.0,3.0);
  assert(events==count);g_object_unref(retained);
  g_hash_table_unref(st.widgets);g_object_unref(st.app);
  puts("GTK native pointer events, payloads, opt-out and destruction: passed");
  return 0;
}
