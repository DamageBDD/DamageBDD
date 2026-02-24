# Makefile
# Supports:
#   make
#   make sandwich
#   make me a sandwich
#   make me a sandwich OWNER=npub1... NAME=BLT NOTES="extra mayo"

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -pedantic
LDLIBS  ?= -lcrypto

BIN     := sandwich
SRC     := sandwich.c

OWNER   ?= "npub1zmg3gvpasgp3zkgceg62yg8fyhqz9sy3dqt45kkwt60nkctyp9rs9wyppc"
NAME    ?= "BLT"
NOTES   ?= "extra mayo"

.PHONY: all clean init demo me a

all: $(BIN)

# Build the binary (THIS is the real 'sandwich' target)
$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

# Helper: initialize ledger
init: $(BIN)
	./$(BIN) init

# Canonical meme wiring:
# `make me a sandwich` => targets: me, a, sandwich
me: $(BIN)
	@echo "🥪 Minting deterministic sandwich..."
	./$(BIN) init
	./$(BIN) mint --owner "$(OWNER)" --name "$(NAME)" --notes "$(NOTES)"
	@echo "No guessing. Only state recovery."
	@echo "You asked nicely."

a:
	@:

demo: $(BIN)
	./$(BIN) init
	./$(BIN) mint --owner "npub1demo..." --name "BLT" --notes "extra mayo"
	./$(BIN) query --name "BLT"

clean:
	rm -f $(BIN) sandwich.ledger
