#include <erl_nif.h>
#include <xcb/xcb.h>
#include <xcb/dpms.h>
#include <xcb/screensaver.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_EVENTS_PER_POLL 64

typedef struct {
    xcb_connection_t *conn;
    xcb_window_t root;
    uint8_t screensaver_first_event;
    ErlNifMutex *lock;
} erm_x11_t;

static ErlNifResourceType *ERM_X11_RESOURCE = NULL;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name)
{
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM ok_value(ErlNifEnv *env, ERL_NIF_TERM value)
{
    return enif_make_tuple2(env, atom(env, "ok"), value);
}

static ERL_NIF_TERM error_atom(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static ERL_NIF_TERM xcb_error_term(ErlNifEnv *env, xcb_generic_error_t *err)
{
    if (err == NULL)
        return error_atom(env, "x11_error");

    ERL_NIF_TERM detail = enif_make_tuple4(
        env,
        atom(env, "x11_error"),
        enif_make_uint(env, err->error_code),
        enif_make_uint(env, err->major_code),
        enif_make_uint(env, err->minor_code)
    );
    return enif_make_tuple2(env, atom(env, "error"), detail);
}

static int get_handle(ErlNifEnv *env, ERL_NIF_TERM term, erm_x11_t **out)
{
    return enif_get_resource(env, term, ERM_X11_RESOURCE, (void **)out);
}

/*
 * Lock the resource and verify that its XCB connection is still open.
 *
 * The NIF functions are exported so they can be replaced by load_nif/2.
 * Returning {error, closed} here prevents an accidental call made after
 * x11_close/1 from dereferencing a NULL xcb_connection_t pointer.
 */
static int lock_open_connection(erm_x11_t *h)
{
    enif_mutex_lock(h->lock);
    if (h->conn == NULL) {
        enif_mutex_unlock(h->lock);
        return 0;
    }
    return 1;
}

static ERL_NIF_TERM no_reply_error(ErlNifEnv *env, erm_x11_t *h)
{
    return error_atom(
        env,
        xcb_connection_has_error(h->conn) ? "connection_lost" : "no_reply"
    );
}

static int dpms_extension_available(erm_x11_t *h)
{
    const xcb_query_extension_reply_t *ext =
        xcb_get_extension_data(h->conn, &xcb_dpms_id);
    return ext != NULL && ext->present;
}

static xcb_screen_t *screen_for_number(xcb_connection_t *conn, int screen_number)
{
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_screen_iterator_t it = xcb_setup_roots_iterator(setup);

    while (it.rem > 0 && screen_number > 0) {
        xcb_screen_next(&it);
        screen_number--;
    }
    return it.rem > 0 ? it.data : NULL;
}

static void erm_x11_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    erm_x11_t *h = (erm_x11_t *)obj;

    if (h->lock != NULL)
        enif_mutex_lock(h->lock);

    if (h->conn != NULL) {
        xcb_disconnect(h->conn);
        h->conn = NULL;
    }

    if (h->lock != NULL) {
        enif_mutex_unlock(h->lock);
        enif_mutex_destroy(h->lock);
        h->lock = NULL;
    }
}

static ERL_NIF_TERM check_void_cookie(ErlNifEnv *env, erm_x11_t *h, xcb_void_cookie_t cookie)
{
    xcb_generic_error_t *err = xcb_request_check(h->conn, cookie);
    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        return result;
    }

    if (xcb_connection_has_error(h->conn))
        return error_atom(env, "connection_lost");

    xcb_flush(h->conn);
    return atom(env, "ok");
}

static ERL_NIF_TERM ss_state_atom(ErlNifEnv *env, uint8_t state)
{
    switch (state) {
        case XCB_SCREENSAVER_STATE_OFF:      return atom(env, "off");
        case XCB_SCREENSAVER_STATE_ON:       return atom(env, "on");
        case XCB_SCREENSAVER_STATE_CYCLE:    return atom(env, "cycle");
        case XCB_SCREENSAVER_STATE_DISABLED: return atom(env, "disabled");
        default:                              return atom(env, "unknown");
    }
}

static ERL_NIF_TERM ss_kind_atom(ErlNifEnv *env, uint8_t kind)
{
    switch (kind) {
        case XCB_SCREENSAVER_KIND_BLANKED:  return atom(env, "blanked");
        case XCB_SCREENSAVER_KIND_INTERNAL: return atom(env, "internal");
        case XCB_SCREENSAVER_KIND_EXTERNAL: return atom(env, "external");
        default:                             return atom(env, "unknown");
    }
}

static ERL_NIF_TERM dpms_level_atom(ErlNifEnv *env, uint16_t level)
{
    switch (level) {
        case XCB_DPMS_DPMS_MODE_ON:      return atom(env, "on");
        case XCB_DPMS_DPMS_MODE_STANDBY: return atom(env, "standby");
        case XCB_DPMS_DPMS_MODE_SUSPEND: return atom(env, "suspend");
        case XCB_DPMS_DPMS_MODE_OFF:     return atom(env, "off");
        default:                         return atom(env, "unknown");
    }
}

static int get_dpms_level(ErlNifEnv *env, ERL_NIF_TERM term, uint16_t *out)
{
    char name[16];
    if (!enif_get_atom(env, term, name, sizeof(name), ERL_NIF_LATIN1))
        return 0;

    if (strcmp(name, "on") == 0) {
        *out = XCB_DPMS_DPMS_MODE_ON;
    } else if (strcmp(name, "standby") == 0) {
        *out = XCB_DPMS_DPMS_MODE_STANDBY;
    } else if (strcmp(name, "suspend") == 0) {
        *out = XCB_DPMS_DPMS_MODE_SUSPEND;
    } else if (strcmp(name, "off") == 0) {
        *out = XCB_DPMS_DPMS_MODE_OFF;
    } else {
        return 0;
    }
    return 1;
}

static ERL_NIF_TERM nif_x11_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argv;
    if (argc != 0)
        return enif_make_badarg(env);

    int screen_number = 0;
    xcb_connection_t *conn = xcb_connect(NULL, &screen_number);
    if (conn == NULL || xcb_connection_has_error(conn)) {
        if (conn != NULL)
            xcb_disconnect(conn);
        return error_atom(env, "cannot_open_display");
    }

    xcb_screen_t *screen = screen_for_number(conn, screen_number);
    if (screen == NULL) {
        xcb_disconnect(conn);
        return error_atom(env, "screen_not_found");
    }

    const xcb_query_extension_reply_t *ss_ext =
        xcb_get_extension_data(conn, &xcb_screensaver_id);
    if (ss_ext == NULL || !ss_ext->present) {
        xcb_disconnect(conn);
        return error_atom(env, "screensaver_extension_unavailable");
    }

    xcb_void_cookie_t select_cookie = xcb_screensaver_select_input_checked(
        conn,
        screen->root,
        XCB_SCREENSAVER_EVENT_NOTIFY_MASK
    );
    xcb_generic_error_t *select_err = xcb_request_check(conn, select_cookie);
    if (select_err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, select_err);
        free(select_err);
        xcb_disconnect(conn);
        return result;
    }

    erm_x11_t *h = enif_alloc_resource(ERM_X11_RESOURCE, sizeof(*h));
    if (h == NULL) {
        xcb_disconnect(conn);
        return error_atom(env, "enomem");
    }

    memset(h, 0, sizeof(*h));
    h->conn = conn;
    h->root = screen->root;
    h->screensaver_first_event = ss_ext->first_event;
    h->lock = enif_mutex_create("erm_dpms_xcb");

    if (h->lock == NULL) {
        xcb_disconnect(conn);
        h->conn = NULL;
        enif_release_resource(h);
        return error_atom(env, "enomem");
    }

    xcb_flush(conn);

    ERL_NIF_TERM resource = enif_make_resource(env, h);
    enif_release_resource(h);
    return ok_value(env, resource);
}

static ERL_NIF_TERM nif_x11_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);

    enif_mutex_lock(h->lock);
    if (h->conn != NULL) {
        xcb_disconnect(h->conn);
        h->conn = NULL;
    }
    enif_mutex_unlock(h->lock);
    return atom(env, "ok");
}

static ERL_NIF_TERM nif_ss_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    xcb_generic_error_t *err = NULL;
    xcb_screensaver_query_info_reply_t *reply = xcb_screensaver_query_info_reply(
        h->conn,
        xcb_screensaver_query_info(h->conn, h->root),
        &err
    );

    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        free(reply);
        enif_mutex_unlock(h->lock);
        return result;
    }
    if (reply == NULL) {
        ERL_NIF_TERM result = no_reply_error(env, h);
        enif_mutex_unlock(h->lock);
        return result;
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, atom(env, "state"), ss_state_atom(env, reply->state), &map);
    enif_make_map_put(env, map, atom(env, "kind"), ss_kind_atom(env, reply->kind), &map);
    enif_make_map_put(env, map, atom(env, "idle_ms"), enif_make_uint(env, reply->ms_since_user_input), &map);
    enif_make_map_put(env, map, atom(env, "until_ms"), enif_make_uint(env, reply->ms_until_server), &map);
    enif_make_map_put(env, map, atom(env, "saver_window"), enif_make_uint(env, reply->saver_window), &map);

    free(reply);
    enif_mutex_unlock(h->lock);
    return ok_value(env, map);
}

static ERL_NIF_TERM nif_ss_events(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    ERL_NIF_TERM events[MAX_EVENTS_PER_POLL];
    unsigned int count = 0;
    xcb_generic_event_t *event;

    while (count < MAX_EVENTS_PER_POLL && (event = xcb_poll_for_event(h->conn)) != NULL) {
        uint8_t response_type = event->response_type & 0x7f;

        if (response_type == (uint8_t)(h->screensaver_first_event + XCB_SCREENSAVER_NOTIFY)) {
            xcb_screensaver_notify_event_t *ss = (xcb_screensaver_notify_event_t *)event;
            ERL_NIF_TERM map = enif_make_new_map(env);
            enif_make_map_put(env, map, atom(env, "state"), ss_state_atom(env, ss->state), &map);
            enif_make_map_put(env, map, atom(env, "kind"), ss_kind_atom(env, ss->kind), &map);
            enif_make_map_put(env, map, atom(env, "forced"), atom(env, ss->forced ? "true" : "false"), &map);
            enif_make_map_put(env, map, atom(env, "time"), enif_make_uint(env, ss->time), &map);
            events[count++] = map;
        }
        free(event);
    }

    if (xcb_connection_has_error(h->conn)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "connection_lost");
    }

    ERL_NIF_TERM list = enif_make_list(env, 0);
    while (count > 0) {
        --count;
        list = enif_make_list_cell(env, events[count], list);
    }

    enif_mutex_unlock(h->lock);
    return ok_value(env, list);
}

static ERL_NIF_TERM nif_get_screensaver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    xcb_generic_error_t *err = NULL;
    xcb_get_screen_saver_reply_t *reply = xcb_get_screen_saver_reply(
        h->conn,
        xcb_get_screen_saver(h->conn),
        &err
    );

    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        free(reply);
        enif_mutex_unlock(h->lock);
        return result;
    }
    if (reply == NULL) {
        ERL_NIF_TERM result = no_reply_error(env, h);
        enif_mutex_unlock(h->lock);
        return result;
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, atom(env, "timeout"), enif_make_uint(env, reply->timeout), &map);
    enif_make_map_put(env, map, atom(env, "interval"), enif_make_uint(env, reply->interval), &map);
    enif_make_map_put(env, map, atom(env, "prefer_blanking"), enif_make_uint(env, reply->prefer_blanking), &map);
    enif_make_map_put(env, map, atom(env, "allow_exposures"), enif_make_uint(env, reply->allow_exposures), &map);

    free(reply);
    enif_mutex_unlock(h->lock);
    return ok_value(env, map);
}

static ERL_NIF_TERM nif_set_screensaver_timeout(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    unsigned int timeout;
    if (argc != 2 || !get_handle(env, argv[0], &h) || !enif_get_uint(env, argv[1], &timeout) || timeout > 32767)
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    xcb_generic_error_t *err = NULL;
    xcb_get_screen_saver_reply_t *current = xcb_get_screen_saver_reply(
        h->conn,
        xcb_get_screen_saver(h->conn),
        &err
    );
    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        free(current);
        enif_mutex_unlock(h->lock);
        return result;
    }
    if (current == NULL) {
        ERL_NIF_TERM result = no_reply_error(env, h);
        enif_mutex_unlock(h->lock);
        return result;
    }

    xcb_void_cookie_t cookie = xcb_set_screen_saver_checked(
        h->conn,
        (int16_t)timeout,
        (int16_t)current->interval,
        current->prefer_blanking,
        current->allow_exposures
    );
    free(current);
    ERL_NIF_TERM result = check_void_cookie(env, h, cookie);
    enif_mutex_unlock(h->lock);
    return result;
}

static ERL_NIF_TERM nif_force_screensaver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    char mode[16];
    if (argc != 2 || !get_handle(env, argv[0], &h) ||
        !enif_get_atom(env, argv[1], mode, sizeof(mode), ERL_NIF_LATIN1))
        return enif_make_badarg(env);

    uint8_t xmode;
    if (strcmp(mode, "active") == 0)
        xmode = XCB_SCREEN_SAVER_ACTIVE;
    else if (strcmp(mode, "reset") == 0)
        xmode = XCB_SCREEN_SAVER_RESET;
    else
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    ERL_NIF_TERM result = check_void_cookie(env, h, xcb_force_screen_saver_checked(h->conn, xmode));
    enif_mutex_unlock(h->lock);
    return result;
}

static ERL_NIF_TERM nif_screensaver_suspend(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    int suspend;
    if (argc != 2 || !get_handle(env, argv[0], &h) || !enif_get_int(env, argv[1], &suspend)) {
        if (argc == 2 && get_handle(env, argv[0], &h)) {
            char b[8];
            if (enif_get_atom(env, argv[1], b, sizeof(b), ERL_NIF_LATIN1)) {
                if (strcmp(b, "true") == 0) suspend = 1;
                else if (strcmp(b, "false") == 0) suspend = 0;
                else return enif_make_badarg(env);
            } else {
                return enif_make_badarg(env);
            }
        } else {
            return enif_make_badarg(env);
        }
    }

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    ERL_NIF_TERM result = check_void_cookie(
        env,
        h,
        xcb_screensaver_suspend_checked(h->conn, suspend ? 1u : 0u)
    );
    enif_mutex_unlock(h->lock);
    return result;
}

static ERL_NIF_TERM nif_dpms_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    if (!dpms_extension_available(h)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "dpms_extension_unavailable");
    }

    xcb_generic_error_t *err = NULL;
    xcb_dpms_capable_reply_t *capable = xcb_dpms_capable_reply(
        h->conn,
        xcb_dpms_capable(h->conn),
        &err
    );
    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        free(capable);
        enif_mutex_unlock(h->lock);
        return result;
    }
    if (capable == NULL) {
        ERL_NIF_TERM result = no_reply_error(env, h);
        enif_mutex_unlock(h->lock);
        return result;
    }

    if (!capable->capable) {
        ERL_NIF_TERM map = enif_make_new_map(env);
        enif_make_map_put(env, map, atom(env, "capable"), atom(env, "false"), &map);
        enif_make_map_put(env, map, atom(env, "enabled"), atom(env, "false"), &map);
        enif_make_map_put(env, map, atom(env, "level"), atom(env, "unknown"), &map);
        free(capable);
        enif_mutex_unlock(h->lock);
        return ok_value(env, map);
    }
    free(capable);

    err = NULL;
    xcb_dpms_info_reply_t *info = xcb_dpms_info_reply(h->conn, xcb_dpms_info(h->conn), &err);
    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        free(info);
        enif_mutex_unlock(h->lock);
        return result;
    }
    if (info == NULL) {
        ERL_NIF_TERM result = no_reply_error(env, h);
        enif_mutex_unlock(h->lock);
        return result;
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, atom(env, "capable"), atom(env, "true"), &map);
    enif_make_map_put(env, map, atom(env, "enabled"), atom(env, info->state ? "true" : "false"), &map);
    enif_make_map_put(env, map, atom(env, "level"), dpms_level_atom(env, info->power_level), &map);

    free(info);
    enif_mutex_unlock(h->lock);
    return ok_value(env, map);
}

static ERL_NIF_TERM nif_get_dpms_timeouts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    if (!dpms_extension_available(h)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "dpms_extension_unavailable");
    }

    xcb_generic_error_t *err = NULL;
    xcb_dpms_get_timeouts_reply_t *reply = xcb_dpms_get_timeouts_reply(
        h->conn,
        xcb_dpms_get_timeouts(h->conn),
        &err
    );

    if (err != NULL) {
        ERL_NIF_TERM result = xcb_error_term(env, err);
        free(err);
        free(reply);
        enif_mutex_unlock(h->lock);
        return result;
    }
    if (reply == NULL) {
        ERL_NIF_TERM result = no_reply_error(env, h);
        enif_mutex_unlock(h->lock);
        return result;
    }

    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, atom(env, "standby"), enif_make_uint(env, reply->standby_timeout), &map);
    enif_make_map_put(env, map, atom(env, "suspend"), enif_make_uint(env, reply->suspend_timeout), &map);
    enif_make_map_put(env, map, atom(env, "off"), enif_make_uint(env, reply->off_timeout), &map);

    free(reply);
    enif_mutex_unlock(h->lock);
    return ok_value(env, map);
}

static ERL_NIF_TERM nif_set_dpms_timeouts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    unsigned int standby, suspend, off;
    if (argc != 4 || !get_handle(env, argv[0], &h) ||
        !enif_get_uint(env, argv[1], &standby) || standby > 65535 ||
        !enif_get_uint(env, argv[2], &suspend) || suspend > 65535 ||
        !enif_get_uint(env, argv[3], &off) || off > 65535)
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    if (!dpms_extension_available(h)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "dpms_extension_unavailable");
    }

    ERL_NIF_TERM result = check_void_cookie(
        env,
        h,
        xcb_dpms_set_timeouts_checked(
            h->conn,
            (uint16_t)standby,
            (uint16_t)suspend,
            (uint16_t)off
        )
    );
    enif_mutex_unlock(h->lock);
    return result;
}

static ERL_NIF_TERM nif_dpms_enable(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);
    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    if (!dpms_extension_available(h)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "dpms_extension_unavailable");
    }

    ERL_NIF_TERM result = check_void_cookie(env, h, xcb_dpms_enable_checked(h->conn));
    enif_mutex_unlock(h->lock);
    return result;
}

static ERL_NIF_TERM nif_dpms_disable(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    if (argc != 1 || !get_handle(env, argv[0], &h))
        return enif_make_badarg(env);
    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    if (!dpms_extension_available(h)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "dpms_extension_unavailable");
    }

    ERL_NIF_TERM result = check_void_cookie(env, h, xcb_dpms_disable_checked(h->conn));
    enif_mutex_unlock(h->lock);
    return result;
}

static ERL_NIF_TERM nif_dpms_force(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    erm_x11_t *h;
    uint16_t level;
    if (argc != 2 || !get_handle(env, argv[0], &h) || !get_dpms_level(env, argv[1], &level))
        return enif_make_badarg(env);

    if (!lock_open_connection(h))
        return error_atom(env, "closed");

    if (!dpms_extension_available(h)) {
        enif_mutex_unlock(h->lock);
        return error_atom(env, "dpms_extension_unavailable");
    }

    ERL_NIF_TERM result = check_void_cookie(
        env,
        h,
        xcb_dpms_force_level_checked(h->conn, level)
    );
    enif_mutex_unlock(h->lock);
    return result;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)priv;
    (void)info;
    ErlNifResourceFlags tried;
    ERM_X11_RESOURCE = enif_open_resource_type(
        env,
        NULL,
        "erm_x11_resource",
        erm_x11_dtor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        &tried
    );
    return ERM_X11_RESOURCE == NULL ? -1 : 0;
}

static ErlNifFunc nif_funcs[] = {
    {"x11_open", 0, nif_x11_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_close", 1, nif_x11_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_screensaver_info", 1, nif_ss_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_screensaver_events", 1, nif_ss_events, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_get_screensaver", 1, nif_get_screensaver, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_set_screensaver_timeout", 2, nif_set_screensaver_timeout, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_force_screensaver", 2, nif_force_screensaver, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_screensaver_suspend", 2, nif_screensaver_suspend, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_dpms_info", 1, nif_dpms_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_get_dpms_timeouts", 1, nif_get_dpms_timeouts, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_set_dpms_timeouts", 4, nif_set_dpms_timeouts, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_dpms_enable", 1, nif_dpms_enable, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_dpms_disable", 1, nif_dpms_disable, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"x11_dpms_force", 2, nif_dpms_force, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(erm_dpms, nif_funcs, load, NULL, NULL, NULL)
