CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2

.PHONY: all clean
all: damage-fc-agent

damage-fc-agent: damage-fc-agent.c
	$(CC) $(CFLAGS) -std=c11 -static $< -o $@

clean:
	rm -f damage-fc-agent
