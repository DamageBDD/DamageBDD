/* First-party Linux PCM transport. Kernel UAPI + libc/libm; no audio SDK.
 * Wire: Erlang {packet,4}. H=source format, A=16k mono PCM16LE,
 * D=completed, E=error. Input S=stop. No VAD: the user chooses the segment. */
#define _POSIX_C_SOURCE 200809L
#include <sound/asound.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <limits.h>

static int exact(int fd, void *data, size_t n, int writing) {
  unsigned char *p=data;
  while(n) {
    ssize_t k=writing ? write(fd,p,n) : read(fd,p,n);
    if(k<0 && errno==EINTR) continue;
    if(k<=0) return -1;
    p+=k; n-=(size_t)k;
  }
  return 0;
}
static int packet(const void *p, uint32_t n) {
  unsigned char h[4]={(unsigned char)(n>>24),(unsigned char)(n>>16),
                      (unsigned char)(n>>8),(unsigned char)n};
  return exact(1,h,4,1) || exact(1,(void*)p,n,1);
}
static int failure(const char *stage) {
  char b[512];
  snprintf(b,sizeof b,"E%s: %s",stage,strerror(errno));
  (void)packet(b,(uint32_t)strlen(b));
  return 1;
}
static int stopped(int timeout) {
  struct pollfd p={0,POLLIN|POLLHUP,0};
  int n;
  do n=poll(&p,1,timeout); while(n<0 && errno==EINTR);
  if(n<0 || p.revents&(POLLHUP|POLLERR|POLLNVAL)) return 1;
  if(n>0 && (p.revents&POLLIN)) {
    unsigned char b[5];
    if(exact(0,b,sizeof b,0)<0) return 1;
    return !(b[0]||b[1]||b[2]||b[3]!=1||b[4]!='S') ? 1 : -1;
  }
  return 0;
}
static struct snd_interval *interval(struct snd_pcm_hw_params *p,int which) {
  return &p->intervals[which-SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
}
static void set_interval(struct snd_pcm_hw_params *p,int which,unsigned v) {
  struct snd_interval *i=interval(p,which);
  i->min=i->max=v; i->integer=1; i->openmin=i->openmax=i->empty=0;
}
static void set_mask(struct snd_pcm_hw_params *p,int which,unsigned v) {
  struct snd_mask *m=&p->masks[which-SNDRV_PCM_HW_PARAM_FIRST_MASK];
  memset(m,0,sizeof *m); m->bits[v/32]|=1U<<(v%32);
}
static int setup(int fd,unsigned rate,unsigned channels,unsigned period) {
  struct snd_pcm_hw_params p;
  struct snd_pcm_sw_params sw;
  memset(&p,0,sizeof p);
  for(unsigned k=0;k<sizeof p.masks/sizeof p.masks[0];k++)
    for(unsigned j=0;j<sizeof p.masks[0].bits/sizeof p.masks[0].bits[0];j++)
      p.masks[k].bits[j]=UINT_MAX;
  for(unsigned k=0;k<sizeof p.intervals/sizeof p.intervals[0];k++) {
    p.intervals[k].min=0; p.intervals[k].max=UINT_MAX;
  }
  set_mask(&p,SNDRV_PCM_HW_PARAM_ACCESS,SNDRV_PCM_ACCESS_RW_INTERLEAVED);
  set_mask(&p,SNDRV_PCM_HW_PARAM_FORMAT,SNDRV_PCM_FORMAT_S16_LE);
  set_mask(&p,SNDRV_PCM_HW_PARAM_SUBFORMAT,SNDRV_PCM_SUBFORMAT_STD);
  set_interval(&p,SNDRV_PCM_HW_PARAM_SAMPLE_BITS,16);
  set_interval(&p,SNDRV_PCM_HW_PARAM_FRAME_BITS,16*channels);
  set_interval(&p,SNDRV_PCM_HW_PARAM_CHANNELS,channels);
  set_interval(&p,SNDRV_PCM_HW_PARAM_RATE,rate);
  set_interval(&p,SNDRV_PCM_HW_PARAM_PERIOD_SIZE,period);
  set_interval(&p,SNDRV_PCM_HW_PARAM_PERIODS,4);
  set_interval(&p,SNDRV_PCM_HW_PARAM_BUFFER_SIZE,period*4);
  p.rmask=~0U;
  if(ioctl(fd,SNDRV_PCM_IOCTL_HW_PARAMS,&p)<0) return -1;
  memset(&sw,0,sizeof sw);
  sw.tstamp_mode=SNDRV_PCM_TSTAMP_NONE;
  sw.period_step=1; sw.avail_min=period;
  sw.start_threshold=1; sw.stop_threshold=period*4;
  sw.boundary=period*4;
  while(sw.boundary <= (ULONG_MAX/2)-(period*4)) sw.boundary*=2;
  if(ioctl(fd,SNDRV_PCM_IOCTL_SW_PARAMS,&sw)<0) return -1;
  return ioctl(fd,SNDRV_PCM_IOCTL_PREPARE);
}
static int device(const char *path,unsigned *rate,unsigned *channels,int capture) {
  /* Explicit physical device only. No shell, ALSA plugin names or privileged
   * access escalation; ordinary user/session device ACLs apply. */
  size_t n=strlen(path);
  if(strncmp(path,"/dev/snd/pcm",12) || n<14 ||
      path[n-1]!=(capture?'c':'p')) {errno=EINVAL;return -1;}
  unsigned rates[]={16000,48000};
  for(unsigned r=0;r<2;r++) for(unsigned c=1;c<=2;c++) {
    unsigned periods[]={rates[r]/50,256,512,1024};
    for(unsigned p=0;p<4;p++) {
      int fd=open(path,O_RDWR|O_NONBLOCK|O_CLOEXEC);
      if(fd<0) return -1;
      struct stat st;
      if(fstat(fd,&st)<0 || !S_ISCHR(st.st_mode)) {close(fd);errno=ENODEV;return -1;}
      if(setup(fd,rates[r],c,periods[p])==0) {*rate=rates[r];*channels=c;return fd;}
      close(fd);
    }
  }
  errno=ENOTSUP;return -1;
}
static int16_t s16(const unsigned char *p) {
  return (int16_t)((unsigned)p[0]|((unsigned)p[1]<<8));
}
static void put16(unsigned char *p,int v) {
  if(v>32767)v=32767;
  if(v< -32768)v=-32768;
  p[0]=(unsigned char)v;p[1]=(unsigned char)(v>>8);
}
/* 63-tap windowed lowpass before 48 -> 16 kHz decimation. The zero-initialised
 * delay line adds a documented 31/48000 second startup transient. */
struct filter {double taps[63],hist[63];unsigned pos,phase;};
static void filter_init(struct filter *f) {
  double sum=0;memset(f,0,sizeof *f);
  for(int k=0;k<63;k++) {
    double x=k-31;
    double sinc=x==0 ? 0.30 : sin(3.141592653589793*0.30*x)/(3.141592653589793*x);
    f->taps[k]=sinc*(0.54-0.46*cos(2*3.141592653589793*k/62));
    sum+=f->taps[k];
  }
  for(unsigned k=0;k<63;k++)f->taps[k]/=sum;
}
static int capture(const char *path,unsigned max_ms,int from_file) {
  unsigned rate=16000,channels=1;
  int fd=from_file?open(path,O_RDONLY|O_CLOEXEC):device(path,&rate,&channels,1);
  if(fd<0)return failure("open capture device (check path, ownership and device availability)");
  unsigned char hello[6]={'H',(unsigned char)(rate>>24),(unsigned char)(rate>>16),
                          (unsigned char)(rate>>8),(unsigned char)rate,(unsigned char)channels};
  if(packet(hello,sizeof hello)) {close(fd);return 1;}
  if(!from_file && ioctl(fd,SNDRV_PCM_IOCTL_START)<0) {close(fd);return failure("start capture");}
  uint64_t count=0,limit=(uint64_t)max_ms*16;
  unsigned char input[4096],output[4097];
  struct filter f;filter_init(&f);
  int reason=0;
  while(count<limit) {
    int stop=stopped(from_file?20:0);
    if(stop) {reason=stop<0?3:0;break;}
    ssize_t frames;
    if(from_file) {
      ssize_t bytes=read(fd,input,640);
      if(bytes<0 && errno==EINTR)continue;
      if(bytes<0){close(fd);return failure("read fixture PCM");}
      if(bytes%2){errno=EINVAL;close(fd);return failure("unaligned fixture PCM");}
      frames=bytes/2;
    } else {
      struct pollfd p={fd,POLLIN,0};
      int ready=poll(&p,1,50);
      if(ready<0 && errno==EINTR)continue;
      if(ready<0){close(fd);return failure("poll capture");}
      if(!ready)continue;
      if(p.revents&(POLLHUP|POLLNVAL)){errno=ENODEV;close(fd);return failure("capture disconnected");}
      struct snd_xferi x;memset(&x,0,sizeof x);
      x.buf=input;x.frames=sizeof(input)/(channels*2);
      if(ioctl(fd,SNDRV_PCM_IOCTL_READI_FRAMES,&x)<0) {
        if(errno==EAGAIN||errno==EINTR)continue;
        close(fd);return failure("read PCM (overrun/discontinuity ends this take)");
      }
      frames=x.result;
      if(frames<0){errno=(int)-frames;close(fd);return failure("capture PCM result");}
    }
    if(frames==0){reason=2;break;}
    unsigned out=1;output[0]='A';
    for(ssize_t k=0;k<frames && count<limit;k++) {
      int value=s16(input+k*channels*2);
      if(channels==2)value=(value+s16(input+k*4+2))/2;
      if(rate==48000) {
        f.hist[f.pos]=value;f.pos=(f.pos+1)%63;
        if(++f.phase<3)continue;
        f.phase=0;double v=0;
        for(unsigned j=0;j<63;j++)v+=f.taps[j]*f.hist[(f.pos+62-j)%63];
        value=(int)lrint(v);
      }
      put16(output+out,value);out+=2;count++;
    }
    if(out>1 && packet(output,out)){close(fd);return 1;}
  }
  if(count>=limit)reason=1;
  if(!from_file)(void)ioctl(fd,SNDRV_PCM_IOCTL_DROP);
  close(fd);
  unsigned char done[2]={'D',(unsigned char)reason};
  return packet(done,sizeof done)?1:0;
}
static uint32_t u32(const unsigned char *p) {
  return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static int play(const char *path,const char *output,int check_only) {
  int wav=open(path,O_RDONLY|O_CLOEXEC);unsigned char h[44];
  if(wav<0)return failure("open note");
  struct stat st;
  if(fstat(wav,&st)<0 || !S_ISREG(st.st_mode) || exact(wav,h,44,0) ||
     memcmp(h,"RIFF",4)||memcmp(h+8,"WAVEfmt ",8)||u32(h+16)!=16||
     s16(h+20)!=1||s16(h+22)!=1||u32(h+24)!=16000||
     u32(h+28)!=32000||s16(h+32)!=2||s16(h+34)!=16||memcmp(h+36,"data",4)||
     u32(h+40)%2 || u32(h+40)>19200000U || st.st_size!=(off_t)(44+u32(h+40)) ||
     u32(h+4)!=36+u32(h+40)) {
    close(wav);errno=EINVAL;return failure("invalid note WAV");
  }
  unsigned rate=16000,channels=1;
  int fd=check_only?-1:device(output,&rate,&channels,0);
  if(!check_only && fd<0){close(wav);return failure("open playback device");}
  unsigned char input[640],pcm[3840];uint32_t remain=u32(h+40);
  while(remain) {
    if(stopped(check_only?1:0))break;
    unsigned n=remain<sizeof input?remain:sizeof input;
    if(exact(wav,input,n,0)){if(fd>=0)close(fd);close(wav);return failure("read note PCM");}
    remain-=n;
    if(check_only)continue;
    unsigned frames=0;
    for(unsigned k=0;k<n;k+=2)for(unsigned repeat=0;repeat<rate/16000;repeat++) {
      for(unsigned c=0;c<channels;c++) {
        pcm[(frames*channels+c)*2]=input[k];
        pcm[(frames*channels+c)*2+1]=input[k+1];
      }
      frames++;
    }
    unsigned sent=0;
    while(sent<frames) {
      if(stopped(0))goto finished;
      struct pollfd p={fd,POLLOUT,0};
      int ready=poll(&p,1,50);
      if(ready<0&&errno==EINTR)continue;
      if(ready<0){close(fd);close(wav);return failure("poll playback");}
      if(!ready)continue;
      struct snd_xferi x;memset(&x,0,sizeof x);x.buf=pcm+sent*channels*2;x.frames=frames-sent;
      if(ioctl(fd,SNDRV_PCM_IOCTL_WRITEI_FRAMES,&x)<0) {
        if(errno==EAGAIN||errno==EINTR)continue;
        close(fd);close(wav);return failure("write playback PCM");
      }
      if(x.result<0){errno=(int)-x.result;close(fd);close(wav);return failure("playback PCM result");}
      sent+=(unsigned)x.result;
    }
  }
  /* Wait for hardware consumption, while Stop/Escape can still interrupt. */
  if(fd>=0)for(;;) {
    snd_pcm_sframes_t delay=0;
    if(ioctl(fd,SNDRV_PCM_IOCTL_DELAY,&delay)<0 || delay<=0 || stopped(10))break;
  }
finished:
  if(fd>=0){(void)ioctl(fd,SNDRV_PCM_IOCTL_DROP);close(fd);}
  close(wav);return packet("D",1)?1:0;
}
int main(int argc,char **argv) {
  if(argc==4 && (!strcmp(argv[1],"capture")||!strcmp(argv[1],"capture-file"))) {
    char *end=NULL;unsigned long ms=strtoul(argv[3],&end,10);
    if(!end||*end||ms<100||ms>600000){errno=EINVAL;return failure("invalid duration");}
    return capture(argv[2],(unsigned)ms,!strcmp(argv[1],"capture-file"));
  }
  if(argc==4 && (!strcmp(argv[1],"play")||!strcmp(argv[1],"check-wav")))
    return play(argv[2],argv[3],!strcmp(argv[1],"check-wav"));
  errno=EINVAL;return failure("usage: capture DEVICE MAX_MS | play WAV DEVICE");
}
