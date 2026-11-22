#include <stdio.h>
#include <stdlib.h>
#include "tamalib.h"
#include "cpu.h"
extern int cpu_kmask_fix;
static timestamp_t T;
static void* m(u32_t s){return malloc(s);} static void f(void*p){free(p);}
static void halt(void){} static bool_t le(log_level_t l){return 0;} static void lg(log_level_t l,char*b,...){}
static void su(timestamp_t ts){T=ts;} static timestamp_t gt(void){return T;}
static void us(void){} static unsigned lcdh=0; static void slm(u8_t x,u8_t y,bool_t v){lcdh=lcdh*31+x*64+y*2+v;}
static void sli(u8_t i,bool_t v){lcdh=lcdh*31+1000+i*2+v;} static void sf(u32_t f){lcdh=lcdh*31+f;} static void pf(bool_t e){lcdh=lcdh*31+7+e;}
static int hd(void){return 0;}
static hal_t hal={m,f,halt,le,lg,su,gt,us,slm,sli,sf,pf,hd};
int v1_link_in(u32_t t){return 0;} void v1_link_out(int l,u32_t t){}
static u12_t prog[8192];
int main(int argc,char**argv){
  FILE*fp=fopen(argv[1],"rb"); unsigned char buf[16384]; int n=fread(buf,1,16384,fp); fclose(fp);
  for(int i=0;i<n/2;i++) prog[i]=((buf[2*i]<<8)|buf[2*i+1])&0xFFF;
  long steps=atol(argv[2]);
  tamalib_register_hal(&hal); cpu_kmask_fix=1; tamalib_init(prog,0,1000000);
  state_t*s=cpu_get_state();
  for(long k=1;k<=steps;k++){
    if(k%5000==1) thw_set_button((k/5000)%4,((k/5000)/4)%2?BTN_STATE_PRESSED:BTN_STATE_RELEASED);
    if(cpu_step()){printf("fault %ld\n",k);break;}
    if(k%1000==0){ unsigned h=0; for(int i=0;i<0x300;i++) h=h*131+GET_RAM_MEMORY(s->memory,i); for(int i=0xE00;i<0xE66;i++) h=h*131+GET_DISP1_MEMORY(s->memory,i); for(int i=0xE80;i<0xEE6;i++) h=h*131+GET_DISP2_MEMORY(s->memory,i); for(int i=0xF00;i<0xF80;i++) h=h*131+GET_IO_MEMORY(s->memory,i);
      printf("%ld pc=%x x=%x y=%x a=%x b=%x sp=%x f=%x np=%x t=%u hl=%d mem=%08x lcd=%08x\n",k,*s->pc,*s->x,*s->y,*s->a,*s->b,*s->sp,*s->flags,*s->np,*s->tick_counter,*s->cpu_halted,h,lcdh);}
  }
}
