# Makefile for sandwich
# Yes, this supports:
#     make me a sandwich

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -pedantic
LDLIBS  ?= -lcrypto

BIN     := sandwich
SRC     := sandwich.c

OWNER   ?= npub1sudo...
NAME    ?= DefaultSandwich
NOTES   ?= made_by_make

.PHONY: all clean init demo me a sandwich

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

init: $(BIN)
	./$(BIN) init

# --- The magic ---
# "make me a sandwich" resolves to:
#   make me
#   make a
#   make sandwich

me: sandwich
	@echo "You asked nicely."

a:
	@true

sandwich: $(BIN)
	@echo "🥪 Minting deterministic sandwich..."
	./$(BIN) init
	./$(BIN) mint --owner "$(OWNER)" --name "$(NAME)" --notes "$(NOTES)"
	@echo "No guessing. Only state recovery."

demo: $(BIN)
	./$(BIN) init
	./$(BIN) mint --owner "npub1demo..." --name "BLT" --notes "extra mayo"
	./$(BIN) query --name "BLT"

clean:
	rm -f $(BIN) sandwich.ledger
