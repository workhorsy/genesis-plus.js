
import types;

/* ======================================================================== */
/* ======================== MAIN 68K CONFIGURATION ======================== */
/* ======================================================================== */

/* Configuration switches.
 * Use OPT_SPECIFY_HANDLER for configuration options that allow callbacks.
 * OPT_SPECIFY_HANDLER causes the core to link directly to the function
 * or macro you specify, rather than using callback functions whose pointer
 * must be passed in using m68k_set_xxx_callback().
 */
const int OPT_OFF             = 0;
const int OPT_ON              = 1;
const int OPT_SPECIFY_HANDLER = 2;

/* If ON, CPU will call the interrupt acknowledge callback when it services an
 * interrupt.
 * If off, all interrupts will be autovectored and all interrupt requests will
 * auto-clear when the interrupt is serviced.
 */
static s32 M68K_INT_ACK_CALLBACK(s32 A) { return vdp_68k_irq_ack(A); }

/* If ON, CPU will call the callback when it encounters a tas
 * instruction.
 */
alias OPT_OFF M68K_TAS_HAS_CALLBACK;
void M68K_TAS_CALLBACK() { your_tas_handler_function(); }

/* If ON, the CPU will generate address error exceptions if it tries to
 * access a word or longword at an odd address.
 * NOTE: This is only emulated properly for 68000 mode.
 */
alias OPT_ON M68K_EMULATE_ADDRESS_ERROR;




