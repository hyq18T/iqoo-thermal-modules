#include <linux/module.h>
struct module __this_module
__section(".gnu.linkonce.this_module") = {
    .name = "bq_pwr_aux",
    .init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
    .exit = cleanup_module,
#endif
    .arch = MODULE_ARCH_INIT,
};
MODULE_INFO(name, "bq_pwr_aux");
