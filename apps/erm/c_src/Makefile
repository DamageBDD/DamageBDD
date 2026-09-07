ERL ?= erl
CC ?= cc

ERL_ROOT := $(shell $(ERL) -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERL_INCLUDE := $(ERL_ROOT)/usr/include
PKG_CONFIG ?= pkg-config

CFLAGS ?= -O2 -g
CFLAGS += -fPIC -Wall -Wextra -Wpedantic -I$(ERL_INCLUDE) \
          $(shell $(PKG_CONFIG) --cflags xcb xcb-screensaver xcb-dpms)
LDLIBS := $(shell $(PKG_CONFIG) --libs xcb xcb-screensaver xcb-dpms)

TARGET := ../priv/erm_dpms_nif.so
SRC := erm_dpms_nif.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	mkdir -p ../priv
	$(CC) $(CFLAGS) -shared -o $@ $< $(LDLIBS)

clean:
	rm -f $(TARGET)
