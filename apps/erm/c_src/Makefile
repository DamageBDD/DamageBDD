# Build OHF-Voice/piper1-gpl/libpiper first (see docs/erm_tts.md).
PIPER_PREFIX ?= /opt/piper
CXX ?= c++
CXXFLAGS ?= -O2 -Wall -Wextra
TARGET ?= ../priv/erm_tts_port
all: $(TARGET)
$(TARGET): erm_tts_port.cpp
	mkdir -p $(dir $(TARGET))
	$(CXX) $(CXXFLAGS) -std=c++17 -pthread -I$(PIPER_PREFIX)/include $< -L$(PIPER_PREFIX)/lib -Wl,--disable-new-dtags,-rpath,$(PIPER_PREFIX)/lib -lpiper -lonnxruntime -o $@
.PHONY: all
