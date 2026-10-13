CC ?= cc
PKG_CONFIG ?= pkg-config
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags gio-2.0 gio-unix-2.0)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror
LDLIBS += $(shell $(PKG_CONFIG) --libs gio-2.0 gio-unix-2.0)
TARGET = ../../priv/erm_kdeconnect_share
.PHONY: all clean
all: $(TARGET)
$(TARGET): erm_kdeconnect_share.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)
clean:
	rm -f $(TARGET)
