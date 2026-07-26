import time

def list_ops(n):
    total = 0
    i = 0
    while i < n:
        i += 1
        l = []
        l.append(i)
        l.append(i + 1)
        l.append(i + 2)
        l.append(i + 3)
        total += len(l)
        total += l.index(i + 2)
        l.pop(0)
        total += len(l)
    return total

def dict_ops(n):
    total = 0
    i = 0
    while i < n:
        i += 1
        d = {}
        d["a"] = i
        d["b"] = i + 1
        d["c"] = i + 2
        total += d.get("a", 0)
        total += len(list(d.keys()))
        total += d.pop("b")
    return total

def string_ops(n):
    total = 0
    i = 0
    base = "the quick brown fox jumps over the lazy dog"
    parts = ["a", "b", "c", "d"]
    while i < n:
        i += 1
        r = base.replace("fox", "cat")
        total += len(r)
        j = "-".join(parts)
        total += len(j)
    return total

n = 3_000_000

list_start = time.perf_counter()
list_total = list_ops(n)
list_time = time.perf_counter() - list_start

dict_start = time.perf_counter()
dict_total = dict_ops(n)
dict_time = time.perf_counter() - dict_start

string_start = time.perf_counter()
string_total = string_ops(n)
string_time = time.perf_counter() - string_start

print("list")
print(list_time)
print("dict")
print(dict_time)
print("string")
print(string_time)
print("total")
print(list_time + dict_time + string_time)
