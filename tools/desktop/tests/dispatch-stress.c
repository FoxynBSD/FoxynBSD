/* Exercise queues, deadlines and timers before using libdispatch for a UI. */
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static int64_t
elapsed_ns(struct timespec a, struct timespec b)
{
    return (b.tv_sec - a.tv_sec) * 1000000000LL + b.tv_nsec - a.tv_nsec;
}

int
main(void)
{
    dispatch_queue_t global, serial;
    dispatch_group_t group;
    dispatch_semaphore_t signal;
    dispatch_source_t timer;
    struct timespec start, end;
    __block int count = 0, serial_count = 0, bad_order = 0, ticks = 0;
    int i;

    alarm(30);
    global = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    serial = dispatch_queue_create("foxyn.serial", DISPATCH_QUEUE_SERIAL);
    group = dispatch_group_create();
    signal = dispatch_semaphore_create(0);
    if (!global || !serial || !group || !signal)
        return 1;
    clock_gettime(CLOCK_MONOTONIC, &start);
    if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 50000000LL)) == 0)
        return 2;
    clock_gettime(CLOCK_MONOTONIC, &end);
    if (elapsed_ns(start, end) < 35000000LL)
        return 3;
    for (i = 0; i < 1000; i++) {
        dispatch_group_async(group, global, ^{ __atomic_fetch_add(&count, 1, __ATOMIC_RELAXED); });
        int expected = i;
        dispatch_group_async(group, serial, ^{
            if (serial_count != expected) bad_order = 1;
            serial_count++;
        });
    }
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10000000000LL)) != 0 ||
        count != 1000 || serial_count != 1000 || bad_order)
        return 4;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, serial);
    if (!timer) return 5;
    dispatch_source_set_event_handler(timer, ^{
        if (++ticks == 3) dispatch_semaphore_signal(signal);
    });
    clock_gettime(CLOCK_MONOTONIC, &start);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 50000000LL), 50000000LL, 0);
    dispatch_resume(timer);
    if (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 5000000000LL)) != 0)
        return 6;
    clock_gettime(CLOCK_MONOTONIC, &end);
    if (elapsed_ns(start, end) < 120000000LL || elapsed_ns(start, end) > 3000000000LL)
        return 7;
    dispatch_source_cancel(timer);
    dispatch_release(timer);
    dispatch_release(signal);
    dispatch_release(group);
    dispatch_release(serial);
    alarm(0);
    printf("dispatch-stress: ok jobs=2000 timer=%lldms\n", (long long)(elapsed_ns(start, end) / 1000000));
    return 0;
}
