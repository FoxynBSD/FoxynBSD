#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

int main(void)
{
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t g = dispatch_group_create();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_source_t timer;
    struct timespec start, end;
    __block int count = 0;
    int i;
    for (i = 0; i < 128; i++)
        dispatch_group_async(g, q, ^{ __atomic_fetch_add(&count, 1, __ATOMIC_RELAXED); });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 5000000000LL)) != 0 || count != 128) {
        fprintf(stderr, "dispatch-lab: FAIL group %d\n", count);
        return 1;
    }
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!timer) return 1;
    dispatch_source_set_event_handler(timer, ^{ dispatch_semaphore_signal(done); });
    clock_gettime(CLOCK_MONOTONIC, &start);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 100000000), DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(timer);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3000000000LL)) != 0) {
        fputs("dispatch-lab: FAIL timer timeout\n", stderr);
        return 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    int64_t elapsed = (end.tv_sec - start.tv_sec) * 1000000000LL + end.tv_nsec - start.tv_nsec;
    if (elapsed < 80000000LL || elapsed > 2000000000LL) {
        fprintf(stderr, "dispatch-lab: FAIL timer elapsed %lld ns\n", (long long)elapsed);
        return 1;
    }
    printf("dispatch-lab: ok group=128 timer=%lld ms\n", (long long)(elapsed / 1000000));
    dispatch_source_cancel(timer);
    dispatch_release(timer);
    dispatch_release(done);
    dispatch_release(g);
    return 0;
}
