/***************************************************************************************
 *  Genesis Plus
 *  Video Display Processor (68k & Z80 CPU interface)
 *
 *  Support for SG-1000, Master System (315-5124 & 315-5246), Game Gear & Mega Drive VDP
 *
 *  Copyright (C) 1998, 1999, 2000, 2001, 2002, 2003  Charles Mac Donald (original code)
 *  Copyright (C) 2007-2013  Eke-Eke (Genesis Plus GX)
 *
 *  Redistribution and use of this code or any derivative works are permitted
 *  provided that the following conditions are met:
 *
 *   - Redistributions may not be sold, nor may they be used in a commercial
 *     product or activity.
 *
 *   - Redistributions that are modified from the original source must include the
 *     complete source code, including the source code for all components used by a
 *     binary built from the modified sources. However, as a special exception, the
 *     source code distributed need not include anything that is normally distributed
 *     (in either source or binary form) with the major components (compiler, kernel,
 *     and so on) of the operating system on which the executable runs, unless that
 *     component itself accompanies the executable.
 *
 *   - Redistributions must reproduce the above copyright notice, this list of
 *     conditions and the following disclaimer in the documentation and/or other
 *     materials provided with the distribution.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 *  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 *  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 *  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 *  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 *  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 *  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 *  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 *  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *
 ****************************************************************************************/

import common;
import hvc;

/* VDP context */
u8[0x400] sat;     /* Internal copy of sprite attribute table */
u8[0x10000] vram;  /* Video RAM (64K x 8-bit) */
u8[0x80] cram;     /* On-chip color RAM (64 x 9-bit) */
u8[0x80] vsram;    /* On-chip vertical scroll RAM (40 x 11-bit) */
u8[0x20] reg;      /* Internal VDP registers (23 x 8-bit) */
u8 hint_pending;   /* 0= Line interrupt is pending */
u8 vint_pending;   /* 1= Frame interrupt is pending */
u16 status;        /* VDP status flags */
u32 dma_length;    /* DMA remaining length */

/* Global variables */
u16 ntab;                      /* Name table A base address */
u16 ntbb;                      /* Name table B base address */
u16 ntwb;                      /* Name table W base address */
u16 satb;                      /* Sprite attribute table base address */
u16 hscb;                      /* Horizontal scroll table base address */
u8[0x800] bg_name_dirty;       /* 1= This pattern is dirty */
u16[0x800] bg_name_list;       /* List of modified pattern indices */
u16 bg_list_index;             /* # of modified patterns in list */
u8 hscroll_mask;               /* Horizontal Scrolling line mask */
u8 playfield_shift;            /* Width of planes A, B (in bits) */
u8 playfield_col_mask;         /* Playfield column mask */
u16 playfield_row_mask;        /* Playfield row mask */
u16 vscroll;                   /* Latched vertical scroll value */
u8 odd_frame;                  /* 1: odd field, 0: even field */
u8 im2_flag;                   /* 1= Interlace mode 2 is being used */
u8 interlaced;                 /* 1: Interlaced mode 1 or 2 */
u8 vdp_pal;                    /* 1: PAL , 0: NTSC (default) */
u16 v_counter;                 /* Vertical counter */
u16 vc_max;                    /* Vertical counter overflow value */
u16 lines_per_frame;           /* PAL: 313 lines, NTSC: 262 lines */
s32 fifo_write_cnt;             /* VDP writes fifo count */
u32 fifo_lastwrite;            /* last VDP write cycle */
u32 hvc_latch;                 /* latched HV counter */
/*const*/ u8[] hctab;               /* pointer to H Counter table */

/* Mark a pattern as modified */
void MARK_BG_DIRTY(int index, out int name)
{
  name = (index >> 5) & 0x7FF;
  if(bg_name_dirty[name] == 0)
  {
    bg_name_list[bg_list_index++] = cast(u16) name;
  }
  bg_name_dirty[name] |= (1 << ((index >> 2) & 7));
}

/* Function pointers */
void function(u32 data) vdp_68k_data_w;
void function(u32 data) vdp_z80_data_w;
u32 function() vdp_68k_data_r;
u32 function() vdp_z80_data_r;

/* Tables that define the playfield layout */
static const u8[] hscroll_mask_table = [ 0x00, 0x07, 0xF8, 0xFF ];
static const u8[] shift_table        = [ 6, 7, 0, 8 ];
static const u8[] col_mask_table     = [ 0x0F, 0x1F, 0x0F, 0x3F ];
static const u16[] row_mask_table    = [ 0x0FF, 0x1FF, 0x2FF, 0x3FF ];

static u8 border;          /* Border color index */
static u8 pending;         /* Pending write flag */
static u8 code;            /* Code register */
static u8 dma_type;        /* DMA mode */
static u16 addr;           /* Address register */
static u16 addr_latch;     /* Latched A15, A14 of address */
static u16 sat_base_mask;  /* Base bits of SAT */
static u16 sat_addr_mask;  /* Index bits of SAT */
static u16 dma_src;        /* DMA source address */
static u16 dmafill;        /* DMA Fill setup */
static u32 dma_endCycles;  /* 68k cycles to DMA end */
static u32 fifo_latency;   /* CPU access latency */
static int cached_write;      /* 2nd part of 32-bit CTRL port write (Genesis mode) or LSB of CRAM data (Game Gear mode) */
static u16[4] fifo;        /* FIFO buffer */

 /* set Z80 or 68k interrupt lines */
static void function(u32 level) set_irq_line;
static void function(u32 level) set_irq_line_delay;

/* Vertical counter overflow values (see hvc.h) */
static const u16[2][4] vc_table = 
[
  /* NTSC, PAL */
  [0xDA , 0xF2],  /* Mode 4 (192 lines) */
  [0xEA , 0x102], /* Mode 5 (224 lines) */
  [0xDA , 0xF2],  /* Mode 4 (192 lines) */
  [0x106, 0x10A]  /* Mode 5 (240 lines) */
];

/* DMA Timings (number of access slots per line) */
static const u8[2][2] dma_timing =
[
/* H32, H40 */
  [16 , 18],  /* active display */
  [167, 205]  /* blank display */
];

/* DMA processing functions (set by VDP register 23 high nibble) */
static const void function(u32 length)[16] dma_func =
[
  /* 0x0-0x3 : DMA from 68k bus $000000-$7FFFFF (external area) */
  &vdp_dma_68k_ext, &vdp_dma_68k_ext, &vdp_dma_68k_ext, &vdp_dma_68k_ext,

  /* 0x4-0x7 : DMA from 68k bus $800000-$FFFFFF (internal RAM & I/O) */
  &vdp_dma_68k_ram, &vdp_dma_68k_io, &vdp_dma_68k_ram, &vdp_dma_68k_ram,

  /* 0x8-0xB : DMA Fill */
  &vdp_dma_fill, &vdp_dma_fill, &vdp_dma_fill, &vdp_dma_fill,

  /* 0xC-0xF : DMA Copy */
  &vdp_dma_copy, &vdp_dma_copy, &vdp_dma_copy, &vdp_dma_copy
];


/*--------------------------------------------------------------------------*/
/* Init, reset, context functions                                           */
/*--------------------------------------------------------------------------*/

void vdp_init()
{
  /* PAL/NTSC timings */
  lines_per_frame = vdp_pal ? 313: 262;

  /* CPU interrupt line(s)*/
  if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
  {
    /* 68k cpu */
    set_irq_line = &m68k_set_irq;
    set_irq_line_delay = &m68k_set_irq_delay;
  }
  else
  {
    /* Z80 cpu */
    set_irq_line = &z80_set_irq_line;
    set_irq_line_delay = &z80_set_irq_line;
  }
}

void vdp_reset()
{
  int i;

  sat[] = 0;
  vram[] = 0;
  cram[] = 0;
  vsram[] = 0;
  reg[] = 0;

  addr            = 0;
  addr_latch      = 0;
  code            = 0;
  pending         = 0;
  border          = 0;
  hint_pending    = 0;
  vint_pending    = 0;
  dmafill         = 0;
  dma_src         = 0;
  dma_type        = 0;
  dma_length      = 0;
  dma_endCycles   = 0;
  odd_frame       = 0;
  im2_flag        = 0;
  interlaced      = 0;
  fifo_write_cnt  = 0;
  fifo_lastwrite  = 0;
  cached_write   = -1;

  ntab = 0;
  ntbb = 0;
  ntwb = 0;
  satb = 0;
  hscb = 0;

  vscroll = 0;

  hscroll_mask        = 0x00;
  playfield_shift     = 6;
  playfield_col_mask  = 0x0F;
  playfield_row_mask  = 0x0FF;
  sat_base_mask       = 0xFE00;
  sat_addr_mask       = 0x01FF;

  /* reset pattern cache changes */
  bg_list_index = 0;
  bg_name_dirty[] = 0;
  bg_name_list[] = 0;

  /* default HVC */
  hvc_latch = 0x10000;
  hctab = cast(ubyte[]) cycle2hc32;
  vc_max = vc_table[0][vdp_pal];
  v_counter = cast(u16) (lines_per_frame - 1);

  /* default Window clipping */
  window_clip(0,0);

  /* default FIFO timings */
  fifo_latency = 214;

  /* reset VDP status (FIFO empty flag is set) */
  if (system_hw & SYSTEM_MD)
  {
    status = vdp_pal | 0x200;
  }
  else
  {
    status = 0;
  }

  /* default display area */
  bitmap.viewport.w   = 256;
  bitmap.viewport.h   = 192;
  bitmap.viewport.ow  = 256;
  bitmap.viewport.oh  = 192;

  /* default overscan area */
  if ((system_hw == SYSTEM_GG) && !config.gg_extra)
  {
    /* Display area reduced to 160x144 if overscan is disabled */
    bitmap.viewport.x = (config.overscan & 2) ? 14 : -48;
    bitmap.viewport.y = (config.overscan & 1) ? (24 * (vdp_pal + 1)) : -24;
  }
  else
  {
    bitmap.viewport.x = (config.overscan & 2) * 7;
    bitmap.viewport.y = (config.overscan & 1) * 24 * (vdp_pal + 1);
  }

  /* default rendering mode */
  update_bg_pattern_cache = &update_bg_pattern_cache_m4;
  if (system_hw < SYSTEM_MD)
  {
    /* Mode 0 */
    render_bg = &render_bg_m0;
    render_obj = &render_obj_tms;
    parse_satb = &parse_satb_tms;
  }
  else
  {
    /* Mode 4 */
    render_bg = &render_bg_m4;
    render_obj = &render_obj_m4;
    parse_satb = &parse_satb_m4;
  }

  /* 68k bus access mode (Mode 4 by default) */
  vdp_68k_data_w = &vdp_68k_data_w_m4;
  vdp_68k_data_r = &vdp_68k_data_r_m4;

  /* Z80 bus access mode */
  switch (system_hw)
  {
    case SYSTEM_SG:
    {
      /* SG-1000 port access */
      vdp_z80_data_w = &vdp_z80_data_w_sg;
      vdp_z80_data_r = &vdp_z80_data_r_m4;
      break;
    }

    case SYSTEM_GG:
    {
      /* Game Gear port access */
      vdp_z80_data_w = &vdp_z80_data_w_gg;
      vdp_z80_data_r = &vdp_z80_data_r_m4;
      break;
    }

    case SYSTEM_MARKIII:
    case SYSTEM_SMS:
    case SYSTEM_SMS2:
    case SYSTEM_GGMS:
    {
      /* Master System port access */
      vdp_z80_data_w = &vdp_z80_data_w_ms;
      vdp_z80_data_r = &vdp_z80_data_r_m4;
      break;
    }

    default:
    {
      /* Genesis port access */
      vdp_z80_data_w = &vdp_z80_data_w_m4;
      vdp_z80_data_r = &vdp_z80_data_r_m4;
      break;
    }
  }

  /* SG-1000 specific */
  if (system_hw == SYSTEM_SG)
  {
    /* 16k address decoding by default (Magical Kid Wiz) */
    vdp_reg_w(1, 0x80, 0);

    /* no H-INT on TMS9918 */
    vdp_reg_w(10, 0xFF, 0);
  }

  /* Master System specific */
  else if ((system_hw & SYSTEM_SMS) && (!(config.bios & 1) || !(system_bios & SYSTEM_SMS)))
  {
    /* force registers initialization (only if Master System BIOS is disabled or not loaded) */
    vdp_reg_w(0 , 0x36, 0);
    vdp_reg_w(1 , 0x80, 0);
    vdp_reg_w(2 , 0xFF, 0);
    vdp_reg_w(3 , 0xFF, 0);
    vdp_reg_w(4 , 0xFF, 0);
    vdp_reg_w(5 , 0xFF, 0);
    vdp_reg_w(6 , 0xFF, 0);
    vdp_reg_w(10, 0xFF, 0);

    /* Mode 4 */
    render_bg = &render_bg_m4;
    render_obj = &render_obj_m4;
    parse_satb = &parse_satb_m4;
  }

  /* Mega Drive specific */
  else if (((system_hw == SYSTEM_MD) || (system_hw == SYSTEM_MCD)) && (config.bios & 1) && !(system_bios & SYSTEM_MD))
  {
    /* force registers initialization (only if TMSS model is emulated and BOOT ROM is not loaded) */
    vdp_reg_w(0 , 0x04, 0);
    vdp_reg_w(1 , 0x04, 0);
    vdp_reg_w(10, 0xFF, 0);
    vdp_reg_w(12, 0x81, 0);
    vdp_reg_w(15, 0x02, 0);
  }

  /* reset color palette */
  for(i = 0; i < 0x20; i ++)
  {
    color_update_m4(i, 0x00);
  }
  color_update_m4(0x40, 0x00);
}

int vdp_context_save(u8 *state)
{
  int bufferptr = 0;

  // FIXME: It looks like these are using sizeof instead of the actual length
  save_param(&bufferptr, state, sat.ptr, sat.sizeof);
  save_param(&bufferptr, state, vram.ptr, vram.sizeof);
  save_param(&bufferptr, state, cram.ptr, cram.sizeof);
  save_param(&bufferptr, state, vsram.ptr, vsram.sizeof);
  save_param(&bufferptr, state, reg.ptr, reg.sizeof);
  save_param(&bufferptr, state, &addr, addr.sizeof);
  save_param(&bufferptr, state, &addr_latch, addr_latch.sizeof);
  save_param(&bufferptr, state, &code, code.sizeof);
  save_param(&bufferptr, state, &pending, pending.sizeof);
  save_param(&bufferptr, state, &status, status.sizeof);
  save_param(&bufferptr, state, &dmafill, dmafill.sizeof);
  save_param(&bufferptr, state, &hint_pending, hint_pending.sizeof);
  save_param(&bufferptr, state, &vint_pending, vint_pending.sizeof);
  save_param(&bufferptr, state, &dma_length, dma_length.sizeof);
  save_param(&bufferptr, state, &dma_type, dma_type.sizeof);
  save_param(&bufferptr, state, &dma_src, dma_src.sizeof);
  save_param(&bufferptr, state, &cached_write, cached_write.sizeof);
  return bufferptr;
}

int vdp_context_load(u8 *state)
{
  int i, bufferptr = 0;
  u8 temp_reg[0x20];

// FIXME: It looks like these are using sizeof instead of the actual length
  load_param(&bufferptr, state, sat.ptr, sat.sizeof);
  load_param(&bufferptr, state, vram.ptr, vram.sizeof);
  load_param(&bufferptr, state, cram.ptr, cram.sizeof);
  load_param(&bufferptr, state, vsram.ptr, vsram.sizeof);
  load_param(&bufferptr, state, temp_reg.ptr, temp_reg.sizeof);

  /* restore VDP registers */
  if (system_hw < SYSTEM_MD)
  {
    if (system_hw > SYSTEM_SG)
    {
      for (i=0;i<0x10;i++) 
      {
        pending = 1;
        addr_latch = temp_reg[i];
        vdp_sms_ctrl_w(0x80 | i);
      }
    }
    else
    {
      for (i=0;i<0x08;i++) 
      {
        pending = 1;
        addr_latch = temp_reg[i];
        vdp_tms_ctrl_w(0x80 | i);
      }
    }
  }
  else
  {
    for (i=0;i<0x20;i++) 
    {
      vdp_reg_w(i, temp_reg[i], 0);
    }
  }

  // FIXME: It looks like these are using sizeof instead of the actual length
  load_param(&bufferptr, state, &addr, addr.sizeof);
  load_param(&bufferptr, state, &addr_latch, addr_latch.sizeof);
  load_param(&bufferptr, state, &code, code.sizeof);
  load_param(&bufferptr, state, &pending, pending.sizeof);
  load_param(&bufferptr, state, &status, status.sizeof);
  load_param(&bufferptr, state, &dmafill, dmafill.sizeof);
  load_param(&bufferptr, state, &hint_pending, hint_pending.sizeof);
  load_param(&bufferptr, state, &vint_pending, vint_pending.sizeof);
  load_param(&bufferptr, state, &dma_length, dma_length.sizeof);
  load_param(&bufferptr, state, &dma_type, dma_type.sizeof);
  load_param(&bufferptr, state, &dma_src, dma_src.sizeof);

  load_param(&bufferptr, state, &cached_write, cached_write.sizeof);

  /* restore FIFO timings */
  fifo_latency = (reg[12] & 1) ? 190 : 214;
  fifo_latency <<= ((code & 0x0F) < 0x03);

  /* restore current NTSC/PAL mode */
  if (system_hw & SYSTEM_MD)
  {
    status = (status & ~1) | vdp_pal;
  }

  if (reg[1] & 0x04)
  {
    /* Mode 5 */
    bg_list_index = 0x800;

    /* reinitialize palette */
    color_update_m5(0, *cast(u16 *)&cram[border << 1]);
    for(i = 1; i < 0x40; i++)
    {
      color_update_m5(i, *cast(u16 *)&cram[i << 1]);
    }
  }
  else
  {
    /* Modes 0,1,2,3,4 */
    bg_list_index = 0x200;

    /* reinitialize palette */
    for(i = 0; i < 0x20; i ++)
    {
      color_update_m4(i, *cast(u16 *)&cram[i << 1]);
    }
    color_update_m4(0x40, *cast(u16 *)&cram[(0x10 | (border & 0x0F)) << 1]);
  }

  /* invalidate cache */
  for (i=0;i<bg_list_index;i++) 
  {
    bg_name_list[i] = cast(u16) i;
    bg_name_dirty[i] = 0xFF;
  }

  return bufferptr;
}


/*--------------------------------------------------------------------------*/
/* DMA update function                                                      */
/*--------------------------------------------------------------------------*/

void vdp_dma_update(u32 cycles)
{
  int dma_cycles, dma_bytes;

  /* DMA transfer rate (bytes per line) 

     According to the manual, here's a table that describes the transfer
   rates of each of the three DMA types:

      DMA Mode      Width       Display      Transfer Count
      -----------------------------------------------------
      68K > VDP     32-cell     Active       16
                                Blanking     167
                    40-cell     Active       18
                                Blanking     205
      VRAM Fill     32-cell     Active       15
                                Blanking     166
                    40-cell     Active       17
                                Blanking     204
      VRAM Copy     32-cell     Active       8
                                Blanking     83
                    40-cell     Active       9
                                Blanking     102

   'Active' is the active display period, 'Blanking' is either the vertical
   blanking period or when the display is forcibly blanked via register #1.

   The above transfer counts are all in bytes, unless the destination is
   CRAM or VSRAM for a 68K > VDP transfer, in which case it is in words.
  */
  u32 rate = dma_timing[(status & 8) || !(reg[1] & 0x40)][reg[12] & 1];

  /* Adjust for 68k bus DMA to VRAM (one word = 2 access) or DMA Copy (one read + one write = 2 access) */
  rate = rate >> (dma_type & 1);

  /* Remaining DMA cycles */
  if (status & 8)
  {
    /* Process DMA until the end of VBLANK */
    /* NOTE: DMA timings can not change during VBLANK because active display width cannot be modified. */
    /* Indeed, writing VDP registers during DMA is either impossible (when doing DMA from 68k bus, CPU */
    /* is locked) or will abort DMA operation (in case of DMA Fill or Copy). */
    dma_cycles = (lines_per_frame * MCYCLES_PER_LINE) - cycles;
  }
  else
  {
    /* Process DMA until the end of current line */
    dma_cycles = (mcycles_vdp + MCYCLES_PER_LINE) - cycles;
  }

  /* Remaining DMA bytes for that line */
  dma_bytes = (dma_cycles * rate) / MCYCLES_PER_LINE;

version(LOGVDP) {
  error("[%d(%d)][%d(%d)] DMA type %d (%d access/line)(%d cycles left)-> %d access (%d remaining) (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE,dma_type, rate, dma_cycles, dma_bytes, dma_length, m68k_get_reg(M68K_REG_PC));
}

  /* Check if DMA can be finished before the end of current line */
  if (dma_length < cast(u32) dma_bytes)
  {
    /* Adjust remaining DMA bytes */
    dma_bytes = dma_length;
    dma_cycles = (dma_bytes * MCYCLES_PER_LINE) / rate;
  }

  /* Update DMA timings */
  if (dma_type < 2)
  {
    /* 68K is frozen during DMA from 68k bus */
    m68k.cycles = cycles + dma_cycles;
version(LOGVDP) {
    error("-->CPU frozen for %d cycles\n", dma_cycles);
}
  }
  else
  {
    /* Set DMA Busy flag */
    status |= 0x02;

    /* 68K is still running, set DMA end cycle */
    dma_endCycles = cycles + dma_cycles;
version(LOGVDP) {
    error("-->DMA ends in %d cycles\n", dma_cycles);
}
  }

  /* Process DMA */
  if (dma_bytes > 0)
  {
    /* Update DMA length */
    dma_length -= dma_bytes;

    /* Process DMA operation */
    dma_func[reg[23] >> 4](dma_bytes);

    /* Check if DMA is finished */
    if (!dma_length)
    {
      /* DMA source address registers are incremented during DMA */
      u16 end = cast(u16) (reg[21] + (reg[22] << 8) + reg[19] + (reg[20] << 8));
      reg[21] = end & 0xff;
      reg[22] = end >> 8;

      /* DMA length registers are decremented during DMA */
      reg[19] = reg[20] = 0;

      /* perform cached write, if any */
      if (cached_write >= 0)
      {
        vdp_68k_ctrl_w(cached_write);
        cached_write = -1;
      }
    }
  }
}


/*--------------------------------------------------------------------------*/
/* Control port access functions                                            */
/*--------------------------------------------------------------------------*/

void vdp_68k_ctrl_w(u32 data)
{
  /* Check pending flag */
  if (pending == 0)
  {
    /* A single long word write instruction could have started DMA with the first word */
    if (dma_length)
    {
      /* 68k is frozen during 68k bus DMA */
      /* Second word should be written after DMA completion */
      /* See Formula One & Kawasaki Superbike Challenge */
      if (dma_type < 2)
      {
        /* Latch second control word for later */
        cached_write = data;
        return;
      }
    }

    /* Check CD0-CD1 bits */
    if ((data & 0xC000) == 0x8000)
    {
      /* VDP register write */
      vdp_reg_w((data >> 8) & 0x1F, data & 0xFF, m68k.cycles);
    }
    else
    {
      /* Set pending flag (Mode 5 only) */
      pending = reg[1] & 4;
    }

    /* Update address and code registers */
    addr = addr_latch | (data & 0x3FFF);
    code = ((code & 0x3C) | ((data >> 14) & 0x03));
  }
  else
  {
    /* Clear pending flag */
    pending = 0;

    /* Save address bits A15 and A14 */
    addr_latch = (data & 3) << 14;

    /* Update address and code registers */
    addr = addr_latch | (addr & 0x3FFF);
    code = ((code & 0x03) | ((data >> 2) & 0x3C));

    /* Detect DMA operation (CD5 bit set) */
    if (code & 0x20)
    {
      /* DMA must be enabled */
      if (reg[1] & 0x10)
      {
        /* DMA type */
        switch (reg[23] >> 6)
        {
          case 2:
          {
            /* DMA Fill will be triggered by next DATA port write */
            dmafill = 0x100;
            break;
          }

          case 3:
          {
            /* DMA length */
            dma_length = (reg[20] << 8) | reg[19];

            /* Zero DMA length */
            if (!dma_length)
            {
              dma_length = 0x10000;
            }

            /* DMA source address */
            dma_src = (reg[22] << 8) | reg[21];

            /* trigger DMA copy */
            dma_type = 3;
            vdp_dma_update(m68k.cycles);
            break;
          }

          default:
          {
            /* DMA length */
            dma_length = (reg[20] << 8) | reg[19];

            /* Zero DMA length */
            if (!dma_length)
            {
              dma_length = 0x10000;
            }

            /* DMA source address */
            dma_src = (reg[22] << 8) | reg[21];

            /* Transfer from SVP ROM/RAM ($000000-$3fffff) or CD Word-RAM ($200000-$3fffff/$600000-$7fffff) */
            if (((system_hw == SYSTEM_MCD) && ((reg[23] & 0x70) == ((module_scd.scd.cartridge.boot >> 1) + 0x10))) || (svp.svp && !(reg[23] & 0x60)))
            {
              /* source data is available with one cycle delay, i.e first word written by VDP is */
              /* previous data being held on 68k bus at that time, then source words are written */
              /* normally to VDP RAM, with only last source word being ignored */
              addr += reg[15];
              dma_length--;
            }

            /* trigger DMA from 68k bus */
            dma_type = (code & 0x06) ? 0 : 1;
            vdp_dma_update(m68k.cycles);
            break;
          }
        }
      }
    }
  }

  /* 
     FIFO emulation (Chaos Engine/Soldier of Fortune, Double Clutch, Sol Deace) 
     --------------------------------------------------------------------------

      CPU access per line is limited during active display:
         H32: 16 access --> 3420/16 = ~214 Mcycles between access
         H40: 18 access --> 3420/18 = ~190 Mcycles between access

      This is an approximation: on real hardware, access slots are fixed.

      Each VRAM access is byte wide, so one VRAM write (word) need twice cycles.

      Note: Invalid code 0x02 (register write) apparently behaves the same as VRAM
      access, although no data is written in this case (fixes Clue menu)
  */
  fifo_latency = (reg[12] & 1) ? 190 : 214;
  fifo_latency <<= ((code & 0x0F) < 0x03);
}

/* Mega Drive VDP control port specific (MS compatibility mode) */
void vdp_z80_ctrl_w(u32 data)
{
  switch (pending)
  {
    case 0:
    {
      /* Latch LSB */
      addr_latch = cast(u16) data;

      /* Set LSB pending flag */
      pending = 1;
      return;
    }

    case 1:
    {
      /* Update address and code registers */
      addr = (addr & 0xC000) | ((data & 0x3F) << 8) | addr_latch ;
      code = ((code & 0x3C) | ((data >> 6) & 0x03));

      if ((code & 0x03) == 0x02)
      {
        /* VDP register write */
        vdp_reg_w(data & 0x1F, addr_latch, Z80.cycles);

        /* Clear pending flag  */
        pending = 0;
        return;
      }

      /* Set Mode 5 pending flag  */
      pending = (reg[1] & 4) >> 1;

      if (!pending && !(code & 0x03))
      {
        /* Process VRAM read */
        fifo[0] = vram[addr & 0x3FFF];

        /* Increment address register */
        addr += (reg[15] + 1);
      }
      return;
    }

    case 2:
    {
      /* Latch LSB */
      addr_latch = cast(u16) data;

      /* Set LSB pending flag */
      pending = 3;
      return;
    }

    case 3:
    {
      /* Clear pending flag  */
      pending = 0;

      /* Update address and code registers */
      addr = ((addr_latch & 3) << 14) | (addr & 0x3FFF);
      code = ((code & 0x03) | ((addr_latch >> 2) & 0x3C));

      /* Detect DMA operation (CD5 bit set) */
      if (code & 0x20)
      {
        /* DMA should be enabled */
        if (reg[1] & 0x10)
        {
          /* DMA type */
          switch (reg[23] >> 6)
          {
            case 2:
            {
              /* DMA Fill will be triggered by next write to DATA port */
              dmafill = 0x100;
              break;
            }

            case 3:
            {
              /* DMA length */
              dma_length = (reg[20] << 8) | reg[19];

              /* Zero DMA length */
              if (!dma_length)
              {
                dma_length = 0x10000;
              }

              /* DMA source address */
              dma_src = (reg[22] << 8) | reg[21];

              /* trigger DMA copy */
              dma_type = 3;
              vdp_dma_update(Z80.cycles);
              break;
            }

            default:
            {
              /* DMA from 68k bus does not work when Z80 is in control */
              break;
            }
          }
        }
      }
    }
    default:
    {
        throw new Exception("Case default unexpected.");
    }
  }
}

/* Master System & Game Gear VDP control port specific */
void vdp_sms_ctrl_w(u32 data)
{
  if(pending == 0)
  {
    /* Update address register LSB */
    addr = (addr & 0x3F00) | (data & 0xFF);

    /* Latch LSB */
    addr_latch = cast(u16) data;

    /* Set LSB pending flag */
    pending = 1;
  }
  else
  {
    /* Update address and code registers */
    code = (data >> 6) & 3;
    addr = (data << 8 | addr_latch) & 0x3FFF;

    /* Clear pending flag  */
    pending = 0;

    if (code == 0)
    {
      /* Process VRAM read */
      fifo[0] = vram[addr & 0x3FFF];

      /* Increment address register */
      addr = (addr + 1) & 0x3FFF;
      return;
    }

    if (code == 2)
    {
      /* Save current VDP mode */
      int mode, prev = (reg[0] & 0x06) | (reg[1] & 0x18);

      /* Write VDP register 0-15 */
      vdp_reg_w(data & 0x0F, addr_latch, Z80.cycles);

      /* Check VDP mode changes */
      mode = (reg[0] & 0x06) | (reg[1] & 0x18);
      prev ^= mode;
 
      if (prev)
      {
        /* Check for extended modes */
        if (system_hw > SYSTEM_SMS)
        {
          int height;

          if (mode == 0x0E) /* M1=0,M2=1,M3=1,M4=1 */
          {
            /* Mode 4 extended (240 lines) */
            height = 240;

            /* Update vertical counter max value */
            vc_max = vc_table[3][vdp_pal];
          }
          else if (mode == 0x16) /* M1=1,M2=1,M3=0,M4=1 */
          {
            /* Mode 4 extended (224 lines) */
            height = 224;

            /* Update vertical counter max value */
            vc_max = vc_table[1][vdp_pal];
          }
          else
          {
            /* Mode 4 default (224 lines) */
            height = 192;

            /* Default vertical counter max value */
            vc_max = vc_table[0][vdp_pal];
          }

          if (height != bitmap.viewport.h)
          {
            if (v_counter < bitmap.viewport.h)
            {
              /* update active display */
              bitmap.viewport.h = height;

              /* update vertical overscan */
              if (config.overscan & 1)
              {
                bitmap.viewport.y = (240 + 48*vdp_pal - height) >> 1;
              }
              else
              {
                if ((system_hw == SYSTEM_GG) && !config.gg_extra)
                {
                  /* Display area reduced to 160x144 */
                  bitmap.viewport.y = (144 - height) / 2;
                }
                else
                {
                  bitmap.viewport.y = 0;
                }
              }
            }
            else
            {
              /* Changes should be applied on next frame */
              bitmap.viewport.changed |= 2;
            }
          }
        }

        /* Rendering mode */
        switch (mode)
        {
          case 0x00: /* Graphics I */
          {
            render_bg = &render_bg_m0;
            break;
          }

          case 0x10: /* Text */
          {
            render_bg = &render_bg_m1;
           break;
          }

          case 0x02: /* Graphics II */
          {
            render_bg = &render_bg_m2;
            break;
          }

          case 0x12: /* Text (Extended PG) */
          {
            render_bg = &render_bg_m1x;
            break;
          }

          case 0x08: /* Multicolor */
          {
            render_bg = &render_bg_m3;
            break;
          }

          case 0x18: /* Invalid (1+3) */
          {
            render_bg = &render_bg_inv;
            break;
          }

          case 0x0A: /* Multicolor (Extended PG) */
          {
            render_bg = &render_bg_m3x;
            break;
          }

          case 0x1A: /* Invalid (1+2+3) */
          {
            render_bg = &render_bg_inv;
           break;
          }

          default: /* Mode 4 */
          {
            render_bg = &render_bg_m4;
            break;
          }
        }

        /* Mode switching */
        if (prev & 0x04)
        {
          int i;

          if (mode & 0x04)
          {
            /* Mode 4 sprites */
            parse_satb = &parse_satb_m4;
            render_obj = &render_obj_m4;

            /* force BG cache update*/
            bg_list_index = 0x200;
          }
          else
          {
            /* TMS-mode sprites */
            parse_satb = &parse_satb_tms;
            render_obj = &render_obj_tms;

            /* BG cache is not used */
            bg_list_index = 0;
          }

          /* reinitialize palette */
          for(i = 0; i < 0x20; i ++)
          {
            color_update_m4(i, *cast(u16 *)&cram[i << 1]);
          }
          color_update_m4(0x40, *cast(u16 *)&cram[(0x10 | (border & 0x0F)) << 1]);
        }
      }
    }
  }
}

/* TMS9918 (SG-1000) VDP control port specific */
void vdp_tms_ctrl_w(u32 data)
{
  if(pending == 0)
  {
    /* Latch LSB */
    addr_latch = cast(u16) data;

    /* Set LSB pending flag */
    pending = 1;
  }
  else
  {
    /* Update address and code registers */
    code = (data >> 6) & 3;
    addr = (data << 8 | addr_latch) & 0x3FFF;

    /* Clear pending flag  */
    pending = 0;

    if (code == 0)
    {
      /* Process VRAM read */
      fifo[0] = vram[addr & 0x3FFF];

      /* Increment address register */
      addr = (addr + 1) & 0x3FFF;
      return;
    }

    if (code & 2)
    {
      /* VDP register index (0-7) */
      data &= 0x07;

      /* Write VDP register */
      vdp_reg_w(data, addr_latch, Z80.cycles);
 
      /* Check VDP mode changes */
      if (data < 2)
      {
        int mode = (reg[0] & 0x02) | (reg[1] & 0x18);

        /* Rendering mode */
        switch (mode)
        {
          case 0x00: /* Graphics I */
          {
            render_bg = &render_bg_m0;
            break;
          }

          case 0x10: /* Text */
          {
            render_bg = &render_bg_m1;
            break;
          }

          case 0x02: /* Graphics II */
          {
            render_bg = &render_bg_m2;
            break;
          }

          case 0x12: /* Text (Extended PG) */
          {
            render_bg = &render_bg_m1x;
            break;
          }

          case 0x08: /* Multicolor */
          {
            render_bg = &render_bg_m3;
            break;
          }

          case 0x18: /* Invalid (1+3) */
          {
            render_bg = &render_bg_inv;
            break;
          }

          case 0x0A: /* Multicolor (Extended PG) */
          {
            render_bg = &render_bg_m3x;
            break;
          }

          case 0x1A: /* Invalid (1+2+3) */
          {
            render_bg = &render_bg_inv;
            break;
          }
          default:
          {
              throw new Exception("Case default unexpected.");
          }
        }
      }
    }
  }
}

  /*
   * Status register
   *
   * Bits
   * 0  NTSC(0)/PAL(1)
   * 1  DMA Busy
   * 2  During HBlank
   * 3  During VBlank
   * 4  0:1 even:odd field (interlaced modes only)
   * 5  Sprite collision
   * 6  Too many sprites per line
   * 7  v interrupt occurred
   * 8  Write FIFO full
   * 9  Write FIFO empty
   * 10 - 15  Open Bus
   */
u32 vdp_68k_ctrl_r(u32 cycles)
{
  u32 temp;

  /* Update FIFO flags */
  vdp_fifo_update(cycles);

  /* Update DMA Busy flag */
  if ((status & 2) && !dma_length && (cycles >= dma_endCycles))
  {
    status &= 0xFFFD;
  }

  /* Return VDP status */
  temp = status;

  /* Clear pending flag */
  pending = 0;

  /* Clear SOVR & SCOL flags */
  status &= 0xFF9F;

  /* Display OFF: VBLANK flag is set */
  if (!(reg[1] & 0x40))
  {
    temp |= 0x08;
  }

  /* HBLANK flag (Sonic 3 and Sonic 2 "VS Modes", Lemmings 2, Mega Turrican, V.R Troopers, Gouketsuji Ichizoku,...) */
  /* NB: this is not 100% accurate and need to be verified on real hardware */
  if ((cycles % MCYCLES_PER_LINE) < 588)
  {
    temp |= 0x04;
  }

version(LOGVDP) {
  error("[%d(%d)][%d(%d)] VDP 68k status read -> 0x%x (0x%x) (%x)\n", v_counter, cycles/MCYCLES_PER_LINE-1, cycles, cycles%MCYCLES_PER_LINE, temp, status, m68k_get_reg(M68K_REG_PC));
}
  return (temp);
}

u32 vdp_z80_ctrl_r(u32 cycles)
{
  u32 temp;

  /* Cycle-accurate SOVR & VINT flags */
  int line = (lines_per_frame + (cycles / MCYCLES_PER_LINE) - 1) % lines_per_frame;

  /* Update DMA Busy flag (Mega Drive VDP specific) */
  if ((system_hw & SYSTEM_MD) && (status & 2) && !dma_length && (cycles >= dma_endCycles))
  {
    status &= 0xFD;
  }

  /* Check if we are already on next line */
  if (line > v_counter)
  {
    v_counter = cast(u16) line;
    if (line == (bitmap.viewport.h + 1))
    {
      /* set VINT flag (immediately cleared after) */
      status |= 0x80;
    }
    else if ((line >= 0) && (line < bitmap.viewport.h) && !(work_ram[0x1ffb] & md_cart.cart.special))
    {
      /* Check sprites overflow & collision */
      render_line(line);
    }
  }

  /* Return VDP status */
  temp = status;

  /* Clear pending flag */
  pending = 0;

  /* Clear VINT, SOVR & SCOL flags */
  status &= 0xFF1F;

  /* Mega Drive VDP specific */
  if (system_hw & SYSTEM_MD)
  {
    /* Display OFF: VBLANK flag is set */
    if (!(reg[1] & 0x40))
    {
      temp |= 0x08;
    }

    /* HBLANK flag */
    if ((cycles % MCYCLES_PER_LINE) < 588)
    {
      temp |= 0x04;
    }
  }
  else if (reg[0] & 0x04)
  {
    /* Mode 4 unused bits (fixes PGA Tour Golf) */
    temp |= 0x1F;
  }

  /* Cycle-accurate SCOL flag */
  if ((temp & 0x20) && (line == (spr_col >> 8)))
  {
    if (system_hw & SYSTEM_MD)
    {
      /* COL flag is set at HCount 0xFF on MD */
      if ((cycles % MCYCLES_PER_LINE) < 105)
      {
        status |= 0x20;
        temp &= ~0x20;
      }
    }
    else
    {
      /* COL flag is set at the pixel it occurs */
      u8 hc = hctab[(cycles + SMS_CYCLE_OFFSET + 15) % MCYCLES_PER_LINE];
      if ((hc < (spr_col & 0xff)) || (hc > 0xf3))
      {
        status |= 0x20;
        temp &= ~0x20;
      }
    }
  }

  /* Clear HINT & VINT pending flags */
  hint_pending = vint_pending = 0;

  /* Clear Z80 interrupt */
  Z80.irq_state = CLEAR_LINE;

version(LOGVDP) {
  error("[%d(%d)][%d(%d)] VDP Z80 status read -> 0x%x (0x%x) (%x)\n", v_counter, cycles/MCYCLES_PER_LINE-1, cycles, cycles%MCYCLES_PER_LINE, temp, status, Z80.pc.w.l);
}
  return (temp);
}

/*--------------------------------------------------------------------------*/
/* HV Counters                                                              */
/*--------------------------------------------------------------------------*/

u32 vdp_hvc_r(u32 cycles)
{
  int vc;
  u32 temp = hvc_latch;

  /* Check if HVC is frozen */
  if (!temp)
  {
    /* Cycle-accurate HCounter (Striker, Mickey Mania, Skitchin, Road Rash I,II,III, Sonic 3D Blast...) */
    temp = hctab[cycles % MCYCLES_PER_LINE];
  }
  else
  {
    if (reg[1] & 4)
    {
      /* Mode 5: both counters are frozen (Lightgun games, Sunset Riders) */
version(LOGVDP) {
      error("[%d(%d)][%d(%d)] HVC read -> 0x%x (%x)\n", v_counter, (cycles/MCYCLES_PER_LINE-1)%lines_per_frame, cycles, cycles%MCYCLES_PER_LINE, hvc_latch & 0xffff, m68k_get_reg(M68K_REG_PC));
}
      return (temp & 0xffff);
    }
    else
    {
      /* Mode 4: VCounter runs normally, HCounter is frozen */
      temp &= 0xff;
    }
  }

  /* Cycle-accurate VCounter (cycle counter starts from line -1) */
  vc = (cycles / MCYCLES_PER_LINE) - 1;

  /* VCounter overflow */
  if (vc > vc_max)
  {
    vc -= lines_per_frame;
  }

  /* Interlaced modes */
  if (interlaced)
  {
    /* Interlace mode 2 (Sonic the Hedgehog 2, Combat Cars) */
    vc <<= im2_flag;

    /* Replace bit 0 with bit 8 */
    vc = (vc & ~1) | ((vc >> 8) & 1);
  }

  temp |= ((vc & 0xff) << 8);
  
version(LOGVDP) {
  error("[%d(%d)][%d(%d)] HVC read -> 0x%x (%x)\n", v_counter, (cycles/MCYCLES_PER_LINE-1)%lines_per_frame, cycles, cycles%MCYCLES_PER_LINE, temp, m68k_get_reg(M68K_REG_PC));
}
  return (temp);
}


/*--------------------------------------------------------------------------*/
/* Test registers                                                           */
/*--------------------------------------------------------------------------*/

void vdp_test_w()
{

}


/*--------------------------------------------------------------------------*/
/* 68k interrupt handler (TODO: check how interrupts are handled in Mode 4) */
/*--------------------------------------------------------------------------*/

int vdp_68k_irq_ack()
{
version(LOGVDP) {
  error("[%d(%d)][%d(%d)] INT Level %d ack (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE,int_level, m68k_get_reg(M68K_REG_PC));
}

  /* VINT has higher priority (Fatal Rewind) */
  if (vint_pending & reg[1])
  {
version(LOGVDP) {
    error("---> VINT cleared\n");
}

    /* Clear VINT pending flag */
    vint_pending = 0;
    status &= ~0x80;

    /* Update IRQ status */
    if (hint_pending & reg[0])
    {
      m68k_set_irq(4);
    }
    else
    {
      m68k_set_irq(0);
    }
  }
  else
  {
version(LOGVDP) {
    error("---> HINT cleared\n");
}

    /* Clear HINT pending flag */
    hint_pending = 0;

    /* Update IRQ status */
    m68k_set_irq(0);
  }

  return M68K_INT_ACK_AUTOVECTOR;
}


/*--------------------------------------------------------------------------*/
/* VDP registers update function                                            */
/*--------------------------------------------------------------------------*/

static void vdp_reg_w(u32 r, u32 d, u32 cycles)
{
version(LOGVDP) {
  error("[%d(%d)][%d(%d)] VDP register %d write -> 0x%x (%x)\n", v_counter, cycles/MCYCLES_PER_LINE-1, cycles, cycles%MCYCLES_PER_LINE, r, d, m68k_get_reg(M68K_REG_PC));
}

  /* VDP registers #11 to #23 cannot be updated in Mode 4 (Captain Planet & Avengers, Bass Master Classic Pro Edition) */
  if (!(reg[1] & 4) && (r > 10))
  {
    return;
  }

  switch(r)
  {
    case 0: /* CTRL #1 */
    {
      /* Look for changed bits */
      r = d ^ reg[0];
      reg[0] = cast(u8) d;

      /* Line Interrupt */
      if ((r & 0x10) && hint_pending)
      {
        /* Update IRQ status */
        if (vint_pending & reg[1])
        {
          set_irq_line(6);
        }
        else if (d & 0x10)
        {
          set_irq_line_delay(4);
        }
        else
        {
          set_irq_line(0);
        }
      }

      /* Palette selection */
      if (r & 0x04)
      {
        /* Mega Drive VDP only */
        if (system_hw & SYSTEM_MD)
        {
          /* Reset color palette */
          int i;
          if (reg[1] & 0x04)
          {
            /* Mode 5 */
            color_update_m5(0x00, *cast(u16 *)&cram[border << 1]);
            for (i = 1; i < 0x40; i++)
            {
              color_update_m5(i, *cast(u16 *)&cram[i << 1]);
            }
          }
          else
          {
            /* Mode 4 */
            for (i = 0; i < 0x20; i++)
            {
              color_update_m4(i, *cast(u16 *)&cram[i << 1]);
            }
            color_update_m4(0x40, *cast(u16 *)&cram[(0x10 | (border & 0x0F)) << 1]);
          }
        }
      }

      /* HVC latch (Sunset Riders, Lightgun games) */
      if (r & 0x02)
      {
        /* Mega Drive VDP only */
        if (system_hw & SYSTEM_MD)
        {
          /* Mode 5 only */
          if (reg[1] & 0x04)
          {
            if (d & 0x02)
            {
              /* Latch current HVC */
              hvc_latch = vdp_hvc_r(cycles) | 0x10000;
            }
            else
            {
              /* Free-running HVC */
              hvc_latch = 0;
            }
          }
        }
      }
      break;
    }

    case 1: /* CTRL #2 */
    {
      /* Look for changed bits */
      r = d ^ reg[1];
      reg[1] = cast(u8) d;

      /* Display status (modified during active display) */
      if ((r & 0x40) && (v_counter < bitmap.viewport.h))
      {
        /* Cycle offset vs HBLANK */
        int offset = cycles - mcycles_vdp - 860;
        if (offset <= 0)
        {
          /* If display was disabled during HBLANK (Mickey Mania 3D level), sprite rendering is limited  */
          if ((d & 0x40) && (object_count > 5) && (offset >= -500))
          {
            object_count = 5;
          }

          /* Redraw entire line (Legend of Galahad, Lemmings 2, Formula One, Kawasaki Super Bike, Deadly Moves,...) */
          render_line(v_counter);

version(LOGVDP) {
          error("Line redrawn (%d sprites) \n",object_count);
}
        }
        else if (system_hw & SYSTEM_MD)
        {
          /* Active pixel offset  */
          if (reg[12] & 1)
          {
            /* dot clock = MCLK / 8 */
            offset = (offset / 8);
          }
          else
          {
            /* dot clock = MCLK / 10 */
            offset = (offset / 10) + 16;
          }

          /* Line is partially blanked (Nigel Mansell's World Championship Racing , Ren & Stimpy Show, ...) */
          if (offset < bitmap.viewport.w)
          {
version(LOGVDP) {
            error("Line %d redrawn from pixel %d\n",v_counter,offset);
}
            if (d & 0x40)
            {
              render_line(v_counter);
              blank_line(v_counter, 0, offset);
            }
            else
            {
              blank_line(v_counter, offset, bitmap.viewport.w - offset);
            }
          }
        }
      }

      /* Frame Interrupt */
      if ((r & 0x20) && vint_pending)
      {
        /* Update IRQ status */
        if (d & 0x20) 
        {
          set_irq_line_delay(6);
        }
        else if (hint_pending & reg[0])
        {
          set_irq_line(4);
        }
        else
        {
          set_irq_line(0);
        }
      }

      /* Active display height */
      if (r & 0x08)
      {
        /* Mega Drive VDP only */
        if (system_hw & SYSTEM_MD)
        {
          /* Mode 5 only */
          if (d & 0x04)
          {
            if (v_counter < bitmap.viewport.h)
            {
              /* Update active display height */
              bitmap.viewport.h = 224 + ((d & 8) << 1);
              bitmap.viewport.y = (config.overscan & 1) * (8 - (d & 8) + 24*vdp_pal);
            }
            else
            {
              /* Changes should be applied on next frame */
              bitmap.viewport.changed |= 2;
            }

            /* Update vertical counter max value */
            vc_max = vc_table[(d >> 2) & 3][vdp_pal];
          }
        }
      }

      /* Rendering mode */
      if (r & 0x04)
      {
        /* Mega Drive VDP only */
        if (system_hw & SYSTEM_MD)
        {
          int i;
          if (d & 0x04)
          {
            /* Mode 5 rendering */
            parse_satb = &parse_satb_m5;
            update_bg_pattern_cache = &update_bg_pattern_cache_m5;
            if (im2_flag)
            {
              render_bg = (reg[11] & 0x04) ? &render_bg_m5_im2_vs : &render_bg_m5_im2;
              render_obj = (reg[12] & 0x08) ? &render_obj_m5_im2_ste : &render_obj_m5_im2;
            }
            else
            {
              render_bg = (reg[11] & 0x04) ? &render_bg_m5_vs : &render_bg_m5;
              render_obj = (reg[12] & 0x08) ? &render_obj_m5_ste : &render_obj_m5;
            }

            /* Reset color palette */
            color_update_m5(0x00, *cast(u16 *)&cram[border << 1]);
            for (i = 1; i < 0x40; i++)
            {
              color_update_m5(i, *cast(u16 *)&cram[i << 1]);
            }

            /* Mode 5 bus access */
            vdp_68k_data_w = &vdp_68k_data_w_m5;
            vdp_z80_data_w = &vdp_z80_data_w_m5;
            vdp_68k_data_r = &vdp_68k_data_r_m5;
            vdp_z80_data_r = &vdp_z80_data_r_m5;

            /* Change display height */
            if (v_counter < bitmap.viewport.h)
            {
              /* Update active display */
              bitmap.viewport.h = 224 + ((d & 8) << 1);
              bitmap.viewport.y = (config.overscan & 1) * (8 - (d & 8) + 24*vdp_pal);
            }
            else
            {
              /* Changes should be applied on next frame */
              bitmap.viewport.changed |= 2;
            }

            /* Clear HVC latched value */
            hvc_latch = 0;

            /* Check if HVC latch bit is set */
            if (reg[0] & 0x02)
            {
              /* Latch current HVC */
              hvc_latch = vdp_hvc_r(cycles) | 0x10000;
            }

            /* max tiles to invalidate */
            bg_list_index = 0x800;
          }
          else
          {
            /* Mode 4 rendering */
            parse_satb = &parse_satb_m4;
            update_bg_pattern_cache = &update_bg_pattern_cache_m4;
            render_bg = &render_bg_m4;
            render_obj = &render_obj_m4;

            /* Reset color palette */
            for (i = 0; i < 0x20; i++)
            {
              color_update_m4(i, *cast(u16 *)&cram[i << 1]);
            }
            color_update_m4(0x40, *cast(u16 *)&cram[(0x10 | (border & 0x0F)) << 1]);

            /* Mode 4 bus access */
            vdp_68k_data_w = &vdp_68k_data_w_m4;
            vdp_z80_data_w = &vdp_z80_data_w_m4;
            vdp_68k_data_r = &vdp_68k_data_r_m4;
            vdp_z80_data_r = &vdp_z80_data_r_m4;

            if (v_counter < bitmap.viewport.h)
            {
              /* Update active display height */
              bitmap.viewport.h = 192;
              bitmap.viewport.y = (config.overscan & 1) * 24 * (vdp_pal + 1);
            }
            else
            {
              /* Changes should be applied on next frame */
              bitmap.viewport.changed |= 2;
            }

            /* Latch current HVC */
            hvc_latch = vdp_hvc_r(cycles) | 0x10000;

            /* max tiles to invalidate */
            bg_list_index = 0x200;
          }

          /* Invalidate pattern cache */
          for (i=0;i<bg_list_index;i++) 
          {
            bg_name_list[i] = cast(u16) i;
            bg_name_dirty[i] = 0xFF;
          }

          /* Update vertical counter max value */
          vc_max = vc_table[(d >> 2) & 3][vdp_pal];
        }
        else
        {
          /* No effect (cleared to avoid mode 5 detection elsewhere) */
          reg[1] &= ~0x04;
        }
      }
      break;
    }

    case 2: /* Plane A Name Table Base */
    {
      reg[2] = cast(u8) d;
      ntab = (d << 10) & 0xE000;

      /* Plane A Name Table Base changed during HBLANK */
      if ((v_counter < bitmap.viewport.h) && (reg[1] & 0x40) && (cycles <= (mcycles_vdp + 860)))
      {
        /* render entire line */
        render_line(v_counter);
      }
      break;
    }

    case 3: /* Window Plane Name Table Base */
    {
      reg[3] = cast(u8) d;
      if (reg[12] & 0x01)
      {
        ntwb = (d << 10) & 0xF000;
      }
      else
      {
        ntwb = (d << 10) & 0xF800;
      }

      /* Window Plane Name Table Base changed during HBLANK */
      if ((v_counter < bitmap.viewport.h) && (reg[1] & 0x40) && (cycles <= (mcycles_vdp + 860)))
      {
        /* render entire line */
        render_line(v_counter);
      }
      break;
    }

    case 4: /* Plane B Name Table Base */
    {
      reg[4] = cast(u8) d;
      ntbb = (d << 13) & 0xE000;

      /* Plane B Name Table Base changed during HBLANK (Adventures of Batman & Robin) */
      if ((v_counter < bitmap.viewport.h) && (reg[1] & 0x40) && (cycles <= (mcycles_vdp + 860)))
      {
        /* render entire line */
        render_line(v_counter);
      }

      break;
    }

    case 5: /* Sprite Attribute Table Base */
    {
      reg[5] = cast(u8) d;
      satb = (d << 9) & sat_base_mask;
      break;
    }

    case 7: /* Backdrop color */
    {
      reg[7] = cast(u8) d;

      /* Check if backdrop color changed */
      d &= 0x3F;

      if (d != border)
      {
        /* Update backdrop color */
        border = cast(u8) d;

        /* Reset palette entry */
        if (reg[1] & 4)
        {
          /* Mode 5 */
          color_update_m5(0x00, *cast(u16 *)&cram[d << 1]);
        }
        else
        {
          /* Mode 4 */
          color_update_m4(0x40, *cast(u16 *)&cram[(0x10 | (d & 0x0F)) << 1]);
        }

        /* Backdrop color modified during HBLANK (Road Rash 1,2,3)*/
        if ((v_counter < bitmap.viewport.h) && (cycles <= (mcycles_vdp + 860)))
        {
          /* remap entire line */
          remap_line(v_counter);
        }
      }
      break;
    }

    case 8:   /* Horizontal Scroll (Mode 4 only) */
    {
      int line;
      
      /* Hscroll is latched at HCount 0xF3, HCount 0xF6 on MD */
      /* Line starts at HCount 0xF4, HCount 0xF6 on MD */
      if (system_hw < SYSTEM_MD)
      {
        cycles = cycles + 15;
      }

      /* Make sure Hscroll has not already been latched */
      line = (lines_per_frame + (cycles / MCYCLES_PER_LINE) - 1) % lines_per_frame;
      if ((line > v_counter) && (line < bitmap.viewport.h) && !(work_ram[0x1ffb] & md_cart.cart.special))
      {
        v_counter = cast(u16) line;
        render_line(line);
      }

      reg[8] = cast(u8) d;
      break;
    }

    case 11:  /* CTRL #3 */
    {
      reg[11] = cast(u8) d;

      /* Horizontal scrolling mode */
      hscroll_mask = hscroll_mask_table[d & 0x03];

      /* Vertical Scrolling mode */
      if (d & 0x04)
      {
        render_bg = &im2_flag ? &render_bg_m5_im2_vs : &render_bg_m5_vs;
      }
      else
      {
        render_bg = &im2_flag ? &render_bg_m5_im2 : &render_bg_m5;
      }
      break;
    }

    case 12:  /* CTRL #4 */
    {
      /* Look for changed bits */
      r = d ^ reg[12];
      reg[12] = cast(u8) d;

      /* Shadow & Highlight mode */
      if (r & 0x08)
      {
        /* Reset color palette */
        int i;
        color_update_m5(0x00, *cast(u16 *)&cram[border << 1]);
        for (i = 1; i < 0x40; i++)
        {
          color_update_m5(i, *cast(u16 *)&cram[i << 1]);
        }

        /* Update sprite rendering function */
        if (d & 0x08)
        {
          render_obj = &im2_flag ? &render_obj_m5_im2_ste : &render_obj_m5_ste;
        }
        else
        {
          render_obj = &im2_flag ? &render_obj_m5_im2 : &render_obj_m5;
        }
      }

      /* Interlaced modes */
      if (r & 0x06)
      {
        /* changes should be applied on next frame */
        bitmap.viewport.changed |= 2;
      }

      /* Active display width */
      if (r & 0x01)
      {
        if (d & 0x01)
        {
          /* Update display-dependant registers */
          ntwb = (reg[3] << 10) & 0xF000;
          satb = (reg[5] << 9) & 0xFC00;
          sat_base_mask = 0xFC00;
          sat_addr_mask = 0x03FF;

          /* Update HC table */
          hctab = cast(ubyte[]) cycle2hc40;

          /* Update clipping */
          window_clip(reg[17], 1);

          /* Update fifo timings */
          fifo_latency = 190;
        }
        else
        {
          /* Update display-dependant registers */
          ntwb = (reg[3] << 10) & 0xF800;
          satb = (reg[5] << 9) & 0xFE00;
          sat_base_mask = 0xFE00;
          sat_addr_mask = 0x01FF;

          /* Update HC table */
          hctab = cast(ubyte[]) cycle2hc32;

          /* Update clipping */
          window_clip(reg[17], 0);

          /* Update FIFO timings */
          fifo_latency = 214;
        }

        /* Adjust FIFO timings for VRAM writes */
        fifo_latency <<= ((code & 0x0F) < 0x03);

        /* Active display width modified during HBLANK (Bugs Bunny Double Trouble) */
        if ((v_counter < bitmap.viewport.h) && (cycles <= (mcycles_vdp + 860)))
        {
          /* Update active display width */
          bitmap.viewport.w = 256 + ((d & 1) << 6);

          /* Redraw entire line */
          render_line(v_counter);
        }
        else
        {
          /* Changes should be applied on next frame (Golden Axe III intro) */
          /* NB: This is not 100% accurate but is required by GCN/Wii port (GX texture direct mapping) */
          /* and isn't noticeable anyway since display is generally disabled when active width is modified */
          bitmap.viewport.changed |= 2;
        }
      }
      break;
    }

    case 13: /* HScroll Base Address */
    {
      reg[13] = cast(u8) d;
      hscb = (d << 10) & 0xFC00;
      break;
    }

    case 16: /* Playfield size */
    {
      reg[16] = cast(u8) d;
      playfield_shift = shift_table[(d & 3)];
      playfield_col_mask = col_mask_table[(d & 3)];
      playfield_row_mask = row_mask_table[(d >> 4) & 3];
      break;
    }

    case 17: /* Window/Plane A vertical clipping */
    {
      reg[17] = cast(u8) d;
      window_clip(d, reg[12] & 1);
      break;
    }

    default:
    {
      reg[r] = cast(u8) d;
      break;
    }
  }
}


/*--------------------------------------------------------------------------*/
/* FIFO update function (Genesis mode only)                                 */
/*--------------------------------------------------------------------------*/

static void vdp_fifo_update(u32 cycles)
{
  if (fifo_write_cnt > 0)
  {
    /* Get number of FIFO reads */
    int fifo_read = ((cycles - fifo_lastwrite) / fifo_latency);

    if (fifo_read > 0)
    {
      /* Process FIFO entries */
      fifo_write_cnt -= fifo_read;

      /* Clear FIFO full flag */
      status &= 0xFEFF;

      /* Check remaining FIFO entries */
      if (fifo_write_cnt <= 0)
      {
        /* Set FIFO empty flag */
        status |= 0x200; 
        fifo_write_cnt = 0;
      }

      /* Update FIFO cycle count */
      fifo_lastwrite += (fifo_read * fifo_latency);
    }
  }
}


/*--------------------------------------------------------------------------*/
/* Internal 16-bit data bus access function (Mode 5 only)                   */
/*--------------------------------------------------------------------------*/

static void vdp_bus_w(u32 data)
{
  /* Check destination code */
  switch (code & 0x0F)
  {
    case 0x01:  /* VRAM */
    {
      /* VRAM address */
      int index = addr & 0xFFFE;

      /* Pointer to VRAM */
      u16 *p = cast(u16 *)&vram[index];

      /* Byte-swap data if A0 is set */
      if (addr & 1)
      {
        data = ((data >> 8) | (data << 8)) & 0xFFFF;
      }

      /* Intercept writes to Sprite Attribute Table */
      if ((index & sat_base_mask) == satb)
      {
        /* Update internal SAT */
        *cast(u16 *) &sat[index & sat_addr_mask] = cast(u16) data;
      }

      /* Only write unique data to VRAM */
      if (data != *p)
      {
        int name;

        /* Write data to VRAM */
        *p = cast(u16) data;

        /* Update pattern cache */
        MARK_BG_DIRTY (index, name);
      }

version(LOGVDP) {
      error("[%d(%d)][%d(%d)] VRAM 0x%x write -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    case 0x03:  /* CRAM */
    {
      /* Pointer to CRAM 9-bit word */
      u16 *p = cast(u16 *)&cram[addr & 0x7E];

      /* Pack 16-bit bus data (BBB0GGG0RRR0) to 9-bit CRAM data (BBBGGGRRR) */
      data = ((data & 0xE00) >> 3) | ((data & 0x0E0) >> 2) | ((data & 0x00E) >> 1);

      /* Check if CRAM data is being modified */
      if (data != *p)
      {
        /* CRAM index (64 words) */
        int index = (addr >> 1) & 0x3F;

        /* Write CRAM data */
        *p = cast(u16) data;

        /* Color entry 0 of each palette is never displayed (transparent pixel) */
        if (index & 0x0F)
        {
          /* Update color palette */
          color_update_m5(index, data);
        }

        /* Update backdrop color */
        if (index == border)
        {
          color_update_m5(0x00, data);
        }

        /* CRAM modified during HBLANK (Striker, Zero the Kamikaze, etc) */
        if ((v_counter < bitmap.viewport.h) && (reg[1]& 0x40) && (m68k.cycles <= (mcycles_vdp + 860)))
        {
          /* Remap current line */
          remap_line(v_counter);
        }
      }
version(LOGVDP) {
      error("[%d(%d)][%d(%d)] CRAM 0x%x write -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    case 0x05:  /* VSRAM */
    {
      *cast(u16 *)&vsram[addr & 0x7E] = cast(u16) data;

      /* 2-cell Vscroll mode */
      if (reg[11] & 0x04)
      {
        /* VSRAM writes during HBLANK (Adventures of Batman & Robin) */
        if ((v_counter < bitmap.viewport.h) && (reg[1]& 0x40) && (m68k.cycles <= (mcycles_vdp + 860)))
        {
          /* Remap current line */
          render_line(v_counter);
        }
      }
version(LOGVDP) {
      error("[%d(%d)][%d(%d)] VSRAM 0x%x write -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    default:
    {
version(LOGERROR) {
      error("[%d(%d)][%d(%d)] Invalid (%d) 0x%x write -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, code, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }
  }

  /* Increment address register */
  addr += reg[15];
}


/*--------------------------------------------------------------------------*/
/* 68k data port access functions (Genesis mode)                            */
/*--------------------------------------------------------------------------*/

static void vdp_68k_data_w_m4(u32 data)
{
  /* Clear pending flag */
  pending = 0;

  /* Restricted VDP writes during active display */
  if (!(status & 8) && (reg[1] & 0x40))
  {
    /* Update VDP FIFO */
    vdp_fifo_update(m68k.cycles);

    /* Clear FIFO empty flag */
    status &= 0xFDFF;

    /* up to 4 words can be stored */
    if (fifo_write_cnt < 4)
    {
      /* Increment FIFO counter */
      fifo_write_cnt++;

      /* Set FIFO full flag if 4 words are stored */
      status |= ((fifo_write_cnt & 4) << 6);
    }
    else
    {
      /* CPU is halted until last FIFO entry has been processed (Chaos Engine, Soldiers of Fortune, Double Clutch) */
      fifo_lastwrite += fifo_latency;
      m68k.cycles = fifo_lastwrite;
    }
  }

  /* Check destination code */
  if (code & 0x02)
  {
    /* CRAM index (32 words) */
    int index = addr & 0x1F;

    /* Pointer to CRAM 9-bit word */
    u16 *p = cast(u16 *)&cram[index << 1];

    /* Pack 16-bit data (xxx000BBGGRR) to 9-bit CRAM data (xxxBBGGRR) */
    data = ((data & 0xE00) >> 3) | (data & 0x3F);

    /* Check if CRAM data is being modified */
    if (data != *p)
    {
      /* Write CRAM data */
      *p = cast(u16) data;

      /* Update color palette */
      color_update_m4(index, data);

      /* Update backdrop color */
      if (index == (0x10 | (border & 0x0F)))
      {
        color_update_m4(0x40, data);
      }
    }
  }
  else
  {
    /* VRAM address (interleaved format) */
    int index = ((addr << 1) & 0x3FC) | ((addr & 0x200) >> 8) | (addr & 0x3C00);

    /* Pointer to VRAM */
    u16 *p = cast(u16 *)&vram[index];

    /* Byte-swap data if A0 is set */
    if (addr & 1)
    {
      data = ((data >> 8) | (data << 8)) & 0xFFFF;
    }

    /* Only write unique data to VRAM */
    if (data != *p)
    {
      int name;

      /* Write data to VRAM */
      *p = cast(u16) data;

      /* Update the pattern cache */
      MARK_BG_DIRTY (index, name);
    }
  }

  /* Increment address register (TODO: check how address is incremented in Mode 4) */
  addr += (reg[15] + 1);
}

static void vdp_68k_data_w_m5(u32 data)
{
  /* Clear pending flag */
  pending = 0;

  /* Restricted VDP writes during active display */
  if (!(status & 8) && (reg[1] & 0x40))
  {
    /* Update VDP FIFO */
    vdp_fifo_update(m68k.cycles);

    /* Clear FIFO empty flag */
    status &= 0xFDFF;

    /* up to 4 words can be stored */
    if (fifo_write_cnt < 4)
    {
      /* Increment FIFO counter */
      fifo_write_cnt++;

      /* Set FIFO full flag if 4 words are stored */
      status |= ((fifo_write_cnt & 4) << 6);
    }
    else
    {
      /* CPU is halted until last FIFO entry has been processed (Chaos Engine, Soldiers of Fortune, Double Clutch) */
      fifo_lastwrite += fifo_latency;
      m68k.cycles = fifo_lastwrite;
    }
  }
  
  /* Write data */
  vdp_bus_w(data);

  /* DMA Fill */
  if (dmafill & 0x100)
  {
    /* Fill data = MSB (DMA fill flag is cleared) */
    dmafill = cast(u16) data >> 8;

    /* DMA length */
    dma_length = (reg[20] << 8) | reg[19];

    /* Zero DMA length */
    if (!dma_length)
    {
      dma_length = 0x10000;
    }

    /* Process DMA Fill*/
    dma_type = 2;
    vdp_dma_update(m68k.cycles);
  }
}

static u32 vdp_68k_data_r_m4()
{
  /* VRAM address (interleaved format) */
  int index = ((addr << 1) & 0x3FC) | ((addr & 0x200) >> 8) | (addr & 0x3C00);

  /* Clear pending flag */
  pending = 0;

  /* Increment address register (TODO: check how address is incremented in Mode 4) */
  addr += (reg[15] + 1);

  /* Read VRAM data */
  return *cast(u16 *) &vram[index];
}

static u32 vdp_68k_data_r_m5()
{
  u16 data = 0;

  /* Clear pending flag */
  pending = 0;

  switch (code & 0x0F)
  {
    case 0x00: /* VRAM */
    {
      /* Read data */
      data = *cast(u16 *)&vram[addr & 0xFFFE];

version(LOGVDP) {
      error("[%d(%d)][%d(%d)] VRAM 0x%x read -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    case 0x04: /* VSRAM */
    {
      /* Read data */
      data = *cast(u16 *)&vsram[addr & 0x7E];

version(LOGVDP) {
      error("[%d(%d)][%d(%d)] VSRAM 0x%x read -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    case 0x08: /* CRAM */
    {
      /* Read data */
      data = *cast(u16 *)&cram[addr & 0x7E];

      /* Unpack 9-bit CRAM data (BBBGGGRRR) to 16-bit bus data (BBB0GGG0RRR0) */
      data = ((data & 0x1C0) << 3) | ((data & 0x038) << 2) | ((data & 0x007) << 1);

version(LOGVDP) {
      error("[%d(%d)][%d(%d)] CRAM 0x%x read -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    case 0x0c: /* undocumented 8-bit VRAM read (cf. http://gendev.spritesmind.net/forum/viewtopic.php?t=790) */
    {
      /* Read data (MSB forced to zero) */
      data = *cast(u16 *)&vram[addr & 0xFFFE] & 0xff;

version(LOGVDP) {
      error("[%d(%d)][%d(%d)] 8-bit VRAM 0x%x read -> 0x%x (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, addr, data, m68k_get_reg(M68K_REG_PC));
}
      break;
    }

    default:
    {
      /* Invalid code value */
version(LOGERROR) {
      error("[%d(%d)][%d(%d)] Invalid (%d) 0x%x read (%x)\n", v_counter, m68k.cycles/MCYCLES_PER_LINE-1, m68k.cycles, m68k.cycles%MCYCLES_PER_LINE, code, addr, m68k_get_reg(M68K_REG_PC));
}
      break;
    }
  }

  /* Increment address register */
  addr += reg[15];

  /* Return data */
  return data;
}


/*--------------------------------------------------------------------------*/
/* Z80 data port access functions (Master System compatibility mode)        */
/*--------------------------------------------------------------------------*/

static void vdp_z80_data_w_m4(u32 data)
{
  /* Clear pending flag */
  pending = 0;

  /* Check destination code */
  if (code & 0x02)
  {
    /* CRAM index (32 words) */
    int index = addr & 0x1F;

    /* Pointer to CRAM word */
    u16 *p = cast(u16 *)&cram[index << 1];

    /* Check if CRAM data is being modified */
    if (data != *p)
    {
      /* Write CRAM data */
      *p = cast(u16) data;

      /* Update color palette */
      color_update_m4(index, data);

      /* Update backdrop color */
      if (index == (0x10 | (border & 0x0F)))
      {
        color_update_m4(0x40, data);
      }
    }
  }
  else
  {
    /* VRAM address */
    int index = addr & 0x3FFF;

    /* Only write unique data to VRAM */
    if (data != vram[index])
    {
      int name;

      /* Write data */
      vram[index] = cast(u8) data;

      /* Update pattern cache */
      MARK_BG_DIRTY(index, name);
    }
  }

  /* Increment address register (TODO: check how address is incremented in Mode 4) */
  addr += (reg[15] + 1);
}

static void vdp_z80_data_w_m5(u32 data)
{
  /* Clear pending flag */
  pending = 0;

  /* Check destination code */
  switch (code & 0x0F)
  {
    case 0x01:  /* VRAM */
    {
      /* VRAM address (write low byte to even address & high byte to odd address) */
      int index = addr ^ 1;

      /* Intercept writes to Sprite Attribute Table */
      if ((index & sat_base_mask) == satb)
      {
        /* Update internal SAT */
        WRITE_BYTE(sat, index & sat_addr_mask, cast(u8) data);
      }

      /* Only write unique data to VRAM */
      if (data != READ_BYTE(vram, index))
      {
        int name;

        /* Write data */
        WRITE_BYTE(vram, index, cast(u8) data);

        /* Update pattern cache */
        MARK_BG_DIRTY (index, name);
      }
      break;
    }

    case 0x03:  /* CRAM */
    {
      /* Pointer to CRAM word */
      u16 *p = cast(u16 *)&cram[addr & 0x7E];

      /* Pack 8-bit value into 9-bit CRAM data */
      if (addr & 1)
      {
        /* Write high byte (0000BBB0 -> BBBxxxxxx) */
        data = (*p & 0x3F) | ((data & 0x0E) << 5);
      }
      else
      {
        /* Write low byte (GGG0RRR0 -> xxxGGGRRR) */
        data = (*p & 0x1C0) | ((data & 0x0E) >> 1)| ((data & 0xE0) >> 2);
      }

      /* Check if CRAM data is being modified */
      if (data != *p)
      {
        /* CRAM index (64 words) */
        int index = (addr >> 1) & 0x3F;

        /* Write CRAM data */
        *p = cast(u8) data;

        /* Color entry 0 of each palette is never displayed (transparent pixel) */
        if (index & 0x0F)
        {
          /* Update color palette */
          color_update_m5(index, data);
        }

        /* Update backdrop color */
        if (index == border)
        {
          color_update_m5(0x00, data);
        }
      }
      break;
    }

    case 0x05: /* VSRAM */
    {
      /* Write low byte to even address & high byte to odd address */
      WRITE_BYTE(vsram, (addr & 0x7F) ^ 1, cast(u8) data);
      break;
    }

    default:
    {
        throw new Exception("Case default unexpected.");
    }
  }

  /* Increment address register  */
  addr += reg[15];

  /* DMA Fill */
  if (dmafill & 0x100)
  {
    /* Fill data (DMA fill flag is cleared) */
    dmafill = cast(u16) data;

    /* DMA length */
    dma_length = (reg[20] << 8) | reg[19];

    /* Zero DMA length */
    if (!dma_length)
    {
      dma_length = 0x10000;
    }

    /* Process DMA Fill */
    dma_type = 2;
    vdp_dma_update(Z80.cycles);
  }
}

static u32 vdp_z80_data_r_m4()
{
  /* Read buffer */
  u32 data = fifo[0];

  /* Clear pending flag */
  pending = 0;

  /* Process next read */
  fifo[0] = vram[addr & 0x3FFF];

  /* Increment address register (TODO: check how address is incremented in Mode 4) */
  addr += (reg[15] + 1);

  /* Return data */
  return data;
}

static u32 vdp_z80_data_r_m5()
{
  u32 data = 0;

  /* Clear pending flag */
  pending = 0;

  switch (code & 0x0F)
  {
    case 0x00: /* VRAM */
    {
      /* Return low byte from even address & high byte from odd address */
      data = READ_BYTE(vram, addr ^ 1);
      break;
    }

    case 0x04: /* VSRAM */
    {
      /* Return low byte from even address & high byte from odd address */
      data = READ_BYTE(vsram, (addr & 0x7F) ^ 1);
      break;
    }

    case 0x08: /* CRAM */
    {
      /* Read CRAM data */
      data = *cast(u16 *)&cram[addr & 0x7E];

      /* Unpack 9-bit CRAM data (BBBGGGRRR) to 16-bit data (BBB0GGG0RRR0) */
      data = ((data & 0x1C0) << 3) | ((data & 0x038) << 2) | ((data & 0x007) << 1);

      /* Return low byte from even address & high byte from odd address */
      if (addr & 1)
      {
        data = data >> 8;
      }

      data &= 0xFF;
      break;
    }
    default:
    {
        throw new Exception("Case default unexpected.");
    }
  }

  /* Increment address register */
  addr += reg[15];

  /* Return data */
  return data;
}


/*-----------------------------------------------------------------------------*/
/* VDP specific data port access functions (Master System, Game Gear, SG-1000) */
/*-----------------------------------------------------------------------------*/

static void vdp_z80_data_w_ms(u32 data)
{
  /* Clear pending flag */
  pending = 0;

  if (code < 3)
  {
    int index;

    /* check if we are already on next line */
    int line = (lines_per_frame + (Z80.cycles / MCYCLES_PER_LINE) - 1) % lines_per_frame;
    if ((line > v_counter) && (line < bitmap.viewport.h) && !(work_ram[0x1ffb] & md_cart.cart.special))
    {
      v_counter = cast(u16) line;
      render_line(line);
    }

    /* VRAM address */
    index = addr & 0x3FFF;

    /* VRAM write */
    if (data != vram[index])
    {
      int name;
      vram[index] = cast(u8) data;
      MARK_BG_DIRTY(index, name);
    }

version(LOGVDP) {
    error("[%d(%d)][%d(%d)] VRAM 0x%x write -> 0x%x (%x)\n", v_counter, Z80.cycles/MCYCLES_PER_LINE-1, Z80.cycles, Z80.cycles%MCYCLES_PER_LINE, index, data, Z80.pc.w.l);
}
  }
  else
  {
    /* CRAM address */
    int index = addr & 0x1F;

    /* Pointer to CRAM word */
    u16 *p = cast(u16 *)&cram[index << 1];

    /* Check if CRAM data is being modified */
    if (data != *p)
    {
      /* Write CRAM data */
      *p = cast(u16) data;

      /* Update color palette */
      color_update_m4(index, data);

      /* Update backdrop color */
      if (index == (0x10 | (border & 0x0F)))
      {
        color_update_m4(0x40, data);
      }
    }
version(LOGVDP) {
    error("[%d(%d)][%d(%d)] CRAM 0x%x write -> 0x%x (%x)\n", v_counter, Z80.cycles/MCYCLES_PER_LINE-1, Z80.cycles, Z80.cycles%MCYCLES_PER_LINE, addr, data, Z80.pc.w.l);
}
  }

  /* Update read buffer */
  fifo[0] = cast(u16) data;

  /* Update address register */
  addr++;
}

static void vdp_z80_data_w_gg(u32 data)
{
  /* Clear pending flag */
  pending = 0;

  if (code < 3)
  {
    int index;

    /* check if we are already on next line*/
    int line = (lines_per_frame + (Z80.cycles / MCYCLES_PER_LINE) - 1) % lines_per_frame;
    if ((line > v_counter) && (line < bitmap.viewport.h) && !(work_ram[0x1ffb] & md_cart.cart.special))
    {
      v_counter = cast(u16) line;
      render_line(line);
    }

    /* VRAM address */
    index = addr & 0x3FFF;

    /* VRAM write */
    if (data != vram[index])
    {
      int name;
      vram[index] = cast(u8) data;
      MARK_BG_DIRTY(index, name);
    }
version(LOGVDP) {
    error("[%d(%d)][%d(%d)] VRAM 0x%x write -> 0x%x (%x)\n", v_counter, Z80.cycles/MCYCLES_PER_LINE-1, Z80.cycles, Z80.cycles%MCYCLES_PER_LINE, index, data, Z80.pc.w.l);
}
  }
  else
  {
    if (addr & 1)
    {
      /* Pointer to CRAM word */
      u16 *p = cast(u16 *)&cram[addr & 0x3E];

      /* 12-bit data word */
      data = (data << 8) | cached_write;

      /* Check if CRAM data is being modified */
      if (data != *p)
      {
        /* Color index (0-31) */
        int index = (addr >> 1) & 0x1F;
        
        /* Write CRAM data */
        *p = cast(u16) data;

        /* Update color palette */
        color_update_m4(index, data);

        /* Update backdrop color */
        if (index == (0x10 | (border & 0x0F)))
        {
          color_update_m4(0x40, data);
        }
      }
    }
    else
    {
      /* Latch LSB */
      cached_write = data;
    }
version(LOGVDP) {
    error("[%d(%d)][%d(%d)] CRAM 0x%x write -> 0x%x (%x)\n", v_counter, Z80.cycles/MCYCLES_PER_LINE-1, Z80.cycles, Z80.cycles%MCYCLES_PER_LINE, addr, data, Z80.pc.w.l);
}
  }

  /* Update read buffer */
  fifo[0] = cast(u16) data;

  /* Update address register */
  addr++;
}

static void vdp_z80_data_w_sg(u32 data)
{
  /* VRAM address */
  int index = addr & 0x3FFF;

  /* Clear pending flag */
  pending = 0;

  /* 4K address decoding (cf. tms9918a.txt) */
  if (!(reg[1] & 0x80))
  {
    index = (index & 0x203F) | ((index >> 6) & 0x40) | ((index << 1) & 0x1F80);
  }

  /* VRAM write */
  vram[index] = cast(u8) data;

  /* Update address register */
  addr++;

version(LOGVDP) {
  error("[%d(%d)][%d(%d)] VRAM 0x%x write -> 0x%x (%x)\n", v_counter, Z80.cycles/MCYCLES_PER_LINE-1, Z80.cycles, Z80.cycles%MCYCLES_PER_LINE, index, data, Z80.pc.w.l);
}
}

/*--------------------------------------------------------------------------*/
/* DMA operations                                                           */
/*--------------------------------------------------------------------------*/

/* DMA from 68K bus: $000000-$7FFFFF (external area) */
static void vdp_dma_68k_ext(u32 length)
{
  u16 data;

  /* 68k bus source address */
  u32 source = (reg[23] << 17) | (dma_src << 1);

  do
  {
    /* Read data word from 68k bus */
    if (m68k.memory_map[source>>16].read16)
    {
      data = cast(u16) m68k.memory_map[source>>16].read16(source);
    }
    else
    {
      data = (cast(u16[])(m68k.memory_map[source>>16].base[(source & 0xFFFF) .. $]))[0];
    }
 
    /* Increment source address */
    source += 2;

    /* 128k DMA window */
    source = (reg[23] << 17) | (source & 0x1FFFF);

    /* Write data word to VRAM, CRAM or VSRAM */
    vdp_bus_w(data);
  }
  while (--length);

  /* Update DMA source address */
  dma_src = (source >> 1) & 0xffff;
}

/* DMA from 68K bus: $800000-$FFFFFF (internal area) except I/O area */
static void vdp_dma_68k_ram(u32 length)
{
  u16 data;

  /* 68k bus source address */
  u32 source = (reg[23] << 17) | (dma_src << 1);

  do
  {
    /* access Work-RAM by default  */
    data = (cast(u16[])(work_ram[(source & 0xFFFF) .. $]))[0];
   
    /* Increment source address */
    source += 2;

    /* 128k DMA window */
    source = (reg[23] << 17) | (source & 0x1FFFF);

    /* Write data word to VRAM, CRAM or VSRAM */
    vdp_bus_w(data);
  }
  while (--length);

  /* Update DMA source address */
  dma_src = (source >> 1) & 0xffff;
}

/* DMA from 68K bus: $A00000-$A1FFFF (I/O area) specific */
static void vdp_dma_68k_io(u32 length)
{
  u16 data;

  /* 68k bus source address */
  u32 source = (reg[23] << 17) | (dma_src << 1);

  do
  {
    /* Z80 area */
    if (source <= 0xA0FFFF)
    {
      /* Return $FFFF only when the Z80 isn't hogging the Z-bus.
      (e.g. Z80 isn't reset and 68000 has the bus) */
      if(zstate ^ 3)
          data = (cast(u16[])(work_ram[(source & 0xFFFF) .. $]))[0];
      else
          data =  0xFFFF;
    }

    /* The I/O chip and work RAM try to drive the data bus which results 
       in both values being combined in random ways when read.
       We return the I/O chip values which seem to have precedence, */
    else if (source <= 0xA1001F)
    {
      data = cast(u16) io_68k_read((source >> 1) & 0x0F);
      data = cast(u16) (data << 8 | data);
    }

    /* All remaining locations access work RAM */
    else
    {
      data = (cast(u16[])(work_ram[(source & 0xFFFF) .. $]))[0];
    }

    /* Increment source address */
    source += 2;

    /* 128k DMA window */
    source = (reg[23] << 17) | (source & 0x1FFFF);

    /* Write data to VRAM, CRAM or VSRAM */
    vdp_bus_w(data);
  }
  while (--length);

  /* Update DMA source address */
  dma_src = (source >> 1) & 0xffff;
}

/*  VRAM Copy (TODO: check if CRAM or VSRAM copy is possible) */
static void vdp_dma_copy(u32 length)
{
  /* VRAM read/write operation only */
  if ((code & 0x1E) == 0x10)
  {
    int name;
    u8 data;
    
    /* VRAM source address */
    u16 source = dma_src;

    do
    {
      /* Read byte from source address */
      data = READ_BYTE(vram, source);

      /* Intercept writes to Sprite Attribute Table */
      if ((addr & sat_base_mask) == satb)
      {
        /* Update internal SAT */
        WRITE_BYTE(sat, addr & sat_addr_mask, data);
      }

      /* Write byte to VRAM address */
      WRITE_BYTE(vram, addr, data);

      /* Update pattern cache */
      MARK_BG_DIRTY(addr, name);

      /* Increment source address */
      source++;

      /* Increment VRAM address */
      addr += reg[15];
    }
    while (--length);

    /* Update DMA source address */
    dma_src = source;
  }
}

/* VRAM Fill (TODO: check if CRAM or VSRAM fill is possible) */
static void vdp_dma_fill(u32 length)
{
  /* VRAM write operation only (Williams Greatest Hits after soft reset) */
  if ((code & 0x1F) == 0x01)
  {
    int name;
    u8 data = cast(u8) dmafill;

    do
    {
      /* Intercept writes to Sprite Attribute Table */
      if ((addr & sat_base_mask) == satb)
      {
        /* Update internal SAT */
        WRITE_BYTE(sat, (addr & sat_addr_mask) ^ 1, data);
      }

      /* Write byte to adjacent VRAM address */
      WRITE_BYTE(vram, addr ^ 1, data);

      /* Update pattern cache */
      MARK_BG_DIRTY (addr, name);

      /* Increment VRAM address */
      addr += reg[15];
    }
    while (--length);
  }
}
