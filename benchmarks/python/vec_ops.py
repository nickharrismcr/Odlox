import time

def tight(n):
    a2 = (1.0, 1.0)
    b2 = (2.0, 2.0)
    a3 = (1.0, 1.0, 1.0)
    b3 = (2.0, 2.0, 2.0)
    a4 = (1.0, 1.0, 1.0, 1.0)
    b4 = (2.0, 2.0, 2.0, 2.0)
    i = 0
    while i < n:
        a2 = (a2[0] + b2[0], a2[1] + b2[1])
        a3 = (a3[0] + b3[0], a3[1] + b3[1], a3[2] + b3[2])
        a4 = (a4[0] + b4[0], a4[1] + b4[1], a4[2] + b4[2], a4[3] + b4[3])
        i += 1
    return a2[0] + a3[0] + a4[0]

start = time.perf_counter()
print(tight(5_000_000))
print(time.perf_counter() - start)
