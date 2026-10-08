CC      ?= cc
INSTALL ?= install

ERL_ROOT        ?= $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().' -s init stop)
ERL_EI_INC      := $(ERL_ROOT)/usr/include
ERL_EI_LIB      := $(ERL_ROOT)/usr/lib

GTK_CFLAGS      ?= $(shell pkg-config --cflags gtk4)
GTK_LIBS        ?= $(shell pkg-config --libs gtk4)
SHUMATE_CFLAGS  ?= $(shell pkg-config --silence-errors --cflags shumate-1.0)
SHUMATE_LIBS    ?= $(shell pkg-config --silence-errors --libs shumate-1.0)

CFLAGS  := -O2 -Wall -Wextra $(GTK_CFLAGS) -I$(ERL_EI_INC)
LDFLAGS := $(GTK_LIBS) -L$(ERL_EI_LIB) -lei
PRIV_BIN := ../../priv/bin
INSTALLED_TARGET := $(PRIV_BIN)/gtknode4

# Maps are an optional gtknode4 capability. If libshumate is installed the
# native node advertises the `map` widget; otherwise the rest of ERM still
# builds and gtkgs rejects map creation from the negotiated capabilities.
ifneq ($(strip $(SHUMATE_LIBS)),)
CFLAGS  += $(SHUMATE_CFLAGS) -DHAVE_LIBSHUMATE=1
LDFLAGS += $(SHUMATE_LIBS)
endif

.PHONY: all install clean

# ERM launches priv/bin/gtknode4. Keep that runtime binary in sync whenever the
# native node is rebuilt so a stale executable cannot silently hide a newly
# added protocol capability such as libshumate maps.
all: gtknode4 install

gtknode4: gtknode4.o
	$(CC) gtknode4.o $(LDFLAGS) -o $@

gtknode4.o: gtknode4.c gtknode4.h
	$(CC) $(CFLAGS) -c $< -o $@

install: gtknode4
	mkdir -p $(PRIV_BIN)
	$(INSTALL) -m 0755 gtknode4 $(INSTALLED_TARGET).new
	mv -f $(INSTALLED_TARGET).new $(INSTALLED_TARGET)

clean:
	rm -f gtknode4 gtknode4.o $(INSTALLED_TARGET).new
