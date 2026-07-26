import time

class Zoo:
    def __init__(self):
        self.aarvark  = 1
        self.baboon   = 1
        self.cat      = 1
        self.donkey   = 1
        self.elephant = 1
        self.fox      = 1

    def ant(self):    return self.aarvark
    def banana(self): return self.baboon
    def tuna(self):   return self.cat
    def hay(self):    return self.donkey
    def grass(self):  return self.elephant
    def mouse(self):  return self.fox

zoo = Zoo()
total = 0
start = time.perf_counter()
batch = 0
while time.perf_counter() - start < 10:
    for _ in range(10000):
        total += (zoo.ant() + zoo.banana() + zoo.tuna() +
                  zoo.hay() + zoo.grass() + zoo.mouse())
    batch += 1

print(total)
print(batch)
print(time.perf_counter() - start)
