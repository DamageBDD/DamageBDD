-ifndef(ERM_LOG_HRL).
-define(ERM_LOG_HRL, true).

%% OTP logger domains. Domains are lists of atoms so logger_filters:domain/2
%% can route all erm events, or narrower UI/process/autoplay events, to a
%% dedicated file handler without scraping message text.
-define(ERM_LOG_DOMAIN, [erm]).
-define(ERM_LOG_DOMAIN_GTK, [erm, gtk]).
-define(ERM_LOG_DOMAIN_GTKNODE4, [erm, gtk, gtknode4]).
-define(ERM_LOG_DOMAIN_GTKGS, [erm, gtk, gtkgs]).
-define(ERM_LOG_DOMAIN_MPV, [erm, mpv]).
-define(ERM_LOG_DOMAIN_MPV_UI, [erm, mpv, ui]).
-define(ERM_LOG_DOMAIN_MPV_PROC, [erm, mpv, proc]).
-define(ERM_LOG_DOMAIN_MPV_AUTOPLAY, [erm, mpv, autoplay]).

-define(ERM_LOG_META(Domain), #{domain => Domain}).

-endif.
