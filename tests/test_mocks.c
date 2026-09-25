/*
 * test_mocks.c — Common mock implementations for test coverage error injection
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int test_fail_malloc = 0;
int test_fail_calloc = 0;
int test_fail_realloc = 0;
int test_fake_null_time = 0;

void* test_mock_malloc(size_t sz) {
    if (test_fail_malloc) return NULL;
    return malloc(sz);
}

void* test_mock_calloc(size_t n, size_t sz) {
    if (test_fail_calloc) return NULL;
    return calloc(n, sz);
}

void* test_mock_realloc(void* ptr, size_t sz) {
    if (test_fail_realloc) return NULL;
    return realloc(ptr, sz);
}

struct tm* test_mock_localtime(const time_t* timep) {
    if (test_fake_null_time) return NULL;
    return localtime(timep);
}
