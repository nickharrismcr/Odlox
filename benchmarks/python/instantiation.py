import time

class Foo:
    def __init__(self): pass

start = time.perf_counter()
i = 0
while i < 8000000:
    Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo()
    Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo()
    Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo(); Foo()
    i += 1

print(time.perf_counter() - start)
