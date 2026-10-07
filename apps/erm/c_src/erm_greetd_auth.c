/*
 * ERM greetd authentication helper.
 *
 * Security boundary:
 *   - argv: username + opaque session id only
 *   - owns GREETD_SOCK and all PAM responses
 *   - secret text is held only by GtkPasswordEntry/native heap
 *   - stdout emits fixed state/error tokens only
 *   - session command is fixed; no shell and no UI supplied argv
 */
#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/resource.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_FRAME (1024U * 1024U)
#define MAX_RESPONSE 4096U

static int fd = -1;
static GtkWidget *prompt_window;
static GtkWidget *prompt_label;
static GtkWidget *prompt_entry;
static GMainLoop *prompt_loop;
static int prompt_cancelled;

static void emit(const char *s) { fputs(s, stdout); fputc('\n', stdout); fflush(stdout); }
static void wipe(void *p, size_t n) { volatile unsigned char *v = p; while (n--) *v++ = 0; }

static int valid_id(const char *s) {
  size_t n = strlen(s); if (!n || n > 64) return 0;
  for (size_t i=0;i<n;i++) { unsigned char c=s[i];
    if (!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-')) return 0;
  }
  return 1;
}

static int write_all(int f, const void *buf, size_t n) {
  const unsigned char *p = buf;
  while (n) { ssize_t r = write(f,p,n); if (r < 0) { if(errno==EINTR) continue; return -1; } p += r; n -= (size_t)r; }
  return 0;
}
static int read_all(int f, void *buf, size_t n) {
  unsigned char *p = buf;
  while (n) { ssize_t r = read(f,p,n); if (r == 0) return -1; if (r < 0) { if(errno==EINTR) continue; return -1; } p += r; n -= (size_t)r; }
  return 0;
}

static int send_json(const char *json) {
  uint32_t n = (uint32_t)strlen(json);
  if (write_all(fd,&n,sizeof n) || write_all(fd,json,n)) return -1;
  return 0;
}
static char *recv_json(void) {
  uint32_t n=0; if (read_all(fd,&n,sizeof n)) return NULL;
  if (!n || n > MAX_FRAME) return NULL;
  char *b = calloc(1,(size_t)n+1); if(!b) return NULL;
  if (read_all(fd,b,n)) { free(b); return NULL; }
  b[n]='\0'; return b;
}

static char *json_escape(const char *s) {
  size_t n = strlen(s), cap = n*6 + 1; char *o = malloc(cap); if(!o) return NULL; char *p=o;
  for (size_t i=0;i<n;i++) { unsigned char c=s[i];
    switch(c) {
      case '"': *p++='\\';*p++='"';break; case '\\':*p++='\\';*p++='\\';break;
      case '\b':*p++='\\';*p++='b';break; case '\f':*p++='\\';*p++='f';break;
      case '\n':*p++='\\';*p++='n';break; case '\r':*p++='\\';*p++='r';break; case '\t':*p++='\\';*p++='t';break;
      default: if(c<0x20){ sprintf(p,"\\u%04x",c); p+=6; } else *p++=(char)c;
    }
  }
  *p='\0'; return o;
}

static int field_eq(const char *j, const char *key, const char *value) {
  char needle[128];
  if (snprintf(needle, sizeof needle, "\"%s\"", key) >= (int)sizeof needle) return 0;
  const char *p = strstr(j, needle); if (!p) return 0;
  p += strlen(needle);
  while (*p==' '||*p=='\t'||*p=='\r'||*p=='\n') p++;
  if (*p++ != ':') return 0;
  while (*p==' '||*p=='\t'||*p=='\r'||*p=='\n') p++;
  if (*p++ != '"') return 0;
  size_t n=strlen(value);
  return strncmp(p,value,n)==0 && p[n]=='"';
}

static char *field_string(const char *j, const char *key) {
  char needle[128];
  if (snprintf(needle,sizeof needle,"\"%s\"",key) >= (int)sizeof needle) return NULL;
  const char *p=strstr(j,needle);
  if(!p) return NULL;
  p+=strlen(needle);
  while(*p==' '||*p=='\t'||*p=='\r'||*p=='\n') p++;
  if(*p++!=':') return NULL;
  while(*p==' '||*p=='\t'||*p=='\r'||*p=='\n') p++;
  if(*p++!='"') return NULL;
  size_t cap=strlen(p)+1;
  char *o=malloc(cap);
  if(!o) return NULL;
  char *q=o;
  while(*p && *p!='"') {
    if(*p!='\\'){*q++=*p++;continue;}
    p++; if(!*p)break;
    switch(*p++){
      case '"':*q++='"';break; case '\\':*q++='\\';break; case '/':*q++='/';break;
      case 'b':*q++='\b';break; case 'f':*q++='\f';break; case 'n':*q++='\n';break;
      case 'r':*q++='\r';break; case 't':*q++='\t';break;
      case 'u': if(strlen(p)>=4){*q++='?';p+=4;} break;
      default:*q++='?';break;
    }
  }
  *q='\0'; return o;
}

static void submit_clicked(GtkButton *b, gpointer data) { (void)b;(void)data; prompt_cancelled=0; if(prompt_loop) g_main_loop_quit(prompt_loop); }
static void cancel_clicked(GtkButton *b, gpointer data) { (void)b;(void)data; prompt_cancelled=1; if(prompt_loop) g_main_loop_quit(prompt_loop); }
static void entry_activate(GtkEntry *e, gpointer data) { (void)e;(void)data; prompt_cancelled=0; if(prompt_loop) g_main_loop_quit(prompt_loop); }

static char *prompt(const char *message, int secret) {
  prompt_cancelled=0;
  prompt_window = gtk_window_new(); gtk_window_set_title(GTK_WINDOW(prompt_window),"Authentication");
  gtk_window_set_modal(GTK_WINDOW(prompt_window),TRUE); gtk_window_set_default_size(GTK_WINDOW(prompt_window),420,180);
  GtkWidget *box=gtk_box_new(GTK_ORIENTATION_VERTICAL,12); gtk_widget_set_margin_top(box,20); gtk_widget_set_margin_bottom(box,20); gtk_widget_set_margin_start(box,20); gtk_widget_set_margin_end(box,20);
  prompt_label=gtk_label_new(message && *message ? message : "Authentication required"); gtk_label_set_wrap(GTK_LABEL(prompt_label),TRUE); gtk_label_set_xalign(GTK_LABEL(prompt_label),0.0f); gtk_box_append(GTK_BOX(box),prompt_label);
  prompt_entry = secret ? gtk_password_entry_new() : gtk_entry_new(); gtk_widget_set_hexpand(prompt_entry,TRUE); gtk_box_append(GTK_BOX(box),prompt_entry);
  GtkWidget *row=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8); GtkWidget *cancel=gtk_button_new_with_label("Cancel"); GtkWidget *ok=gtk_button_new_with_label("Continue"); gtk_box_append(GTK_BOX(row),cancel); gtk_box_append(GTK_BOX(row),ok); gtk_box_append(GTK_BOX(box),row);
  g_signal_connect(ok,"clicked",G_CALLBACK(submit_clicked),NULL); g_signal_connect(cancel,"clicked",G_CALLBACK(cancel_clicked),NULL);
  if (!secret) g_signal_connect(prompt_entry,"activate",G_CALLBACK(entry_activate),NULL);
  gtk_window_set_child(GTK_WINDOW(prompt_window),box); gtk_window_present(GTK_WINDOW(prompt_window)); gtk_widget_grab_focus(prompt_entry);
  emit("state:prompt");
  prompt_loop=g_main_loop_new(NULL,FALSE); g_main_loop_run(prompt_loop); g_main_loop_unref(prompt_loop); prompt_loop=NULL;
  char *out=NULL;
  if(!prompt_cancelled){ const char *t = gtk_editable_get_text(GTK_EDITABLE(prompt_entry)); size_t n=strlen(t); if(n<=MAX_RESPONSE) out=g_strdup(t); }
  gtk_window_destroy(GTK_WINDOW(prompt_window)); prompt_window=NULL; prompt_entry=NULL; prompt_label=NULL;
  return out;
}

static int connect_greetd(void) {
  const char *path=getenv("GREETD_SOCK"); if(!path || !*path) return -1;
  int s=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0); if(s<0) return -1;
  struct sockaddr_un a; memset(&a,0,sizeof a); a.sun_family=AF_UNIX;
  if(strlen(path)>=sizeof(a.sun_path)){close(s);return -1;} strcpy(a.sun_path,path);
  if(connect(s,(struct sockaddr*)&a,sizeof a)<0){close(s);return -1;} return s;
}

static int cancel_session(void) { return send_json("{\"type\":\"cancel_session\"}"); }

static int auth_flow(const char *username,const char *session_id) {
  char *u=json_escape(username); if(!u) return 1;
  size_t sz=strlen(u)+64; char *req=malloc(sz); if(!req){free(u);return 1;}
  snprintf(req,sz,"{\"type\":\"create_session\",\"username\":\"%s\"}",u); free(u);
  if(send_json(req)){free(req);return 1;} free(req);
  emit("state:authenticating");

  for(;;){
    char *j=recv_json(); if(!j) return 1;
    if(field_eq(j,"type","success")) { free(j); break; }
    if(field_eq(j,"type","error")) {
      int auth=field_eq(j,"error_type","auth_error"); free(j); emit(auth?"error:auth_failed":"error:greetd"); return auth?2:1;
    }
    if(!field_eq(j,"type","auth_message")){free(j);emit("error:protocol");return 1;}
    int secret=field_eq(j,"auth_message_type","secret");
    int visible=field_eq(j,"auth_message_type","visible");
    int info=field_eq(j,"auth_message_type","info");
    int error=field_eq(j,"auth_message_type","error");
    char *message=field_string(j,"auth_message");
    free(j);
    if(info||error){
      char *ignored=prompt(message ? message : (error ? "Authentication error" : "Authentication information"),0);
      if(ignored){wipe(ignored,strlen(ignored));g_free(ignored);} free(message);
      if(prompt_cancelled){cancel_session();emit("state:cancelled");return 3;}
      if(send_json("{\"type\":\"post_auth_message_response\"}")) return 1;
      continue;
    }
    if(!(secret||visible)){free(message);emit("error:protocol");return 1;}
    char *ans=prompt(message ? message : (secret ? "Password" : "Authentication response"),secret);
    free(message);
    if(!ans){ cancel_session(); emit("state:cancelled"); return 3; }
    char *e=json_escape(ans); wipe(ans,strlen(ans)); g_free(ans); if(!e){cancel_session();return 1;}
    size_t rs=strlen(e)+96; char *r=malloc(rs); if(!r){wipe(e,strlen(e));free(e);cancel_session();return 1;}
    snprintf(r,rs,"{\"type\":\"post_auth_message_response\",\"response\":\"%s\"}",e);
    wipe(e,strlen(e));free(e); int wr=send_json(r); wipe(r,strlen(r));free(r); if(wr) return 1;
    emit("state:authenticating");
  }

  char *sid=json_escape(session_id); if(!sid) return 1;
  size_t ns=strlen(sid)+512; char *start=malloc(ns); if(!start){free(sid);return 1;}
  snprintf(start,ns,
    "{\"type\":\"start_session\",\"cmd\":[\"/usr/lib/erm-session/bin/erm_session\",\"foreground\"],"
    "\"env\":[\"ERM_SESSION_ID=%s\",\"XDG_SESSION_TYPE=x11\"]}",sid);
  free(sid); if(send_json(start)){free(start);return 1;} free(start);
  char *reply=recv_json(); if(!reply) return 1;
  int ok=field_eq(reply,"type","success"); free(reply);
  if(!ok){emit("error:start_session");return 1;}
  emit("state:accepted"); return 0;
}

int main(int argc,char **argv){
  struct rlimit z={0,0}; setrlimit(RLIMIT_CORE,&z); prctl(PR_SET_DUMPABLE,0,0,0,0); prctl(PR_SET_PDEATHSIG,SIGTERM,0,0,0);
  if(argc!=3 || !valid_id(argv[2])){emit("error:arguments");return 64;}
  gtk_init();
  fd=connect_greetd(); if(fd<0){emit("error:greetd_socket");return 1;}
  int rc=auth_flow(argv[1],argv[2]); close(fd); fd=-1; return rc;
}
