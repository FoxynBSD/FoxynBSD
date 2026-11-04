/*-
 * Copyright (c) 2026 The FoxynBSD Project
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * The "xterm" terminal emulator of syscons: what terminfo's xterm entry
 * (TERM=xterm, xterm-256color) sends, beside the "sc" emulator (cons25),
 * which stays as it is.  A virtual console gets it with vidcontrol -T
 * xterm, or every console with the SC_DFLT_TERM="xterm" kernel option.
 *
 * Over what scterm-sc.c does, it has the parts that line editors and
 * full-screen programs rely on:
 *	- ESC [ ? private modes: cursor keys (1), origin (6), autowrap (7),
 *	  cursor visible (25), the alternate screen (47, 1047, 1048, 1049:
 *	  the main screen waits in scp->alt, which syscons allocates, since
 *	  the emulator runs under its spin lock and cannot); the others (bracketed paste 2004, mouse, focus, ...) are read
 *	  and ignored instead of shown;
 *	- the column (G) and repeat (b) commands, scroll regions (r),
 *	  insert mode (4 h), xterm's deferred wrap at the last column;
 *	- reports: cursor position (6 n), status (5 n), device attributes
 *	  (c), queued with sc_respond();
 *	- SGR with dim, italic, invisible, bright (90-97, 100-107) and 256
 *	  and direct colours, mapped to the nearest of the adapter's 16;
 *	- the DEC line drawing set (ESC ( 0), drawn with the CP437 glyphs
 *	  of the console font;
 *	- OSC, DCS, APC, PM and SOS strings, skipped up to their end;
 *	- xterm's function and cursor keys (te_fkeystr).
 * There is no UTF-8: like the "sc" emulator, it shows bytes.
 */

#include "opt_syscons.h"

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/consio.h>
#include <sys/kbio.h>
#include <sys/thread2.h>

#include <machine/pc/display.h>

#include "syscons.h"
#include "sctermvar.h"

#ifndef SC_DUMB_TERMINAL

#define MAX_ESC_PAR	16

/* parser states */
#define ST_GROUND	0
#define ST_ESC		1	/* seen ESC */
#define ST_ESC_INTER	2	/* ESC and intermediates: ( ) * + # space */
#define ST_CSI		3	/* seen ESC [ */
#define ST_CSI_IGNORE	4	/* a CSI to skip up to its final byte */
#define ST_STRING	5	/* OSC, DCS, ...: skip up to BEL or ST */
#define ST_STRING_ESC	6	/* ESC inside a string */

typedef struct {
	u_short		fg;
	u_short		bg;
} color_t;

typedef struct {
	int		xpos;
	int		ypos;
	int		attr_mask;
	color_t		cur_color;
	int		charset;	/* G0: 0 ASCII, 1 line drawing */
	int		origin;
	int		valid;
} cursor_save_t;

typedef struct {
	int		flags;
#define XT_BUSY		(1 << 0)
	int		state;
	int		num_param;
	int		param[MAX_ESC_PAR];
	int		have_digit;	/* the current parameter has digits */
	u_char		prefix;		/* CSI private marker: ? > = < */
	u_char		inter;		/* the last intermediate byte */

	/* modes */
	int		wrapnext;	/* the last column was written */
	int		autowrap;	/* DECAWM */
	int		origin;		/* DECOM */
	int		insert;		/* IRM */
	int		appcursor;	/* DECCKM */
	int		top;		/* scroll region, first line */
	int		bottom;		/* scroll region, line after last */
	int		region_ysize;	/* screen height of the region */
	int		charset[2];	/* G0, G1: 0 ASCII, 1 line drawing */
	int		gl;		/* 0: G0, 1: G1 (SO/SI) */
	int		last_char;	/* for REP */

	cursor_save_t	saved;		/* DECSC, CSI s, 1048 */
	cursor_save_t	alt_saved;	/* 1049 */
	int		alt_active;	/* the main screen is in scp->alt */

	int		attr_mask;
#define NORMAL_ATTR	0x00
#define BLINK_ATTR	0x01
#define BOLD_ATTR	0x02
#define UNDERLINE_ATTR	0x04
#define REVERSE_ATTR	0x08
#define FG_CHANGED	0x10
#define BG_CHANGED	0x20
#define INVISIBLE_ATTR	0x40
	int		cur_attr;
	color_t		cur_color;
	color_t		std_color;
	color_t		rev_color;
	color_t		dflt_std_color;
	color_t		dflt_rev_color;
} term_stat;

static sc_term_init_t	xterm_init;
static sc_term_term_t	xterm_term;
static sc_term_puts_t	xterm_puts;
static sc_term_ioctl_t	xterm_ioctl;
static sc_term_reset_t	xterm_reset;
static sc_term_default_attr_t	xterm_default_attr;
static sc_term_clear_t	xterm_clear;
static sc_term_notify_t	xterm_notify;
static sc_term_input_t	xterm_input;
static sc_term_fkeystr_t	xterm_fkeystr;

static sc_term_sw_t sc_term_xterm = {
	{ NULL, NULL },
	"xterm",				/* emulator name */
	"xterm terminal",			/* description */
	"*",					/* matching renderer */
	sizeof(term_stat),			/* softc size */
	0,
	xterm_init,
	xterm_term,
	xterm_puts,
	xterm_ioctl,
	xterm_reset,
	xterm_default_attr,
	xterm_clear,
	xterm_notify,
	xterm_input,
	xterm_fkeystr,
};

SCTERM_MODULE(xterm, sc_term_xterm);

static term_stat	reserved_term_stat;

/* ANSI colour number to adapter colour */
static const u_char ansi_col[16] = {
	FG_BLACK,     FG_RED,          FG_GREEN,      FG_BROWN,
	FG_BLUE,      FG_MAGENTA,      FG_CYAN,       FG_LIGHTGREY,
	FG_DARKGREY,  FG_LIGHTRED,     FG_LIGHTGREEN, FG_YELLOW,
	FG_LIGHTBLUE, FG_LIGHTMAGENTA, FG_LIGHTCYAN,  FG_WHITE
};

/* the 16 ANSI colours as a VGA shows them, to match 256 and RGB colours */
static const u_char ansi_rgb[16][3] = {
	{   0,   0,   0 }, { 170,   0,   0 }, {   0, 170,   0 },
	{ 170,  85,   0 }, {   0,   0, 170 }, { 170,   0, 170 },
	{   0, 170, 170 }, { 170, 170, 170 }, {  85,  85,  85 },
	{ 255,  85,  85 }, {  85, 255,  85 }, { 255, 255,  85 },
	{  85,  85, 255 }, { 255,  85, 255 }, {  85, 255, 255 },
	{ 255, 255, 255 }
};

/* DEC special graphics, 0x5f-0x7e, in the CP437 console font */
static const u_char dec_graphics[32] = {
	0x20,		/* _ blank */
	0x04,		/* ` diamond */
	0xb1,		/* a checker board */
	0xf9,		/* b HT */
	0xf9,		/* c FF */
	0xf9,		/* d CR */
	0xf9,		/* e LF */
	0xf8,		/* f degree */
	0xf1,		/* g plus/minus */
	0xb0,		/* h board */
	0xf9,		/* i lantern */
	0xd9,		/* j lower right corner */
	0xbf,		/* k upper right corner */
	0xda,		/* l upper left corner */
	0xc0,		/* m lower left corner */
	0xc5,		/* n crossing lines */
	0xc4,		/* o scan line 1 */
	0xc4,		/* p scan line 3 */
	0xc4,		/* q horizontal line */
	0xc4,		/* r scan line 7 */
	0x5f,		/* s scan line 9 */
	0xc3,		/* t left tee */
	0xb4,		/* u right tee */
	0xc1,		/* v bottom tee */
	0xc2,		/* w top tee */
	0xb3,		/* x vertical line */
	0xf3,		/* y less or equal */
	0xf2,		/* z greater or equal */
	0xe3,		/* { pi */
	0xd8,		/* | not equal */
	0x9c,		/* } pound */
	0xfa,		/* ~ centered dot */
};

static void	xterm_reset_state(scr_stat *scp, term_stat *tcp);
static int	mask2attr(term_stat *tcp);
static void	xterm_exec(scr_stat *scp, term_stat *tcp, u_char c);

static int
xterm_init(scr_stat *scp, void **softc, int code)
{
	term_stat *tcp;

	if (*softc == NULL) {
		if (reserved_term_stat.flags & XT_BUSY)
			return EINVAL;
		*softc = &reserved_term_stat;
	}
	tcp = *softc;

	switch (code) {
	case SC_TE_COLD_INIT:
		bzero(tcp, sizeof(*tcp));
		tcp->flags = XT_BUSY;
		tcp->dflt_std_color.fg = SC_NORM_ATTR & 0x0f;
		tcp->dflt_std_color.bg = (SC_NORM_ATTR >> 4) & 0x0f;
		tcp->dflt_rev_color.fg = SC_NORM_REV_ATTR & 0x0f;
		tcp->dflt_rev_color.bg = (SC_NORM_REV_ATTR >> 4) & 0x0f;
		tcp->std_color = tcp->dflt_std_color;
		tcp->rev_color = tcp->dflt_rev_color;
		xterm_reset_state(scp, tcp);
		++sc_term_xterm.te_refcount;
		break;

	case SC_TE_WARM_INIT:
		/* also after a mode change: the screen size may differ */
		xterm_reset_state(scp, tcp);
		break;
	}

	return 0;
}

static int
xterm_term(scr_stat *scp, void **softc)
{
	if (*softc == &reserved_term_stat) {
		*softc = NULL;
		bzero(&reserved_term_stat, sizeof(reserved_term_stat));
	}
	--sc_term_xterm.te_refcount;
	return 0;
}

/*
 * Modes, attributes and the parser back to their power-on values.  The
 * screen is left alone; a main screen kept in scp->alt is dropped (a
 * mode change made a new, empty scp->alt).
 */
static void
xterm_reset_state(scr_stat *scp, term_stat *tcp)
{
	tcp->state = ST_GROUND;
	tcp->num_param = 0;
	tcp->wrapnext = 0;
	tcp->autowrap = 1;
	tcp->origin = 0;
	tcp->insert = 0;
	tcp->appcursor = 0;
	tcp->top = 0;
	tcp->bottom = scp->ysize;
	tcp->region_ysize = scp->ysize;
	tcp->charset[0] = tcp->charset[1] = 0;
	tcp->gl = 0;
	tcp->last_char = -1;
	tcp->saved.valid = 0;
	tcp->alt_saved.valid = 0;
	tcp->alt_active = 0;
	tcp->attr_mask = NORMAL_ATTR;
	tcp->cur_color = tcp->std_color;
	tcp->cur_attr = mask2attr(tcp);
}

/*
 * The scroll region, valid for the current screen size: the region set
 * for another height (vidcontrol changed the mode) is the whole screen.
 */
static void
region(scr_stat *scp, term_stat *tcp, int *top, int *bottom)
{
	if (tcp->region_ysize != scp->ysize || tcp->bottom > scp->ysize ||
	    tcp->top >= tcp->bottom) {
		tcp->top = 0;
		tcp->bottom = scp->ysize;
		tcp->region_ysize = scp->ysize;
	}
	*top = tcp->top;
	*bottom = tcp->bottom;
}

static int
blank_char(scr_stat *scp)
{
	return scp->sc->scr_map[0x20];
}

/*
 * Erase with the current background, as xterm does (bce), but without
 * the reverse, underline and blink of the current attributes.
 */
static int
erase_attr(term_stat *tcp)
{
	return (tcp->cur_color.fg | (tcp->cur_color.bg << 4)) << 8;
}

/* lines [top, bottom) up by n, blank lines at the bottom */
static void
scroll_up(scr_stat *scp, term_stat *tcp, int top, int bottom, int n)
{
	int i;

	if (n > bottom - top)
		n = bottom - top;
	if (n <= 0)
		return;
#ifndef SC_NO_HISTORY
	/* lines off the top of the whole main screen go to the history */
	if (top == 0 && bottom == scp->ysize && !tcp->alt_active &&
	    scp->history != NULL) {
		for (i = 0; i < n; i++)
			sc_hist_save_one_line(scp, i * scp->xsize);
	}
#endif
	sc_remove_cutmarking(scp);
	sc_vtb_move(&scp->vtb, (top + n) * scp->xsize, top * scp->xsize,
		    (bottom - top - n) * scp->xsize);
	sc_vtb_erase(&scp->vtb, (bottom - n) * scp->xsize, n * scp->xsize,
		     blank_char(scp), erase_attr(tcp));
	mark_for_update(scp, top * scp->xsize);
	mark_for_update(scp, bottom * scp->xsize - 1);
}

/* lines [top, bottom) down by n, blank lines at the top */
static void
scroll_down(scr_stat *scp, term_stat *tcp, int top, int bottom, int n)
{
	if (n > bottom - top)
		n = bottom - top;
	if (n <= 0)
		return;
	sc_remove_cutmarking(scp);
	sc_vtb_move(&scp->vtb, top * scp->xsize, (top + n) * scp->xsize,
		    (bottom - top - n) * scp->xsize);
	sc_vtb_erase(&scp->vtb, top * scp->xsize, n * scp->xsize,
		     blank_char(scp), erase_attr(tcp));
	mark_for_update(scp, top * scp->xsize);
	mark_for_update(scp, bottom * scp->xsize - 1);
}

static void
move_to(scr_stat *scp, term_stat *tcp, int x, int y)
{
	tcp->wrapnext = 0;
	sc_move_cursor(scp, x, y);
}

/* line feed: down a line, scrolling the region at its last line */
static void
index_down(scr_stat *scp, term_stat *tcp)
{
	int top, bottom;

	region(scp, tcp, &top, &bottom);
	tcp->wrapnext = 0;
	if (scp->ypos == bottom - 1)
		scroll_up(scp, tcp, top, bottom, 1);
	else if (scp->ypos < scp->ysize - 1)
		sc_move_cursor(scp, scp->xpos, scp->ypos + 1);
}

/* reverse index: up a line, scrolling the region at its first line */
static void
index_up(scr_stat *scp, term_stat *tcp)
{
	int top, bottom;

	region(scp, tcp, &top, &bottom);
	tcp->wrapnext = 0;
	if (scp->ypos == top)
		scroll_down(scp, tcp, top, bottom, 1);
	else if (scp->ypos > 0)
		sc_move_cursor(scp, scp->xpos, scp->ypos - 1);
}

static void
cursor_save(scr_stat *scp, term_stat *tcp, cursor_save_t *s)
{
	s->xpos = scp->xpos;
	s->ypos = scp->ypos;
	s->attr_mask = tcp->attr_mask;
	s->cur_color = tcp->cur_color;
	s->charset = tcp->charset[0];
	s->origin = tcp->origin;
	s->valid = 1;
}

static void
cursor_restore(scr_stat *scp, term_stat *tcp, cursor_save_t *s)
{
	if (!s->valid) {
		move_to(scp, tcp, 0, 0);
		return;
	}
	tcp->attr_mask = s->attr_mask;
	tcp->cur_color = s->cur_color;
	tcp->cur_attr = mask2attr(tcp);
	tcp->charset[0] = s->charset;
	tcp->origin = s->origin;
	move_to(scp, tcp, s->xpos, s->ypos);
}

static void
cursor_visible(scr_stat *scp, int on)
{
	sc_softc_t *sc = scp->sc;
	int current = (scp == sc->cur_scp && !ISGRAPHSC(scp));

	if (on && !(scp->status & CURSOR_ENABLED)) {
		scp->status |= CURSOR_ENABLED;
		if (current)
			sc_draw_cursor_image(scp);
	} else if (!on && (scp->status & CURSOR_ENABLED)) {
		if (current)
			sc_remove_cursor_image(scp);
		scp->status &= ~CURSOR_ENABLED;
	}
}

/*
 * The buffer syscons allocates beside the screen's, to keep the main
 * screen in, if it is there and has the screen's size.
 */
static int
alt_usable(scr_stat *scp)
{
	return ((scp->alt.vtb_flags & VTB_VALID) &&
		scp->alt.vtb_buffer != NULL &&
		scp->alt.vtb_cols == scp->xsize &&
		scp->alt.vtb_rows == scp->ysize);
}

/* to the alternate screen: keep the main one and clear */
static void
alt_enter(scr_stat *scp, term_stat *tcp)
{
	int size = scp->xsize * scp->ysize;

	if (tcp->alt_active)
		return;
	if (alt_usable(scp))
		sc_vtb_copy(&scp->vtb, 0, &scp->alt, 0, size);
	tcp->alt_active = 1;
	sc_remove_cutmarking(scp);
	sc_vtb_erase(&scp->vtb, 0, size, blank_char(scp), erase_attr(tcp));
	mark_all(scp);
}

/* back to the main screen, as it was (cleared without the buffer) */
static void
alt_leave(scr_stat *scp, term_stat *tcp)
{
	int size = scp->xsize * scp->ysize;

	if (!tcp->alt_active)
		return;
	tcp->alt_active = 0;
	sc_remove_cutmarking(scp);
	if (alt_usable(scp))
		sc_vtb_copy(&scp->alt, 0, &scp->vtb, 0, size);
	else
		sc_vtb_erase(&scp->vtb, 0, size, blank_char(scp),
			     erase_attr(tcp));
	mark_all(scp);
}

static void
respond(scr_stat *scp, const char *fmt, int a, int b)
{
	char buf[32];
	int len;

	len = ksnprintf(buf, sizeof(buf), fmt, a, b);
	if (len > 0 && len < (int)sizeof(buf))
		sc_respond(scp, (u_char *)buf, len);
}

/* the nearest of the 16 colours to an RGB colour; bg: of the first 8 */
static int
rgb2ansi(int r, int g, int b, int bg)
{
	int i, best, d, dbest, dr, dg, db;

	best = 0;
	dbest = 3 * 256 * 256;	/* past any distance */
	for (i = 0; i < (bg ? 8 : 16); i++) {
		dr = r - ansi_rgb[i][0];
		dg = g - ansi_rgb[i][1];
		db = b - ansi_rgb[i][2];
		d = dr * dr + dg * dg + db * db;
		if (d < dbest) {
			dbest = d;
			best = i;
		}
	}
	return best;
}

/* a colour of the 256-colour palette as one of the 16 */
static int
c256toansi(int n, int bg)
{
	static const u_char level[6] = { 0, 95, 135, 175, 215, 255 };
	int v;

	if (n < 0 || n > 255)
		return 7;
	if (n < 16)
		return (bg ? n & 7 : n);
	if (n < 232) {
		n -= 16;
		return rgb2ansi(level[n / 36], level[(n / 6) % 6],
				level[n % 6], bg);
	}
	v = 8 + (n - 232) * 10;
	return rgb2ansi(v, v, v, bg);
}

static void
set_fg(term_stat *tcp, int ansi)
{
	tcp->attr_mask |= FG_CHANGED;
	tcp->cur_color.fg = ansi_col[ansi & 0x0f];
}

static void
set_bg(term_stat *tcp, int ansi)
{
	tcp->attr_mask |= BG_CHANGED;
	tcp->cur_color.bg = ansi_col[ansi & 0x07];
}

/*
 * 38 and 48: ;5;n or ;2;r;g;b, from parameter *ip on; *ip ends at the
 * last parameter used.
 */
static void
sgr_extended(term_stat *tcp, int *ip, int bg)
{
	int i = *ip;
	int *p = tcp->param;
	int n = tcp->num_param;
	int c;

	if (i + 1 >= n)
		return;
	if (p[i + 1] == 5 && i + 2 < n) {
		c = c256toansi(p[i + 2], bg);
		*ip = i + 2;
	} else if (p[i + 1] == 2 && i + 4 < n) {
		c = rgb2ansi(p[i + 2], p[i + 3], p[i + 4], bg);
		*ip = i + 4;
	} else {
		*ip = n;
		return;
	}
	if (bg)
		set_bg(tcp, c);
	else
		set_fg(tcp, c);
}

static void
sgr(term_stat *tcp)
{
	int i, n;

	if (tcp->num_param == 0) {
		tcp->num_param = 1;
		tcp->param[0] = 0;
	}
	for (i = 0; i < tcp->num_param; i++) {
		switch (n = tcp->param[i]) {
		case 0:
			tcp->attr_mask = NORMAL_ATTR;
			tcp->cur_color = tcp->std_color;
			break;
		case 1:
			tcp->attr_mask |= BOLD_ATTR;
			break;
		case 2:		/* dim: no lower intensity, not bold */
			tcp->attr_mask &= ~BOLD_ATTR;
			break;
		case 3:		/* italic: no italic font */
			break;
		case 4:
			tcp->attr_mask |= UNDERLINE_ATTR;
			break;
		case 5:
		case 6:
			tcp->attr_mask |= BLINK_ATTR;
			break;
		case 7:
			tcp->attr_mask |= REVERSE_ATTR;
			break;
		case 8:
			tcp->attr_mask |= INVISIBLE_ATTR;
			break;
		case 21:	/* double underline */
			tcp->attr_mask |= UNDERLINE_ATTR;
			break;
		case 22:
			tcp->attr_mask &= ~BOLD_ATTR;
			break;
		case 23:
			break;
		case 24:
			tcp->attr_mask &= ~UNDERLINE_ATTR;
			break;
		case 25:
			tcp->attr_mask &= ~BLINK_ATTR;
			break;
		case 27:
			tcp->attr_mask &= ~REVERSE_ATTR;
			break;
		case 28:
			tcp->attr_mask &= ~INVISIBLE_ATTR;
			break;
		case 30: case 31: case 32: case 33:
		case 34: case 35: case 36: case 37:
			set_fg(tcp, n - 30);
			break;
		case 38:
			sgr_extended(tcp, &i, 0);
			break;
		case 39:
			tcp->attr_mask &= ~FG_CHANGED;
			tcp->cur_color.fg = tcp->std_color.fg;
			break;
		case 40: case 41: case 42: case 43:
		case 44: case 45: case 46: case 47:
			set_bg(tcp, n - 40);
			break;
		case 48:
			sgr_extended(tcp, &i, 1);
			break;
		case 49:
			tcp->attr_mask &= ~BG_CHANGED;
			tcp->cur_color.bg = tcp->std_color.bg;
			break;
		case 90: case 91: case 92: case 93:
		case 94: case 95: case 96: case 97:
			set_fg(tcp, n - 90 + 8);
			break;
		case 100: case 101: case 102: case 103:
		case 104: case 105: case 106: case 107:
			/* the adapter's bright backgrounds are its blink */
			set_bg(tcp, n - 100);
			break;
		}
	}
	tcp->cur_attr = mask2attr(tcp);
}

/* ESC [ ? n h / l */
static void
private_mode(scr_stat *scp, term_stat *tcp, int set)
{
	int i;

	for (i = 0; i < tcp->num_param; i++) {
		switch (tcp->param[i]) {
		case 1:		/* DECCKM: application cursor keys */
			tcp->appcursor = set;
			break;
		case 6:		/* DECOM: origin mode */
			tcp->origin = set;
			if (set) {
				int top, bottom;

				region(scp, tcp, &top, &bottom);
				move_to(scp, tcp, 0, top);
			} else {
				move_to(scp, tcp, 0, 0);
			}
			break;
		case 7:		/* DECAWM: autowrap */
			tcp->autowrap = set;
			if (!set)
				tcp->wrapnext = 0;
			break;
		case 25:	/* DECTCEM: cursor visible */
			cursor_visible(scp, set);
			break;
		case 47:
		case 1047:
			if (set)
				alt_enter(scp, tcp);
			else
				alt_leave(scp, tcp);
			break;
		case 1048:
			if (set)
				cursor_save(scp, tcp, &tcp->saved);
			else
				cursor_restore(scp, tcp, &tcp->saved);
			break;
		case 1049:
			if (set) {
				cursor_save(scp, tcp, &tcp->alt_saved);
				alt_enter(scp, tcp);
			} else {
				alt_leave(scp, tcp);
				if (tcp->alt_saved.valid)
					cursor_restore(scp, tcp,
						       &tcp->alt_saved);
			}
			break;
		default:
			/*
			 * 2004 bracketed paste, 1000-1006 mouse, 1004
			 * focus, 12 blink, 1034 meta, 2026 synchronized
			 * output, ...: nothing to do on this console.
			 */
			break;
		}
	}
}

/* ESC [ n h / l */
static void
ansi_mode(term_stat *tcp, int set)
{
	int i;

	for (i = 0; i < tcp->num_param; i++) {
		if (tcp->param[i] == 4)		/* IRM: insert mode */
			tcp->insert = set;
	}
}

/* a parameter, with def for a missing or zero one */
static int
par(term_stat *tcp, int i, int def)
{
	if (i >= tcp->num_param || tcp->param[i] == 0)
		return def;
	return tcp->param[i];
}

static void
print_char(scr_stat *scp, term_stat *tcp, u_char c)
{
	int glyph;

	if (tcp->wrapnext) {
		tcp->wrapnext = 0;
		if (tcp->autowrap) {
			sc_move_cursor(scp, 0, scp->ypos);
			index_down(scp, tcp);
		}
	}
	if (tcp->insert)
		sc_term_ins_char(scp, 1, blank_char(scp), erase_attr(tcp));
	if (tcp->charset[tcp->gl] && c >= 0x5f && c <= 0x7e)
		glyph = dec_graphics[c - 0x5f];
	else
		glyph = scp->sc->scr_map[c];
	sc_vtb_putc(&scp->vtb, scp->cursor_pos, glyph, tcp->cur_attr);
	mark_for_update(scp, scp->cursor_pos);
	tcp->last_char = c;
	if (scp->xpos < scp->xsize - 1) {
		scp->xpos++;
		scp->cursor_pos++;
	} else if (tcp->autowrap) {
		tcp->wrapnext = 1;
	}
}

/* C0 controls, also inside an escape sequence, as xterm does */
static void
control(scr_stat *scp, term_stat *tcp, u_char c)
{
	switch (c) {
	case 0x07:	/* BEL */
		sc_bell(scp, scp->bell_pitch, scp->bell_duration);
		break;
	case 0x08:	/* BS */
		if (scp->xpos > 0)
			move_to(scp, tcp, scp->xpos - 1, scp->ypos);
		else
			tcp->wrapnext = 0;
		break;
	case 0x09:	/* HT: tab stops every 8 columns */
		move_to(scp, tcp, imin((scp->xpos & ~7) + 8, scp->xsize - 1),
			scp->ypos);
		break;
	case 0x0a:	/* LF, VT, FF */
	case 0x0b:
	case 0x0c:
		index_down(scp, tcp);
		break;
	case 0x0d:	/* CR */
		move_to(scp, tcp, 0, scp->ypos);
		break;
	case 0x0e:	/* SO: G1 */
		tcp->gl = 1;
		break;
	case 0x0f:	/* SI: G0 */
		tcp->gl = 0;
		break;
	}
}

/* the final byte of ESC [ ... */
static void
csi(scr_stat *scp, term_stat *tcp, u_char c)
{
	sc_softc_t *sc = scp->sc;
	int top, bottom, n, x, y;

	region(scp, tcp, &top, &bottom);

	if (tcp->prefix == '?') {
		switch (c) {
		case 'h':
			private_mode(scp, tcp, 1);
			break;
		case 'l':
			private_mode(scp, tcp, 0);
			break;
		case 'J':	/* DECSED */
		case 'K':	/* DECSEL */
			tcp->prefix = 0;
			csi(scp, tcp, c);
			break;
		}
		return;
	}
	if (tcp->prefix != 0)	/* > = <: secondary DA, key modifiers */
		return;
	if (tcp->inter != 0) {
		/* ! p: soft reset; space q: cursor style, ... */
		if (tcp->inter == '!' && c == 'p') {
			xterm_reset_state(scp, tcp);
			cursor_visible(scp, 1);
		}
		return;
	}

	switch (c) {
	case '@':	/* ICH */
		tcp->wrapnext = 0;
		sc_term_ins_char(scp, par(tcp, 0, 1), blank_char(scp),
				 erase_attr(tcp));
		break;
	case 'A':	/* CUU */
		n = par(tcp, 0, 1);
		y = scp->ypos - n;
		if (scp->ypos >= top && y < top)
			y = top;
		move_to(scp, tcp, scp->xpos, y);
		break;
	case 'B':	/* CUD */
	case 'e':	/* VPR */
		n = par(tcp, 0, 1);
		y = scp->ypos + n;
		if (scp->ypos < bottom && y >= bottom)
			y = bottom - 1;
		move_to(scp, tcp, scp->xpos, y);
		break;
	case 'C':	/* CUF */
	case 'a':	/* HPR */
		move_to(scp, tcp, scp->xpos + par(tcp, 0, 1), scp->ypos);
		break;
	case 'D':	/* CUB */
		move_to(scp, tcp, scp->xpos - par(tcp, 0, 1), scp->ypos);
		break;
	case 'E':	/* CNL */
		move_to(scp, tcp, 0, imin(scp->ypos + par(tcp, 0, 1),
					  bottom - 1));
		break;
	case 'F':	/* CPL */
		move_to(scp, tcp, 0, imax(scp->ypos - par(tcp, 0, 1), top));
		break;
	case 'G':	/* CHA */
	case '`':	/* HPA */
		move_to(scp, tcp, par(tcp, 0, 1) - 1, scp->ypos);
		break;
	case 'H':	/* CUP */
	case 'f':	/* HVP */
		y = par(tcp, 0, 1) - 1;
		x = par(tcp, 1, 1) - 1;
		if (tcp->origin)
			y = imin(y + top, bottom - 1);
		move_to(scp, tcp, x, y);
		break;
	case 'I':	/* CHT */
		for (n = par(tcp, 0, 1); n > 0; n--)
			control(scp, tcp, 0x09);
		break;
	case 'J':	/* ED */
		tcp->wrapnext = 0;
		n = par(tcp, 0, 0);
		if (n == 3)	/* the scrollback; the screen stays */
			break;
		sc_term_clr_eos(scp, n, blank_char(scp), erase_attr(tcp));
		break;
	case 'K':	/* EL */
		tcp->wrapnext = 0;
		sc_term_clr_eol(scp, par(tcp, 0, 0), blank_char(scp),
				erase_attr(tcp));
		break;
	case 'L':	/* IL */
		if (scp->ypos >= top && scp->ypos < bottom) {
			scroll_down(scp, tcp, scp->ypos, bottom,
				    par(tcp, 0, 1));
			move_to(scp, tcp, 0, scp->ypos);
		}
		break;
	case 'M':	/* DL */
		if (scp->ypos >= top && scp->ypos < bottom) {
			scroll_up(scp, tcp, scp->ypos, bottom,
				  par(tcp, 0, 1));
			move_to(scp, tcp, 0, scp->ypos);
		}
		break;
	case 'P':	/* DCH */
		tcp->wrapnext = 0;
		sc_term_del_char(scp, par(tcp, 0, 1), blank_char(scp),
				 erase_attr(tcp));
		break;
	case 'S':	/* SU */
		scroll_up(scp, tcp, top, bottom, par(tcp, 0, 1));
		break;
	case 'T':	/* SD */
		if (tcp->num_param <= 1)	/* not mouse tracking */
			scroll_down(scp, tcp, top, bottom, par(tcp, 0, 1));
		break;
	case 'X':	/* ECH */
		tcp->wrapnext = 0;
		n = imin(par(tcp, 0, 1), scp->xsize - scp->xpos);
		sc_vtb_erase(&scp->vtb, scp->cursor_pos, n, blank_char(scp),
			     erase_attr(tcp));
		mark_for_update(scp, scp->cursor_pos);
		mark_for_update(scp, scp->cursor_pos + n - 1);
		break;
	case 'Z':	/* CBT */
		tcp->wrapnext = 0;
		sc_term_backtab(scp, par(tcp, 0, 1));
		break;
	case 'b':	/* REP */
		if (tcp->last_char >= 0) {
			for (n = imin(par(tcp, 0, 1),
				      scp->xsize * scp->ysize); n > 0; n--)
				print_char(scp, tcp, tcp->last_char);
		}
		break;
	case 'c':	/* DA: a VT100 with advanced video */
		if (par(tcp, 0, 0) == 0)
			respond(scp, "\033[?1;2c", 0, 0);
		break;
	case 'd':	/* VPA */
		y = par(tcp, 0, 1) - 1;
		if (tcp->origin)
			y = imin(y + top, bottom - 1);
		move_to(scp, tcp, scp->xpos, y);
		break;
	case 'g':	/* TBC: the tab stops are fixed */
		break;
	case 'h':
		ansi_mode(tcp, 1);
		break;
	case 'l':
		ansi_mode(tcp, 0);
		break;
	case 'm':
		sgr(tcp);
		break;
	case 'n':	/* DSR */
		switch (par(tcp, 0, 0)) {
		case 5:
			respond(scp, "\033[0n", 0, 0);
			break;
		case 6:
			y = scp->ypos;
			if (tcp->origin)
				y -= top;
			respond(scp, "\033[%d;%dR", y + 1, scp->xpos + 1);
			break;
		}
		break;
	case 'r':	/* DECSTBM */
		top = par(tcp, 0, 1) - 1;
		bottom = par(tcp, 1, scp->ysize);
		if (bottom > scp->ysize)
			bottom = scp->ysize;
		if (top < bottom - 1) {
			tcp->top = top;
			tcp->bottom = bottom;
			tcp->region_ysize = scp->ysize;
			move_to(scp, tcp, 0, tcp->origin ? top : 0);
		}
		break;
	case 's':	/* SCOSC */
		cursor_save(scp, tcp, &tcp->saved);
		break;
	case 'u':	/* SCORC */
		cursor_restore(scp, tcp, &tcp->saved);
		break;
	case 't':	/* window manipulation: there is no window */
		break;
	case 'z':	/* switch to virtual console n, as the sc emulator */
		if (tcp->num_param == 1)
			sc_switch_scr(sc, tcp->param[0]);
		break;
	}
}

/* the byte after ESC, or after ESC and an intermediate */
static void
esc(scr_stat *scp, term_stat *tcp, u_char c)
{
	if (tcp->inter != 0) {
		switch (tcp->inter) {
		case '(':	/* G0 */
		case ')':	/* G1 */
			tcp->charset[tcp->inter == ')'] = (c == '0');
			break;
		}
		return;
	}
	switch (c) {
	case '7':	/* DECSC */
		cursor_save(scp, tcp, &tcp->saved);
		break;
	case '8':	/* DECRC */
		cursor_restore(scp, tcp, &tcp->saved);
		break;
	case 'D':	/* IND */
		index_down(scp, tcp);
		break;
	case 'E':	/* NEL */
		move_to(scp, tcp, 0, scp->ypos);
		index_down(scp, tcp);
		break;
	case 'M':	/* RI */
		index_up(scp, tcp);
		break;
	case 'c':	/* RIS */
		tcp->std_color = tcp->dflt_std_color;
		tcp->rev_color = tcp->dflt_rev_color;
		alt_leave(scp, tcp);
		xterm_reset_state(scp, tcp);
		cursor_visible(scp, 1);
		sc_clear_screen(scp);
		break;
	case 'H':	/* HTS: the tab stops are fixed */
	case '=':	/* DECKPAM */
	case '>':	/* DECKPNM */
	default:
		break;
	}
}

static void
csi_param(term_stat *tcp, u_char c)
{
	if (c >= '0' && c <= '9') {
		if (tcp->num_param == 0)
			tcp->num_param = 1;
		if (tcp->num_param <= MAX_ESC_PAR) {
			int *p = &tcp->param[tcp->num_param - 1];

			if (*p < 10000)
				*p = *p * 10 + (c - '0');
		}
		tcp->have_digit = 1;
	} else {	/* ';' or ':' */
		if (tcp->num_param == 0)
			tcp->num_param = 1;
		if (tcp->num_param < MAX_ESC_PAR)
			tcp->param[tcp->num_param++] = 0;
		else
			tcp->num_param = MAX_ESC_PAR + 1;	/* too many */
		tcp->have_digit = 0;
	}
}

/* one byte of output */
static void
xterm_exec(scr_stat *scp, term_stat *tcp, u_char c)
{
	int i;

	/* CAN and SUB end any sequence; ESC starts a new one */
	if (c == 0x18 || c == 0x1a) {
		tcp->state = ST_GROUND;
		return;
	}
	if (c == 0x1b) {
		if (tcp->state == ST_STRING) {
			tcp->state = ST_STRING_ESC;
			return;
		}
		tcp->state = ST_ESC;
		tcp->inter = 0;
		return;
	}

	switch (tcp->state) {
	case ST_GROUND:
		if (c < 0x20)
			control(scp, tcp, c);
		else if (c != 0x7f)
			print_char(scp, tcp, c);
		return;

	case ST_STRING_ESC:
		/* ESC \ ends the string; anything else stays in it */
		tcp->state = (c == '\\') ? ST_GROUND : ST_STRING;
		return;

	case ST_STRING:
		if (c == 0x07)
			tcp->state = ST_GROUND;
		return;
	}

	if (c < 0x20) {
		control(scp, tcp, c);
		return;
	}

	switch (tcp->state) {
	case ST_ESC:
	case ST_ESC_INTER:
		if (c >= 0x20 && c <= 0x2f) {	/* intermediate */
			tcp->inter = c;
			tcp->state = ST_ESC_INTER;
			return;
		}
		if (tcp->state == ST_ESC) {
			switch (c) {
			case '[':
				tcp->state = ST_CSI;
				tcp->num_param = 0;
				tcp->have_digit = 0;
				tcp->prefix = 0;
				tcp->inter = 0;
				for (i = 0; i < MAX_ESC_PAR; i++)
					tcp->param[i] = 0;
				return;
			case ']':	/* OSC */
			case 'P':	/* DCS */
			case 'X':	/* SOS */
			case '^':	/* PM */
			case '_':	/* APC */
				tcp->state = ST_STRING;
				return;
			}
		}
		tcp->state = ST_GROUND;
		esc(scp, tcp, c);
		return;

	case ST_CSI:
		if ((c >= '0' && c <= '9') || c == ';' || c == ':') {
			if (tcp->inter != 0)
				tcp->state = ST_CSI_IGNORE;
			else
				csi_param(tcp, c);
			return;
		}
		if (c >= '<' && c <= '?') {	/* private marker */
			if (tcp->num_param == 0 && tcp->prefix == 0 &&
			    tcp->inter == 0)
				tcp->prefix = c;
			else
				tcp->state = ST_CSI_IGNORE;
			return;
		}
		if (c >= 0x20 && c <= 0x2f) {	/* intermediate */
			tcp->inter = c;
			return;
		}
		tcp->state = ST_GROUND;
		if (c >= 0x40 && c <= 0x7e) {
			if (tcp->num_param > MAX_ESC_PAR)
				return;
			csi(scp, tcp, c);
		}
		return;

	case ST_CSI_IGNORE:
		if (c >= 0x40 && c <= 0x7e)
			tcp->state = ST_GROUND;
		return;
	}
}

static void
xterm_puts(scr_stat *scp, u_char *buf, int len)
{
	term_stat *tcp = scp->ts;

	atomic_add_char(&scp->sc->write_in_progress, 1);
	while (len-- > 0)
		xterm_exec(scp, tcp, *buf++);
	atomic_add_char(&scp->sc->write_in_progress, -1);
}

static int
xterm_ioctl(scr_stat *scp, struct tty *tp, u_long cmd, caddr_t data,
	    int flag)
{
	term_stat *tcp = scp->ts;
	vid_info_t *vi;

	switch (cmd) {
	case GIO_ATTR:		/* get current attributes */
		*(int*)data = (tcp->cur_attr >> 8) & 0xff;
		return 0;
	case CONS_GETINFO:	/* get current (virtual) console info */
		vi = (vid_info_t *)data;
		if (vi->size != sizeof(struct vid_info))
			return EINVAL;
		vi->mv_norm.fore = tcp->std_color.fg;
		vi->mv_norm.back = tcp->std_color.bg;
		vi->mv_rev.fore = tcp->rev_color.fg;
		vi->mv_rev.back = tcp->rev_color.bg;
		/* the other fields are filled by the upper routine */
		return ENOIOCTL;
	}
	return ENOIOCTL;
}

static int
xterm_reset(scr_stat *scp, int code)
{
	return 0;
}

static void
xterm_default_attr(scr_stat *scp, int color, int rev_color)
{
	term_stat *tcp = scp->ts;

	tcp->dflt_std_color.fg = color & 0x0f;
	tcp->dflt_std_color.bg = (color >> 4) & 0x0f;
	tcp->dflt_rev_color.fg = rev_color & 0x0f;
	tcp->dflt_rev_color.bg = (rev_color >> 4) & 0x0f;
	tcp->std_color = tcp->dflt_std_color;
	tcp->rev_color = tcp->dflt_rev_color;
	tcp->cur_color = tcp->std_color;
	tcp->cur_attr = mask2attr(tcp);
}

static void
xterm_clear(scr_stat *scp)
{
	term_stat *tcp = scp->ts;

	tcp->wrapnext = 0;
	sc_move_cursor(scp, 0, 0);
	sc_vtb_clear(&scp->vtb, scp->sc->scr_map[0x20], tcp->cur_attr);
	mark_all(scp);
}

static void
xterm_notify(scr_stat *scp, int event)
{
}

static int
xterm_input(scr_stat *scp, int c, struct tty *tp)
{
	return FALSE;
}

/*
 * xterm's strings for the keys of the default keymap's function key
 * table (kbdtables.h), by its index: F1-F12 alone, with shift, control
 * and both, then the editing and cursor keys.  The keypad's - and + and
 * the keys past Del keep the keymap's strings.
 */
#define FK_HOME		48
#define FK_UP		49
#define FK_PGUP		50
#define FK_LEFT		52
#define FK_KP5		53
#define FK_RIGHT	54
#define FK_END		56
#define FK_DOWN		57
#define FK_PGDN		58
#define FK_INS		59
#define FK_DEL		60

/* xterm's modifier parameter: none, shift, control, shift+control */
static const int xterm_fkey_mod[4] = { 1, 2, 5, 6 };

static const char *const xterm_fkeys[12] = {
	"P", "Q", "R", "S", "15", "17", "18", "19", "20", "21", "23", "24"
};

static const u_char *
xterm_fkeystr(scr_stat *scp, int c, size_t *len)
{
	/* filled for each key: the console has one keyboard */
	static char buf[16];
	term_stat *tcp = scp->ts;
	const char *k, *cur;
	int i, mod, n;

	i = c - F_FN;
	if (i < 0)
		return NULL;
	if (i < 48) {
		/* modifier: 1 none, 2 shift, 5 control, 6 both */
		mod = xterm_fkey_mod[i / 12];
		k = xterm_fkeys[i % 12];
		if (k[1] == '\0') {		/* F1-F4 */
			if (mod == 1)
				n = ksnprintf(buf, sizeof(buf), "\033O%s", k);
			else
				n = ksnprintf(buf, sizeof(buf), "\033[1;%d%s",
					      mod, k);
		} else {
			if (mod == 1)
				n = ksnprintf(buf, sizeof(buf), "\033[%s~",
					      k);
			else
				n = ksnprintf(buf, sizeof(buf), "\033[%s;%d~",
					      k, mod);
		}
		*len = n;
		return (const u_char *)buf;
	}

	cur = NULL;
	switch (i) {
	case FK_HOME:	cur = "H"; break;
	case FK_UP:	cur = "A"; break;
	case FK_LEFT:	cur = "D"; break;
	case FK_KP5:	cur = "E"; break;
	case FK_RIGHT:	cur = "C"; break;
	case FK_END:	cur = "F"; break;
	case FK_DOWN:	cur = "B"; break;
	case FK_PGUP:	k = "\033[5~"; break;
	case FK_PGDN:	k = "\033[6~"; break;
	case FK_INS:	k = "\033[2~"; break;
	case FK_DEL:	k = "\033[3~"; break;
	default:
		return NULL;
	}
	if (cur != NULL) {
		/* ESC O in application cursor mode, ESC [ otherwise */
		n = ksnprintf(buf, sizeof(buf), "\033%c%s",
			      tcp->appcursor ? 'O' : '[', cur);
		*len = n;
		return (const u_char *)buf;
	}
	*len = strlen(k);
	return (const u_char *)k;
}

/*
 * The adapter attribute word of the logical attributes and colours.
 * Bold is the bright foreground; reverse swaps the colours that were
 * set, else uses the reverse ones; invisible is the background colour.
 */
static int
mask2attr(term_stat *tcp)
{
	int attr, fg, bg, mask = tcp->attr_mask;

	if (!(mask & REVERSE_ATTR)) {
		fg = tcp->cur_color.fg;
		bg = tcp->cur_color.bg;
	} else if (mask & (FG_CHANGED | BG_CHANGED)) {
		fg = tcp->cur_color.bg;
		bg = tcp->cur_color.fg;
	} else {
		fg = tcp->rev_color.fg;
		bg = tcp->rev_color.bg;
	}
	if (mask & (BOLD_ATTR | UNDERLINE_ATTR))
		fg |= 0x08;
	if (mask & INVISIBLE_ATTR)
		fg = bg;
	attr = (fg & 0x0f) | ((bg & 0x07) << 4);
	if (mask & BLINK_ATTR)
		attr |= 0x80;
	return (attr << 8);
}

#endif /* SC_DUMB_TERMINAL */
