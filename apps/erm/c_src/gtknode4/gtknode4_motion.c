/* GTK owns interpolation and drawing. No per-frame Erlang messages. */
#include "gtknode4_motion.h"
#include <math.h>
#include <string.h>

enum { X, Y, SCALE, ROTATION, OPACITY, INPUT, OUTPUT, MOOD, N_VALUES };
static const char *names[] = {"x", "y", "scale", "rotation", "opacity",
                              "input", "output", "mood"};
typedef struct { double from[N_VALUES], to[N_VALUES], start, duration; int ease; } Segment;
typedef struct {
  GtkWidget parent;
  GtkWidget *child;
  gboolean meter, active, paused, reduced;
  guint tick;
  long animation_id;
  double value[N_VALUES], initial[N_VALUES], elapsed, total;
  gint64 last_time;
  Segment segments[64];
  int count;
} Gn4Motion;
typedef struct { GtkWidgetClass parent; } Gn4MotionClass;
G_DEFINE_TYPE(Gn4Motion, gn4_motion, GTK_TYPE_WIDGET)
static guint finished_signal;

static gboolean number(const char *buf, int *idx, double *v) {
  int i = *idx; long n;
  if (ei_decode_double(buf, idx, v) < 0) {
    *idx = i;
    if (ei_decode_long(buf, idx, &n) < 0) return FALSE;
    *v = n;
  }
  return isfinite(*v);
}
static gboolean atom(const char *buf, int *idx, char *out, int capacity) {
  int type, size;
  if (ei_get_type(buf, idx, &type, &size) < 0 || size >= capacity) return FALSE;
  return ei_decode_atom(buf, idx, out) == 0;
}
static gboolean values(const char *buf, int *idx, double *v) {
  int count;
  if (ei_decode_map_header(buf, idx, &count) < 0 || count > N_VALUES) return FALSE;
  for (int i = 0; i < count; i++) {
    char key[32]; double n; int k;
    if (!atom(buf, idx, key, sizeof(key)) || !number(buf, idx, &n)) return FALSE;
    for (k = 0; k < N_VALUES; k++) if (!strcmp(key, names[k])) break;
    if (k == N_VALUES || fabs(n) > 100000 ||
        (k == SCALE && (n < .01 || n > 100)) ||
        ((k == OPACITY || k == INPUT || k == OUTPUT) && (n < 0 || n > 1)) ||
        (k == MOOD && (n < 0 || n > 5 || floor(n) != n))) return FALSE;
    v[k] = n;
  }
  return TRUE;
}
static double easing(int kind, double t) {
  if (t >= 1) return 1;
  if (kind == 1) return 1 - pow(1-t, 3);
  if (kind == 2) return 1 - exp(-7*t) * (cos(10*t) + .7*sin(10*t));
  return t;
}
static void invalidate(Gn4Motion *m) {
  gtk_widget_set_opacity(GTK_WIDGET(m), CLAMP(m->value[OPACITY], 0, 1));
  if (m->child) gtk_widget_queue_allocate(GTK_WIDGET(m));
  gtk_widget_queue_draw(GTK_WIDGET(m));
}
static void sample(Gn4Motion *m, double ms) {
  memcpy(m->value, m->initial, sizeof(m->value));
  for (int i = 0; i < m->count; i++) {
    Segment *s = &m->segments[i];
    if (ms < s->start) break;
    double t = s->duration > 0 ? CLAMP((ms-s->start)/s->duration, 0, 1) : 1;
    double e = easing(s->ease, t);
    for (int k = 0; k < N_VALUES; k++)
      m->value[k] = k == MOOD ? s->to[k] : s->from[k] + (s->to[k]-s->from[k])*e;
    if (t < 1) break;
  }
  invalidate(m);
}
static gboolean enabled(Gn4Motion *m) {
  gboolean on = TRUE;
  g_object_get(gtk_widget_get_settings(GTK_WIDGET(m)), "gtk-enable-animations", &on, NULL);
  return on && !m->reduced;
}
static gboolean animate_tick(GtkWidget *w, GdkFrameClock *clock, gpointer unused) {
  (void)unused;
  Gn4Motion *m = (Gn4Motion *)w;
  gint64 now = gdk_frame_clock_get_frame_time(clock);
  if (m->active && !m->paused) {
    if (m->last_time) m->elapsed += (now-m->last_time)/1000.0;
    if (!enabled(m)) m->elapsed = m->total;
    sample(m, m->elapsed);
    if (m->elapsed >= m->total) {
      m->active = FALSE;
      g_signal_emit(m, finished_signal, 0, m->animation_id, "completed");
    }
  }
  m->last_time = now;
  gboolean busy = m->meter && (int)m->value[MOOD] == 2 && enabled(m);
  if (busy) gtk_widget_queue_draw(w);
  if ((m->active && !m->paused) || busy) return G_SOURCE_CONTINUE;
  m->tick = 0;
  return G_SOURCE_REMOVE;
}
static void schedule(Gn4Motion *m) {
  if (!m->tick) {
    m->last_time = 0;
    m->tick = gtk_widget_add_tick_callback(GTK_WIDGET(m), animate_tick, NULL, NULL);
  }
}
static void cancel(Gn4Motion *m, const char *reason) {
  gboolean active = m->active;
  m->active = m->paused = FALSE;
  if (m->tick) gtk_widget_remove_tick_callback(GTK_WIDGET(m), m->tick);
  m->tick = 0;
  if (active) g_signal_emit(m, finished_signal, 0, m->animation_id, reason);
}
static void measure(GtkWidget *w, GtkOrientation orientation, int for_size,
                    int *minimum, int *natural, int *min_base, int *nat_base) {
  Gn4Motion *m = (Gn4Motion *)w;
  *min_base = *nat_base = -1;
  if (m->child) gtk_widget_measure(m->child, orientation, for_size, minimum, natural, min_base, nat_base);
  else *minimum = *natural = m->meter ? 220 : 0;
}
static void allocate(GtkWidget *w, int width, int height, int baseline) {
  Gn4Motion *m = (Gn4Motion *)w;
  if (!m->child) return;
  graphene_point_t center = GRAPHENE_POINT_INIT(width*.5f + m->value[X], height*.5f + m->value[Y]);
  graphene_point_t back = GRAPHENE_POINT_INIT(-width*.5f, -height*.5f);
  GskTransform *t = gsk_transform_translate(NULL, &center);
  t = gsk_transform_rotate(t, m->value[ROTATION]);
  t = gsk_transform_scale(t, m->value[SCALE], m->value[SCALE]);
  t = gsk_transform_translate(t, &back);
  gtk_widget_allocate(m->child, width, height, baseline, t);
}
static void circle(cairo_t *cr, double r, double width, double red, double green, double blue, double alpha) {
  cairo_set_source_rgba(cr, red, green, blue, alpha);
  cairo_set_line_width(cr, width); cairo_arc(cr, 0, 0, r, 0, 2*G_PI); cairo_stroke(cr);
}
static void snapshot(GtkWidget *w, GtkSnapshot *s) {
  Gn4Motion *m = (Gn4Motion *)w;
  if (m->child) gtk_widget_snapshot_child(w, m->child, s);
  if (!m->meter) return;
  double width = gtk_widget_get_width(w), height = gtk_widget_get_height(w);
  graphene_rect_t rect = GRAPHENE_RECT_INIT(0, 0, width, height);
  cairo_t *cr = gtk_snapshot_append_cairo(s, &rect);
  cairo_translate(cr, width/2, height/2);
  double scale = MIN(width, height)/240; cairo_scale(cr, scale, scale);
  double in = CLAMP(m->value[INPUT], 0, 1), out = CLAMP(m->value[OUTPUT], 0, 1);
  int mood = (int)m->value[MOOD];
  double r=.23, g=.85, b=.78;
  if (mood == 3) {r=.63; g=.51; b=1;}
  if (mood == 4) {r=1; g=.38; b=.42;}
  if (mood == 2) {r=.35; g=.63; b=1;}
  double energy = MAX(in, out);
  cairo_pattern_t *halo = cairo_pattern_create_radial(0,0,12,0,0,100);
  cairo_pattern_add_color_stop_rgba(halo,0,r,g,b,.13+.2*energy);
  cairo_pattern_add_color_stop_rgba(halo,1,r,g,b,0);
  cairo_set_source(cr,halo); cairo_paint(cr); cairo_pattern_destroy(halo);
  circle(cr,87,1,.45,.56,.68,.2);
  circle(cr,66+9*in,2,.23,.85,.78,.3+.6*in);
  circle(cr,77+8*out,2,.63,.51,1,.2+.7*out);
  circle(cr,48,1.5,r,g,b,.8);
  cairo_set_line_cap(cr,CAIRO_LINE_CAP_ROUND);
  for(int i=-3;i<=3;i++) {
    double h=5+(28*energy)*(1-fabs((double)i)/4.0);
    cairo_set_source_rgba(cr,r,g,b,.8); cairo_set_line_width(cr,4);
    cairo_move_to(cr,i*10,-h); cairo_line_to(cr,i*10,h); cairo_stroke(cr);
  }
  if (mood == 2) {
    GdkFrameClock *clock=gtk_widget_get_frame_clock(w);
    double a = enabled(m) && clock ? gdk_frame_clock_get_frame_time(clock)/700000.0 : -G_PI/2;
    cairo_set_source_rgba(cr,r,g,b,.9); cairo_set_line_width(cr,3);
    cairo_arc(cr,0,0,87,a,a+G_PI*.6); cairo_stroke(cr);
  }
  cairo_destroy(cr);
}
static void dispose(GObject *object) {
  Gn4Motion *m=(Gn4Motion *)object;
  if(m->tick) gtk_widget_remove_tick_callback(GTK_WIDGET(m),m->tick);
  m->tick=0;
  if(m->child) {gtk_widget_unparent(m->child); m->child=NULL;}
  G_OBJECT_CLASS(gn4_motion_parent_class)->dispose(object);
}
static void gn4_motion_class_init(Gn4MotionClass *c) {
  GtkWidgetClass *w=GTK_WIDGET_CLASS(c);
  w->measure=measure; w->size_allocate=allocate; w->snapshot=snapshot;
  G_OBJECT_CLASS(c)->dispose=dispose;
  gtk_widget_class_set_css_name(w,"erm-motion");
  finished_signal=g_signal_new("motion-finished",G_TYPE_FROM_CLASS(c),G_SIGNAL_RUN_LAST,
                              0,NULL,NULL,NULL,G_TYPE_NONE,2,G_TYPE_LONG,G_TYPE_STRING);
}
static void gn4_motion_init(Gn4Motion *m) {
  m->value[SCALE]=m->value[OPACITY]=1;
  memcpy(m->initial,m->value,sizeof(m->value));
  gtk_widget_set_overflow(GTK_WIDGET(m),GTK_OVERFLOW_VISIBLE);
}
GtkWidget *gn4_motion_new(gboolean meter) {
  Gn4Motion *m=g_object_new(gn4_motion_get_type(),NULL); m->meter=meter;
  return GTK_WIDGET(m);
}
gboolean gn4_motion_child(GtkWidget *w, GtkWidget *child) {
  Gn4Motion *m=(Gn4Motion *)w;
  if(m->meter || (m->child && child)) return FALSE;
  if(m->child) gtk_widget_unparent(m->child);
  m->child=child;
  if(child) gtk_widget_set_parent(child,w);
  gtk_widget_queue_resize(w);
  return TRUE;
}
static void error(ei_x_buff *r,const char *reason) {
  ei_x_encode_tuple_header(r,2); ei_x_encode_atom(r,"error"); ei_x_encode_atom(r,reason);
}
void gn4_motion_command(GtkWidget *w,const char *action,const char *buf,int *idx,ei_x_buff *r) {
  if(!GN4_IS_MOTION(w)) {error(r,"motion_container_required"); return;}
  Gn4Motion *m=(Gn4Motion *)w;
  if(!strcmp(action,"play")) {
    int arity,count; long id; char reduced[16];
    Segment segments[64]; double next[N_VALUES],total=0;
    memcpy(next,m->value,sizeof(next));
    if(ei_decode_tuple_header(buf,idx,&arity)<0 || arity!=3 || ei_decode_long(buf,idx,&id)<0 || id<0 ||
       !atom(buf,idx,reduced,sizeof(reduced)) || (strcmp(reduced,"true") && strcmp(reduced,"false")) ||
       ei_decode_list_header(buf,idx,&count)<0 || count<1 || count>64) {error(r,"badarg");return;}
    for(int i=0;i<count;i++) {
      double duration,delay; char ease[24];
      if(ei_decode_tuple_header(buf,idx,&arity)<0 || arity!=4 || !number(buf,idx,&duration) ||
         !number(buf,idx,&delay) || duration<0 || delay<0 || !atom(buf,idx,ease,sizeof(ease))) {error(r,"badarg");return;}
      Segment *s=&segments[i]; memcpy(s->from,next,sizeof(next));
      if(!values(buf,idx,next)) {error(r,"badarg");return;}
      memcpy(s->to,next,sizeof(next)); s->start=total+delay; s->duration=duration;
      s->ease=!strcmp(ease,"linear")?0:!strcmp(ease,"out_cubic")?1:!strcmp(ease,"spring")?2:-1;
      total+=delay+duration;
      if(s->ease<0 || total>600000) {error(r,"badarg");return;}
    }
    if(ei_decode_list_header(buf,idx,&arity)<0 || arity!=0) {error(r,"badarg");return;}
    cancel(m,"replaced"); m->animation_id=id; m->reduced=!strcmp(reduced,"true");
    memcpy(m->initial,m->value,sizeof(m->value)); memcpy(m->segments,segments,count*sizeof(Segment));
    m->count=count; m->elapsed=0; m->total=total; m->active=TRUE;
    if(!enabled(m) || total==0) {
      sample(m,total); m->active=FALSE; g_signal_emit(m,finished_signal,0,id,"completed");
    } else schedule(m);
  } else if(!strcmp(action,"set")) {
    double next[N_VALUES]; memcpy(next,m->value,sizeof(next));
    if(!values(buf,idx,next)) {error(r,"badarg");return;}
    cancel(m,"replaced"); memcpy(m->value,next,sizeof(next));
    memcpy(m->initial,next,sizeof(next)); m->count=0; m->elapsed=m->total=0;
    invalidate(m);
    if(m->meter && (int)m->value[MOOD]==2 && enabled(m)) schedule(m);
  } else if(!strcmp(action,"seek")) {
    double ms;
    if(!number(buf,idx,&ms) || ms<0 || ms>m->total) {error(r,"badarg");return;}
    m->elapsed=ms; m->paused=TRUE; sample(m,ms);
    if(m->tick) gtk_widget_remove_tick_callback(w,m->tick);
    m->tick=0;
  } else if(!strcmp(action,"cancel")) cancel(m,"cancelled");
  else if(!strcmp(action,"pause")) {
    m->paused=TRUE;
    if(m->tick) gtk_widget_remove_tick_callback(w,m->tick);
    m->tick=0;
  } else if(!strcmp(action,"resume")) {m->paused=FALSE; if(m->active) schedule(m);}
  else if(!strcmp(action,"inspect")) {
    ei_x_encode_tuple_header(r,2); ei_x_encode_atom(r,"ok"); ei_x_encode_map_header(r,N_VALUES+4);
    for(int k=0;k<N_VALUES;k++) {ei_x_encode_atom(r,names[k]); ei_x_encode_double(r,m->value[k]);}
    ei_x_encode_atom(r,"active"); ei_x_encode_atom(r,m->active?"true":"false");
    ei_x_encode_atom(r,"paused"); ei_x_encode_atom(r,m->paused?"true":"false");
    ei_x_encode_atom(r,"animation_id"); ei_x_encode_long(r,m->animation_id);
    ei_x_encode_atom(r,"elapsed_ms"); ei_x_encode_double(r,MIN(m->elapsed,m->total));
    return;
  } else {error(r,"unsupported_motion_action");return;}
  ei_x_encode_atom(r,"ok");
}
