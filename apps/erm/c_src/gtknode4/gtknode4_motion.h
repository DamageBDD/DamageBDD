#ifndef GTKNODE4_MOTION_H
#define GTKNODE4_MOTION_H
#include <gtk/gtk.h>
#include <ei.h>
GType gn4_motion_get_type(void);
#define GN4_IS_MOTION(w) (G_TYPE_CHECK_INSTANCE_TYPE((w), gn4_motion_get_type()))
GtkWidget *gn4_motion_new(gboolean meter);
gboolean gn4_motion_child(GtkWidget *stage, GtkWidget *child);
void gn4_motion_command(GtkWidget *widget, const char *action,
                        const char *buf, int *idx, ei_x_buff *result);
#endif
