%%--------------------------------------------------------------------
%% ERM Shop Demo
%%
%% A touch-friendly wxErlang sample shop shell that pays invoices using
%% the erm_pay NWC layer.
%%
%% Requires:
%%   erm_theme.erl
%%   erm_ui.erl
%%   erm_pay*.erl if you want live NWC payments
%%
%% Run:
%%   c(erm_theme).
%%   c(erm_ui).
%%   c(erm_shop_demo).
%%   erm_pay_sup:start_link(). %% optional until checkout
%%   erm_shop_demo:start().
%%
%% First connect NWC from shell or via Wallet tab:
%%   erm_pay:connect(<<"nostr+walletconnect://...">>).
%%--------------------------------------------------------------------

-module(erm_shop_demo).
-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").

-export([
    start/0,
    start_link/0,
    stop/1
]).

-export([
    init/1,
    handle_event/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(ID_HOME, 1001).
-define(ID_SHOP, 1002).
-define(ID_CART, 1003).
-define(ID_ACCOUNT, 1004).
-define(ID_SEARCH, 1005).
-define(ID_PAY, 1006).
-define(ID_CLEAR_CART, 1007).
-define(ID_CONNECT_NWC, 1008).
-define(ID_REFRESH_STATUS, 1009).
-define(ID_THEME_DARK, 1010).
-define(ID_THEME_AMBER, 1011).
-define(ID_THEME_LIGHT, 1012).
-define(ID_ADD_BASE, 2000).
-define(ID_REMOVE_BASE, 3000).

-define(CARD_WIDTH, 390).

-record(st, {
    frame,
    root,
    body,
    top,
    bottom,
    view = home,
    products = [],
    cart = #{},
    pay_ref = undefined,
    status = <<"Ready">>
}).

start() ->
    wx_object:start(?MODULE, [], []).

start_link() ->
    wx_object:start_link(?MODULE, [], []).

stop(Pid) ->
    wx_object:call(Pid, stop).

init([]) ->
    _Wx = wx:new(),

    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "ERM Shop", [
        {size, {430, 840}}
    ]),

    Root = erm_ui:panel(Frame, root),
    erm_ui:apply_root(Root),

    RootSizer = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Root, RootSizer),

    Top = erm_ui:panel(Root, top),
    Body = wxScrolledWindow:new(Root, []),
    Bottom = erm_ui:panel(Root, bottom),

    wxWindow:setBackgroundColour(Body, erm_theme:color(bg, erm_theme:current())),
    wxScrolledWindow:setScrollRate(Body, 0, 14),

    wxSizer:add(RootSizer, Top, [
        {flag, ?wxEXPAND bor ?wxALL},
        {border, 0}
    ]),
    wxSizer:add(RootSizer, Body, [
        {proportion, 1},
        {flag, ?wxEXPAND bor ?wxALL},
        {border, 0}
    ]),
    wxSizer:add(RootSizer, Bottom, [
        {flag, ?wxEXPAND bor ?wxALL},
        {border, 0}
    ]),

    wxFrame:connect(Frame, command_button_clicked),
    wxFrame:connect(Frame, close_window),

    _ = maybe_subscribe_pay_events(),

    St0 = #st{
        frame = Frame,
        root = Root,
        body = Body,
        top = Top,
        bottom = Bottom,
        products = products()
    },

    St1 = render(home, St0),
    wxFrame:show(Frame),
    {Frame, St1}.

handle_call(stop, _From, St = #st{frame = Frame}) ->
    wxFrame:destroy(Frame),
    {reply, ok, St};
handle_call(_Call, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_Cast, St) ->
    {noreply, St}.

handle_event(#wx{id = ?ID_HOME, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(home, St)};
handle_event(#wx{id = ?ID_SHOP, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(shop, St)};
handle_event(#wx{id = ?ID_CART, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(cart, St)};
handle_event(#wx{id = ?ID_ACCOUNT, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(account, St)};
handle_event(#wx{id = ?ID_SEARCH, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(shop, St#st{status = <<"Search stub: wire product filter here">>})};
handle_event(#wx{id = ?ID_CLEAR_CART, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(cart, St#st{cart = #{}, status = <<"Cart cleared">>})};
handle_event(#wx{id = ?ID_PAY, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, pay_cart(St)};
handle_event(#wx{id = ?ID_CONNECT_NWC, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, connect_nwc_dialog(St)};
handle_event(#wx{id = ?ID_REFRESH_STATUS, event = #wxCommand{type = command_button_clicked}}, St) ->
    {noreply, render(account, St#st{status = pay_status_text()})};
handle_event(#wx{id = ?ID_THEME_DARK, event = #wxCommand{type = command_button_clicked}}, St) ->
    ok = erm_ui:set_theme(damage_dark),
    {noreply, render(St#st.view, St#st{status = <<"Theme: Damage Dark">>})};
handle_event(#wx{id = ?ID_THEME_AMBER, event = #wxCommand{type = command_button_clicked}}, St) ->
    ok = erm_ui:set_theme(amber_terminal),
    {noreply, render(St#st.view, St#st{status = <<"Theme: Amber Terminal">>})};
handle_event(#wx{id = ?ID_THEME_LIGHT, event = #wxCommand{type = command_button_clicked}}, St) ->
    ok = erm_ui:set_theme(clean_light),
    {noreply, render(St#st.view, St#st{status = <<"Theme: Clean Light">>})};
handle_event(#wx{id = Id, event = #wxCommand{type = command_button_clicked}}, St) when
    Id >= ?ID_ADD_BASE, Id < ?ID_REMOVE_BASE
->
    ProductId = Id - ?ID_ADD_BASE,
    {noreply, render(St#st.view, add_to_cart(ProductId, St))};
handle_event(#wx{id = Id, event = #wxCommand{type = command_button_clicked}}, St) when
    Id >= ?ID_REMOVE_BASE
->
    ProductId = Id - ?ID_REMOVE_BASE,
    {noreply, render(cart, remove_from_cart(ProductId, St))};
handle_event(#wx{event = #wxClose{}}, St = #st{frame = Frame}) ->
    wxFrame:destroy(Frame),
    {stop, normal, St};
handle_event(_Event, St) ->
    {noreply, St}.

handle_info({erm_pay, #{type := payment_started, ref := Ref}}, St) ->
    {noreply, render(cart, St#st{pay_ref = Ref, status = <<"Paying invoice over NWC...">>})};
handle_info({erm_pay, #{type := payment_paid, ref := Ref, result := _Result}}, St) ->
    Status = iolist_to_binary(["Payment confirmed: ", io_lib:format("~p", [Ref])]),
    {noreply, render(home, St#st{cart = #{}, pay_ref = undefined, status = Status})};
handle_info({erm_pay, #{type := payment_failed, reason := Reason}}, St) ->
    Status = iolist_to_binary(["Payment failed: ", io_lib:format("~p", [Reason])]),
    {noreply, render(cart, St#st{pay_ref = undefined, status = Status})};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) ->
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%%--------------------------------------------------------------------
%% Rendering
%%--------------------------------------------------------------------

render(View, St0) ->
    St = St0#st{view = View},
    apply_shell_theme(St),
    rebuild_top(St),
    rebuild_body(View, St),
    rebuild_bottom(St),
    wxWindow:layout(St#st.root),
    wxWindow:refresh(St#st.root),
    St.

apply_shell_theme(#st{root = Root, body = Body, top = Top, bottom = Bottom}) ->
    Theme = erm_theme:current(),
    wxWindow:setBackgroundColour(Root, erm_theme:color(bg, Theme)),
    wxWindow:setBackgroundColour(Body, erm_theme:color(bg, Theme)),
    wxWindow:setBackgroundColour(Top, erm_theme:color(surface, Theme)),
    wxWindow:setBackgroundColour(Bottom, erm_theme:color(surface, Theme)),
    ok.

rebuild_top(St = #st{top = Top}) ->
    wxWindow:destroyChildren(Top),
    wxWindow:setBackgroundColour(Top, erm_theme:color(surface, erm_theme:current())),

    Sizer = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Top, Sizer),

    Row = wxBoxSizer:new(?wxHORIZONTAL),

    Title = erm_ui:title(Top, "⚡ ERM Shop"),
    Search = erm_ui:touch_button(Top, ?ID_SEARCH, "Search"),
    Cart = erm_ui:touch_button(Top, ?ID_CART, cart_label(St)),

    wxSizer:add(Row, Title, [
        {proportion, 1},
        {flag, ?wxALIGN_CENTER_VERTICAL bor ?wxLEFT},
        {border, 16}
    ]),
    wxSizer:add(Row, Search, [{flag, ?wxALL}, {border, 6}]),
    wxSizer:add(Row, Cart, [{flag, ?wxALL}, {border, 6}]),

    Status = erm_ui:status_text(Top, St#st.status),

    wxSizer:add(Sizer, Row, [{flag, ?wxEXPAND}]),
    wxSizer:add(Sizer, Status, [
        {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM},
        {border, 16}
    ]),
    ok.

rebuild_body(home, St = #st{body = Body}) ->
    reset_body(Body),
    S = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Body, S),

    add_hero(
        Body,
        S,
        "Lightning-native shopping",
        "Browse items, build a cart, then pay a merchant BOLT11 invoice through NWC. No cards. No fiat rails. Just a delegated wallet connection."
    ),
    add_section_title(Body, S, "Featured"),
    lists:foreach(
        fun(P) -> add_product_card(Body, S, P, St) end,
        first_n(2, St#st.products)
    ),

    wxScrolledWindow:fitInside(Body),
    ok;
rebuild_body(shop, St = #st{body = Body}) ->
    reset_body(Body),
    S = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Body, S),

    add_section_title(Body, S, "Shop"),
    add_small_text(
        Body,
        S,
        "Touch-friendly cards. Later: categories, filters, merchant search, Nostr listings."
    ),
    lists:foreach(fun(P) -> add_product_card(Body, S, P, St) end, St#st.products),

    wxScrolledWindow:fitInside(Body),
    ok;
rebuild_body(cart, St = #st{body = Body}) ->
    reset_body(Body),
    S = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Body, S),

    add_section_title(Body, S, "Cart"),
    case maps:size(St#st.cart) of
        0 ->
            add_hero(
                Body,
                S,
                "Your cart is empty",
                "Add something from the shop, then pay with your NWC wallet connection."
            );
        _ ->
            lists:foreach(
                fun({ProductId, Qty}) ->
                    add_cart_row(Body, S, ProductId, Qty, St)
                end,
                maps:to_list(St#st.cart)
            ),
            add_total_panel(Body, S, St),
            Pay = erm_ui:touch_button(Body, ?ID_PAY, "Pay with NWC"),
            Clear = erm_ui:touch_button(Body, ?ID_CLEAR_CART, "Clear cart"),
            add_centered_control(S, Pay, 12),
            add_centered_control(S, Clear, 12)
    end,

    wxScrolledWindow:fitInside(Body),
    ok;
rebuild_body(account, #st{body = Body}) ->
    reset_body(Body),
    S = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Body, S),

    add_section_title(Body, S, "Account / Wallet"),
    add_hero(
        Body,
        S,
        "NWC wallet connection",
        "Connect a delegated wallet URI. Keep wallet-side budgets tight. ERM only receives permission to request payments through that connection."
    ),
    add_small_text(Body, S, pay_status_text()),

    Connect = erm_ui:touch_button(Body, ?ID_CONNECT_NWC, "Connect / replace NWC URI"),
    Refresh = erm_ui:touch_button(Body, ?ID_REFRESH_STATUS, "Refresh status"),
    add_centered_control(S, Connect, 12),
    add_centered_control(S, Refresh, 12),

    add_section_title(Body, S, "Theme"),
    Dark = erm_ui:touch_button(Body, ?ID_THEME_DARK, "Damage Dark"),
    Amber = erm_ui:touch_button(Body, ?ID_THEME_AMBER, "Amber Terminal"),
    Light = erm_ui:touch_button(Body, ?ID_THEME_LIGHT, "Clean Light"),
    add_centered_control(S, Dark, 12),
    add_centered_control(S, Amber, 12),
    add_centered_control(S, Light, 12),

    wxScrolledWindow:fitInside(Body),
    ok.

rebuild_bottom(St = #st{bottom = Bottom}) ->
    wxWindow:destroyChildren(Bottom),
    wxWindow:setBackgroundColour(Bottom, erm_theme:color(surface, erm_theme:current())),

    S = wxBoxSizer:new(?wxHORIZONTAL),
    wxWindow:setSizer(Bottom, S),

    add_tab(Bottom, S, ?ID_HOME, "Home", St#st.view =:= home),
    add_tab(Bottom, S, ?ID_SHOP, "Shop", St#st.view =:= shop),
    add_tab(Bottom, S, ?ID_CART, cart_short_label(St), St#st.view =:= cart),
    add_tab(Bottom, S, ?ID_ACCOUNT, "Wallet", St#st.view =:= account),
    ok.

reset_body(Body) ->
    wxWindow:destroyChildren(Body),
    wxWindow:setBackgroundColour(Body, erm_theme:color(bg, erm_theme:current())),
    ok.

add_tab(Parent, Sizer, Id, Label, Active) ->
    Text =
        case Active of
            true -> "● " ++ to_list(Label);
            false -> to_list(Label)
        end,

    Btn = erm_ui:touch_button(Parent, Id, Text),
    erm_ui:paint_button(Btn, Active),

    wxSizer:add(Sizer, Btn, [
        {proportion, 1},
        {flag, ?wxEXPAND bor ?wxALL},
        {border, 5}
    ]),
    ok.

add_hero(Parent, Sizer, Title, Body) ->
    Panel = erm_ui:card_alt(Parent),
    wxWindow:setMinSize(Panel, {?CARD_WIDTH, -1}),

    PS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Panel, PS),

    T = erm_ui:title(Panel, Title),
    B = erm_ui:body_text(Panel, Body),

    wxSizer:add(PS, T, [{flag, ?wxEXPAND bor ?wxALL}, {border, 16}]),
    wxSizer:add(PS, B, [
        {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM},
        {border, 16}
    ]),

    add_centered_card(Sizer, Panel, 14),
    ok.

add_section_title(Parent, Sizer, Text) ->
    T = erm_ui:section(Parent, Text),
    wxSizer:add(Sizer, T, [
        {flag, ?wxALIGN_CENTER_HORIZONTAL bor ?wxLEFT bor ?wxRIGHT bor ?wxTOP},
        {border, 16}
    ]),
    ok.

add_small_text(Parent, Sizer, Text0) ->
    T = erm_ui:small_text(Parent, Text0),
    wxSizer:add(Sizer, T, [
        {flag, ?wxALIGN_CENTER_HORIZONTAL bor ?wxLEFT bor ?wxRIGHT bor ?wxTOP},
        {border, 16}
    ]),
    ok.

add_product_card(Parent, Sizer, Product, St) ->
    #{id := Id, name := Name, desc := Desc, sats := Sats} = Product,

    Panel = erm_ui:card(Parent),
    wxWindow:setMinSize(Panel, {?CARD_WIDTH, -1}),

    PS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Panel, PS),

    NameText = erm_ui:section(Panel, Name),
    DescText = erm_ui:body_text(Panel, Desc),
    PriceText = erm_ui:title(Panel, io_lib:format("~p sats", [Sats])),
    Btn = erm_ui:touch_button(Panel, ?ID_ADD_BASE + Id, add_label(Id, St)),

    wxSizer:add(PS, NameText, [{flag, ?wxEXPAND bor ?wxALL}, {border, 14}]),
    wxSizer:add(PS, DescText, [
        {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT},
        {border, 14}
    ]),
    wxSizer:add(PS, PriceText, [{flag, ?wxEXPAND bor ?wxALL}, {border, 14}]),
    wxSizer:add(PS, Btn, [
        {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM},
        {border, 14}
    ]),

    add_centered_card(Sizer, Panel, 14),
    ok.

add_cart_row(Parent, Sizer, ProductId, Qty, St) ->
    Product = find_product(ProductId, St#st.products),
    #{name := Name, sats := Sats} = Product,

    Panel = erm_ui:card(Parent),
    wxWindow:setMinSize(Panel, {?CARD_WIDTH, -1}),

    Row = wxBoxSizer:new(?wxHORIZONTAL),
    wxWindow:setSizer(Panel, Row),

    Label = io_lib:format("~s  x~p  —  ~p sats", [to_list(Name), Qty, Qty * Sats]),
    Text = erm_ui:body_text(Panel, Label),
    Remove = erm_ui:touch_button(Panel, ?ID_REMOVE_BASE + ProductId, "−"),

    wxSizer:add(Row, Text, [
        {proportion, 1},
        {flag, ?wxALIGN_CENTER_VERTICAL bor ?wxALL},
        {border, 14}
    ]),
    wxSizer:add(Row, Remove, [{flag, ?wxALL}, {border, 10}]),

    add_centered_card(Sizer, Panel, 14),
    ok.

add_total_panel(Parent, Sizer, St) ->
    TotalSats = cart_total_sats(St),

    Panel = erm_ui:card_alt(Parent),
    wxWindow:setMinSize(Panel, {?CARD_WIDTH, -1}),

    PS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Panel, PS),

    Text = erm_ui:title(Panel, io_lib:format("Total: ~p sats", [TotalSats])),
    wxSizer:add(PS, Text, [{flag, ?wxEXPAND bor ?wxALL}, {border, 16}]),

    add_centered_card(Sizer, Panel, 14),
    ok.

add_centered_card(Sizer, Window, Border) ->
    wxSizer:add(Sizer, Window, [
        {flag, ?wxALIGN_CENTER_HORIZONTAL bor ?wxLEFT bor ?wxRIGHT bor ?wxTOP},
        {border, Border}
    ]),
    ok.

add_centered_control(Sizer, Window, Border) ->
    wxWindow:setMinSize(Window, {?CARD_WIDTH, 42}),
    wxSizer:add(Sizer, Window, [
        {flag, ?wxALIGN_CENTER_HORIZONTAL bor ?wxLEFT bor ?wxRIGHT bor ?wxTOP},
        {border, Border}
    ]),
    ok.

%%--------------------------------------------------------------------
%% Actions
%%--------------------------------------------------------------------

add_to_cart(ProductId, St = #st{cart = Cart}) ->
    Qty = maps:get(ProductId, Cart, 0) + 1,
    St#st{cart = Cart#{ProductId => Qty}, status = <<"Added to cart">>}.

remove_from_cart(ProductId, St = #st{cart = Cart0}) ->
    Cart =
        case maps:get(ProductId, Cart0, 0) of
            Qty when Qty =< 1 -> maps:remove(ProductId, Cart0);
            Qty -> Cart0#{ProductId => Qty - 1}
        end,
    St#st{cart = Cart, status = <<"Cart updated">>}.

pay_cart(St = #st{cart = Cart}) when map_size(Cart) =:= 0 ->
    render(cart, St#st{status = <<"Cart is empty">>});
pay_cart(St) ->
    case ensure_nwc_connected() of
        ok ->
            case ask_invoice(St) of
                {ok, Invoice} ->
                    Metadata = checkout_metadata(St),
                    case erm_pay:pay_invoice_async(Invoice, Metadata) of
                        {ok, Ref} ->
                            render(cart, St#st{pay_ref = Ref, status = <<"Payment requested">>});
                        {error, Reason} ->
                            render(cart, St#st{status = fmt_bin("NWC error: ~p", [Reason])})
                    end;
                cancel ->
                    render(cart, St#st{status = <<"Checkout cancelled">>})
            end;
        {error, Reason} ->
            render(account, St#st{status = fmt_bin("Connect NWC first: ~p", [Reason])})
    end.

connect_nwc_dialog(St = #st{frame = Frame}) ->
    Dialog = wxTextEntryDialog:new(
        Frame,
        "Paste NWC URI. This demo stores it locally with file mode 0600.",
        [{caption, "Connect NWC"}]
    ),
    case wxTextEntryDialog:showModal(Dialog) of
        ?wxID_OK ->
            Value = wxTextEntryDialog:getValue(Dialog),
            wxTextEntryDialog:destroy(Dialog),
            case erm_pay:connect(unicode:characters_to_binary(Value)) of
                {ok, _Redacted} ->
                    render(account, St#st{status = <<"NWC connected">>});
                {error, Reason} ->
                    render(account, St#st{status = fmt_bin("NWC connection failed: ~p", [Reason])})
            end;
        _ ->
            wxTextEntryDialog:destroy(Dialog),
            render(account, St#st{status = <<"NWC unchanged">>})
    end.

ask_invoice(St = #st{frame = Frame}) ->
    Total = cart_total_sats(St),
    Prompt = io_lib:format(
        "Paste merchant BOLT11 invoice for ~p sats. In production this comes from the merchant checkout endpoint.",
        [Total]
    ),
    Dialog = wxTextEntryDialog:new(Frame, Prompt, [{caption, "Lightning Checkout"}]),
    case wxTextEntryDialog:showModal(Dialog) of
        ?wxID_OK ->
            Value = wxTextEntryDialog:getValue(Dialog),
            wxTextEntryDialog:destroy(Dialog),
            Bin = unicode:characters_to_binary(Value),
            case Bin of
                <<>> -> cancel;
                _ -> {ok, Bin}
            end;
        _ ->
            wxTextEntryDialog:destroy(Dialog),
            cancel
    end.

ensure_nwc_connected() ->
    case catch erm_pay:status() of
        #{connected := true} -> ok;
        #{connected := false} -> {error, not_connected};
        {'EXIT', _} -> {error, erm_pay_not_running};
        Other -> {error, Other}
    end.

maybe_subscribe_pay_events() ->
    case catch erm_pay:subscribe() of
        ok -> ok;
        _ -> skipped
    end.

pay_status_text() ->
    case catch erm_pay:status() of
        #{connected := true, uri := Uri} ->
            iolist_to_binary(["Connected: ", Uri]);
        #{connected := false} ->
            <<"Not connected">>;
        {'EXIT', _} ->
            <<"erm_pay is not running. Start erm_pay_sup first.">>;
        Other ->
            fmt_bin("Status: ~p", [Other])
    end.

checkout_metadata(St) ->
    TotalSats = cart_total_sats(St),
    #{
        source => erm_shop_demo,
        merchant => <<"demo-merchant">>,
        cart => cart_lines(St),
        amount_msat => TotalSats * 1000,
        comment => <<"ERM Shop demo checkout">>
    }.

cart_lines(St = #st{cart = Cart}) ->
    lists:map(
        fun({ProductId, Qty}) ->
            Product = find_product(ProductId, St#st.products),
            #{id => ProductId, qty => Qty, name => maps:get(name, Product)}
        end,
        maps:to_list(Cart)
    ).

%%--------------------------------------------------------------------
%% Data
%%--------------------------------------------------------------------

products() ->
    [
        #{
            id => 1,
            name => <<"BDD Verification Pass">>,
            sats => 2100,
            desc => <<"One behaviour execution pass for an API, node, or app workflow.">>
        },
        #{
            id => 2,
            name => <<"Nostr Relay Smoke Test">>,
            sats => 3400,
            desc => <<"Publish, subscribe, classify, and score relay behaviour.">>
        },
        #{
            id => 3,
            name => <<"CLN Health Probe">>,
            sats => 5500,
            desc => <<"Check peer state, liquidity warnings, invoice flow, and log signals.">>
        },
        #{
            id => 4,
            name => <<"ECAI Index Lookup">>,
            sats => 8900,
            desc =>
                <<"Query an encoded knowledge index and return deterministic traversal proof metadata.">>
        },
        #{
            id => 5,
            name => <<"Tor Onion Service Check">>,
            sats => 14400,
            desc => <<"Validate hidden service reachability, port routing, and timeout behaviour.">>
        }
    ].

first_n(N, List) ->
    first_n(N, List, []).

first_n(0, _List, Acc) ->
    lists:reverse(Acc);
first_n(_N, [], Acc) ->
    lists:reverse(Acc);
first_n(N, [H | T], Acc) ->
    first_n(N - 1, T, [H | Acc]).

find_product(ProductId, Products) ->
    case [P || P <- Products, maps:get(id, P) =:= ProductId] of
        [Product | _] -> Product;
        [] -> #{id => ProductId, name => <<"Unknown item">>, sats => 0, desc => <<>>}
    end.

%%--------------------------------------------------------------------
%% Cart helpers
%%--------------------------------------------------------------------

cart_total_sats(St = #st{cart = Cart}) ->
    lists:sum([
        Qty * maps:get(sats, find_product(ProductId, St#st.products))
     || {ProductId, Qty} <- maps:to_list(Cart)
    ]).

cart_count(#st{cart = Cart}) ->
    lists:sum(maps:values(Cart)).

cart_label(St) ->
    io_lib:format("Cart (~p)", [cart_count(St)]).

cart_short_label(St) ->
    io_lib:format("Cart ~p", [cart_count(St)]).

add_label(ProductId, #st{cart = Cart}) ->
    case maps:get(ProductId, Cart, 0) of
        0 -> "Add to cart";
        Qty -> io_lib:format("Add to cart (~p)", [Qty])
    end.

%%--------------------------------------------------------------------
%% Formatting
%%--------------------------------------------------------------------

fmt_bin(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).

to_list(V) when is_binary(V) ->
    unicode:characters_to_list(V);
to_list(V) when is_list(V) ->
    V;
to_list(V) when is_atom(V) ->
    atom_to_list(V);
to_list(V) ->
    io_lib:format("~p", [V]).
