// Deterministic exit/failure/cancellation boundary; never produces sound.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void){const char*p=getenv("PHRASE_LAB_PLAYER_PID");
 if(p){FILE*f=fopen(p,"w");if(!f)return 3;fprintf(f,"%ld",(long)getpid());fclose(f);for(;;)pause();}
 return getenv("PHRASE_LAB_PLAYER_FAIL")?1:0;}
