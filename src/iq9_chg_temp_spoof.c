// SPDX-License-Identifier: GPL-2.0-only
/*
 * bq_pwr_aux - iQOO 9 (V2171A / PD2171, kernel 5.10.233-gki) charging
 * temperature spoof LKM.
 *
 * The vivo charging stack (vivo_chg_cms) computes its charging limits from
 * several temperatures, all of which are read through small pointer-output
 * getters:
 *
 *   cms_get_primary_board_temp(cms, int *out)    board NTC (0.1 C)
 *   cms_get_parallel_board_temp(cms, int *out)   parallel board NTC
 *   cms_get_usb_conn_temp(cms, int *out)         USB connector NTC
 *   cms_get_usb_conn1_temp(cms, int *out)        USB connector NTC #2
 *   cms_get_batt_therm(cms, int *out)            battery thermistor
 *   cms_get_batt_therm1(cms, int *out)           battery thermistor #2
 *
 * All of them store the value through the second argument (0.1 C units,
 * default 250 = 25.0 C when the source is unavailable), so a kretprobe
 * rewrites *out after the call returns.
 *
 * The battery/FG temperature exposed through power_supply "battery/temp",
 * the "battery"/"bq_bms" thermal zones and the framework UI is spoofed by
 * writing the vivo factory knob /sys/class/cms_class/fixed_temp (userspace
 * setup does that when spoofing is enabled; the value 0 restores the real
 * reading).  The thermal_zone_get_temp kretprobe additionally covers the
 * configured thermal zones regardless of that knob.
 *
 * Stm32 MCU (vivo_chg_mcu) temperatures such as bat_conn_temp /
 * master_bat_conn_temp / bat_board_temp are consumed by the inlined
 * cms_get_bat_btb_therm_m path that cannot be probed directly, so the
 * single ADC->temperature converter stm32l011_temp_from_voltage is hooked
 * instead (func_mask bit7): every MCU NTC channel is rewritten before it
 * reaches the cms property cache and the stm32_debug sysfs nodes.
 *
 * action bit0 enables spoofing, bit1 enables kernel log sampling.
 * func_mask / zone_mask enable each hook individually (decimal or 0x-hex).
 *
 * Kernel CFI note: this kernel is built with the old (pre-KCFI) Clang CFI.
 * The module loader resolves "__cfi_check" inside each module and uses it to
 * validate every CFI-checked indirect call into the module (kretprobe
 * handlers, module init/exit, module parameters).  This module exports a
 * pass-through __cfi_check stub so a plain (non-LTO/non-CFI) build stays
 * callable.
 */

#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/ptrace.h>

#ifdef IQ9_CHG_TEMP_SPOOF_GENERATED_VERSIONS
#include "iq9_chg_temp_spoof_versions.h"
#endif

#define LOG_EVERY 64u

/* struct thermal_zone_device: int id; char type[THERMAL_NAME_LENGTH]; */
#define TZD_TYPE_OFF 4u

static unsigned int action = 1;
static unsigned int func_mask = 0x7fu;
static unsigned int zone_mask = 0x000fu;
static int zone_tgt_mc = 36000;
static int cms_tgt_x10 = 360;
static int mcu_tgt_x10 = 360;

static unsigned int zone_hits;
static unsigned int cms_hits;
static unsigned int mcu_conv_hits;
static unsigned int n32_hits;
static unsigned int n32_seen_mask;
static int n32_tgt_x10 = 360;
static unsigned int n32_prop_mask;
/* Actual kernel address of the running copy of stm32_db_mcu_get_property.
 * Several loaded modules carry that symbol name; lookup by name picks the
 * first one in module list order, which is not necessarily the active MCU
 * driver (vivo_chg_mcu_hvdb).  Userspace reads the address from
 * /proc/kallsyms (with kptr_restrict temporarily lowered) and passes it at
 * load time; 0 falls back to name-based registration. */
static unsigned long n32_addr;
static unsigned int cms_kind_hits[8];
static int real_mcu_conv_x10 = -1;
static int real_cms_x10[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };
static int real_zone_mc[16] = {
	-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
};
static unsigned int zone_kind_hits[16];
static bool enabled;

/* ------------------------------------------------------------------ */
/* CFI pass-through stub                                              */
/* ------------------------------------------------------------------ */
/* The kernel calls this for indirect calls into this module.  Returning
 * without trapping approves the call. */
void __cfi_check(uint64_t id, void *ptr, void *diag)
{
}
/* Keep the symbol referenced so the linker never drops it. */
static void *const __used __cfi_check_keep = (void *)__cfi_check;

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */
static int parse_uint(const char *val, unsigned int *out)
{
	unsigned int v = 0;
	const char *p = val;

	if (!val || !*val)
		return -EINVAL;
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		p += 2;
		if (!*p)
			return -EINVAL;
		while (*p) {
			unsigned int d;

			if (*p >= '0' && *p <= '9')
				d = (unsigned int)(*p - '0');
			else if (*p >= 'a' && *p <= 'f')
				d = (unsigned int)(*p - 'a' + 10);
			else if (*p >= 'A' && *p <= 'F')
				d = (unsigned int)(*p - 'A' + 10);
			else
				break;
			v = (v << 4) | d;
			p++;
		}
	} else {
		while (*p >= '0' && *p <= '9') {
			unsigned int d = (unsigned int)(*p - '0');

			if (v > (0xffffffffu - d) / 10u)
				return -EINVAL;
			v = v * 10u + d;
			p++;
		}
	}
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	if (*p != '\0')
		return -EINVAL;
	*out = v;
	return 0;
}

static int parse_int(const char *val, int *out)
{
	int sign = 1;
	unsigned int v = 0;
	const char *p = val;

	if (!val || !*val)
		return -EINVAL;
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	if (*p == '-') {
		sign = -1;
		p++;
	} else if (*p == '+') {
		p++;
	}
	while (*p >= '0' && *p <= '9') {
		unsigned int d = (unsigned int)(*p - '0');

		if (v > (0x7fffffffu - d) / 10u)
			return -EINVAL;
		v = v * 10u + d;
		p++;
	}
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	if (*p != '\0')
		return -EINVAL;
	*out = (int)(sign * (int)v);
	return 0;
}

static int parse_ulong(const char *val, unsigned long *out)
{
	unsigned long v = 0;
	const char *p = val;

	if (!val || !*val)
		return -EINVAL;
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		p += 2;
		if (!*p)
			return -EINVAL;
		while (*p) {
			unsigned long d;

			if (*p >= '0' && *p <= '9')
				d = (unsigned long)(*p - '0');
			else if (*p >= 'a' && *p <= 'f')
				d = (unsigned long)(*p - 'a' + 10);
			else if (*p >= 'A' && *p <= 'F')
				d = (unsigned long)(*p - 'A' + 10);
			else
				break;
			v = (v << 4) | d;
			p++;
		}
	} else {
		while (*p >= '0' && *p <= '9') {
			unsigned long d = (unsigned long)(*p - '0');

			if (v > (~0UL - d) / 10UL)
				return -EINVAL;
			v = v * 10UL + d;
			p++;
		}
	}
	while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		p++;
	if (*p != '\0')
		return -EINVAL;
	*out = v;
	return 0;
}

static int set_action(const char *val, const struct kernel_param *kp)
{
	unsigned int v;
	int ret;

	ret = parse_uint(val, &v);
	if (ret)
		return ret;
	WRITE_ONCE(action, v);
	WRITE_ONCE(enabled, (v & 1u) != 0);
	pr_info("aux: action=%u enabled=%d\n", v, READ_ONCE(enabled) ? 1 : 0);
	return 0;
}

static int get_uint_param(char *buf, const struct kernel_param *kp)
{
	return snprintf(buf, PAGE_SIZE, "%u\n", *(unsigned int *)kp->arg);
}

static int get_int_param(char *buf, const struct kernel_param *kp)
{
	return snprintf(buf, PAGE_SIZE, "%d\n", *(int *)kp->arg);
}

/* Custom ops for every parameter: the built-in param_ops_int/param_ops_uint
 * symbols would need modversion CRCs that no vendor module carries here. */
static int set_uint_generic(const char *val, const struct kernel_param *kp)
{
	unsigned int v;
	int ret;

	ret = parse_uint(val, &v);
	if (ret)
		return ret;
	WRITE_ONCE(*(unsigned int *)kp->arg, v);
	return 0;
}

static int set_int_generic(const char *val, const struct kernel_param *kp)
{
	int v;
	int ret;

	ret = parse_int(val, &v);
	if (ret)
		return ret;
	WRITE_ONCE(*(int *)kp->arg, v);
	return 0;
}

static const struct kernel_param_ops uint_ops = {
	.set = set_action,
	.get = get_uint_param,
};

static const struct kernel_param_ops uint_rw_ops = {
	.set = set_uint_generic,
	.get = get_uint_param,
};

static const struct kernel_param_ops int_rw_ops = {
	.set = set_int_generic,
	.get = get_int_param,
};

static const struct kernel_param_ops uint_ro_ops = {
	.get = get_uint_param,
};

static const struct kernel_param_ops int_ro_ops = {
	.get = get_int_param,
};

static int set_ulong_generic(const char *val, const struct kernel_param *kp)
{
	unsigned long v;
	int ret;

	ret = parse_ulong(val, &v);
	if (ret)
		return ret;
	WRITE_ONCE(*(unsigned long *)kp->arg, v);
	return 0;
}

static int get_ulong_param(char *buf, const struct kernel_param *kp)
{
	return snprintf(buf, PAGE_SIZE, "0x%lx\n", *(unsigned long *)kp->arg);
}

static const struct kernel_param_ops ulong_rw_ops = {
	.set = set_ulong_generic,
	.get = get_ulong_param,
};

static const struct kernel_param_ops ulong_ro_ops = {
	.get = get_ulong_param,
};

module_param_cb(action, &uint_ops, &action, 0644);
module_param_cb(func_mask, &uint_rw_ops, &func_mask, 0644);
module_param_cb(zone_mask, &uint_rw_ops, &zone_mask, 0644);
module_param_cb(zone_tgt_mc, &int_rw_ops, &zone_tgt_mc, 0644);
module_param_cb(cms_tgt_x10, &int_rw_ops, &cms_tgt_x10, 0644);
module_param_cb(mcu_tgt_x10, &int_rw_ops, &mcu_tgt_x10, 0644);
module_param_cb(n32_tgt_x10, &int_rw_ops, &n32_tgt_x10, 0644);
module_param_cb(n32_prop_mask, &uint_rw_ops, &n32_prop_mask, 0644);
module_param_cb(n32_addr, &ulong_rw_ops, &n32_addr, 0644);
module_param_cb(cms_hits, &uint_ro_ops, &cms_hits, 0444);
module_param_cb(zone_hits, &uint_ro_ops, &zone_hits, 0444);
module_param_cb(mcu_conv_hits, &uint_ro_ops, &mcu_conv_hits, 0444);
module_param_cb(n32_hits, &uint_ro_ops, &n32_hits, 0444);
module_param_cb(n32_seen_mask, &uint_ro_ops, &n32_seen_mask, 0444);
module_param_cb(real_mcu_conv_x10, &int_ro_ops, &real_mcu_conv_x10, 0444);

module_param_cb(real_cms_primary_board_x10, &int_ro_ops,
		&real_cms_x10[0], 0444);
module_param_cb(real_cms_parallel_board_x10, &int_ro_ops,
		&real_cms_x10[1], 0444);
module_param_cb(real_cms_usb_conn_x10, &int_ro_ops,
		&real_cms_x10[2], 0444);
module_param_cb(real_cms_usb_conn1_x10, &int_ro_ops,
		&real_cms_x10[3], 0444);
module_param_cb(real_cms_batt_therm_x10, &int_ro_ops,
		&real_cms_x10[4], 0444);
module_param_cb(real_cms_batt_therm1_x10, &int_ro_ops,
		&real_cms_x10[5], 0444);

/* ------------------------------------------------------------------ */
/* cms pointer-output getters                                         */
/* ------------------------------------------------------------------ */
enum cms_kind {
	CMS_PRIMARY_BOARD,
	CMS_PARALLEL_BOARD,
	CMS_USB_CONN,
	CMS_USB_CONN1,
	CMS_BATT_THERM,
	CMS_BATT_THERM1,
	CMS_KIND_COUNT,
};

/* func_mask bits: bit0 = thermal zones, bit(1+kind) = cms getter,
 * bit7 = stm32 L011 MCU temp conversion (stm32l011_temp_from_voltage),
 * bit8 = N32 MCU psy property rewrite (stm32_db_mcu_get_property). */
enum func_bit {
	FUNC_ZONE = 0,
	FUNC_CMS_BASE = 1,
	FUNC_MCU_CONV = 7,
	FUNC_N32_PROP = 8,
};

struct cms_ctx {
	int *out;
	unsigned int kind;
};

static int cms_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cms_ctx *c = (struct cms_ctx *)ri->data;
	int *out = c->out;
	unsigned int kind = c->kind;
	int real;
	int target = READ_ONCE(cms_tgt_x10);

	if (!out || kind >= CMS_KIND_COUNT)
		return 0;
	real = READ_ONCE(*out);
	WRITE_ONCE(real_cms_x10[kind], real);

	if (!READ_ONCE(enabled) || target <= 0)
		return 0;
	if (!(READ_ONCE(func_mask) & (1u << (FUNC_CMS_BASE + kind))))
		return 0;

	WRITE_ONCE(*out, target);
	WRITE_ONCE(cms_hits, READ_ONCE(cms_hits) + 1u);
	{
		unsigned int hits = READ_ONCE(cms_kind_hits[kind]) + 1u;

		WRITE_ONCE(cms_kind_hits[kind], hits);
		if ((READ_ONCE(action) & 2u) && (hits % LOG_EVERY) == 0u)
			pr_info("aux: cms kind%u real=%d out=%d hits=%u\n",
				kind, real, target, hits);
	}
	return 0;
}

#define CMS_ENTRY_FN(idx)						\
static int cms_entry_##idx(struct kretprobe_instance *ri,		\
			   struct pt_regs *regs)			\
{									\
	struct cms_ctx *c = (struct cms_ctx *)ri->data;			\
									\
	c->out = (int *)regs->regs[1];					\
	c->kind = idx;							\
	return 0;							\
}

CMS_ENTRY_FN(0)
CMS_ENTRY_FN(1)
CMS_ENTRY_FN(2)
CMS_ENTRY_FN(3)
CMS_ENTRY_FN(4)
CMS_ENTRY_FN(5)

/* ------------------------------------------------------------------ */
/* thermal zone hook                                                  */
/* ------------------------------------------------------------------ */
static const char *const zone_kind_names[] = {
	"battery",
	"bq_bms",
	"usb",
	"conn-therm",
	"quiet_therm",
	"camera-therm",
	"rear-cam-therm",
	"wifi-therm-usr",
	"xo-therm",
	"5g-pa-therm-usr",
	"4g-pa-therm-usr",
	"pm8350_tz",
	"pm8350c_tz",
	"pm8350b_tz",
	"pmr735a_tz",
	"pm8450_tz",
};
#define ZONE_COUNT 16

enum zone_bit {
	ZONE_BATTERY = 0,
	ZONE_BQ_BMS,
	ZONE_USB,
	ZONE_CONN,
	ZONE_QUIET,
	ZONE_CAMERA,
	ZONE_REAR_CAM,
	ZONE_WIFI,
	ZONE_XO,
	ZONE_PA5G,
	ZONE_PA4G,
	ZONE_PM8350,
	ZONE_PM8350C,
	ZONE_PM8350B,
	ZONE_PMR735A,
	ZONE_PM8450,
};

struct zone_ctx {
	unsigned long tz;
	unsigned long temp;
};

static int zone_kind_from_type(const char *type)
{
	unsigned int k;

	if (!type)
		return -1;
	for (k = 0; k < ZONE_COUNT; k++) {
		const char *want = zone_kind_names[k];
		unsigned int i;

		for (i = 0; i < 20u && want[i] && type[i]; i++) {
			if (type[i] != want[i])
				break;
		}
		if (want[i] != '\0' || type[i] != '\0')
			continue;
		return (int)k;
	}
	return -1;
}

static int zone_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct zone_ctx *c = (struct zone_ctx *)ri->data;

	c->tz = regs->regs[0];
	c->temp = regs->regs[1];
	return 0;
}

static int zone_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct zone_ctx *c = (struct zone_ctx *)ri->data;
	const char *type = (const char *)(c->tz + TZD_TYPE_OFF);
	int *temp = (int *)c->temp;
	int target = READ_ONCE(zone_tgt_mc);
	int kind;
	int real;

	if (!c->tz || !temp)
		return 0;
	kind = zone_kind_from_type(type);
	if (kind < 0)
		return 0;

	real = READ_ONCE(*temp);
	WRITE_ONCE(real_zone_mc[kind], real);

	if (!READ_ONCE(enabled) || target <= 0)
		return 0;
	if (!(READ_ONCE(func_mask) & (1u << FUNC_ZONE)))
		return 0;
	if (!(READ_ONCE(zone_mask) & (1u << kind)))
		return 0;

	WRITE_ONCE(*temp, target);
	WRITE_ONCE(zone_hits, READ_ONCE(zone_hits) + 1u);
	{
		unsigned int hits = READ_ONCE(zone_kind_hits[kind]) + 1u;

		WRITE_ONCE(zone_kind_hits[kind], hits);
		if ((READ_ONCE(action) & 2u) && (hits % LOG_EVERY) == 0u)
			pr_info("aux: zone %s real=%d out=%d hits=%u\n",
				zone_kind_names[kind], real, target, hits);
	}
	return 0;
}

/* read-only zone params */
#define ZONE_RO_PARAM(pname, idx) \
	module_param_cb(pname, &int_ro_ops, &real_zone_mc[idx], 0444)

ZONE_RO_PARAM(real_zone_battery_mc, ZONE_BATTERY);
ZONE_RO_PARAM(real_zone_bq_bms_mc, ZONE_BQ_BMS);
ZONE_RO_PARAM(real_zone_usb_mc, ZONE_USB);
ZONE_RO_PARAM(real_zone_conn_mc, ZONE_CONN);
ZONE_RO_PARAM(real_zone_quiet_mc, ZONE_QUIET);
ZONE_RO_PARAM(real_zone_camera_mc, ZONE_CAMERA);
ZONE_RO_PARAM(real_zone_rear_cam_mc, ZONE_REAR_CAM);
ZONE_RO_PARAM(real_zone_wifi_mc, ZONE_WIFI);
ZONE_RO_PARAM(real_zone_xo_mc, ZONE_XO);
ZONE_RO_PARAM(real_zone_pa5g_mc, ZONE_PA5G);

/* ------------------------------------------------------------------ */
/* probes                                                             */
/* ------------------------------------------------------------------ */
static struct kretprobe zone_probe = {
	.kp = { .symbol_name = "thermal_zone_get_temp" },
	.entry_handler = zone_entry,
	.handler = zone_ret,
	.data_size = sizeof(struct zone_ctx),
	.maxactive = 32,
};

/* ------------------------------------------------------------------ */
/* stm32 MCU temperature conversion                                   */
/* ------------------------------------------------------------------ */
/* stm32l011_temp_from_voltage(ctx, adc_value, channel) is the single
 * ADC->temperature conversion used by the vivo_chg_mcu driver for every
 * MCU NTC channel (bat/connector/sub-board temps).  Rewriting its return
 * value covers the get_property props that the inlined
 * cms_get_bat_btb_therm_m consumes (bat_conn_temp / master_bat_conn_temp /
 * bat_board_temp) as well as the stm32_debug sysfs nodes. */
static int mcu_conv_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	int real = (int)regs->regs[0];
	int target = READ_ONCE(mcu_tgt_x10);

	WRITE_ONCE(real_mcu_conv_x10, real);

	if (!READ_ONCE(enabled) || target <= 0)
		return 0;
	if (!(READ_ONCE(func_mask) & (1u << FUNC_MCU_CONV)))
		return 0;

	regs->regs[0] = (unsigned long)(long)target;
	{
		unsigned int hits = READ_ONCE(mcu_conv_hits) + 1u;

		WRITE_ONCE(mcu_conv_hits, hits);
		if ((READ_ONCE(action) & 2u) && (hits % LOG_EVERY) == 0u)
			pr_info("aux: mcu conv real=%d out=%d hits=%u\n",
				real, target, hits);
	}
	return 0;
}

static struct kretprobe mcu_conv_probe = {
	.kp = { .symbol_name = "stm32l011_temp_from_voltage" },
	.handler = mcu_conv_ret,
	.data_size = 0,
	.maxactive = 16,
};

/* ------------------------------------------------------------------ */
/* vivo_chg_mcu_N32_hvdb MCU psy get_property                         */
/* ------------------------------------------------------------------ */
/* The N32 MCU driver (the active one on this device) serves every
 * temperature through stm32_db_mcu_get_property(psy, psp, val).
 * Properties 0xc0..0xcf carry the vivo charging temperature group
 * (0xc0/0xc1 are the USB connector temps read by cms_get_usb_conn_temp).
 * n32_prop_mask selects which of those 16 properties is rewritten; with
 * action bit1 set, the first read of every property is logged together
 * with its value (n32_seen_mask tracks which were seen) so the
 * temperature properties can be identified from dmesg. */
#define N32_PROP_BASE 0xc0u
#define N32_PROP_COUNT 16u

struct n32_ctx {
	unsigned int psp;
	unsigned long val;
};

static int n32_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct n32_ctx *c = (struct n32_ctx *)ri->data;

	c->psp = (unsigned int)regs->regs[1];
	c->val = regs->regs[2];
	return 0;
}

static int n32_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct n32_ctx *c = (struct n32_ctx *)ri->data;
	int *val = (int *)c->val;
	unsigned int psp = c->psp;
	unsigned int bit;
	int real;
	int target = READ_ONCE(n32_tgt_x10);

	/* only successful property reads carry a valid value */
	if (!val || (int)regs->regs[0] != 0)
		return 0;
	if (psp < N32_PROP_BASE || psp >= N32_PROP_BASE + N32_PROP_COUNT)
		return 0;
	bit = psp - N32_PROP_BASE;

	real = READ_ONCE(*val);

	/* discovery mode: log the first read of each property once */
	if (READ_ONCE(action) & 2u) {
		unsigned int seen = READ_ONCE(n32_seen_mask);

		if (!(seen & (1u << bit))) {
			WRITE_ONCE(n32_seen_mask, seen | (1u << bit));
			pr_info("aux: n32 prop=0x%x first=%d\n", psp, real);
		}
	}

	if (!READ_ONCE(enabled) || target <= 0)
		return 0;
	if (!(READ_ONCE(func_mask) & (1u << FUNC_N32_PROP)))
		return 0;
	if (!(READ_ONCE(n32_prop_mask) & (1u << bit)))
		return 0;

	WRITE_ONCE(*val, target);
	{
		unsigned int hits = READ_ONCE(n32_hits) + 1u;

		WRITE_ONCE(n32_hits, hits);
		if ((READ_ONCE(action) & 2u) && (hits % LOG_EVERY) == 0u)
			pr_info("aux: n32 prop=0x%x real=%d out=%d hits=%u\n",
				psp, real, target, hits);
	}
	return 0;
}

static struct kretprobe n32_prop_probe = {
	.kp = { .symbol_name = "stm32_db_mcu_get_property" },
	.entry_handler = n32_entry,
	.handler = n32_ret,
	.data_size = sizeof(struct n32_ctx),
	.maxactive = 16,
};

/* ------------------------------------------------------------------ */
/* charging-limit observation probes (read-only)                      */
/* ------------------------------------------------------------------ */
/* These probes exist purely to READ what the vivo charge stack
 * computes; they never rewrite arguments or return values, so the
 * charge behaviour is unchanged.  Values land in the obs_* module
 * parameters so the real current/SOC limits can be sampled while the
 * phone is fast-charging (see scripts / WebUI workflow).
 *
 *   charge_get_chg_up_limit_keep_soc [vivo_chg_cms]
 *       SOC up-limit used by the keep-soc machinery.
 *   cms_get_step_charge_current [vivo_chg_cms]
 *       step (temperature based) charge current selection.
 *   cms_check_fastchg_current [vivo_chg_cms]
 *       fast-charge current gate/check.
 *
 * x0..x2 at entry and x0 at return are captured verbatim; the exact
 * calling convention is decoded from the values themselves. */
#define OBS_COUNT 3

struct obs_rec {
	unsigned int hits;
	unsigned long obj;
	unsigned long a1;
	unsigned long a2;
	int ret;
};

static struct obs_rec obs_recs[OBS_COUNT];

struct obs_ctx {
	unsigned long obj;
	unsigned long a1;
	unsigned long a2;
	unsigned int idx;
};

#define OBS_ENTRY_FN(n)							\
static int obs_entry_##n(struct kretprobe_instance *ri,			\
			 struct pt_regs *regs)				\
{									\
	struct obs_ctx *c = (struct obs_ctx *)ri->data;			\
									\
	c->obj = regs->regs[0];						\
	c->a1  = regs->regs[1];						\
	c->a2  = regs->regs[2];						\
	c->idx = n;							\
	return 0;							\
}

OBS_ENTRY_FN(0)
OBS_ENTRY_FN(1)
OBS_ENTRY_FN(2)

static int obs_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct obs_ctx *c = (struct obs_ctx *)ri->data;
	struct obs_rec *o;
	unsigned int hits;

	if (!c || c->idx >= OBS_COUNT)
		return 0;
	o = &obs_recs[c->idx];

	WRITE_ONCE(o->obj, c->obj);
	WRITE_ONCE(o->a1,  c->a1);
	WRITE_ONCE(o->a2,  c->a2);
	WRITE_ONCE(o->ret, (int)regs->regs[0]);

	hits = READ_ONCE(o->hits) + 1u;
	WRITE_ONCE(o->hits, hits);
	if ((READ_ONCE(action) & 2u) && (hits <= 3u || (hits % LOG_EVERY) == 0u))
		pr_info("aux: obs%u obj=%lx a1=%lx a2=%lx ret=%d hits=%u\n",
			c->idx, c->obj, c->a1, c->a2,
			(int)regs->regs[0], hits);
	return 0;
}

static struct kretprobe obs_rps[OBS_COUNT] = {
	{ .kp = { .symbol_name = "charge_get_chg_up_limit_keep_soc" },
	  .entry_handler = obs_entry_0, .handler = obs_ret,
	  .data_size = sizeof(struct obs_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_get_step_charge_current" },
	  .entry_handler = obs_entry_1, .handler = obs_ret,
	  .data_size = sizeof(struct obs_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_check_fastchg_current" },
	  .entry_handler = obs_entry_2, .handler = obs_ret,
	  .data_size = sizeof(struct obs_ctx), .maxactive = 16 },
};

#define OBS_RO_PARAM(name, field, idx, ops) \
	module_param_cb(name, &ops, &obs_recs[idx].field, 0444)

OBS_RO_PARAM(obs_up_limit_ret,  ret,  0, int_ro_ops);
OBS_RO_PARAM(obs_up_limit_obj,  obj,  0, ulong_ro_ops);
OBS_RO_PARAM(obs_up_limit_a1,   a1,   0, ulong_ro_ops);
OBS_RO_PARAM(obs_up_limit_a2,   a2,   0, ulong_ro_ops);
OBS_RO_PARAM(obs_up_limit_hits, hits, 0, uint_ro_ops);

OBS_RO_PARAM(obs_step_curr_ret,  ret,  1, int_ro_ops);
OBS_RO_PARAM(obs_step_curr_obj,  obj,  1, ulong_ro_ops);
OBS_RO_PARAM(obs_step_curr_a1,   a1,   1, ulong_ro_ops);
OBS_RO_PARAM(obs_step_curr_a2,   a2,   1, ulong_ro_ops);
OBS_RO_PARAM(obs_step_curr_hits, hits, 1, uint_ro_ops);

OBS_RO_PARAM(obs_chk_fastchg_ret,  ret,  2, int_ro_ops);
OBS_RO_PARAM(obs_chk_fastchg_obj,  obj,  2, ulong_ro_ops);
OBS_RO_PARAM(obs_chk_fastchg_a1,   a1,   2, ulong_ro_ops);
OBS_RO_PARAM(obs_chk_fastchg_a2,   a2,   2, ulong_ro_ops);
OBS_RO_PARAM(obs_chk_fastchg_hits, hits, 2, uint_ro_ops);

static struct kretprobe cms_rps[CMS_KIND_COUNT] = {
	{ .kp = { .symbol_name = "cms_get_primary_board_temp" },
	  .entry_handler = cms_entry_0, .handler = cms_ret,
	  .data_size = sizeof(struct cms_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_get_parallel_board_temp" },
	  .entry_handler = cms_entry_1, .handler = cms_ret,
	  .data_size = sizeof(struct cms_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_get_usb_conn_temp" },
	  .entry_handler = cms_entry_2, .handler = cms_ret,
	  .data_size = sizeof(struct cms_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_get_usb_conn1_temp" },
	  .entry_handler = cms_entry_3, .handler = cms_ret,
	  .data_size = sizeof(struct cms_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_get_batt_therm" },
	  .entry_handler = cms_entry_4, .handler = cms_ret,
	  .data_size = sizeof(struct cms_ctx), .maxactive = 16 },
	{ .kp = { .symbol_name = "cms_get_batt_therm1" },
	  .entry_handler = cms_entry_5, .handler = cms_ret,
	  .data_size = sizeof(struct cms_ctx), .maxactive = 16 },
};

/* NOTE: must have external linkage so clang emits a BTI landing pad
 * ("bti c"); the kernel calls mod->init through the function pointer with
 * CONFIG_ARM64_BTI_KERNEL=y.  Same for the exit function below. */
int iq9_spoof_init(void)
{
	unsigned int i;
	int ret;
	int registered = 0;

	WRITE_ONCE(enabled, (READ_ONCE(action) & 1u) != 0);

	ret = register_kretprobe(&zone_probe);
	if (ret) {
		pr_warn("aux: zone probe register failed: %d\n", ret);
		zone_probe.kp.symbol_name = NULL;
	} else {
		registered++;
		pr_info("aux: probe thermal_zone_get_temp ok\n");
	}

	ret = register_kretprobe(&mcu_conv_probe);
	if (ret) {
		pr_warn("aux: mcu conv probe register failed: %d\n", ret);
		mcu_conv_probe.kp.symbol_name = NULL;
	} else {
		registered++;
		pr_info("aux: probe stm32l011_temp_from_voltage ok\n");
	}

	if (READ_ONCE(n32_addr)) {
		n32_prop_probe.kp.symbol_name = NULL;
		n32_prop_probe.kp.addr =
			(kprobe_opcode_t *)READ_ONCE(n32_addr);
	}
	ret = register_kretprobe(&n32_prop_probe);
	if (ret && READ_ONCE(n32_addr)) {
		/* caller-supplied address rejected: fall back to name lookup */
		n32_prop_probe.kp.addr = NULL;
		n32_prop_probe.kp.symbol_name = "stm32_db_mcu_get_property";
		pr_warn("aux: n32 addr probe failed (%d), retry by name\n",
			ret);
		ret = register_kretprobe(&n32_prop_probe);
	}
	if (ret) {
		pr_warn("aux: n32 prop probe register failed: %d\n", ret);
		n32_prop_probe.kp.symbol_name = NULL;
		n32_prop_probe.kp.addr = NULL;
	} else {
		registered++;
		pr_info("aux: probe stm32_db_mcu_get_property ok (%s)\n",
			READ_ONCE(n32_addr) ? "by addr" : "by name");
	}

	for (i = 0; i < CMS_KIND_COUNT; i++) {
		struct kretprobe *rp = &cms_rps[i];

		ret = register_kretprobe(rp);
		if (ret) {
			pr_warn("aux: probe %s failed: %d\n",
				rp->kp.symbol_name, ret);
			rp->kp.symbol_name = NULL;
			continue;
		}
		registered++;
		pr_info("aux: probe %s ok\n", rp->kp.symbol_name);
	}

	for (i = 0; i < OBS_COUNT; i++) {
		struct kretprobe *rp = &obs_rps[i];

		ret = register_kretprobe(rp);
		if (ret) {
			pr_warn("aux: obs probe %s failed: %d\n",
				rp->kp.symbol_name, ret);
			rp->kp.symbol_name = NULL;
			continue;
		}
		registered++;
		pr_info("aux: obs probe %s ok\n", rp->kp.symbol_name);
	}

	pr_info("aux: ready registered=%d/%d action=%u func_mask=0x%x zone_mask=0x%x zone_tgt=%d cms_tgt=%d mcu_tgt=%d\n",
		registered, CMS_KIND_COUNT + OBS_COUNT + 3, READ_ONCE(action),
		READ_ONCE(func_mask), READ_ONCE(zone_mask),
		READ_ONCE(zone_tgt_mc), READ_ONCE(cms_tgt_x10),
		READ_ONCE(mcu_tgt_x10));
	return 0;
}

void iq9_spoof_exit(void)
{
	unsigned int i;

	if (zone_probe.kp.symbol_name) {
		unregister_kretprobe(&zone_probe);
		zone_probe.kp.symbol_name = NULL;
	}
	if (mcu_conv_probe.kp.symbol_name) {
		unregister_kretprobe(&mcu_conv_probe);
		mcu_conv_probe.kp.symbol_name = NULL;
	}
	if (n32_prop_probe.kp.symbol_name || n32_prop_probe.kp.addr) {
		unregister_kretprobe(&n32_prop_probe);
		n32_prop_probe.kp.symbol_name = NULL;
		n32_prop_probe.kp.addr = NULL;
	}
	for (i = 0; i < CMS_KIND_COUNT; i++) {
		if (cms_rps[i].kp.symbol_name) {
			unregister_kretprobe(&cms_rps[i]);
			cms_rps[i].kp.symbol_name = NULL;
		}
	}
	for (i = 0; i < OBS_COUNT; i++) {
		if (obs_rps[i].kp.symbol_name) {
			unregister_kretprobe(&obs_rps[i]);
			obs_rps[i].kp.symbol_name = NULL;
		}
	}
	pr_info("aux: removed zone_hits=%u cms_hits=%u\n",
		READ_ONCE(zone_hits), READ_ONCE(cms_hits));
}

module_init(iq9_spoof_init);
module_exit(iq9_spoof_exit);

MODULE_LICENSE("GPL");
MODULE_VERSION("0.3.0");
MODULE_DESCRIPTION("iQOO 9 charging temperature spoof");
#ifdef IQ9_CHG_TEMP_SPOOF_GENERATED_VERSIONS
MODULE_INFO(vermagic, IQ9_CHG_TEMP_SPOOF_VERMAGIC);
#endif