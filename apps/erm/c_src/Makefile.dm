CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2
PKG_CONFIG ?= pkg-config
TARGET ?= ../priv/erm_greetd_auth

.PHONY: all clean
all: $(TARGET)

$(TARGET): erm_greetd_auth.c
	mkdir -p $(dir $(TARGET))
	$(CC) $(CFLAGS) $(shell $(PKG_CONFIG) --cflags gtk4) $< -o $@ $(shell $(PKG_CONFIG) --libs gtk4)
	chmod 0755 $@

clean:
	rm -f $(TARGET)
