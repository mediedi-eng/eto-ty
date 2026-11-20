#include "BodyRenderer.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float x,y,z,nx,ny,nz; } Vertex;
typedef struct { uint32_t a,b,c,material; } Triangle;
typedef struct { float x,y,z,side,nx,ny,nz; } Projected;
typedef struct { float r,g,b,a; } Color;
typedef struct { float z; Color color; uint8_t region; } Sample;

static float clamp(float v) { return fminf(1, fmaxf(0,v)); }
static float smooth(float left, float right, float value) {
    float t = clamp((value-left)/(right-left));
    return t*t*(3-2*t);
}
static float mix(float a, float b, float t) { return a+(b-a)*t; }
static const Color paint[] = {
    {162,149,156,1}, {198,148,119,1}, {81,54,44,1}, {211,198,177,1}, {91,106,88,1},
    {37,33,37,1}, {182,71,72,1}, {154,102,71,1}, {151,83,102,1}, {157,122,134,.37f},
    {187,89,77,1}, {112,126,158,1}, {246,165,113,1}, {128,110,118,.73f}, {198,163,147,.24f}, {185,154,137,.49f}, {168,130,126,.33f}, {89,61,48,1}, {197,158,144,.36f}
};
static int organ(int m) {
    if (m==6 || m==10 || m==11 || m==12) return 1;
    if (m==7) return 2;
    if (m==8) return 3;
    return 0;
}
static int layer(int m) {
    if (m<6 || m==17) return 0;
    if (m==9) return 1;
    if (m>=13) return 2;
    return 3;
}
static Color shade(int m, const Vertex *v, Projected p, int selected) {
    Color c = paint[m];
    float nx=p.nx, ny=p.ny, nz=p.nz;
    if ((m==8 || m==9) && v->x < 0) { nx=-nx; ny=-ny; nz=-nz; }
    float diffuse=fmaxf(0,-.52f*nx+.66f*ny+.54f*nz);
    float fill=fmaxf(0,.86f*nx+.28f*ny+.42f*nz);
    float back=fmaxf(0,.78f*nx+.30f*ny-.55f*nz);
    float rim=powf(clamp(1-fabsf(nz)),2.2f);
    float gloss=powf(fmaxf(0,-.28f*nx+.38f*ny+.882f*nz),m==0?18:28);
    float brightness=.49f+.58f*diffuse+.13f*fill;
    float chest=(v->x-.025f)*(v->x-.025f)/.015f+(v->y-1.22f)*(v->y-1.22f)/.013f;
    float light=selected==1 ? expf(-chest*2.0f) : 0;
    if (m==1) {
        float lip=expf(-((v->y-1.490f)*(v->y-1.490f)/.000025f+v->x*v->x/.00035f))*
                  smooth(.061f,.089f,v->z);
        c.r+=10*lip; c.g-=24*lip; c.b-=10*lip;
    }
    if (m==0) {
        float limb=smooth(.125f,.22f,fabsf(v->x)) * smooth(.75f,1.02f,v->y);
        float window=smooth(.82f,1.025f,v->y)*(1-smooth(1.325f,1.44f,v->y))*(1-limb);
        float skin=.34f+.44f*(1-window);
        c.r=mix(153,211,skin); c.g=mix(141,157,skin); c.b=mix(151,137,skin);
        c.a=mix(.68f,.32f,window)+.44f*rim;
    }
    if (m==2 || m==17) {
        // Fine streaks retain definition across the sculpted hair cap.
        float strand=.5f+.5f*sinf(v->x*1170 + v->z*320 + 4*sinf(v->y*108));
        brightness += .10f*strand;
    }
    c.r=c.r*brightness+rim*45+back*29+gloss*35+light*58;
    c.g=c.g*brightness+rim*38+back*28+gloss*31+light*12;
    c.b=c.b*brightness+rim*53+back*41+gloss*34;
    if (organ(m)==selected) {
        c.r+= (m==12?18:64); c.g+=14+27*diffuse; c.b+=7+7*diffuse;
    }
    if (m==0 || m==1) {
        float warm=clamp((-nx+.15f)*rim);
        float cool=clamp((nx+.15f)*rim);
        c.r+=72*warm+11*cool; c.g+=34*warm+34*cool; c.b+=14*warm+74*cool;
    }
    c.a=clamp(c.a);
    return c;
}
static Color over(Color base, Color top) {
    return (Color){mix(base.r,top.r,top.a),mix(base.g,top.g,top.a),mix(base.b,top.b,top.a),1};
}
static Color blend3(Color a,Color b,Color c,float x,float y,float z) {
    return (Color){a.r*x+b.r*y+c.r*z,a.g*x+b.g*y+c.g*z,a.b*x+b.b*y+c.b*z,a.a*x+b.a*y+c.a*z};
}
static void draw_triangle(Sample *plane, int width, int height, Projected a, Projected b,
                          Projected c, Color ca, Color cb, Color cc, int region) {
    float det=(b.x-a.x)*(c.y-a.y)-(c.x-a.x)*(b.y-a.y);
    if (fabsf(det)<.0001f) return;
    float inv=1/det;
    int x0=fmaxf(0,floorf(fminf(a.x,fminf(b.x,c.x))));
    int x1=fminf(width-1,ceilf(fmaxf(a.x,fmaxf(b.x,c.x))));
    int y0=fmaxf(0,floorf(fminf(a.y,fminf(b.y,c.y))));
    int y1=fminf(height-1,ceilf(fmaxf(a.y,fmaxf(b.y,c.y))));
    for (int y=y0;y<=y1;y++) {
        float fy=y+.5f-a.y;
        float v=((x0+.5f-a.x)*(c.y-a.y)-fy*(c.x-a.x))*inv;
        float w=((b.x-a.x)*fy-(b.y-a.y)*(x0+.5f-a.x))*inv;
        for (int x=x0;x<=x1;x++,v+=(c.y-a.y)*inv,w-=(b.y-a.y)*inv) {
            float u=1-v-w;
            if (u<0 || v<0 || w<0) continue;
            float depth=a.z*u+b.z*v+c.z*w;
            Sample *s=&plane[y*width+x];
            if (s->z>=depth) continue;
            s->z=depth;
            s->color=blend3(ca,cb,cc,u,v,w);
            s->region=(uint8_t)region;
        }
    }
}
static uint8_t byte(float x) { return (uint8_t)fminf(255,fmaxf(0,x)); }

int body_render(const void *mesh, size_t length, uint8_t *rgba, uint8_t *regions,
                int width, int height, float yaw, float zoom, int selected) {
    if (!mesh || !rgba || !regions || length<12 || width<=0 || height<=0 ||
        width>2048 || height>2048 || memcmp(mesh,"ETM1",4)!=0) return 0;
    uint32_t count[2]; memcpy(count,(const uint8_t *)mesh+4,8);
    if (count[0]>150000 || count[1]>150000 ||
        length!=12+(size_t)count[0]*sizeof(Vertex)+(size_t)count[1]*sizeof(Triangle)) return 0;
    const Vertex *verts=(const Vertex *)((const uint8_t *)mesh+12);
    const Triangle *faces=(const Triangle *)(verts+count[0]);
    size_t pixels=(size_t)width*height;
    Sample *planes=calloc(pixels*4,sizeof(Sample));
    Projected *pv=malloc(count[0]*sizeof(Projected));
    Color *colors=malloc(count[0]*sizeof(Color));
    uint8_t *colored=calloc(count[0],1);
    if (!planes || !pv || !colors || !colored) { free(planes); free(pv); free(colors); free(colored); return 0; }
    float cs=cosf(yaw+.28f), sn=sinf(yaw+.28f);
    float scale=fminf(height*.90f/1.695f,width*.83f/.74f)*zoom;
    float focus=selected==1?1.217f:selected==2?1.105f:1.048f;
    float cy=mix(.844f,focus,clamp((zoom-1)/1.1f));
    for (uint32_t i=0;i<count[0];i++) {
        Vertex v=verts[i];
        float x=cs*v.x+sn*v.z, z=-sn*v.x+cs*v.z;
        pv[i]=(Projected){width*.5f+scale*x,height*.487f-scale*(v.y-cy),2+z,x,
                           cs*v.nx+sn*v.nz,v.ny,-sn*v.nx+cs*v.nz};
    }
    for (uint32_t i=0;i<count[1];i++) {
        Triangle t=faces[i]; uint32_t ids[3]={t.a,t.b,t.c};
        if (t.a>=count[0] || t.b>=count[0] || t.c>=count[0] || t.material>=19) continue;
        for (int k=0;k<3;k++) {
            uint32_t j=ids[k];
            if (!colored[j]) { colors[j]=shade(t.material,&verts[j],pv[j],selected); colored[j]=1; }
        }
        draw_triangle(planes+pixels*layer(t.material),width,height,pv[t.a],pv[t.b],pv[t.c],
                      colors[t.a],colors[t.b],colors[t.c],organ(t.material));
    }
    for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
        size_t i=(size_t)y*width+x;
        float dx=(x-width*.49f)/height,dy=(y-height*.38f)/height;
        float halo=expf(-3.8f*dx*dx-3.7f*dy*dy);
        float floorY=height*.487f+scale*cy;
        float fx=(x-width*.5f)/(scale*.335f),fy=(y-floorY)/(scale*.047f);
        float radius=sqrtf(fx*fx+fy*fy);
        float stage=expf(-radius*radius*1.5f), ring=expf(-fabsf(radius-1)*45);
        Color base={9+22*halo+6*stage+12*ring,23+31*halo+11*stage+20*ring,
                    39+34*halo+13*stage+24*ring,1};
        Sample shell=planes[i], lung=planes[pixels+i], bones=planes[2*pixels+i], org=planes[3*pixels+i];
        // Light scattering on the far skin keeps the chest and limbs one continuous volume.
        if (shell.z) {
            Color far=shell.color;
            far.a=.29f;
            far.r*=.91f; far.g*=.96f; far.b*=1.08f;
            base=over(base,far);
        } else {
            org.z=0; org.region=0; lung.z=0; bones.z=0;
        }
        if (org.z) {
            if (lung.z && lung.z<org.z) base=over(base,lung.color);
            if (bones.z && bones.z<org.z) base=over(base,bones.color);
            base=over(base,org.color);
        }
        if (lung.z && lung.z>=org.z) base=over(base,lung.color);
        if (bones.z && bones.z>=org.z) base=over(base,bones.color);
        if (shell.z) {
            base=over(base,shell.color);
            if (selected==1 && shell.color.a<.99f) {
                float hx=(x-width*.5f)/scale - (cs*.029f+sn*.024f);
                float hy=(height*.487f-y)/scale+cy-1.224f;
                float glow=expf(-((hx*hx)/.007f+(hy*hy)/.010f)*1.5f);
                base.r+=38*glow; base.g+=8*glow; base.b+=3*glow;
            }
        }
        regions[i]=org.region;
        rgba[4*i]=byte(base.r); rgba[4*i+1]=byte(base.g); rgba[4*i+2]=byte(base.b); rgba[4*i+3]=255;
    }
    free(colored); free(colors); free(pv); free(planes);
    return 1;
}
