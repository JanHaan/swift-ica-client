#include "CMachBootstrap.h"
#include <servers/bootstrap.h>

kern_return_t cmb_check_in(const char *name, mach_port_t *receive) {
    return bootstrap_check_in(bootstrap_port, name, receive);
}

kern_return_t cmb_look_up(const char *name, mach_port_t *send) {
    return bootstrap_look_up(bootstrap_port, name, send);
}
