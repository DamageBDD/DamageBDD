/* Fixed +/-0.25 PCM input for the real worker's capture/control protocol test. */
#include <unistd.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[argc-2], "--file-type") || strcmp(argv[argc-1], "raw")) return 2;
    unsigned char pcm[1024];
    for (int i = 0; i < 512; ++i) { pcm[2*i] = 0; pcm[2*i+1] = (i&1) ? 0xe0 : 0x20; }
    for (;;) {
        if (write(1, pcm, sizeof pcm) != sizeof pcm) return 0;
        usleep(32000);
    }
}
