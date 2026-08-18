#ifndef BOBRWHISPER_APPLE_SDK_MATH_H
#define BOBRWHISPER_APPLE_SDK_MATH_H

// Continue header lookup after this compatibility directory so the selected
// Xcode SDK still supplies the real math declarations.
#include_next <math.h>

// Xcode 27's math.h expects Clang's float.h to define these when requested
// with __need_infinity_nan. Zig 0.16's bundled float.h predates that protocol.
#ifndef INFINITY
#define INFINITY (__builtin_inff())
#endif

#ifndef NAN
#define NAN (__builtin_nanf(""))
#endif

#endif
