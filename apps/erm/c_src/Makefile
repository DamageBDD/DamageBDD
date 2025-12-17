CC      ?= cc

ERL_ROOT        := $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().' -s init stop)
ERL_EI_INC      := $(ERL_ROOT)/usr/include
ERL_EI_LIB      := $(ERL_ROOT)/usr/lib

CFLAGS  := -O2 -Wall -Wextra \
           $(shell pkg-config --cflags gtk4) \
           -I$(ERL_EI_INC)

LDFLAGS := $(shell pkg-config --libs gtk4) \
           -L$(ERL_EI_LIB) -lei

all: gtknode4

gtknode4: gtknode4.o
	$(CC) gtknode4.o $(LDFLAGS) -o $@

gtknode4.o: gtknode4.c gtknode4.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f gtknode4 gtknode4.o

