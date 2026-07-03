CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-deprecated-declarations -std=c11
OPENSSL_CFLAGS := $(shell $(PKG_CONFIG) --cflags openssl 2>/dev/null)
OPENSSL_LIBS := $(shell $(PKG_CONFIG) --libs openssl 2>/dev/null || echo -lcrypto)
BIN := damage-nsecbunker-crypto-c
SRC := src/main.c

.PHONY: all clean smoke install

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) $(OPENSSL_CFLAGS) -o $@ $< $(OPENSSL_LIBS)

smoke: $(BIN)
	printf '%s\n' '{"op":"health"}' | ./$(BIN)

clean:
	rm -f $(BIN) *.o /tmp/damage-nsecbunker-c-test.vault

install: $(BIN)
	install -m 0755 $(BIN) /opt/damage/bin/$(BIN)
