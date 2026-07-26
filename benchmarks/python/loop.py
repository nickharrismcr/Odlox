import time

def tight(n):
    i    = 0
    acc  = 0
    f    = 0.0
    facc = 0.0
    while i < n:
        i    += 1
        acc  += i
        f    += 1.0
        facc += f
    return acc

start = time.perf_counter()
print(tight(50_000_000))
print(time.perf_counter() - start)
