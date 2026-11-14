/*
 * mingo-fbsplash: graphical Mingo boot screen drawn straight on /dev/fb0.
 *
 * Soft colour background, the "mingo" logo, a rounded gradient progress bar with a moving
 * shine, the current boot stage as text, and a fade-out at the end. Works at any resolution
 * (everything is scaled from a 1080p design) and follows resolution changes mid-boot.
 *
 *   mingo-fbsplash --check     exit 0 if a usable framebuffer exists
 *   mingo-fbsplash [continue]  run until /run/mingo.booted exists
 *
 * State shared with the text splash / the next stage: /run/mingo.stage (text),
 * /run/mingo.splash (elapsed tenths of a second, so a restarted splash continues).
 * Images: /usr/share/mingo/splash/NAME.rgba (u32 width, u32 height, then RGBA bytes).
 */
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define DIR "/usr/share/mingo/splash/"

typedef struct { int w, h; uint8_t *px; } Img;

static int fd = -1;
static uint8_t *fbm;
static size_t fblen;
static struct fb_var_screeninfo vi;
static struct fb_fix_screeninfo fi;
static int W, H;
static float S;
static uint32_t *bg, *buf;          /* 0x00RRGGBB */
static Img logo, tagline, stage;
static char stage_key[32];
static volatile sig_atomic_t quit_now;

static void on_term(int s) { quit_now = s == SIGUSR1 ? 2 : 1; }   /* USR1: hand-over, keep the picture */

static Img load(const char *path)
{
    Img im = {0, 0, NULL};
    FILE *f = fopen(path, "rb");
    uint32_t hdr[2];
    if (!f) return im;
    if (fread(hdr, 4, 2, f) == 2 && hdr[0] > 0 && hdr[1] > 0 && hdr[0] < 8192 && hdr[1] < 8192) {
        size_t n = (size_t)hdr[0] * hdr[1] * 4;
        im.px = malloc(n);
        if (im.px && fread(im.px, 1, n, f) == n) { im.w = hdr[0]; im.h = hdr[1]; }
        else { free(im.px); im.px = NULL; }
    }
    fclose(f);
    return im;
}

static void fb_close(void)
{
    if (fd >= 0) { munmap(fbm, fblen); close(fd); fd = -1; }
}

static int fb_open(void)
{
    fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) return -1;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vi) || ioctl(fd, FBIOGET_FSCREENINFO, &fi) ||
        (vi.bits_per_pixel != 32 && vi.bits_per_pixel != 16) || vi.xres < 320 || vi.yres < 200) {
        close(fd); fd = -1; return -1;
    }
    fblen = fi.smem_len;
    fbm = mmap(NULL, fblen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fbm == MAP_FAILED) { close(fd); fd = -1; return -1; }
    /* make the framebuffer the visible scan-out: DRM drivers (simpledrm, i915, bochs...) only
       show the fbdev buffer after a mode set, which the deferred console never does */
    vi.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
    vi.xoffset = vi.yoffset = 0;
    ioctl(fd, FBIOPUT_VSCREENINFO, &vi);
    ioctl(fd, FBIOGET_VSCREENINFO, &vi);
    ioctl(fd, FBIOPAN_DISPLAY, &vi);
    ioctl(fd, FBIOBLANK, FB_BLANK_UNBLANK);
    W = vi.xres; H = vi.yres;
    S = H / 1080.0f;
    if (W / 1920.0f < S) S = W / 1920.0f;
    return 0;
}

static void console_mode(int graphics)
{
    int t = open("/dev/tty0", O_RDWR);
    if (t < 0) t = open("/dev/console", O_RDWR);
    if (t >= 0) { ioctl(t, KDSETMODE, graphics ? KD_GRAPHICS : KD_TEXT); close(t); }
}

/* ---- drawing on the RGB buffer ------------------------------------------------------------ */
static inline uint32_t rgb(int r, int g, int b)
{
    r = r < 0 ? 0 : r > 255 ? 255 : r; g = g < 0 ? 0 : g > 255 ? 255 : g; b = b < 0 ? 0 : b > 255 ? 255 : b;
    return (uint32_t)r << 16 | (uint32_t)g << 8 | (uint32_t)b;
}

static inline void blend(uint32_t *p, int r, int g, int b, int a) /* a: 0..255 */
{
    if (a <= 0) return;
    if (a >= 255) { *p = rgb(r, g, b); return; }
    int pr = *p >> 16 & 255, pg = *p >> 8 & 255, pb = *p & 255;
    *p = rgb(pr + (r - pr) * a / 255, pg + (g - pg) * a / 255, pb + (b - pb) * a / 255);
}

/* dark background with blurred colour blobs, like the Aurora wallpaper but dimmer */
static void render_background(void)
{
    static const float blobs[][6] = {           /* x, y (0..1), radius (of height), r, g, b */
        {0.10f, 0.12f, 0.70f, 29, 78, 216}, {0.30f, 0.90f, 0.75f, 91, 43, 191},
        {0.85f, 0.25f, 0.65f, 14, 116, 144}, {0.70f, 1.00f, 0.55f, 190, 58, 124},
        {1.00f, 0.95f, 0.25f, 245, 158, 11},
    };
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            float r = 8, g = 11, b = 24;
            for (unsigned k = 0; k < sizeof blobs / sizeof blobs[0]; k++) {
                float dx = (x - blobs[k][0] * W) / (blobs[k][2] * H);
                float dy = (y - blobs[k][1] * H) / (blobs[k][2] * H);
                float d = dx * dx + dy * dy;
                if (d < 1) {
                    float w = (1 - d) * (1 - d) * 0.55f;
                    r += (blobs[k][3] - r) * w; g += (blobs[k][4] - g) * w; b += (blobs[k][5] - b) * w;
                }
            }
            /* vignette */
            float vx = (x - W / 2.0f) / W, vy = (y - H / 2.0f) / H;
            float v = 1 - (vx * vx + vy * vy) * 0.9f;
            bg[y * W + x] = rgb((int)(r * v), (int)(g * v), (int)(b * v));
        }
}

/* draw an RGBA image centred at (cx, top), scaled by sc, bilinear, with extra alpha */
static void draw_image(uint32_t *dst, const Img *im, int cx, int top, float sc, int alpha)
{
    if (!im->px) return;
    int dw = (int)(im->w * sc), dh = (int)(im->h * sc), x0 = cx - dw / 2;
    for (int y = 0; y < dh; y++) {
        int ty = top + y;
        if (ty < 0 || ty >= H) continue;
        float sy = (y + 0.5f) / sc - 0.5f;
        int y1 = (int)sy; float fy = sy - y1;
        if (y1 < 0) { y1 = 0; fy = 0; }
        int y2 = y1 + 1 < im->h ? y1 + 1 : y1;
        for (int x = 0; x < dw; x++) {
            int tx = x0 + x;
            if (tx < 0 || tx >= W) continue;
            float sx = (x + 0.5f) / sc - 0.5f;
            int x1 = (int)sx; float fx = sx - x1;
            if (x1 < 0) { x1 = 0; fx = 0; }
            int x2 = x1 + 1 < im->w ? x1 + 1 : x1;
            const uint8_t *a = im->px + (y1 * im->w + x1) * 4, *b = im->px + (y1 * im->w + x2) * 4;
            const uint8_t *c = im->px + (y2 * im->w + x1) * 4, *d = im->px + (y2 * im->w + x2) * 4;
            float v[4];
            for (int k = 0; k < 4; k++)
                v[k] = (a[k] * (1 - fx) + b[k] * fx) * (1 - fy) + (c[k] * (1 - fx) + d[k] * fx) * fy;
            blend(&dst[ty * W + tx], (int)v[0], (int)v[1], (int)v[2], (int)(v[3] * alpha / 255));
        }
    }
}

/* rounded progress bar with a blue -> violet fill and a moving shine */
static void draw_bar(uint32_t *dst, float pct, float t)
{
    int bw = (int)(420 * S), bh = (int)(8 * S) < 5 ? 5 : (int)(8 * S);
    int bx = W / 2 - bw / 2, by = (int)(H * 0.66f);
    float rad = bh / 2.0f, fillw = bw * pct / 100.0f;
    float shine = fmodf(t * 0.6f, 1.6f) - 0.3f;    /* sweeps from left to right */
    for (int y = 0; y < bh; y++)
        for (int x = 0; x < bw; x++) {
            /* anti-aliased pill shape */
            float cx = x + 0.5f, cy = y + 0.5f, dx = 0;
            if (cx < rad) dx = rad - cx; else if (cx > bw - rad) dx = cx - (bw - rad);
            float dy = cy - rad, d = sqrtf(dx * dx + dy * dy);
            float cover = rad + 0.5f - d; if (cover <= 0) continue; if (cover > 1) cover = 1;
            uint32_t *p = &dst[(by + y) * W + bx + x];
            if (cx <= fillw) {
                float k = (float)x / bw;
                int r = (int)(59 + (168 - 59) * k), g = (int)(130 + (85 - 130) * k), b = (int)(246 + (247 - 246) * k);
                float s = fabsf(k - shine); s = s < 0.12f ? (0.12f - s) / 0.12f : 0;
                r += (int)((255 - r) * s * 0.55f); g += (int)((255 - g) * s * 0.55f); b += (int)((255 - b) * s * 0.55f);
                blend(p, r, g, b, (int)(255 * cover));
            } else {
                blend(p, 255, 255, 255, (int)(38 * cover));
            }
        }
}

static void present(int y0, int y1, int fade) /* fade 0..256 */
{
    if (y0 < 0) y0 = 0;
    if (y1 > H) y1 = H;
    for (int y = y0; y < y1; y++) {
        uint8_t *row = fbm + (size_t)(y + vi.yoffset) * fi.line_length + vi.xoffset * (vi.bits_per_pixel / 8);
        for (int x = 0; x < W; x++) {
            uint32_t c = buf[y * W + x];
            unsigned r = (c >> 16 & 255) * fade >> 8, g = (c >> 8 & 255) * fade >> 8, b = (c & 255) * fade >> 8;
            if (vi.bits_per_pixel == 32) {
                uint32_t v = (r >> (8 - vi.red.length)) << vi.red.offset | (g >> (8 - vi.green.length)) << vi.green.offset |
                             (b >> (8 - vi.blue.length)) << vi.blue.offset;
                ((uint32_t *)row)[x] = v;
            } else {
                ((uint16_t *)row)[x] = (uint16_t)((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3));
            }
        }
    }
}

static int exists(const char *p) { return access(p, F_OK) == 0; }

static void read_stage(void)
{
    char line[128] = "", key[32] = "starting", path[160];
    FILE *f = fopen("/run/mingo.stage", "r");
    if (f) { if (fgets(line, sizeof line, f)) sscanf(line, "%31s", key); fclose(f); }
    if (!strcmp(key, stage_key)) return;
    snprintf(stage_key, sizeof stage_key, "%s", key);
    free(stage.px);
    snprintf(path, sizeof path, DIR "stage-%s.rgba", key);
    stage = load(path);
}

static int setup(void)
{
    free(bg); free(buf);
    bg = malloc((size_t)W * H * 4);
    buf = malloc((size_t)W * H * 4);
    if (!bg || !buf) return -1;
    render_background();
    draw_image(bg, &logo, W / 2, (int)(H * 0.66f - 300 * S), S, 255);
    draw_image(bg, &tagline, W / 2, (int)(H * 0.66f - 300 * S + logo.h * S + 6 * S), S, 200);
    memcpy(buf, bg, (size_t)W * H * 4);
    present(0, H, 256);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "--check")) {
        int ok = fb_open() == 0;
        fb_close();
        return ok ? 0 : 1;
    }
    int cont = argc > 1 && !strcmp(argv[1], "continue");
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGUSR1, on_term);

    logo = load(DIR "logo.rgba");
    tagline = load(DIR "tagline.rgba");
    if (fb_open() != 0 || setup() != 0) return 1;
    console_mode(1);

    long tenths = 0;
    if (cont) {
        FILE *f = fopen("/run/mingo.splash", "r");
        if (f) { if (fscanf(f, "%ld", &tenths) != 1) tenths = 0; fclose(f); }
    }
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    double base = tenths / 10.0, done_at = -1;
    float shown = cont ? (float)(95.0 - 95.0 * 2.0 / (base + 2.0)) : 0;   /* no jump back when continuing */
    int frame = 0, gone = 0;

    for (;;) {
        if (quit_now) { if (quit_now == 1) console_mode(0); return 0; }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double t = base + (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;

        /* follow resolution changes (graphics driver loading mid-boot) */
        if (++frame % 15 == 0) {
            struct fb_var_screeninfo nv;
            struct fb_fix_screeninfo nf;
            int fresh = open("/dev/fb0", O_RDONLY);      /* a new driver may have replaced fb0 */
            int changed = fresh < 0 || ioctl(fresh, FBIOGET_FSCREENINFO, &nf) ||
                          strncmp(nf.id, fi.id, sizeof nf.id) || nf.smem_start != fi.smem_start;
            if (fresh >= 0) close(fresh);
            if (changed || fd < 0 || ioctl(fd, FBIOGET_VSCREENINFO, &nv) || nv.xres != vi.xres || nv.yres != vi.yres) {
                fb_close();
                if (fb_open() != 0 || setup() != 0) {
                    if (++gone > 40) { console_mode(0); return 1; }
                    usleep(250000);
                    continue;
                }
                gone = 0;
                console_mode(1);
            }
            FILE *f = fopen("/run/mingo.splash", "w");
            if (f) { fprintf(f, "%ld\n", (long)(t * 10)); fclose(f); }
        }
        if (fd < 0) { usleep(100000); continue; }

        int booted = exists("/run/mingo.booted") && t > 2.0;
        if (booted && done_at < 0) done_at = t;
        float target = booted ? 100.0f : (float)(95.0 - 95.0 * 2.0 / (t + 2.0));
        shown += (target - shown) * (booted ? 0.25f : 0.12f);

        read_stage();
        int top = (int)(H * 0.66f - 20 * S), bot = (int)(H * 0.66f + 90 * S);
        for (int y = top; y < bot && y < H; y++) memcpy(&buf[y * W], &bg[y * W], (size_t)W * 4);
        draw_bar(buf, shown, (float)t);
        draw_image(buf, &stage, W / 2, (int)(H * 0.66f + 34 * S), S, 190);

        int fade = 256;
        if (done_at >= 0 && shown > 99.0f) {
            double k = (t - done_at - 0.35) / 0.45;     /* fade to black */
            if (k > 0) fade = k >= 1 ? 0 : (int)(256 * (1 - k));
        }
        if (fade < 256) present(0, H, fade); else present(top, bot, 256);
        if (fade == 0) break;
        usleep(33000);
    }
    console_mode(0);
    return 0;
}
