/***************************************************************************************
 *  Genesis Plus
 *  3-Buttons & 6-Buttons pad support
 *  Support for J-CART & 4-Way Play adapters
 *
 *  Copyright (C) 2007-2011  Eke-Eke (Genesis Plus GX)
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

struct gamepad_t
{
  u8 State;
  u8 Counter;
  u8 Timeout;
}

static gamepad_t[MAX_DEVICES] gamepad;
static u8 pad_index;


void gamepad_reset(int port)
{
  /* default state (Gouketsuji Ichizoku / Power Instinct, Samurai Spirits / Samurai Shodown) */
  gamepad[port].State = 0x40;
  gamepad[port].Counter = 0;
  gamepad[port].Timeout = 0;

  /* reset pad index (4-WayPlay) */
  pad_index = 0;
}

void gamepad_refresh(int port)
{
  /* 6-buttons pad */
  if (gamepad[port].Timeout++ > 25)
  {
    gamepad[port].Counter = 0;
    gamepad[port].Timeout = 0;
  }
}

u8 gamepad_read(int port)
{
  /* bit 7 is latched, returns current TH state */
  u32 data = (gamepad[port].State & 0x40) | 0x3F;

  /* pad value */
  u32 val = input.pad[port];

  /* get current step (TH state) */
  u32 step = gamepad[port].Counter | ((data >> 6) & 1);

  switch (step)
  {
    case 1: /*** First High  ***/
    case 3: /*** Second High ***/
    case 5: /*** Third High  ***/
    {
      /* TH = 1 : ?1CBRLDU */
      data &= ~(val & 0x3F);
      break;
    }

    case 0: /*** First low  ***/
    case 2: /*** Second low ***/
    {
      /* TH = 0 : ?0SA00DU */
      data &= ~(val & 0x03);
      data &= ~((val >> 2) & 0x30);
      data &= ~0x0C;
      break;
    }

    /* 6buttons specific (taken from gen-hw.txt) */
    /* A 6-button gamepad allows the extra buttons to be read based on how */
    /* many times TH is switched from 1 to 0 (and not 0 to 1). Observe the */
    /* following sequence */
    /*
       TH = 1 : ?1CBRLDU    3-button pad return value
       TH = 0 : ?0SA00DU    3-button pad return value
       TH = 1 : ?1CBRLDU    3-button pad return value
       TH = 0 : ?0SA0000    D3-0 are forced to '0'
       TH = 1 : ?1CBMXYZ    Extra buttons returned in D3-0
       TH = 0 : ?0SA1111    D3-0 are forced to '1'
    */
    case 4: /*** Third Low ***/
    {
      /* TH = 0 : ?0SA0000    D3-0 are forced to '0'*/
      data &= ~((val >> 2) & 0x30);
      data &= ~0x0F;
      break;
    }

    case 6: /*** Fourth Low ***/
    {
      /* TH = 0 : ?0SA1111    D3-0 are forced to '1'*/
      data &= ~((val >> 2) & 0x30);
      break;
    }

    case 7: /*** Fourth High ***/
    {
      /* TH = 1 : ?1CBMXYZ    Extra buttons returned in D3-0*/
      data &= ~(val & 0x30);
      data &= ~((val >> 8) & 0x0F);
      break;
    }
  }

  return data;
}

void gamepad_write(int port, u8 data, u8 mask)
{
  /* update bits set as output only */
  data = (gamepad[port].State & ~mask) | (data & mask);

  if (input.dev[port] == DEVICE_PAD6B)
  {
    /* TH=0 to TH=1 transition */
    if (!(gamepad[port].State & 0x40) && (data & 0x40))
    {
      gamepad[port].Counter = (gamepad[port].Counter + 2) & 6;
      gamepad[port].Timeout = 0;
    }
  }

  /* update internal state */
  gamepad[port].State = data;
}


/*--------------------------------------------------------------------------*/
/*  Default ports handlers                                                  */
/*--------------------------------------------------------------------------*/

u8 gamepad_1_read()
{
  return gamepad_read(0);
}

u8 gamepad_2_read()
{
  return gamepad_read(4);
}

void gamepad_1_write(u8 data, u8 mask)
{
  gamepad_write(0, data, mask);
}

void gamepad_2_write(u8 data, u8 mask)
{
  gamepad_write(4, data, mask);
}

/*--------------------------------------------------------------------------*/
/*  4-WayPlay ports handler                                                 */
/*--------------------------------------------------------------------------*/

u8 wayplay_1_read()
{
  if (pad_index < 4)
  {
    return gamepad_read(pad_index);
  }

  /* multitap detection */
  return 0x70;
}

u8 wayplay_2_read()
{
  return 0x7F;
}

void wayplay_1_write(u8 data, u8 mask)
{
  if (pad_index < 4)
  {
    gamepad_write(pad_index, data, mask);
  }
}

void wayplay_2_write(u8 data, u8 mask)
{
  if ((mask & 0x70) == 0x70)
  {
    pad_index = (data & 0x70) >> 4;
  }
}


/*--------------------------------------------------------------------------*/
/*  J-Cart memory handlers                                                  */
/*--------------------------------------------------------------------------*/

u32 jcart_read(u32 address)
{
	assert(address == address);
   /* TH2 output read is fixed to zero (fixes Micro Machines 2) */
   return ((gamepad_read(5) & 0x7F) | ((gamepad_read(6) & 0x3F) << 8));
}

void jcart_write(u32 address, u32 data)
{
	assert(address == address);
  gamepad_write(5, (data & 1) << 6, 0x40);
  gamepad_write(6, (data & 1) << 6, 0x40);
  return;
}
