#ifndef CMACHBOOTSTRAP_H
#define CMACHBOOTSTRAP_H

#include <mach/mach.h>

// <servers/bootstrap.h> is not visible from Swift; these wrap the two calls the helper rendezvous
// needs (docs/99 §4). Both use the task's bootstrap port.

/// Registers `name` in the caller's bootstrap namespace and returns its receive right.
kern_return_t cmb_check_in(const char *name, mach_port_t *receive);

/// Looks up `name` and returns a send right to it.
kern_return_t cmb_look_up(const char *name, mach_port_t *send);

#endif
