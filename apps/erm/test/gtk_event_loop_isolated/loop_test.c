/* Exercise the production loop with a permanently ready GLib source and
 * real libei tick packets. No display or Erlang VM is needed. */
#define main gn4_program_main
#include "../../c_src/gtknode4/gtknode4.c"
#undef main
#include <assert.h>
#include <sys/socket.h>

typedef struct {
  Gn4State state;
  int peer;
  unsigned dispatches;
  gboolean wait_for_tick;
  gboolean acknowledged;
} Test;

static gboolean busy_source(gpointer data) {
  Test *test = data;
  char reply[4];
  test->dispatches++;
  if (test->wait_for_tick && recv(test->peer, reply, 4, MSG_DONTWAIT) == 4) {
    assert(memcmp(reply, "\0\0\0\0", 4) == 0);
    test->acknowledged = TRUE;
    test->state.running = FALSE;
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv) {
  int sockets[2];
  Test test = {0};
  ei_x_buff command;
  int index = 0;
  assert(argc == 2);
  alarm(4); /* Make starvation fail promptly, including against old code. */
  assert(ei_init() == 0);
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  test.state.dist_fd = sockets[0];
  test.state.running = TRUE;
  test.peer = sockets[1];

  if (!strcmp(argv[1], "main")) {
    test.wait_for_tick = TRUE;
    g_idle_add(busy_source, &test);
    assert(write(test.peer, "\0\0\0\0", 4) == 4);
    gn4_main_loop(&test.state);
    assert(test.dispatches > 0 && test.acknowledged);
  } else if (!strcmp(argv[1], "sync")) {
    guint source = g_idle_add(busy_source, &test);
    assert(ei_x_new(&command) == 0);
    assert(ei_x_encode_atom(&command, "sync") == 0);
    gn4_handle_command(&test.state, command.buff, &index, NULL, FALSE);
    assert(test.dispatches > 0);
    assert(g_main_context_pending(NULL)); /* sync must not wait for quiescence. */
    g_source_remove(source);
    ei_x_free(&command);
  } else if (!strcmp(argv[1], "partial")) {
    assert(write(test.peer, "\0", 1) == 1); /* Incomplete distribution header. */
    gint64 start = g_get_monotonic_time();
    assert(!gn4_poll_erlang(&test.state));
    assert(!test.state.running);
    assert(g_get_monotonic_time() - start < 3000000);
  } else if (!strcmp(argv[1], "closed")) {
    close(test.peer);
    test.peer = -1;
    assert(!gn4_main_loop(&test.state));
    assert(!test.state.running);
  } else if (!strcmp(argv[1], "shutdown")) {
    assert(ei_x_new(&command) == 0);
    assert(ei_x_encode_atom(&command, "shutdown") == 0);
    gn4_handle_command(&test.state, command.buff, &index, NULL, FALSE);
    assert(!test.state.running);
    assert(gn4_main_loop(&test.state));
    ei_x_free(&command);
  } else if (!strcmp(argv[1], "idle")) {
    assert(gn4_poll_erlang(&test.state));
    assert(test.state.running);
  } else {
    assert(!"unknown test case");
  }
  close(test.state.dist_fd);
  if (test.peer >= 0) close(test.peer);
  printf("PASS %s\n", argv[1]);
  return 0;
}
