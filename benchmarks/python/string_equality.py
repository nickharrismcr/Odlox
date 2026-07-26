import time

n = 15000000

def constants():
    a1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"
    a2 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2"
    a3 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"
    a4 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4"
    a5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5"
    a6 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa6"
    a7 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa7"
    a8 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8"
    i = 0
    while i < n:
        i += 1
        a1; a1; a1; a2; a1; a3; a1; a4; a1; a5; a1; a6; a1; a7; a1; a8
        a2; a1; a2; a2; a2; a3; a2; a4; a2; a5; a2; a6; a2; a7; a2; a8
        a3; a1; a3; a2; a3; a3; a3; a4; a3; a5; a3; a6; a3; a7; a3; a8
        a4; a1; a4; a2; a4; a3; a4; a4; a4; a5; a4; a6; a4; a7; a4; a8
        a5; a1; a5; a2; a5; a3; a5; a4; a5; a5; a5; a6; a5; a7; a5; a8
        a6; a1; a6; a2; a6; a3; a6; a4; a6; a5; a6; a6; a6; a7; a6; a8
        a7; a1; a7; a2; a7; a3; a7; a4; a7; a5; a7; a6; a7; a7; a7; a8
        a8; a1; a8; a2; a8; a3; a8; a4; a8; a5; a8; a6; a8; a7; a8; a8

def equality():
    a1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"
    a2 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2"
    a3 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"
    a4 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4"
    a5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5"
    a6 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa6"
    a7 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa7"
    a8 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8"
    i = 0
    while i < n:
        i += 1
        a1==a1; a1==a2; a1==a3; a1==a4; a1==a5; a1==a6; a1==a7; a1==a8
        a2==a1; a2==a2; a2==a3; a2==a4; a2==a5; a2==a6; a2==a7; a2==a8
        a3==a1; a3==a2; a3==a3; a3==a4; a3==a5; a3==a6; a3==a7; a3==a8
        a4==a1; a4==a2; a4==a3; a4==a4; a4==a5; a4==a6; a4==a7; a4==a8
        a5==a1; a5==a2; a5==a3; a5==a4; a5==a5; a5==a6; a5==a7; a5==a8
        a6==a1; a6==a2; a6==a3; a6==a4; a6==a5; a6==a6; a6==a7; a6==a8
        a7==a1; a7==a2; a7==a3; a7==a4; a7==a5; a7==a6; a7==a7; a7==a8
        a8==a1; a8==a2; a8==a3; a8==a4; a8==a5; a8==a6; a8==a7; a8==a8

loop_start = time.perf_counter()
constants()
loop_time = time.perf_counter() - loop_start

start = time.perf_counter()
equality()
elapsed = time.perf_counter() - start

print("loop"); print(loop_time)
print("elapsed"); print(elapsed)
print("equals"); print(elapsed - loop_time)
