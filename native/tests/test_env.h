/* native/tests/test_env.h
 *
 * setenv and unsetenv are POSIX and are not provided by the Windows C
 * runtime, so tests that drive behaviour through the environment need
 * this to build there. _putenv_s with an empty value removes a
 * variable, which is what unsetenv does.
 */
#ifndef TTIO_TEST_ENV_H
#define TTIO_TEST_ENV_H

#include <stdlib.h>

#ifdef _WIN32
static inline int test_setenv(const char *k, const char *v) {
    return _putenv_s(k, v);
}
static inline int test_unsetenv(const char *k) {
    return _putenv_s(k, "");
}
#else
static inline int test_setenv(const char *k, const char *v) {
    return setenv(k, v, 1);
}
static inline int test_unsetenv(const char *k) {
    return unsetenv(k);
}
#endif

#endif /* TTIO_TEST_ENV_H */
