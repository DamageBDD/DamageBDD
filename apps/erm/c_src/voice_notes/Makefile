CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror
TARGET = ../../priv/bin/erm_voice_notes_audio
all: $(TARGET)
$(TARGET): erm_voice_notes_audio.c
	mkdir -p $(dir $(TARGET))
	$(CC) $(CFLAGS) $< -lm -o $@.new
	mv -f $@.new $@
clean:
	rm -f $(TARGET) $(TARGET).new
.PHONY: all clean
