BPF_CLANG ?= clang
BPF_LLVM_STRIP ?= llvm-strip
LIBBPF_CFLAGS ?= $(shell pkg-config --cflags libbpf 2>/dev/null)
LIBBPF_LDLIBS ?= $(shell pkg-config --libs libbpf 2>/dev/null)

BPF_OBJ = proc_bw.bpf.o
SKEL_H = ../priv/proc_bw.skel.h

all: $(BPF_OBJ) $(SKEL_H) ../priv/proc_bw

$(BPF_OBJ): proc_bw.bpf.c vmlinux.h
	$(BPF_CLANG) -g -O2 -target bpf -D__TARGET_ARCH_x86 \
		-c $< -o $@
	$(BPF_LLVM_STRIP) -g $@

$(SKEL_H): $(BPF_OBJ)
	bpftool gen skeleton $< > $@

../priv/proc_bw: ../priv/proc_bw.c $(SKEL_H)
	$(CC) -O2 -g -o $@ ../priv/proc_bw.c $(LIBBPF_CFLAGS) $(LIBBPF_LDLIBS)

clean:
	rm -f $(BPF_OBJ) $(SKEL_H) ../priv/proc_bw
